#ifndef BundleDir
  #error BundleDir is required
#endif
#ifndef BuildVersion
  #define BuildVersion "1.0.0"
#endif

[Setup]
AppId={{228B40ED-4384-4671-A6A7-717B87FE061C}
AppName=Spatial PC
AppVersion={#BuildVersion}
AppPublisher=Spatial PC
AppPublisherURL=https://peterwang.tech/spatial-pc
AppSupportURL=https://github.com/peterwangsc/spatial-pc/issues
DefaultDirName={localappdata}\Programs\Spatial PC
DefaultGroupName=Spatial PC
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.22000
WizardStyle=modern
Compression=lzma2
SolidCompression=yes
OutputDir={#BundleDir}\..
OutputBaseFilename=SpatialPC-{#BuildVersion}-win-x64-unsigned-test
UninstallDisplayIcon={app}\SpatialPC.exe
SetupLogging=no
CloseApplications=no
RestartApplications=no
LicenseFile={#BundleDir}\LICENSE.txt

[Files]
Source: "{#BundleDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Spatial PC"; Filename: "{app}\SpatialPC.exe"

[Run]
Filename: "{app}\SpatialPC.exe"; Description: "Open Spatial PC"; Flags: postinstall nowait skipifsilent runasoriginaluser

[UninstallDelete]
Type: filesandordirs; Name: "{app}\host\__pycache__"
Type: filesandordirs; Name: "{app}\host\product\__pycache__"

[Code]
function StopHost(const Folder: String): Boolean;
var ResultCode: Integer;
begin
  Result := True;
  if FileExists(Folder + '\SpatialPC.exe') then
    Result := Exec(Folder + '\SpatialPC.exe', '--quit', Folder, SW_HIDE, ewWaitUntilTerminated, ResultCode) and (ResultCode = 0);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var Framework: Cardinal;
begin
  Result := '';
  if not RegQueryDWordValue(HKLM, 'SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full', 'Release', Framework) or (Framework < 528040) then
    Result := 'Spatial PC requires .NET Framework 4.8, included with supported Windows 11 installations. Run Windows Update first.'
  else if not StopHost(ExpandConstant('{app}')) then
    Result := 'Spatial PC could not stop safely. Quit Spatial PC and retry the update.';
end;

function InitializeUninstall(): Boolean;
var ResultCode: Integer;
begin
  Result := StopHost(ExpandConstant('{app}'));
  if not Result then SuppressibleMsgBox('Quit Spatial PC before uninstalling.', mbError, MB_OK, IDOK);
  if Result and Exec(ExpandConstant('{app}\SpatialPC.exe'), '--firewall-present', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) and (ResultCode = 0) then begin
    Result := ShellExec('runas', ExpandConstant('{app}\SpatialPC.exe'), '--remove-firewall', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) and (ResultCode = 0);
    if not Result then SuppressibleMsgBox('Windows administrator permission is needed to remove the firewall rules for this installation. Uninstall was canceled.', mbError, MB_OK, IDOK);
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var Startup: String;
begin
  if CurUninstallStep = usUninstall then begin
    if RegQueryStringValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Run', 'SpatialPC', Startup) then
      if Pos('"' + ExpandConstant('{app}\SpatialPC.exe') + '"', Startup) = 1 then
        RegDeleteValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Run', 'SpatialPC');
  end;
end;
