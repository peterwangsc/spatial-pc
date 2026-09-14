using System;
using System.Collections.Generic;
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
        string sid=WindowsIdentity.GetCurrent().User.Value;
        bool created;
        using(var mutex=new Mutex(true,"Local\\SpatialPC-"+sid,out created))
        using(var activate=new EventWaitHandle(false,EventResetMode.AutoReset,"Local\\SpatialPC-Activate-"+sid)) {
            if(!created) { activate.Set(); return; }
            var window=new HostWindow(args.Contains("--background"),args.Contains("--development"));
            var registration=ThreadPool.RegisterWaitForSingleObject(activate,(s,t)=>{
                if(window.IsHandleCreated&&!window.IsDisposed)window.BeginInvoke(new Action(window.Reveal));
            },null,Timeout.Infinite,false);
            try { Application.Run(window); } finally { registration.Unregister(null); }
        }
    }
}

internal sealed class HostWindow : Form {
    readonly JavaScriptSerializer json=new JavaScriptSerializer { MaxJsonLength=32768,RecursionLimit=5 };
    readonly Label state=new Label(),details=new Label(),pairHelp=new Label(),approvalText=new Label();
    readonly Button access=new Button(),pair=new Button(),cancelPair=new Button(),revoke=new Button();
    readonly TextBox code=new TextBox(); readonly ComboBox network=new ComboBox();
    readonly ListView devices=new ListView(); readonly Panel approval=new Panel();
    readonly CheckBox startup=new CheckBox(); readonly NotifyIcon tray=new NotifyIcon();
    readonly System.Windows.Forms.Timer timer=new System.Windows.Forms.Timer();
    Process worker; bool enabled=false,quitting=false,configured=false; string requestId=null;
    DateTime pairingUntil=DateTime.MinValue; readonly bool background,development;
    readonly Dictionary<string,string> addresses=new Dictionary<string,string>();
    readonly object commandLock=new object();

