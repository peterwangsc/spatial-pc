using System;
using System.Collections.Generic;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Microsoft.Win32;

internal sealed class HostWindow : Form {
    readonly JavaScriptSerializer json=new JavaScriptSerializer{MaxJsonLength=32768,RecursionLimit=5};
    readonly WizardView view;
    readonly NotifyIcon tray=new NotifyIcon();
    readonly System.Windows.Forms.Timer timer=new System.Windows.Forms.Timer();
    readonly Dictionary<string,string> addresses=new Dictionary<string,string>();
    readonly BlockingCollection<string> outgoing=new BlockingCollection<string>(16);
    readonly bool background,development,fixture;
    string focusPermissionId,focusPermissionName="",authorizedFocusGeneration;
    DateTime focusPermissionUntil=DateTime.MinValue;
    Process worker;
    bool enabled,quitting,configured,networkReady,receivingStatus,firewallReady,pairedDone,focusActive,pairingExpected,focusQrAllowed,focusStopping;
    int deviceCount;
    string pending="",error="",connected="",pairCode="",requestId,requestName="",primaryAction="",secondaryAction="",focusGeneration;
    string attemptNote="";
    string retiredFocusGeneration;
    DateTime pairingUntil=DateTime.MinValue,approvalUntil=DateTime.MinValue,nextNetworkCheck=DateTime.MinValue;
    Bitmap focusBitmap;

