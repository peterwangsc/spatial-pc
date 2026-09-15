// Local Windows10+ fixture launcher: atomic job membership before execution.
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;

namespace FoveatedStreaming.WindowsSample {
 internal sealed class ContainedChild : IDisposable {
  [StructLayout(LayoutKind.Sequential)] struct Security { public int length; public IntPtr descriptor; public int inherit; }
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct Startup {
   public int cb; public string reserved, desktop, title;
   public int x,y,xSize,ySize,xChars,yChars,fill,flags; public short show,reserved2;
   public IntPtr reservedBytes,input,output,error;
  }
  [StructLayout(LayoutKind.Sequential)] struct Extended { public Startup startup; public IntPtr attributes; }
  [StructLayout(LayoutKind.Sequential)] struct Info { public IntPtr process,thread; public int pid,tid; }
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool InitializeProcThreadAttributeList(IntPtr list,int count,int flags,ref IntPtr size);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool UpdateProcThreadAttribute(IntPtr list,uint flags,IntPtr attribute,IntPtr value,IntPtr size,IntPtr previous,IntPtr returned);
  [DllImport("kernel32.dll")] static extern void DeleteProcThreadAttributeList(IntPtr list);
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool CreateProcessW(string application,StringBuilder command,IntPtr processSecurity,IntPtr threadSecurity,bool inherit,uint flags,IntPtr environment,string directory,ref Extended startup,out Info info);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool CreatePipe(out IntPtr read,out IntPtr write,ref Security security,int size);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetHandleInformation(IntPtr handle,uint mask,uint flags);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
  [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr handle,uint milliseconds);
  [DllImport("kernel32.dll")] static extern bool TerminateProcess(IntPtr handle,uint code);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool IsProcessInJob(IntPtr process,IntPtr job,out bool result);
  ProcessJobObject job; IntPtr process,input;
  Task stdoutDrain,stderrDrain;
  int disposed;
  public int Id {get;private set;}
  public bool HasExited {get {return process==IntPtr.Zero || WaitForSingleObject(process,0)==0;}}
  public bool WaitForExit(int milliseconds){return process==IntPtr.Zero||WaitForSingleObject(process,(uint)milliseconds)==0;}
  static void Check(bool ok){if(!ok)throw new Win32Exception(Marshal.GetLastWin32Error());}
  static void Close(ref IntPtr h){if(h!=IntPtr.Zero){CloseHandle(h);h=IntPtr.Zero;}}
  static Task Drain(IntPtr read) {
   var handle=new SafeFileHandle(read,true);
   return Task.Run(()=>{
    using(var stream=new FileStream(handle,FileAccess.Read,4096,false)) {
     var buffer=new byte[4096];
     try {while(stream.Read(buffer,0,buffer.Length)>0) { }} catch(IOException) { }
    }
   });
  }
  public static ContainedChild Start(ProcessStartInfo start,Func<ProcessJobObject> makeJob=null) {
   if(start.UseShellExecute||!Path.IsPathRooted(start.FileName))throw new InvalidOperationException("Explicit native child required");
   var child=new ContainedChild();
   IntPtr outRead=IntPtr.Zero,outWrite=IntPtr.Zero,errRead=IntPtr.Zero,errWrite=IntPtr.Zero,inRead=IntPtr.Zero;
   IntPtr attributes=IntPtr.Zero,jobs=IntPtr.Zero,handles=IntPtr.Zero,environment=IntPtr.Zero;
   bool initialized=false;Info created=new Info();
   try {
    child.job=(makeJob??(()=>new ProcessJobObject()))(); // Failure occurs before process creation.
    IntPtr jobHandle=child.job.Handle;
    var security=new Security{length=Marshal.SizeOf(typeof(Security)),inherit=1};
    Check(CreatePipe(out outRead,out outWrite,ref security,4096));Check(SetHandleInformation(outRead,1,0));
    Check(CreatePipe(out errRead,out errWrite,ref security,4096));Check(SetHandleInformation(errRead,1,0));
    Check(CreatePipe(out inRead,out child.input,ref security,4096));Check(SetHandleInformation(child.input,1,0));
    IntPtr size=IntPtr.Zero;InitializeProcThreadAttributeList(IntPtr.Zero,2,0,ref size);
    attributes=Marshal.AllocHGlobal(size);Check(InitializeProcThreadAttributeList(attributes,2,0,ref size));initialized=true;
    jobs=Marshal.AllocHGlobal(IntPtr.Size);Marshal.WriteIntPtr(jobs,jobHandle);
    // PROC_THREAD_ATTRIBUTE_JOB_LIST: failure is fatal; no uncontained fallback.
    Check(UpdateProcThreadAttribute(attributes,0,new IntPtr(0x2000d),jobs,new IntPtr(IntPtr.Size),IntPtr.Zero,IntPtr.Zero));
    handles=Marshal.AllocHGlobal(3*IntPtr.Size);
    Marshal.WriteIntPtr(handles,0,inRead);Marshal.WriteIntPtr(handles,IntPtr.Size,outWrite);Marshal.WriteIntPtr(handles,2*IntPtr.Size,errWrite);
    Check(UpdateProcThreadAttribute(attributes,0,new IntPtr(0x20002),handles,new IntPtr(3*IntPtr.Size),IntPtr.Zero,IntPtr.Zero));
    var entries=start.EnvironmentVariables.Keys.Cast<string>().OrderBy(k=>k,StringComparer.OrdinalIgnoreCase).Select(k=>k+"="+start.EnvironmentVariables[k]);
    environment=Marshal.StringToHGlobalUni(string.Join("\0",entries)+"\0\0");
    var si=new Extended{startup=new Startup{cb=Marshal.SizeOf(typeof(Extended)),flags=0x100,input=inRead,output=outWrite,error=errWrite},attributes=attributes};
    // CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT | EXTENDED_STARTUPINFO_PRESENT.
    bool launched=CreateProcessW(start.FileName,new StringBuilder("\""+start.FileName+"\" "+start.Arguments),IntPtr.Zero,IntPtr.Zero,true,0x08080400,environment,start.WorkingDirectory,ref si,out created);
    child.process=created.process;child.Id=created.pid;Check(launched);Close(ref created.thread);
    bool contained;Check(IsProcessInJob(child.process,jobHandle,out contained));
    if(!contained)throw new InvalidOperationException("Child job containment missing");
    Close(ref outWrite);Close(ref errWrite);Close(ref inRead);
    child.stdoutDrain=Drain(outRead);outRead=IntPtr.Zero;
    child.stderrDrain=Drain(errRead);errRead=IntPtr.Zero;
    return child;
   }catch {child.Dispose();throw;}
   finally {
    Close(ref created.thread);Close(ref outRead);Close(ref outWrite);Close(ref errRead);Close(ref errWrite);Close(ref inRead);
    if(initialized)DeleteProcThreadAttributeList(attributes);
    foreach(var p in new[]{attributes,jobs,handles,environment})if(p!=IntPtr.Zero)Marshal.FreeHGlobal(p);
   }
  }
  public void Dispose() {
   if(Interlocked.Exchange(ref disposed,1)!=0)return;
   bool exitConfirmed=true;
   try {job?.Dispose();} finally {
    Close(ref input);
    if(process!=IntPtr.Zero) {
     if(WaitForSingleObject(process,2000)!=0){TerminateProcess(process,74);exitConfirmed=WaitForSingleObject(process,1000)==0;}
     Close(ref process);
    }
    // Job close kills descendants, including pipe writers; drain tasks own read handles.
    foreach(var task in new[]{stdoutDrain,stderrDrain})if(task!=null)try{task.Wait(1000);}catch(AggregateException){}
   }
   GC.SuppressFinalize(this);
   if(!exitConfirmed)throw new InvalidOperationException("Owned child exit was not confirmed");
  }
  ~ContainedChild(){try{Dispose();}catch{}}
 }
}
