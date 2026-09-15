// Spatial PC optional Focus child. No global OpenXR registration or UI automation.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;
using FoveatedStreaming.WindowsSample;
using static FoveatedStreaming.WindowsSample.NvCloudXR;

internal static class FocusBridge {
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetDefaultDllDirectories(uint flags);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr AddDllDirectory(string path);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr LoadLibraryEx(string path,IntPtr file,uint flags);
    static volatile bool stopped;
    static readonly JavaScriptSerializer Json=new JavaScriptSerializer{MaxJsonLength=8192,RecursionLimit=3};
    static void Check(nv_rpc_result_t result){if(result!=nv_rpc_result_t.NV_RPC_SUCCESS)throw new InvalidOperationException("Focus RPC failed");}
    static string Line(TextReader input){var text=new StringBuilder();for(int i=0;i<=8192;i++){int c=input.Read();if(c<0)return null;if(c==10)return text.ToString();text.Append((char)c);}throw new InvalidDataException("Command too long");}
    static string Field(Dictionary<string,object> data,string key){object value;if(!data.TryGetValue(key,out value)||!(value is string))throw new InvalidDataException("Missing field");return (string)value;}
    static T Bound<T>(Func<T> operation,int ms=10000){using(var timer=new Timer(_=>Environment.Exit(72),null,ms,Timeout.Infinite)){return operation();}}
    static void Bound(Action operation,int ms=10000){Bound(()=>{operation();return true;},ms);}
    public static int Main(){
        ContainedChild manager=null,scene=null;IntPtr rpc=IntPtr.Zero;
        // Private IPC output only; discard managed vendor/sample logging.
        var output=new StreamWriter(Console.OpenStandardOutput(),new UTF8Encoding(false)){AutoFlush=true};
        Console.SetOut(TextWriter.Null);Console.SetError(TextWriter.Null);
        int exit=1;
        try {
            // Parent assigns this waiting helper to its kill-on-close job before sending start.
            string line=Line(Console.In);if(line==null)return 0;
            var data=Json.Deserialize<Dictionary<string,object>>(line);
            if(data.Count!=7||Field(data,"command")!="start")throw new InvalidDataException("Invalid command");
            string session=Field(data,"sessionId"),client=Field(data,"clientId");
            if(!Regex.IsMatch(session,"\\A[0-9a-f]{32}\\z")||!Regex.IsMatch(client,"\\A[0-9a-f]{32}\\z"))throw new InvalidDataException("Invalid owner");
            string manifest=FixturePolicy.ValidateRuntime(Field(data,"manifest"));
            var managerStart=FixturePolicy.Child(Field(data,"manager"),manifest);
            var sceneStart=FixturePolicy.Child(Field(data,"scene"),manifest);
            string dll=Path.GetFullPath(Field(data,"clientLibrary"));
            if(Path.GetFileName(dll)!="NvStreamManagerClient.dll"||!File.Exists(dll)||dll.StartsWith(@"\\"))throw new InvalidDataException("Invalid library");
            if(Process.GetProcessesByName("NvStreamManager").Length!=0)throw new InvalidOperationException("Existing manager is not owned");
            if(!SetDefaultDllDirectories(0x800|0x400)||AddDllDirectory(Path.GetDirectoryName(dll))==IntPtr.Zero||LoadLibraryEx(dll,IntPtr.Zero,0x100|0x800)==IntPtr.Zero)
                throw new InvalidOperationException("Reviewed library unavailable");
            // Unique pipe isolates this manager from other users/sessions.
            string pipe="spatialpc-focus-"+session;
            managerStart.Arguments="--pipe "+pipe+" --config \"\"";
            manager=ContainedChild.Start(managerStart);
            var eof=new Thread(()=>{try{while(Line(Console.In)!=null){stopped=true;break;}}catch{}finally{stopped=true;}}){IsBackground=true};eof.Start();
            Bound(()=>Check(nv_rpc_client_create(pipe,out rpc)),5000);
            var starting=Stopwatch.StartNew();
            while(true){if(stopped||manager.HasExited)throw new OperationCanceledException();
                var connected=Bound(()=>nv_rpc_client_connect(rpc),3000);
                if(connected==nv_rpc_result_t.NV_RPC_SUCCESS)break;
                if(starting.ElapsedMilliseconds>5000)throw new TimeoutException();Thread.Sleep(50);
            }
            var token=new StringBuilder(4096);UIntPtr written;
            Bound(()=>Check(nv_rpc_client_set_client_id(rpc,"spatialpc-"+session,(UIntPtr)42,token,(UIntPtr)4096,out written)));
            var fingerprint=new StringBuilder(128);
            Bound(()=>Check(nv_rpc_client_get_crypto_key_fingerprint(rpc,nv_crypto_algorithm_t.NV_CRYPTO_ALG_SHA256,fingerprint,(UIntPtr)128)));
            string pin=fingerprint.ToString().ToLowerInvariant();
            if(!Regex.IsMatch(pin,"\\A[0-9a-f]{64}\\z")||token.Length<1||token.Length>4096)throw new InvalidDataException("Invalid trust response");
            Bound(()=>Check(nv_rpc_client_start_cxr_service(rpc,"6.2.3",(UIntPtr)5)));
            var deadline=Stopwatch.StartNew();
            while(true){
                if(stopped||manager.HasExited)throw new OperationCanceledException();
                nv_service_status_t status=Bound(()=>{nv_service_status_t value;Check(nv_rpc_client_get_cxr_service_status(rpc,out value));return value;});
                if(status.openxr_runtime_running)break;
                if(deadline.ElapsedMilliseconds>10000)throw new TimeoutException();Thread.Sleep(50);
            }
            string actual=Bound(()=>get_cxr_service_json_path(rpc));FixturePolicy.MatchRuntime(actual,manifest);
            scene=ContainedChild.Start(sceneStart);
            output.WriteLine(Json.Serialize(new Dictionary<string,object>{{"event","ready"},{"sessionId",session},{"fingerprint",pin},{"token",token.ToString()}}));
            token.Clear();data.Clear();line=null;
            // Local-development lease; remote owner/heartbeat wire is not implemented yet.
            var lifetime=Stopwatch.StartNew();
            while(!stopped&&lifetime.Elapsed<TimeSpan.FromMinutes(10)){
                if(manager.HasExited||scene.HasExited)throw new IOException("Owned Focus child exited");
                Thread.Sleep(100);
            }
            exit=0;
        }catch {exit=1;}
        finally {
            // Child tree disposal precedes potentially blocked vendor RPC destruction.
            Bound(()=>{try{if(scene!=null)scene.Dispose();}finally{if(manager!=null)manager.Dispose();}},6000);
            if(rpc!=IntPtr.Zero)Bound(()=>{try{nv_rpc_client_disconnect(rpc);}finally{nv_rpc_client_destroy(rpc);}},2000);
        }
        return exit;
    }
}
