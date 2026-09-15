// Public synthetic UI/event fixtures only. No backend, identity, registry, network,
// system input or screen capture. DrawToBitmap renders the actual passive controls.
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Linq;
using System.Windows.Forms;

internal static class WizardFixtures {
    static int passed;
    static string output;
    static Dictionary<string,object> D(params object[] values){var d=new Dictionary<string,object>();for(int i=0;i<values.Length;i+=2)d[(string)values[i]]=values[i+1];return d;}
    static void Check(bool condition,string name){if(!condition)throw new Exception(name);passed++;}
    static Dictionary<string,object> Status(bool enabled,int devices=0,string connected=""){
        return D("event","status","enabled",enabled,"needsNetwork",false,"preferredAddress","192.0.2.10","connected",connected,"mediaMode","idle","desktopEncoder","mf","nvencConfigured",true,
            "devices",devices==0?new object[0]:new object[]{D("id",new string('a',32),"name","Example Vision Pro","pairedAt","2026-01-01")},
            "focus",D("state","idle","configured",false,"available",false));
    }
    static HostWindow Ready(){var w=HostWindow.CreateFixture();w.FixtureReceive(Status(true));return w;}
    static void BeginCode(HostWindow w,int seconds=179){w.FixtureAct("pair").GetAwaiter().GetResult();w.FixtureReceive(D("event","pairingCode","code","1234","expiresSeconds",seconds));}
    static Dictionary<string,object> Approval(){return D("event","approval","requestId",new string('b',32),"name","Example Vision Pro","expiresSeconds",45);}
    static void Snapshot(HostWindow w,string name,float scale=1){
        var v=w.FixtureView;w.Controls.Remove(v);v.Dock=DockStyle.None;v.AutoScaleMode=AutoScaleMode.None;v.FixtureScale=scale;
        var all=new List<Control>();Collect(v,all);var fonts=all.Select(c=>c.Font).ToArray();
        if(scale!=1)for(int i=0;i<all.Count;i++)all[i].Font=new Font(fonts[i].FontFamily,fonts[i].Size*scale,fonts[i].Style);
        v.Size=new Size((int)(600*scale),(int)(650*scale));v.CreateControl();foreach(var c in all)c.CreateControl();v.PerformLayout();
        Check(v.Title.Right<=v.Width&&v.Secondary.Bottom<=v.Height,"controls within view");
        if(v.Qr.Image!=null)Check(v.Qr.Bottom<=v.Primary.Top-8*scale,"QR action spacing");
        if(v.Code.Text.Length!=0){Check(v.Code.Font.Size>=56*scale,"code is dominant");Check(v.Code.Text=="1234","only public visual fixture digits");}
        using(var bitmap=new Bitmap(v.Width,v.Height)){v.DrawToBitmap(bitmap,new Rectangle(Point.Empty,v.Size));bitmap.Save(Path.Combine(output,name+".png"),ImageFormat.Png);}
        v.Dispose();w.FixtureDispose();
    }
    static void Collect(Control c,List<Control> result){result.Add(c);foreach(Control child in c.Controls)Collect(child,result);}
    [STAThread] static int Main(string[] args){
        try{
            output=Path.GetFullPath(args[0]);Directory.CreateDirectory(output);Application.EnableVisualStyles();Application.SetCompatibleTextRenderingDefault(false);
            var w=HostWindow.CreateFixture();w.FixtureNetworkSetup();Snapshot(w,"01-network");
            w=HostWindow.CreateFixture();w.FixtureReceive(Status(false));Snapshot(w,"02-access");
            w=Ready();Snapshot(w,"03-pair");
            w=Ready();BeginCode(w);Check(!w.FixtureView.Settings.Enabled,"no hiding active code in settings");Snapshot(w,"04-code");
            w=Ready();BeginCode(w);Snapshot(w,"04-code-150",1.5f);
            w=Ready();BeginCode(w);w.FixtureReceive(D("event","pairingCode","code","0123","expiresSeconds",179));Check(w.FixtureView.Code.Text=="0123","leading zero preserved without screenshot");w.FixtureDispose();
            w=Ready();BeginCode(w);w.FixtureReceive(Approval());Check(w.FixtureView.Code.Text=="","approval clears code");Check(w.FixtureView.Detail.Text.Contains("View and control this PC."),"consent retained");Snapshot(w,"05-approval");
            w=Ready();BeginCode(w);var longApproval=Approval();longApproval["name"]=new string('W',80);w.FixtureReceive(longApproval);Snapshot(w,"05-approval-long-150",1.5f);
            w=Ready();BeginCode(w);w.FixtureReceive(Approval());w.FixtureAct("allow").GetAwaiter().GetResult();w.FixtureAct("allow").GetAwaiter().GetResult();
            Check(w.FixtureCommands.Count(c=>(string)c["command"]=="approve")==1,"allow is single use");
            Check((bool)w.FixtureCommands.Last()["accepted"],"allow emits true");w.FixtureReceive(D("event","paired","deviceId",new string('a',32)));w.FixtureReceive(D("event","pairingClosed"));w.FixtureReceive(Status(true,1));Check(w.FixtureView.Title.Text=="Device added","success survives close/status");Snapshot(w,"06-added");
            w=Ready();w.FixtureReceive(Status(true,1));Snapshot(w,"07-ready");
            w=Ready();w.FixtureReceive(Status(true,1,"Example Vision Pro"));Snapshot(w,"08-connected");
            w=Ready();w.FixtureReceive(Status(true,1));w.FixtureView.ShowSettings(true);Snapshot(w,"09-settings");
            w=Ready();w.FixtureBeginFocus();w.FixtureQr(D("event","focusBarcode","generation","public-generation","requestId","public-request","token","PUBLIC-FIXTURE-NOT-A-CREDENTIAL","digest",new string('0',64)));Check(w.FixtureView.Qr.Image!=null,"public QR rendered");Snapshot(w,"10-apple-qr");
            w=Ready();BeginCode(w);w.FixtureAct("cancel").GetAwaiter().GetResult();w.FixtureReceive(Approval());Check(w.FixtureView.Title.Text!="Allow this device?","late approval ignored after cancel");w.FixtureReceive(D("event","pairingClosed"));Check(w.FixtureView.Code.Text=="","cancel clears digits");w.FixtureDispose();
            w=Ready();BeginCode(w);w.FixtureReceive(Approval());w.FixtureAct("deny").GetAwaiter().GetResult();w.FixtureReceive(D("event","pairingAttemptFailed","attemptsRemaining",2));Check(w.FixtureView.Title.Text=="Canceling…","denial is not an error");w.FixtureReceive(D("event","pairingClosed"));Check(w.FixtureView.Title.Text=="Pair your Vision Pro","denial returns to pair");w.FixtureDispose();
            w=Ready();BeginCode(w);w.FixtureExpiry();int requests=w.FixtureCommands.Count;w.FixtureAct("back").GetAwaiter().GetResult();w.FixtureAct("pair").GetAwaiter().GetResult();Check(w.FixtureCommands.Count==requests,"expiry cannot reopen before close acknowledgement");w.FixtureReceive(D("event","pairingClosed"));w.FixtureAct("pair").GetAwaiter().GetResult();Check(w.FixtureCommands.Count==requests+1,"new pair allowed after close acknowledgement");w.FixtureDispose();
            w=Ready();w.FixtureView.ShowSettings(true);w.FixtureReceive(D("event","error","message","Public fixture recovery"));Check(!w.FixtureView.InSettings,"errors visible from settings");w.FixtureDispose();
            w=Ready();Check(w.FixtureView.Encoder.Parent==null&&w.FixtureView.StartFocus.Parent==null,"runtime controls absent from consumer settings");w.FixtureDispose();
            w=Ready();BeginCode(w);w.FixtureReceive(Approval());w.FixtureExpiry();Check(w.FixtureCommands.Any(c=>(string)c["command"]=="approve"&&!(bool)c["accepted"]),"expired approval denied");Check(w.FixtureView.Primary.Text!="Allow this device","expired approval cannot allow");Snapshot(w,"11-expired");
            w=Ready();BeginCode(w);w.FixtureHide();Check(w.FixtureView.Code.Text=="","hiding window clears code");Check(w.FixtureCommands.Any(c=>(string)c["command"]=="cancelPairing"),"hiding cancels pairing");w.FixtureDispose();
            w=Ready();w.FixtureBeginFocus();w.FixtureQr(D("generation","new","requestId","public","token","PUBLIC-FIXTURE","digest",new string('0',64)));var qr=w.FixtureView.Qr.Image;
            w.FixtureReceive(D("event","focusBarcodeClosed","generation","old"));Check(Object.ReferenceEquals(qr,w.FixtureView.Qr.Image),"stale close preserves current QR");
            w.FixtureReceive(D("event","focusEnded","generation","old"));Check(Object.ReferenceEquals(qr,w.FixtureView.Qr.Image),"stale end preserves current QR");
            w.FixtureReceive(D("event","error","message","Public fixture failure"));Check(w.FixtureView.Qr.Image==null,"error clears QR");Check(w.FixtureCommands.Any(c=>(string)c["command"]=="stopFocus"),"QR error stops owned Focus");w.FixtureDispose();
            foreach(string cancel in new[]{"stopFocus","disable","hide"}){
                w=Ready();w.FixtureBeginFocus();w.FixtureQr(D("generation","canceled","requestId","public","token","PUBLIC-FIXTURE","digest",new string('0',64)));
                if(cancel=="hide")w.FixtureHide();else w.FixtureAct(cancel).GetAwaiter().GetResult();
                w.FixtureQr(D("generation","canceled","requestId","late","token","PUBLIC-FIXTURE","digest",new string('0',64)));
                Check(w.FixtureView.Qr.Image==null,"late QR rejected after "+cancel);Check(!(bool)w.FixtureCommands.Last()["accepted"],"late QR receipt rejected after "+cancel);
                int starts=w.FixtureCommands.Count(c=>(string)c["command"]=="startFocus");w.FixtureBeginFocus();Check(w.FixtureCommands.Count(c=>(string)c["command"]=="startFocus")==starts,"new start waits for idle ack");
                w.FixtureReceive(Status(true));w.FixtureBeginFocus();w.FixtureQr(D("generation","canceled","requestId","old","token","PUBLIC-FIXTURE","digest",new string('0',64)));Check(w.FixtureView.Qr.Image==null,"retired generation still rejected");
                w.FixtureQr(D("generation","fresh","requestId","fresh","token","PUBLIC-FIXTURE","digest",new string('0',64)));Check(w.FixtureView.Qr.Image!=null,"new authorized generation admitted");w.FixtureDispose();
            }
            w=Ready();w.FixtureReceive(Status(true,1));var handle=w.FixtureView.Devices.Handle;w.FixtureView.Devices.Items[0].Selected=true;
            w.FixtureRevoke((id,name)=>{Check(id==new string('a',32)&&name=="Example Vision Pro","revoke captured target");w.FixtureView.Devices.Items[0].Selected=false;var other=new ListViewItem("Other public device"){Tag=new string('c',32)};w.FixtureView.Devices.Items.Add(other);other.Selected=true;return true;});
            Check((string)w.FixtureCommands.Last()["deviceId"]==new string('a',32),"revoke targets captured id after selection change");
            int count=w.FixtureCommands.Count;w.FixtureView.Devices.Items[1].Selected=false;w.FixtureView.Devices.Items[0].Selected=true;w.FixtureRevoke((id,name)=>{w.FixtureView.Devices.Items.Clear();return true;});Check(w.FixtureCommands.Count==count,"disappeared device does not revoke another");w.FixtureDispose();
            File.WriteAllText(Path.Combine(output,"result.txt"),passed+" assertions PASS; public fixture only; no backend/network/input/screenshots.\n");Console.WriteLine(passed+" assertions PASS");return 0;
        }catch(Exception e){Console.Error.WriteLine(e.ToString());return 1;}
    }
}
