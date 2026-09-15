// Owned fake process only: no CloudXR, capture, input, D3D or network.
using System;
using System.Diagnostics;
using System.IO;
using System.Threading;
using FoveatedStreaming.WindowsSample;
class FocusProcessTest {
    static int Main(string[] args){
        if(args.Length==1&&args[0]=="--fake-child"){Thread.Sleep(Timeout.Infinite);return 0;}
        string exe=Process.GetCurrentProcess().MainModule.FileName;
        var child=ContainedChild.Start(new ProcessStartInfo(exe,"--fake-child"){UseShellExecute=false,CreateNoWindow=true,WorkingDirectory=Path.GetDirectoryName(exe)});
        using(var process=Process.GetProcessById(child.Id)){
            if(child.HasExited)throw new Exception("Fixture child exited early");
            child.Dispose();
            if(!process.WaitForExit(1000))throw new Exception("Owned child survived disposal");
            child.Dispose();
        }
        Console.WriteLine("PASS owned fake child disposal confirms exit; repeated disposal safe");return 0;
    }
}