    public HostWindow(bool background,bool development) {
        this.background=background;this.development=development;
        Text="Spatial PC";ClientSize=new Size(780,640);MinimumSize=new Size(720,640);
        Font=new Font("Segoe UI",10);AutoScaleMode=AutoScaleMode.Dpi;StartPosition=FormStartPosition.CenterScreen;
        BackColor=Color.FromArgb(247,249,252);Icon=SystemIcons.Application;
        var layout=new TableLayoutPanel { Dock=DockStyle.Fill,Padding=new Padding(24),ColumnCount=1,RowCount=9 };
        Controls.Add(layout);
        state.Text="Starting Spatial PC…";state.Font=new Font(Font.FontFamily,20,FontStyle.Bold);state.AutoSize=true;
        layout.Controls.Add(state);
        details.Text="Share one physical display with your paired Vision Pro.";details.AutoSize=true;details.Margin=new Padding(0,10,0,14);layout.Controls.Add(details);
        var accessRow=new FlowLayoutPanel { AutoSize=true,Dock=DockStyle.Fill,WrapContents=false };
        access.Text="Enable access";access.AutoSize=true;access.Enabled=false;access.Click+=(s,e)=>Send("enable","value",!enabled);
        network.DropDownStyle=ComboBoxStyle.DropDownList;network.Width=380;network.AccessibleName="Private network";
        network.SelectedIndexChanged+=(s,e)=>{ if(configured&&!enabled&&network.SelectedItem!=null)Send("network","address",addresses[network.SelectedItem.ToString()]); };
        accessRow.Controls.Add(access);accessRow.Controls.Add(network);layout.Controls.Add(accessRow);
        var pairRow=new FlowLayoutPanel { AutoSize=true,Dock=DockStyle.Fill,Margin=new Padding(0,16,0,0) };
        pair.Text="Pair a new device";pair.AutoSize=true;pair.Enabled=false;pair.Click+=(s,e)=>Send("pair");
        cancelPair.Text="Cancel pairing";cancelPair.AutoSize=true;cancelPair.Enabled=false;cancelPair.Click+=(s,e)=>Send("cancelPairing");
        pairRow.Controls.Add(pair);pairRow.Controls.Add(cancelPair);layout.Controls.Add(pairRow);
        var codeRow=new TableLayoutPanel { AutoSize=true,Dock=DockStyle.Fill,ColumnCount=1 };
        code.ReadOnly=true;code.Font=new Font("Consolas",17);code.Dock=DockStyle.Top;code.Visible=false;code.AccessibleName="One-time pairing code";
        pairHelp.Text="On Vision Pro, choose this PC and enter the one-time code. Then approve here.";pairHelp.AutoSize=true;pairHelp.MaximumSize=new Size(700,0);pairHelp.Margin=new Padding(0,8,0,12);
        codeRow.Controls.Add(code);codeRow.Controls.Add(pairHelp);layout.Controls.Add(codeRow);
        approval.Height=84;approval.Dock=DockStyle.Fill;approval.BackColor=Color.FromArgb(225,236,250);approval.Visible=false;
        approvalText.SetBounds(10,7,660,28);approval.Controls.Add(approvalText);
        var allow=new Button { Text="Allow this device",AutoSize=true,Left=10,Top=40 };
        var deny=new Button { Text="Deny",AutoSize=true,Left=175,Top=40 };
        allow.Click+=(s,e)=>Approve(true);deny.Click+=(s,e)=>Approve(false);approval.Controls.Add(allow);approval.Controls.Add(deny);layout.Controls.Add(approval);
        devices.View=View.Details;devices.FullRowSelect=true;devices.MultiSelect=false;devices.Height=140;devices.Dock=DockStyle.Fill;
        devices.Columns.Add("Paired device",430);devices.Columns.Add("Paired",210);devices.AccessibleName="Paired devices";
        devices.SelectedIndexChanged+=(s,e)=>revoke.Enabled=devices.SelectedItems.Count==1;layout.Controls.Add(devices);
        var deviceRow=new FlowLayoutPanel { AutoSize=true,Dock=DockStyle.Fill };
        revoke.Text="Revoke selected device";revoke.AutoSize=true;revoke.Enabled=false;
        revoke.Click+=(s,e)=>{ if(devices.SelectedItems.Count==1&&MessageBox.Show(this,"Revoke this device and disconnect its access?","Spatial PC",MessageBoxButtons.YesNo,MessageBoxIcon.Question)==DialogResult.Yes)Send("revoke","deviceId",devices.SelectedItems[0].Tag); };
        startup.Text="Open Spatial PC when I sign in";startup.AutoSize=true;startup.Margin=new Padding(20,7,0,0);
        using(var key=Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run"))startup.Checked=key!=null&&key.GetValue("SpatialPC")!=null;
        startup.CheckedChanged+=(s,e)=>SetStartup();deviceRow.Controls.Add(revoke);deviceRow.Controls.Add(startup);layout.Controls.Add(deviceRow);
        var footer=new Label { AutoSize=true,MaximumSize=new Size(700,0),ForeColor=Color.DimGray,Text="Closing this window keeps Spatial PC in the notification area. Quit there to stop access. Keyboard navigation on Vision Pro requires Full Keyboard Access to be off." };
        layout.Controls.Add(footer);
        tray.Icon=Icon;tray.Text="Spatial PC — access disabled";tray.Visible=true;tray.DoubleClick+=(s,e)=>Reveal();
        var menu=new ContextMenuStrip();menu.Items.Add("Open Spatial PC",null,(s,e)=>Reveal());menu.Items.Add("Disable access",null,(s,e)=>Send("enable","value",false));menu.Items.Add("Quit",null,async(s,e)=>await Quit());tray.ContextMenuStrip=menu;
        Shown+=(s,e)=>{LoadNetworks();StartWorker();if(background)Hide();};
        FormClosing+=async(s,e)=>{if(quitting)return;e.Cancel=true;if(e.CloseReason==CloseReason.WindowsShutDown||e.CloseReason==CloseReason.TaskManagerClosing)await Quit();else Hide();};
        timer.Interval=1000;timer.Tick+=(s,e)=>{
            if(code.Visible){int remaining=Math.Max(0,(int)(pairingUntil-DateTime.UtcNow).TotalSeconds);pairHelp.Text="Enter this code on Vision Pro. Expires in "+remaining+" seconds. Approve the request here.";if(remaining==0)ClearPairing();}
        };timer.Start();
    }

    public void Reveal(){Show();WindowState=FormWindowState.Normal;Activate();}
    void LoadNetworks(){
        addresses.Clear();network.Items.Clear();
        try {
            var privateAdapters=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            dynamic manager=Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("DCB00C01-570F-4A9B-8D69-199FDBA5723B")));
            foreach(dynamic connection in manager.GetNetworkConnections()) {
                dynamic current=connection.GetNetwork();int category=(int)current.GetCategory();
                if(category==1)privateAdapters.Add(((Guid)connection.GetAdapterId()).ToString());
            }
            foreach(var adapter in NetworkInterface.GetAllNetworkInterfaces())if(adapter.OperationalStatus==OperationalStatus.Up&&privateAdapters.Contains(adapter.Id.Trim('{','}'))) {
                foreach(var address in adapter.GetIPProperties().UnicastAddresses)if(address.Address.AddressFamily==AddressFamily.InterNetwork) {
                    string label=adapter.Name+" · "+address.Address;addresses[label]=address.Address.ToString();network.Items.Add(label);
                }
            }
            if(development){addresses["Development loopback"]="127.0.0.1";network.Items.Add("Development loopback");}
            if(network.Items.Count>0)network.SelectedIndex=0;
        }catch(Exception){details.Text="Set your Wi-Fi or Ethernet network to Private in Windows Settings, then reopen Spatial PC.";}
    }
    void StartWorker(){
        try {
            string root=AppDomain.CurrentDomain.BaseDirectory;
            string python=Path.Combine(root,"runtime","python.exe");
            var start=new ProcessStartInfo(python,"-I -m product.main"+(development?" --development":"")) {
                UseShellExecute=false,CreateNoWindow=true,RedirectStandardInput=true,RedirectStandardOutput=true,RedirectStandardError=true,WorkingDirectory=root,StandardOutputEncoding=Encoding.UTF8,StandardErrorEncoding=Encoding.UTF8 };
            worker=new Process { StartInfo=start,EnableRaisingEvents=true };
            worker.OutputDataReceived+=(s,e)=>{if(e.Data==null)return;if(e.Data.Length>32768){Send("shutdown");return;}try{var value=json.Deserialize<Dictionary<string,object>>(e.Data);BeginInvoke(new Action(()=>Receive(value)));}catch(Exception){}};
            worker.ErrorDataReceived+=(s,e)=>{}; // Backend does not emit secrets; never retain arbitrary stderr.
            worker.Exited+=(s,e)=>{if(!quitting&&IsHandleCreated)BeginInvoke(new Action(()=>{enabled=false;state.Text="Access stopped";details.Text="Spatial PC stopped safely. Quit and reopen to try again.";access.Enabled=false;pair.Enabled=false;ClearPairing();}));};
            worker.Start();worker.BeginOutputReadLine();worker.BeginErrorReadLine();
        }catch(Exception){state.Text="Spatial PC could not start";details.Text="Repair the installation or reinstall Spatial PC.";}
    }
    void Send(string operation,string field=null,object value=null){
        var command=new Dictionary<string,object>{{"command",operation}};if(field!=null)command[field]=value;
        SendObject(command);
    }
    void SendObject(Dictionary<string,object> value){
        try{lock(commandLock){if(worker!=null&&!worker.HasExited){worker.StandardInput.WriteLine(json.Serialize(value));worker.StandardInput.Flush();}}}catch(IOException){}
    }
    void Approve(bool value){if(requestId!=null)SendObject(new Dictionary<string,object>{{"command","approve"},{"requestId",requestId},{"accepted",value}});approval.Visible=false;requestId=null;}
    void ClearPairing(){code.Text="";code.Visible=false;cancelPair.Enabled=false;approval.Visible=false;requestId=null;pair.Enabled=enabled;pairHelp.Text="Pair only with a device you trust to view and control this PC.";}
    void Receive(Dictionary<string,object> value){
        if(quitting||!value.ContainsKey("event"))return;
        string kind=Convert.ToString(value["event"]);
        if(kind=="status") {
            enabled=Convert.ToBoolean(value["enabled"]);configured=true;access.Enabled=network.Items.Count>0;
            access.Text=enabled?"Disable access":"Enable access";network.Enabled=!enabled;pair.Enabled=enabled&&!code.Visible;
            string connected=value.ContainsKey("connected")?Convert.ToString(value["connected"]):"";
            state.Text=enabled?(connected.Length>0?"Connected to "+connected:"Ready for your Vision Pro"):"Access disabled";
            details.Text=Convert.ToString(value["message"]);tray.Text=enabled?"Spatial PC — access enabled":"Spatial PC — access disabled";
            devices.Items.Clear();foreach(var item in (System.Collections.ArrayList)value["devices"]){var device=(Dictionary<string,object>)item;var row=new ListViewItem(Convert.ToString(device["name"])){Tag=device["id"]};row.SubItems.Add(Convert.ToString(device["pairedAt"]));devices.Items.Add(row);}
            if(!enabled)ClearPairing();
            if(value.ContainsKey("needsNetwork")&&Convert.ToBoolean(value["needsNetwork"])&&network.SelectedItem!=null)Send("network","address",addresses[network.SelectedItem.ToString()]);
        } else if(kind=="pairingCode") {
            code.Text=Convert.ToString(value["code"]);code.Visible=true;pair.Enabled=false;cancelPair.Enabled=true;pairingUntil=DateTime.UtcNow.AddSeconds(Convert.ToInt32(value["expiresSeconds"]));Reveal();
        } else if(kind=="approval") {
            code.Text="";code.Visible=false;requestId=Convert.ToString(value["requestId"]);approvalText.Text="Allow "+Convert.ToString(value["name"])+" to view and control this PC?";approval.Visible=true;Reveal();
        } else if(kind=="pairingClosed")ClearPairing();
        else if(kind=="error")details.Text=Convert.ToString(value["message"]);
    }
    void SetStartup(){try{using(var key=Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run")){if(startup.Checked)key.SetValue("SpatialPC","\""+Application.ExecutablePath+"\" --background");else key.DeleteValue("SpatialPC",false);}}catch(Exception){MessageBox.Show(this,"Windows could not update the sign-in preference.","Spatial PC");}}
    async Task Quit(){if(quitting)return;quitting=true;timer.Stop();Send("shutdown");try{if(worker!=null){worker.StandardInput.Close();bool done=await Task.Run(()=>worker.WaitForExit(12000));if(!done)worker.Kill();}}catch(Exception){}tray.Visible=false;tray.Dispose();Close();}
}
