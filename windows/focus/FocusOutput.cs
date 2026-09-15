using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

internal static class FocusOutput {
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int index);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetStdHandle(int index,IntPtr handle);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool DuplicateHandle(IntPtr source,IntPtr handle,IntPtr target,out IntPtr duplicate,uint access,bool inherit,uint options);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern SafeFileHandle CreateFile(string name,uint access,uint share,IntPtr security,uint disposition,uint flags,IntPtr template);
    [DllImport("ucrtbase.dll",CallingConvention=CallingConvention.Cdecl)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)] static extern IntPtr __acrt_iob_func(uint index);
    [DllImport("ucrtbase.dll",CallingConvention=CallingConvention.Cdecl,CharSet=CharSet.Unicode)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)] static extern int _wfreopen_s(out IntPtr result,string file,string mode,IntPtr stream);
    static SafeFileHandle sink;

    public static StreamWriter PrivatePipe(){
        IntPtr duplicate;
        var process=GetCurrentProcess();
        if(!DuplicateHandle(process,GetStdHandle(-11),process,out duplicate,0,false,2))throw new IOException("Private output unavailable");
        var owned=new SafeFileHandle(duplicate,true);
        try {
            // Preserve a private noninheritable duplicate before replacing both OS
            // handles and cached CRT stdout/stderr. Vendor/native output is discarded.
            sink=CreateFile("NUL",0x40000000,3,IntPtr.Zero,3,0,IntPtr.Zero);
            if(sink.IsInvalid||!SetStdHandle(-11,sink.DangerousGetHandle())||!SetStdHandle(-12,sink.DangerousGetHandle()))throw new IOException("Native output diversion failed");
            for(uint i=1;i<=2;i++){
                IntPtr stream;
                if(_wfreopen_s(out stream,"NUL","w",__acrt_iob_func(i))!=0)throw new IOException("CRT output diversion failed");
            }
            Console.SetOut(TextWriter.Null);Console.SetError(TextWriter.Null);
            return new StreamWriter(new FileStream(owned,FileAccess.Write),new UTF8Encoding(false)){AutoFlush=true};
        } catch {owned.Dispose();throw;}
    }
}
