using System;
using System.Threading;
using System.Threading.Tasks;
class FocusCancelTest {
    static void Main(){
        for(int stage=0;stage<7;stage++){
            bool stopped=false;int advanced=0;bool canceled=false;
            using(var entered=new ManualResetEventSlim())using(var release=new ManualResetEventSlim()){
                var gate=new FocusLifecycle(()=>Volatile.Read(ref stopped),()=>true);
                var task=Task.Run(()=>{
                    try{
                        for(int step=0;step<7;step++){
                            int current=step;
                            gate.Call(()=>{if(current==stage){entered.Set();if(!release.Wait(2000))throw new Exception("fixture timeout");}return 1;});
                            advanced++;
                        }
                        throw new Exception("Canceled pipeline completed");
                    }
                    catch(OperationCanceledException){canceled=true;}
                });
                if(!entered.Wait(2000))throw new Exception("fixture never entered");
                Volatile.Write(ref stopped,true);release.Set();
                if(!task.Wait(2000)||!canceled||advanced!=stage)throw new Exception("Late RPC completion advanced lifecycle");
                try{gate.Call(()=>{advanced++;});throw new Exception("Stopped call admitted");}catch(OperationCanceledException){}
                if(advanced!=stage)throw new Exception();
            }
        }
        Console.WriteLine("PASS seven suspended fake-call pipeline boundaries; no advancement after cancellation");
    }
}
