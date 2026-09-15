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
    static readonly AutoResetEvent mediaRequested=new AutoResetEvent(false);
    static readonly JavaScriptSerializer Json=new JavaScriptSerializer{MaxJsonLength=8192,RecursionLimit=3};
    static void Check(nv_rpc_result_t result){if(result!=nv_rpc_result_t.NV_RPC_SUCCESS)throw new InvalidOperationException("Focus RPC failed");}
    static string Line(TextReader input){var text=new StringBuilder();for(int i=0;i<=8192;i++){int c=input.Read();if(c<0)return null;if(c==10)return text.ToString();text.Append((char)c);}throw new InvalidDataException("Command too long");}
    static string Field(Dictionary<string,object> data,string key){object value;if(!data.TryGetValue(key,out value)||!(value is string))throw new InvalidDataException("Missing field");return (string)value;}
    static T Bound<T>(Func<T> operation,int ms=10000){using(var timer=new Timer(_=>Environment.Exit(72),null,ms,Timeout.Infinite)){return operation();}}
    static void Bound(Action operation,int ms=10000){Bound(()=>{operation();return true;},ms);}
    public static int Main(){
        ContainedChild manager=null,scene=null;IntPtr rpc=IntPtr.Zero;
        // Private IPC output only; discard managed vendor/sample logging.
        var output=FocusOutput.PrivatePipe();
        int exit=1;
        try {
            // Parent assigns this waiting helper to its kill-on-close job before sending start.
            string line=Line(Console.In);if(line==null)return 0;
            var data=Json.Deserialize<Dictionary<string,object>>(line);
            if(data.Count!=8||Field(data,"command")!="prepare")throw new InvalidDataException("Invalid command");
            string session=Field(data,"sessionId"),client=Field(data,"clientId");
            if(!Regex.IsMatch(session,"\\A[0-9a-f]{32}\\z")||!Regex.IsMatch(client,"\\A[!-~]{1,256}\\z"))throw new InvalidDataException("Invalid system client label");
            var eof=new Thread(()=>{try{
                string next=Line(Console.In);
                if(next==null)return;
                var command=new JavaScriptSerializer{MaxJsonLength=8192,RecursionLimit=3}.Deserialize<Dictionary<string,object>>(next);
                if(command.Count!=1||Field(command,"command")!="startMedia")return;
                mediaRequested.Set();
                Line(Console.In); // Any subsequent command or EOF stops this generation.
            }catch{}finally{stopped=true;mediaRequested.Set();}}){IsBackground=true};eof.Start();
            string manifest=FixturePolicy.ValidateRuntime(Field(data,"manifest"));
            var managerStart=FixturePolicy.Child(Field(data,"manager"),manifest);
            var sceneStart=FixturePolicy.Child(Field(data,"scene"),manifest);
            string config=Path.GetFullPath(Field(data,"runtimeConfig"));
            if(!File.Exists(config)||config.StartsWith(@"\\")||config.IndexOf('"')>=0)throw new InvalidDataException("Invalid runtime configuration");
            string dll=Path.GetFullPath(Field(data,"clientLibrary"));
            if(Path.GetFileName(dll)!="NvStreamManagerClient.dll"||!File.Exists(dll)||dll.StartsWith(@"\\"))throw new InvalidDataException("Invalid library");
            if(Process.GetProcessesByName("NvStreamManager").Length!=0)throw new InvalidOperationException("Existing manager is not owned");
            if(!SetDefaultDllDirectories(0x800|0x400)||AddDllDirectory(Path.GetDirectoryName(dll))==IntPtr.Zero||LoadLibraryEx(dll,IntPtr.Zero,0x100|0x800)==IntPtr.Zero)
                throw new InvalidOperationException("Reviewed library unavailable");
            // Unique pipe isolates this manager from other users/sessions.
            string pipe="spatialpc-focus-"+session;
            managerStart.Arguments="--pipe "+pipe+" --config \""+config+"\"";
            if(stopped)throw new OperationCanceledException();
            manager=ContainedChild.Start(managerStart);
            var lifecycle=new FocusLifecycle(()=>stopped,()=>!manager.HasExited);
            lifecycle.Call(()=>Bound(()=>Check(nv_rpc_client_create(pipe,out rpc)),5000));
            var starting=Stopwatch.StartNew();
            while(true){if(stopped||manager.HasExited)throw new OperationCanceledException();
                var connected=lifecycle.Call(()=>Bound(()=>nv_rpc_client_connect(rpc),3000));
                if(connected==nv_rpc_result_t.NV_RPC_SUCCESS)break;
                if(starting.ElapsedMilliseconds>5000)throw new TimeoutException();Thread.Sleep(50);
            }
            var token=new byte[4096];UIntPtr written=UIntPtr.Zero;
            lifecycle.Call(()=>Bound(()=>Check(nv_rpc_client_set_client_id(rpc,client,(UIntPtr)client.Length,token,(UIntPtr)4096,out written))));
            string tokenText=FocusTrust.Token(token,written);Array.Clear(token,0,token.Length);
            var fingerprint=new StringBuilder(128);
            lifecycle.Call(()=>Bound(()=>Check(nv_rpc_client_get_crypto_key_fingerprint(rpc,nv_crypto_algorithm_t.NV_CRYPTO_ALG_SHA256,fingerprint,(UIntPtr)128))));
            string pin=fingerprint.ToString().ToLowerInvariant();
            if(!Regex.IsMatch(pin,"\\A[0-9a-f]{64}\\z"))throw new InvalidDataException("Invalid trust response");
            lifecycle.Check();
            output.WriteLine(Json.Serialize(new Dictionary<string,object>{{"event","prepared"},{"sessionId",session},{"fingerprint",pin},{"token",tokenText}}));
            tokenText=null;data.Clear();line=null;
            // No runtime or scene until the local system pairing route sends WAITING.
            var pairing=Stopwatch.StartNew();
            while(!mediaRequested.WaitOne(100)){
                if(manager.HasExited)throw new IOException("Owned manager exited");
                if(pairing.Elapsed>TimeSpan.FromSeconds(180))throw new TimeoutException();
            }
            lifecycle.Check();
            lifecycle.Call(()=>Bound(()=>Check(nv_rpc_client_start_cxr_service(rpc,"6.2.3",(UIntPtr)5))));
            var deadline=Stopwatch.StartNew();
            while(true){
                if(stopped||manager.HasExited)throw new OperationCanceledException();
                nv_service_status_t status=lifecycle.Call(()=>Bound(()=>{nv_service_status_t value;Check(nv_rpc_client_get_cxr_service_status(rpc,out value));return value;}));
                if(status.openxr_runtime_running)break;
                if(deadline.ElapsedMilliseconds>10000)throw new TimeoutException();Thread.Sleep(50);
            }
            string actual=lifecycle.Call(()=>Bound(()=>get_cxr_service_json_path(rpc)));FixturePolicy.MatchRuntime(actual,manifest);
            lifecycle.Check();
            scene=ContainedChild.Start(sceneStart);
            lifecycle.Check();
            output.WriteLine(Json.Serialize(new Dictionary<string,object>{{"event","ready"},{"sessionId",session}}));
            // Local-development lease; remote owner/heartbeat wire is not implemented yet.
            var lifetime=Stopwatch.StartNew();
            while(!stopped&&lifetime.Elapsed<TimeSpan.FromMinutes(10)){
                if(manager.HasExited||scene.HasExited)throw new IOException("Owned Focus child exited");
                Thread.Sleep(100);
            }
            exit=0;
        }catch(OperationCanceledException){exit=stopped?0:1;}catch {exit=1;}
        finally {
            // Child tree disposal precedes potentially blocked vendor RPC destruction.
            Bound(()=>{try{if(scene!=null)scene.Dispose();}finally{if(manager!=null)manager.Dispose();}},6000);
            if(rpc!=IntPtr.Zero)Bound(()=>{try{nv_rpc_client_disconnect(rpc);}finally{nv_rpc_client_destroy(rpc);}},2000);
        }
        return exit;
    }
}
