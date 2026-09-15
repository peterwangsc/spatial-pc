using System;
using System.IO;

internal sealed class FocusLifecycle {
    readonly Func<bool> stopped,alive;
    public FocusLifecycle(Func<bool> stopped,Func<bool> alive){this.stopped=stopped;this.alive=alive;}
    public void Check(){
        if(stopped())throw new OperationCanceledException();
        if(!alive())throw new IOException("Owned manager exited");
    }
    public T Call<T>(Func<T> call){Check();T result=call();Check();return result;}
    public void Call(Action call){Call(()=>{call();return true;});}
}
