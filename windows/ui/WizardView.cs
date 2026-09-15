using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

internal sealed class PairingCodeLabel : Label {
    protected override void OnPaint(PaintEventArgs e) {
        e.Graphics.Clear(BackColor);if(Text.Length!=4)return;
        float scale=Font.Size/56f*e.Graphics.DpiX/96f;int gap=(int)(12*scale),card=Math.Min((int)(86*scale),(Width-3*gap)/4),height=(int)(108*scale);
        int left=(Width-4*card-3*gap)/2,top=(Height-height)/2,radius=(int)(14*scale);
        e.Graphics.SmoothingMode=SmoothingMode.AntiAlias;
        for(int i=0;i<4;i++){
            var box=new Rectangle(left+i*(card+gap),top,card,height);
            using(var path=new GraphicsPath())using(var fill=new SolidBrush(Color.FromArgb(242,245,249)))using(var border=new Pen(Color.FromArgb(215,223,234),1.5f*scale)){
                int d=radius*2;path.AddArc(box.Left,box.Top,d,d,180,90);path.AddArc(box.Right-d,box.Top,d,d,270,90);path.AddArc(box.Right-d,box.Bottom-d,d,d,0,90);path.AddArc(box.Left,box.Bottom-d,d,d,90,90);path.CloseFigure();e.Graphics.FillPath(fill,path);e.Graphics.DrawPath(border,path);
            }
            TextRenderer.DrawText(e.Graphics,Text[i].ToString(),Font,box,ForeColor,TextFormatFlags.HorizontalCenter|TextFormatFlags.VerticalCenter|TextFormatFlags.NoPadding);
        }
    }
}

// Passive view: no backend, network, registry, identity, QR generation or input automation.
internal sealed class WizardPage {
    internal string Title="",Detail="",Code="",Footnote="",Primary="",Secondary="";
    internal bool Busy=false,Sensitive=false;
    internal Image Qr;
}

internal sealed class WizardView : UserControl {
    internal readonly Button Primary=new Button(),Secondary=new Button(),Settings=new Button();
    internal readonly ComboBox Network=new ComboBox(),Encoder=new ComboBox();
    internal readonly ListView Devices=new ListView();
    internal readonly CheckBox Startup=new CheckBox();
    internal readonly Button Access=new Button(),Revoke=new Button(),Quit=new Button(),SetupNetwork=new Button(),StartFocus=new Button(),StopFocus=new Button();
    internal readonly Label FocusStatus=new Label();
    readonly Label networkSummary=new Label();
    internal readonly Label Title=new Label(),Detail=new Label(),Code=new PairingCodeLabel(),Footnote=new Label();
    internal readonly PictureBox Qr=new PictureBox();
    readonly Panel page=new Panel();
    readonly FlowLayoutPanel settingsPage=new FlowLayoutPanel();
    readonly Label brand=new Label();
    internal bool InSettings { get; private set; }
    bool sensitive;
#if UI_FIXTURE
    internal float FixtureScale=0;
#endif

