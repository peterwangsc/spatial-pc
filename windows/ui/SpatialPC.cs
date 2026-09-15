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
            var window=new HostWindow(args.Contains("--background"),args.Contains("--development"));
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
