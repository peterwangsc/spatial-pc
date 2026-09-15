using System;
using System.Collections.Generic;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Security.Principal;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Microsoft.Win32;

internal static class Program {
    [STAThread] static void Main(string[] args) {
        Application.EnableVisualStyles(); Application.SetCompatibleTextRenderingDefault(false);
        if(args.Contains("--configure-firewall")||args.Contains("--remove-firewall")){Environment.ExitCode=FirewallPolicy.Configure(args.Contains("--remove-firewall"));return;}
        if(args.Contains("--firewall-present")){Environment.ExitCode=FirewallPolicy.Present()?0:1;return;}
        string sid=WindowsIdentity.GetCurrent().User.Value;
        bool created;
        using(var mutex=new Mutex(true,"Local\\SpatialPC-"+sid,out created))
        using(var activate=new EventWaitHandle(false,EventResetMode.AutoReset,"Local\\SpatialPC-Activate-"+sid))
        using(var quit=new EventWaitHandle(false,EventResetMode.AutoReset,"Local\\SpatialPC-Quit-"+sid)) {
            if(args.Contains("--quit")) {
                if(!created){quit.Set();try{if(!mutex.WaitOne(15000)){Environment.ExitCode=2;return;}}catch(AbandonedMutexException){}mutex.ReleaseMutex();}
                return;
            }
            if(!created) { activate.Set(); return; }
            bool focusDefault=DevelopmentDefaults.FocusEnabled(AppDomain.CurrentDomain.BaseDirectory);
            var window=new HostWindow(args.Contains("--background"),args.Contains("--development"),focusDefault||args.Contains("--xr-development"),focusDefault||args.Contains("--focus-control-development"));
            var registration=ThreadPool.RegisterWaitForSingleObject(activate,(s,t)=>{
                if(window.IsHandleCreated&&!window.IsDisposed)window.BeginInvoke(new Action(window.Reveal));
            },null,Timeout.Infinite,false);
            var quitRegistration=ThreadPool.RegisterWaitForSingleObject(quit,(s,t)=>{
                if(window.IsHandleCreated&&!window.IsDisposed)window.BeginInvoke(new Action(async()=>await window.Quit()));
            },null,Timeout.Infinite,false);
            try { Application.Run(window); } finally { registration.Unregister(null);quitRegistration.Unregister(null); }
        }
    }
}

// Package-local development intent. Availability alone never enables access,
// grants a device permission, opens a QR window, or starts a vendor process.
internal static class DevelopmentDefaults {
    internal static bool FocusEnabled(string root) {
        try {
            string path=Path.Combine(root,"development-defaults.json");
            if(!File.Exists(path)||new FileInfo(path).Length>2048)return false;
            var data=new JavaScriptSerializer{MaxJsonLength=2048,RecursionLimit=3}.Deserialize<Dictionary<string,object>>(File.ReadAllText(path));
            if(data==null||data.Count!=3||!data.ContainsKey("version")||!(data["version"] is int)||(int)data["version"]!=1||
               !data.ContainsKey("focusEnabled")||!(data["focusEnabled"] is bool)||!(bool)data["focusEnabled"]||
               !data.ContainsKey("deploymentSha256")||!(data["deploymentSha256"] is string))return false;
            string deployment=Path.Combine(root,"focus","deployment.json");
            if(!File.Exists(deployment)||new FileInfo(deployment).Length>32768)return false;
            using(var sha=SHA256.Create())using(var stream=File.OpenRead(deployment))
                return String.Equals(BitConverter.ToString(sha.ComputeHash(stream)).Replace("-","").ToLowerInvariant(),(string)data["deploymentSha256"],StringComparison.Ordinal);
        } catch(IOException) {return false;}
          catch(UnauthorizedAccessException) {return false;}
          catch(ArgumentException) {return false;}
          catch(InvalidOperationException) {return false;}
    }
}