    internal WizardView() {
        Dock=DockStyle.Fill;BackColor=Color.White;Font=new Font("Segoe UI",11);AutoScaleMode=AutoScaleMode.Dpi;
        brand.Text="Spatial PC";brand.Font=new Font("Segoe UI",15,FontStyle.Bold);brand.AutoSize=true;Controls.Add(brand);
        Style(Settings,false);Settings.Text="Settings";Controls.Add(Settings);
        page.BackColor=Color.White;Controls.Add(page);
        foreach(var label in new[]{Title,Detail,Code,Footnote}) { label.TextAlign=ContentAlignment.MiddleCenter;label.UseMnemonic=false;page.Controls.Add(label); }
        Title.Font=new Font("Segoe UI",25,FontStyle.Bold);Title.ForeColor=Color.FromArgb(20,27,39);
        Detail.ForeColor=Color.FromArgb(69,77,90);Code.Font=new Font("Segoe UI Semibold",56,FontStyle.Regular);Code.ForeColor=Color.FromArgb(12,18,29);
        Code.AccessibleName="Four-digit pairing code";Footnote.ForeColor=Color.FromArgb(99,108,122);
        Qr.SizeMode=PictureBoxSizeMode.Zoom;Qr.BackColor=Color.White;Qr.AccessibleName="Apple system pairing QR code";page.Controls.Add(Qr);
        Style(Primary,true);Style(Secondary,false);page.Controls.Add(Primary);page.Controls.Add(Secondary);
        settingsPage.FlowDirection=FlowDirection.TopDown;settingsPage.WrapContents=false;settingsPage.AutoScroll=true;settingsPage.Padding=new Padding(12,4,12,24);Controls.Add(settingsPage);
        var heading=new Label{Text="Settings",AutoSize=true,Font=new Font("Segoe UI",23,FontStyle.Bold),Margin=new Padding(0,0,0,22)};settingsPage.Controls.Add(heading);
        AddSettingLabel("Access");Style(Access,false);Access.Width=240;settingsPage.Controls.Add(Access);
        AddSettingLabel("Private network");Network.DropDownStyle=ComboBoxStyle.DropDownList;Network.AccessibleName="Private network";Network.Width=440;settingsPage.Controls.Add(Network);
        networkSummary.AutoSize=true;networkSummary.Margin=new Padding(0,4,0,8);settingsPage.Controls.Add(networkSummary);
        Style(SetupNetwork,false);SetupNetwork.Text="Set up network";SetupNetwork.Width=240;settingsPage.Controls.Add(SetupNetwork);
        AddSettingLabel("Paired devices");Devices.View=View.Details;Devices.HeaderStyle=ColumnHeaderStyle.None;Devices.FullRowSelect=true;Devices.MultiSelect=false;Devices.HideSelection=false;Devices.Width=440;Devices.Height=94;Devices.Columns.Add("Device",410);Devices.AccessibleName="Paired devices";settingsPage.Controls.Add(Devices);
        Style(Revoke,false);Revoke.Text="Revoke device";Revoke.Enabled=false;Revoke.Width=240;settingsPage.Controls.Add(Revoke);
        Startup.Text="Open at sign-in";Startup.AutoSize=true;Startup.Margin=new Padding(0,18,0,14);settingsPage.Controls.Add(Startup);
        {
            AddSettingLabel("Focus");Encoder.DropDownStyle=ComboBoxStyle.DropDownList;Encoder.Width=300;Encoder.AccessibleName="Desktop encoder";
            Encoder.Items.AddRange(new object[]{"Media Foundation","NVENC (preview)"});Encoder.SelectedIndex=0;settingsPage.Controls.Add(Encoder);
            Style(StartFocus,false);StartFocus.Text="Start Focus";StartFocus.Width=240;settingsPage.Controls.Add(StartFocus);
            Style(StopFocus,false);StopFocus.Text="Stop XR Focus";StopFocus.Width=240;settingsPage.Controls.Add(StopFocus);
            FocusStatus.AutoSize=true;FocusStatus.MaximumSize=new Size(440,0);settingsPage.Controls.Add(FocusStatus);
        }
        Style(Quit,false);Quit.Text="Quit Spatial PC";Quit.Width=240;Quit.Margin=new Padding(0,20,0,0);settingsPage.Controls.Add(Quit);
        ShowSettings(false);
    }
    void AddSettingLabel(string text){settingsPage.Controls.Add(new Label{Text=text,AutoSize=true,Font=new Font("Segoe UI",10,FontStyle.Bold),Margin=new Padding(0,12,0,8)});}
    static void Style(Button b,bool primary){b.FlatStyle=FlatStyle.Flat;b.FlatAppearance.BorderSize=0;b.Height=46;b.Font=new Font("Segoe UI",11,primary?FontStyle.Bold:FontStyle.Regular);b.BackColor=primary?Color.FromArgb(31,81,225):Color.FromArgb(242,245,249);b.ForeColor=primary?Color.White:Color.FromArgb(51,64,85);b.UseVisualStyleBackColor=false;b.Cursor=Cursors.Hand;}
    internal void Present(WizardPage value) {
        sensitive=value.Sensitive;if(sensitive)ShowSettings(false);
        Title.Text=value.Title;Detail.Text=value.Detail;Code.Text=value.Code;Footnote.Text=value.Footnote;Footnote.Visible=value.Footnote.Length!=0;
        Code.Visible=value.Code.Length!=0;Qr.Image=value.Qr;Qr.Visible=value.Qr!=null;
        Primary.Text=value.Primary;Primary.Visible=value.Primary.Length!=0;Primary.Enabled=!value.Busy;
        Secondary.Text=value.Secondary;Secondary.Visible=value.Secondary.Length!=0;Secondary.Enabled=true;
        networkSummary.Text=Network.Text;networkSummary.Visible=!Network.Enabled;Network.Visible=Network.Enabled;
        Settings.Enabled=!sensitive;PerformLayout();Invalidate(true);
    }
    internal void ShowSettings(bool show){if(show&&sensitive)return;InSettings=show;page.Visible=!show;settingsPage.Visible=show;Settings.Text=show?"Done":"Settings";PerformLayout();}
    protected override void OnLayout(LayoutEventArgs e) {
        base.OnLayout(e);float scale=DeviceDpi/96f;
#if UI_FIXTURE
        if(FixtureScale>0)scale=FixtureScale;
#endif
        Func<int,int> px=n=>(int)Math.Round(n*scale);int w=ClientSize.Width,h=ClientSize.Height;
        brand.Location=new Point(px(30),px(24));Settings.SetBounds(Math.Max(px(360),w-px(122)),px(18),px(94),px(38));
        page.SetBounds(px(24),px(76),Math.Max(px(300),w-px(48)),Math.Max(px(380),h-px(88)));settingsPage.SetBounds(px(28),px(80),Math.Max(px(300),w-px(56)),Math.Max(px(360),h-px(92)));
        int pw=page.Width,ph=page.Height;
        Title.SetBounds(px(12),px(24),pw-px(24),px(70));Detail.SetBounds(px(24),px(98),pw-px(48),px(Code.Text.Length!=0||Qr.Image!=null?66:100));
        Code.SetBounds(px(8),px(174),pw-px(16),px(142));Footnote.SetBounds(px(20),px(322),pw-px(40),px(32));
        int qr=Math.Min(px(276),Math.Max(px(180),ph-px(276)));Qr.SetBounds((pw-qr)/2,px(166),qr,qr);
        int actionTop=Code.Text.Length!=0||Qr.Image!=null?ph-px(108):Math.Min(ph-px(108),px(282));
        Primary.SetBounds((pw-px(268))/2,actionTop,px(268),px(48));Secondary.SetBounds((pw-px(268))/2,actionTop+px(54),px(268),px(42));
        foreach(Control c in settingsPage.Controls){if(c is ComboBox||c is ListView)c.Width=Math.Max(px(250),settingsPage.ClientSize.Width-px(46));if(c is Button){c.Width=px(240);c.Height=px(46);}}
        Devices.Height=px(94);if(Devices.Columns.Count>0)Devices.Columns[0].Width=Math.Max(px(200),Devices.Width-px(28));
    }
}