    public HostWindow(bool background,bool development):this(background,development,false) {}
    HostWindow(bool background,bool development,bool fixture) {
        this.fixture=fixture;
        this.background=background;this.development=development;
        Text="Spatial PC";ClientSize=new Size(600,650);MinimumSize=new Size(550,620);AutoScaleMode=AutoScaleMode.Dpi;
        Font=new Font("Segoe UI",11);StartPosition=FormStartPosition.CenterScreen;Icon=Icon.ExtractAssociatedIcon(Application.ExecutablePath);
        view=new WizardView();Controls.Add(view);
        view.Primary.Click+=async(s,e)=>await Act(primaryAction);view.Secondary.Click+=async(s,e)=>await Act(secondaryAction);
        view.Settings.Click+=(s,e)=>view.ShowSettings(!view.InSettings);
        view.Network.SelectedIndexChanged+=(s,e)=>{if(configured&&!enabled&&!receivingStatus&&view.Network.SelectedItem!=null){networkReady=false;Send("network","address",addresses[view.Network.SelectedItem.ToString()]);Render();}};
        view.Access.Click+=async(s,e)=>await Act(enabled?"disable":"enable");
        view.SetupNetwork.Click+=async(s,e)=>await ConfigureFirewall();
        view.Devices.SelectedIndexChanged+=(s,e)=>view.Revoke.Enabled=view.Devices.SelectedItems.Count==1;
        view.Revoke.Click+=(s,e)=>ConfirmRevoke((id,name)=>MessageBox.Show(this,"Revoke "+name+"?\nThis disconnects its access.","Spatial PC",MessageBoxButtons.YesNo,MessageBoxIcon.Question)==DialogResult.Yes);
        if(!fixture)using(var key=Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run"))view.Startup.Checked=key!=null&&String.Equals(key.GetValue("SpatialPC") as string,StartupCommand,StringComparison.OrdinalIgnoreCase);
        view.Startup.CheckedChanged+=(s,e)=>SetStartup();view.Quit.Click+=async(s,e)=>await Quit();
        view.Encoder.SelectedIndexChanged+=(s,e)=>{if(!receivingStatus)Send("desktopEncoder","value",view.Encoder.SelectedIndex==1?"nvenc":"mf");};
        view.StartFocus.Click+=(s,e)=>{if(MessageBox.Show(this,"Open Focus pairing for three minutes? Vision Pro uses separate system QR pairing. XR media is not encrypted. Desktop sharing will pause.","Spatial PC",MessageBoxButtons.YesNo,MessageBoxIcon.Warning)==DialogResult.Yes)BeginFocus();};
        view.StopFocus.Click+=(s,e)=>StopFocus();
        tray.Icon=Icon;tray.Text="Spatial PC — access disabled";tray.Visible=!fixture;tray.DoubleClick+=(s,e)=>Reveal();
        var menu=new ContextMenuStrip();menu.Items.Add("Open Spatial PC",null,(s,e)=>Reveal());menu.Items.Add("Disable access",null,(s,e)=>{InvalidateFocus();Send("enable","value",false);});menu.Items.Add("Quit",null,async(s,e)=>await Quit());tray.ContextMenuStrip=menu;
        if(!fixture)Shown+=(s,e)=>{LoadNetworks();firewallReady=development||FirewallPolicy.Configured();StartWorker();Render();if(background)Hide();};
        FormClosing+=async(s,e)=>{if(quitting)return;e.Cancel=true;if(e.CloseReason==CloseReason.WindowsShutDown||e.CloseReason==CloseReason.TaskManagerClosing)await Quit();else{CancelSensitive();Hide();}};
        timer.Interval=1000;timer.Tick+=(s,e)=>Tick();if(!fixture)timer.Start();Render();
    }
    public void Reveal(){if(fixture)return;Show();WindowState=FormWindowState.Normal;Activate();}
    void ConfirmRevoke(Func<string,string,bool> confirm){
        if(view.Devices.SelectedItems.Count!=1)return;
        var selected=view.Devices.SelectedItems[0];string id=Convert.ToString(selected.Tag),name=selected.Text;
        if(confirm(id,name)&&view.Devices.Items.Cast<ListViewItem>().Any(row=>Convert.ToString(row.Tag)==id)){if(focusActive||focusQrAllowed)InvalidateFocus();Send("revoke","deviceId",id);}
    }
    void BeginFocus(){if(focusStopping||focusActive||focusQrAllowed)return;if(focusGeneration!=null)retiredFocusGeneration=focusGeneration;focusGeneration=null;focusQrAllowed=true;view.StartFocus.Enabled=false;Send("startFocus");view.ShowSettings(false);Render();}
    void InvalidateFocus(){focusQrAllowed=false;focusStopping=true;view.StartFocus.Enabled=false;if(focusGeneration!=null||authorizedFocusGeneration!=null)retiredFocusGeneration=focusGeneration??authorizedFocusGeneration;authorizedFocusGeneration=null;ClearFocusQr();}
    void StopFocus(){InvalidateFocus();Send("stopFocus");Send("status");Render();}
    void CancelSensitive(){if(focusPermissionId!=null)FocusPermission(false);if(focusBitmap!=null||focusQrAllowed)StopFocus();if(pairingExpected){pairingExpected=false;Send("cancelPairing");ClearPairing();pending="cancel";}Render();}
    void Tick(){
        if(focusPermissionId!=null&&DateTime.UtcNow>=focusPermissionUntil)FocusPermission(false);
        if(!fixture&&enabled&&!development&&DateTime.UtcNow>=nextNetworkCheck){nextNetworkCheck=DateTime.UtcNow.AddSeconds(5);try{
            if(view.Network.SelectedItem==null||!NetworkPolicy.PrivateAddresses().ContainsValue(addresses[view.Network.SelectedItem.ToString()])){InvalidateFocus();Send("enable","value",false);Fail("Your Private network changed. Choose a network in Settings.");}
        }catch(Exception){InvalidateFocus();Send("enable","value",false);Fail("Check your Private network in Settings.");}}
        if(pairCode.Length!=0&&DateTime.UtcNow>=pairingUntil){pairingExpected=false;Send("cancelPairing");ClearPairing();pending="cancel";Fail("Code expired. Pair the device again.");}
        if(requestId!=null&&DateTime.UtcNow>=approvalUntil){Approve(false);Fail("Approval expired. Pair the device again.");}
        if(pairCode.Length!=0)Render();
    }
    async Task Act(string action){
        if(action=="allowFocus"||action=="denyFocus"){FocusPermission(action=="allowFocus");return;}
        if(action=="settings"){error="";view.ShowSettings(true);Render();return;}
        if(action=="back"||action=="done"){error="";pairedDone=false;Render();return;}
        if(action=="cancel"){pairingExpected=false;Send("cancelPairing");ClearPairing();pending="cancel";Render();return;}
        if(action=="allow"){Approve(true);return;}if(action=="deny"){Approve(false);return;}
        if(action=="stopFocus"){StopFocus();return;}
        if(action=="quit"){await Quit();return;}
        if(pending.Length!=0)return;error="";
        if(action=="setup"){await ConfigureFirewall();return;}
        if(action=="refresh"){LoadNetworks();Render();return;}
        if(action=="enable"){
            if(!networkReady){Fail("Choose a Private network in Settings.");return;}
            if(!fixture&&!development&&!FirewallPolicy.Configured()){Fail(FirewallPolicy.BlockReason()??"Set up network access in Settings.");return;}
            pending="enable";Send("enable","value",true);
        }else if(action=="disable"){CancelSensitive();InvalidateFocus();Send("enable","value",false);}
        else if(action=="pair"&&enabled&&!focusActive){pairedDone=false;pairingExpected=true;pending="pair";Send("pair");}
        Render();
    }
    void Render(){
        var page=new WizardPage();primaryAction="";secondaryAction="";
        if(focusBitmap!=null){page.Title="Scan with Vision Pro";page.Qr=focusBitmap;page.Sensitive=true;page.Secondary="Cancel";secondaryAction="stopFocus";}
        else if(focusPermissionId!=null){page.Title="Allow Focus?";page.Detail=focusPermissionName+"\nUses separate Apple pairing.\nXR media is not encrypted.";page.Primary="Allow Focus";primaryAction="allowFocus";page.Secondary="Deny";secondaryAction="denyFocus";page.Sensitive=true;}
        else if(requestId!=null){page.Title="Allow this device?";page.Detail=requestName+"\nView and control this PC.";page.Sensitive=true;page.Primary="Allow this device";primaryAction="allow";page.Secondary="Deny";secondaryAction="deny";}
        else if(pairCode.Length!=0){page.Title="Enter on Vision Pro";page.Code=pairCode;page.Sensitive=true;int remaining=Math.Max(0,(int)(pairingUntil-DateTime.UtcNow).TotalSeconds);page.Footnote=attemptNote.Length!=0?attemptNote:"Expires in "+remaining/60+":"+(remaining%60).ToString("00");page.Secondary="Cancel";secondaryAction="cancel";}
        else if(error.Length!=0){page.Title="Couldn’t finish";page.Detail=error;page.Primary=worker!=null&&worker.HasExited?"Quit Spatial PC":"Back";primaryAction=page.Primary=="Back"?"back":"quit";}
        else if(pending.Length!=0){page.Title=pending=="approve"?"Adding device…":pending=="pair"?"Getting code…":pending=="cancel"?"Canceling…":pending=="setup"?"Setting up…":"Enabling access…";page.Busy=true;if(pending=="approve"||pending=="pair"){page.Sensitive=true;page.Secondary="Cancel";secondaryAction="cancel";}}
        else if(pairedDone){page.Title="Device added";page.Detail="Ready on Vision Pro";page.Primary="Done";primaryAction="done";}
        else if(!firewallReady){page.Title="Set up your PC";page.Detail="Allow Spatial PC on your Private network.";page.Primary="Set up network";primaryAction="setup";}
        else if(view.Network.Items.Count==0){page.Title="Choose a Private network";page.Detail="Set your network to Private in Windows Settings.";page.Primary="Check again";primaryAction="refresh";}
        else if(!configured||!networkReady){page.Title="Getting ready…";}
        else if(focusActive){page.Title="Focus session";page.Primary="Stop Focus";primaryAction="stopFocus";}
        else if(!enabled){page.Title="Access is off";page.Detail="Allow paired devices to view and control this PC.";page.Primary="Enable access";primaryAction="enable";}
        else if(connected.Length!=0){page.Title="Connected";page.Detail=connected;}
        else{page.Title=deviceCount==0?"Pair your Vision Pro":"Ready";page.Detail=deviceCount==0?"":"Connect from Vision Pro";page.Primary="Pair a new device";primaryAction="pair";}
        view.Access.Text=enabled?"Disable access":"Enable access";view.Access.Enabled=configured&&networkReady&&pending.Length==0;
        view.Network.Enabled=!enabled&&pending.Length==0;view.SetupNetwork.Enabled=!enabled&&pending.Length==0;view.SetupNetwork.Visible=!firewallReady;
        view.Present(page);
    }
    void Fail(string message){if(pending!="cancel")pending="";error=message;view.ShowSettings(false);Render();}
    async Task ConfigureFirewall(){
        if(fixture)throw new InvalidOperationException("Fixture cannot configure the network");
        string issue=FirewallPolicy.BlockReason();if(issue!=null){Fail(issue);return;}pending="setup";Render();
        try{using(var setup=Process.Start(new ProcessStartInfo(Application.ExecutablePath,"--configure-firewall"){UseShellExecute=true,Verb="runas",WindowStyle=ProcessWindowStyle.Hidden})){
            await Task.Run(()=>setup.WaitForExit());firewallReady=setup.ExitCode==0&&FirewallPolicy.Configured();
            if(firewallReady){if(worker==null)StartWorker();}else error=FirewallPolicy.BlockReason()??"Network setup didn’t finish. Try again.";
        }}catch(Exception){error="Network setup was canceled. Try again.";}finally{pending="";view.ShowSettings(false);Render();}
    }
    void LoadNetworks(){
        if(fixture)throw new InvalidOperationException("Fixture cannot enumerate the network");
        addresses.Clear();view.Network.Items.Clear();try{foreach(var entry in NetworkPolicy.PrivateAddresses()){addresses[entry.Key]=entry.Value;view.Network.Items.Add(entry.Key);}}catch(Exception){}
        if(development){addresses["Development loopback"]="127.0.0.1";view.Network.Items.Insert(0,"Development loopback");}if(view.Network.Items.Count>0)view.Network.SelectedIndex=0;
    }
    void StartWorker(){
        if(fixture)throw new InvalidOperationException("Fixture cannot start a backend");
        try{
            string root=AppDomain.CurrentDomain.BaseDirectory;var start=new ProcessStartInfo(Path.Combine(root,"runtime","python.exe"),"-I -B -m product.main"+(development?" --development":"")){
                UseShellExecute=false,CreateNoWindow=true,RedirectStandardInput=true,RedirectStandardOutput=true,RedirectStandardError=true,WorkingDirectory=root,StandardOutputEncoding=Encoding.UTF8,StandardErrorEncoding=Encoding.UTF8};
            worker=new Process{StartInfo=start,EnableRaisingEvents=true};
            worker.OutputDataReceived+=(s,e)=>{if(e.Data==null)return;if(e.Data.Length>32768){Send("shutdown");return;}try{var value=json.Deserialize<Dictionary<string,object>>(e.Data);BeginInvoke(new Action(()=>Receive(value)));}catch(Exception){}};
            worker.ErrorDataReceived+=(s,e)=>{};
            worker.Exited+=(s,e)=>{if(!quitting&&IsHandleCreated)BeginInvoke(new Action(()=>{enabled=false;configured=false;ClearPairing();InvalidateFocus();Fail("Quit and reopen Spatial PC.");}));};
            worker.Start();worker.BeginOutputReadLine();worker.BeginErrorReadLine();
            var sender=new Thread(()=>{try{foreach(string item in outgoing.GetConsumingEnumerable()){worker.StandardInput.WriteLine(item);worker.StandardInput.Flush();}worker.StandardInput.Close();}catch(Exception){try{worker.StandardInput.Close();}catch(Exception){}}});sender.IsBackground=true;sender.Start();
        }catch(Exception){Fail("Repair or reinstall Spatial PC.");}
    }
    void Send(string operation,string field=null,object value=null){var command=new Dictionary<string,object>{{"command",operation}};if(field!=null)command[field]=value;SendObject(command);}
    void SendObject(Dictionary<string,object> value){
#if UI_FIXTURE
        if(fixture){FixtureCommands.Add(value);return;}
#endif
        try{if(worker!=null&&!worker.HasExited&&!outgoing.TryAdd(json.Serialize(value)))Fail("Host is busy. Quit and reopen Spatial PC.");}catch(InvalidOperationException){}
    }
    void Approve(bool accepted){string id=requestId;if(id==null)return;requestId=null;requestName="";bool valid=DateTime.UtcNow<approvalUntil;pending=accepted&&valid?"approve":"cancel";if(!accepted||!valid)pairingExpected=false;SendObject(new Dictionary<string,object>{{"command","approve"},{"requestId",id},{"accepted",accepted&&valid}});Render();}
    void FocusPermission(bool accepted){string id=focusPermissionId;if(id==null)return;focusPermissionId=null;focusPermissionName="";SendObject(new Dictionary<string,object>{{"command","focusPermissionDecision"},{"requestId",id},{"accepted",accepted&&DateTime.UtcNow<focusPermissionUntil}});Render();}
    void ClearPairing(){pairCode="";requestId=null;requestName="";attemptNote="";if(pending=="pair"||pending=="approve")pending="";}
    void ClearFocusQr(){view.Qr.Image=null;var bitmap=focusBitmap;focusBitmap=null;if(bitmap!=null)bitmap.Dispose();}
    void PresentFocusQr(Dictionary<string,object> value){
        bool presented=false;
        try{
            string incoming=Convert.ToString(value["generation"]);
            if(!focusQrAllowed||focusStopping||incoming==retiredFocusGeneration||focusGeneration!=null||(authorizedFocusGeneration!=null&&incoming!=authorizedFocusGeneration)){if(!focusQrAllowed||focusStopping)retiredFocusGeneration=incoming;return;}
            ClearFocusQr();string payload=json.Serialize(new Dictionary<string,object>{{"token",value["token"]},{"digest",value["digest"]}});focusBitmap=FocusQr.Render(payload);payload=null;focusGeneration=incoming;
            ClearPairing();view.ShowSettings(false);Render();Reveal();view.Refresh();presented=Visible&&view.Qr.Visible&&view.Qr.Image!=null;
        }catch(Exception){InvalidateFocus();Fail("QR code unavailable. Try Focus again.");}
        finally{value.Remove("token");value.Remove("digest");SendObject(new Dictionary<string,object>{{"command","focusBarcodeReceipt"},{"requestId",value["requestId"]},{"accepted",presented}});}
    }
    void Receive(Dictionary<string,object> value){
        if(quitting||!value.ContainsKey("event"))return;string kind=Convert.ToString(value["event"]);
        if(kind=="status"){
            receivingStatus=true;
            try{
                string mode=value.ContainsKey("mediaMode")?Convert.ToString(value["mediaMode"]):"idle";focusActive=mode=="focus";
                view.Encoder.Enabled=mode=="idle"&&value.ContainsKey("nvencConfigured")&&Convert.ToBoolean(value["nvencConfigured"]);
                if(view.Encoder.Items.Count>0)view.Encoder.SelectedIndex=value.ContainsKey("desktopEncoder")&&Convert.ToString(value["desktopEncoder"])=="nvenc"?1:0;
                if(value.ContainsKey("focus")){var caps=(Dictionary<string,object>)value["focus"];string phase=Convert.ToString(caps["state"]);if(mode=="idle"&&phase=="idle"&&focusStopping)focusStopping=false;view.StartFocus.Enabled=Convert.ToBoolean(caps["available"])&&view.Network.SelectedItem!=null&&!focusStopping&&!focusQrAllowed;view.StopFocus.Enabled=phase=="starting"||phase=="ready";view.FocusStatus.Text=Convert.ToBoolean(caps["configured"])?"Focus: "+phase:"Focus runtime missing or invalid. Repair Spatial PC to use Focus.";}
                if(!configured&&value.ContainsKey("preferredAddress")){string preferred=Convert.ToString(value["preferredAddress"]);foreach(var entry in addresses)if(entry.Value==preferred){view.Network.SelectedItem=entry.Key;break;}}
                enabled=Convert.ToBoolean(value["enabled"]);configured=true;networkReady=value.ContainsKey("needsNetwork")&&!Convert.ToBoolean(value["needsNetwork"]);
                connected=value.ContainsKey("connected")?Convert.ToString(value["connected"]):"";if(connected.Length>0)pairedDone=false;if(pending=="enable"&&enabled)pending="";
                string selected=view.Devices.SelectedItems.Count==1?Convert.ToString(view.Devices.SelectedItems[0].Tag):null;
                view.Devices.Items.Clear();foreach(var item in (System.Collections.IEnumerable)value["devices"]){var d=(Dictionary<string,object>)item;var row=new ListViewItem(Convert.ToString(d["name"])){Tag=d["id"]};view.Devices.Items.Add(row);if(Convert.ToString(row.Tag)==selected)row.Selected=true;}
                deviceCount=view.Devices.Items.Count;tray.Text=enabled?"Spatial PC — access enabled":"Spatial PC — access disabled";
                if(!enabled){pairingExpected=false;ClearPairing();}if(!networkReady&&view.Network.SelectedItem!=null)Send("network","address",addresses[view.Network.SelectedItem.ToString()]);
            }finally{receivingStatus=false;}
        }else if(kind=="pairingCode"){
            if(!pairingExpected)return;
            string incoming=Convert.ToString(value["code"]);if(incoming.Length!=4||incoming.Any(c=>c<'0'||c>'9')){Send("cancelPairing");ClearPairing();Fail("Pairing code unavailable. Try again.");return;}
            error="";pending="";pairCode=incoming;pairingUntil=DateTime.UtcNow.AddSeconds(Convert.ToInt32(value["expiresSeconds"]));view.ShowSettings(false);Reveal();
        }else if(kind=="approval"){
            if(!pairingExpected)return;
            pairCode="";pending="";error="";requestId=Convert.ToString(value["requestId"]);requestName=Convert.ToString(value["name"]);approvalUntil=DateTime.UtcNow.AddSeconds(Convert.ToInt32(value["expiresSeconds"]));view.ShowSettings(false);Reveal();
        }else if(kind=="paired"){ClearPairing();pairingExpected=false;pairedDone=true;error="";}
        else if(kind=="pairingClosed"){pairingExpected=false;ClearPairing();if(pending=="cancel")pending="";}
        else if(kind=="pairingAttemptFailed"){if(pending=="cancel")return;if(pairCode.Length!=0)attemptNote="Check the code · "+Convert.ToInt32(value["attemptsRemaining"])+" attempts left";else{ClearPairing();Fail("Pairing didn’t finish. Try again.");}}
        else if(kind=="focusPermission"){
            if(focusPermissionId!=null||pairingExpected){SendObject(new Dictionary<string,object>{{"command","focusPermissionDecision"},{"requestId",value["requestId"]},{"accepted",false}});return;}
            focusPermissionId=Convert.ToString(value["requestId"]);focusPermissionName=Convert.ToString(value["name"]);focusPermissionUntil=DateTime.UtcNow.AddSeconds(Convert.ToInt32(value["expiresSeconds"]));view.ShowSettings(false);Reveal();
        }
        else if(kind=="focusPermissionClosed"){if(focusPermissionId==Convert.ToString(value["requestId"])){focusPermissionId=null;focusPermissionName="";}}
        else if(kind=="focusControlStarted"){
            string generation=Convert.ToString(value["generation"]);
            if(!focusStopping&&generation!=retiredFocusGeneration){authorizedFocusGeneration=generation;focusGeneration=null;focusQrAllowed=true;view.ShowSettings(false);}
        }
        else if(kind=="focusControlClosed"){if(authorizedFocusGeneration==Convert.ToString(value["generation"])){InvalidateFocus();focusStopping=false;}}
        else if(kind=="focusBarcode")PresentFocusQr(value);
        else if(kind=="focusBarcodeClosed"){string generation=Convert.ToString(value["generation"]);if(focusGeneration==generation)ClearFocusQr();else if(!focusQrAllowed)retiredFocusGeneration=generation;}
        else if(kind=="focusEnded"){if(focusGeneration==Convert.ToString(value["generation"])){InvalidateFocus();error="Focus ended. Your device is still paired.";}}
        else if(kind=="error"){pairingExpected=false;ClearPairing();if(focusBitmap!=null||focusQrAllowed)StopFocus();Fail(Convert.ToString(value["message"]));}
        Render();
    }
    string StartupCommand{get{return "\""+Application.ExecutablePath+"\" --background";}}
    void SetStartup(){if(fixture)return;try{using(var key=Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run")){if(view.Startup.Checked)key.SetValue("SpatialPC",StartupCommand);else if(String.Equals(key.GetValue("SpatialPC") as string,StartupCommand,StringComparison.OrdinalIgnoreCase))key.DeleteValue("SpatialPC",false);}}catch(Exception){Fail("Couldn’t update the sign-in preference.");}}
    public async Task Quit(){if(quitting)return;quitting=true;InvalidateFocus();timer.Stop();Send("shutdown");outgoing.CompleteAdding();try{if(worker!=null){bool done=await Task.Run(()=>worker.WaitForExit(12000));if(!done)worker.Kill();}}catch(Exception){}tray.Visible=false;tray.Dispose();Close();}
#if UI_FIXTURE
    internal readonly List<Dictionary<string,object>> FixtureCommands=new List<Dictionary<string,object>>();
    internal static HostWindow CreateFixture(){var w=new HostWindow(false,false,true);w.firewallReady=true;w.addresses["Ethernet · 192.0.2.10"]="192.0.2.10";w.view.Network.Items.Add("Ethernet · 192.0.2.10");w.view.Network.SelectedIndex=0;return w;}
    internal WizardView FixtureView{get{return view;}}
    internal void FixtureReceive(Dictionary<string,object> value){Receive(value);}
    internal Task FixtureAct(string action){return Act(action);}
    internal void FixtureExpiry(){pairingUntil=approvalUntil=DateTime.UtcNow.AddSeconds(-1);Tick();}
    internal void FixtureHide(){CancelSensitive();}
    internal void FixtureNetworkSetup(){firewallReady=false;Render();}
    internal void FixtureQr(Dictionary<string,object> value){PresentFocusQr(value);}
    internal void FixtureBeginFocus(){BeginFocus();}
    internal void FixtureRevoke(Func<string,string,bool> confirm){ConfirmRevoke(confirm);}
    internal void FixtureDispose(){ClearFocusQr();timer.Dispose();tray.Dispose();Dispose();}
#endif
}
