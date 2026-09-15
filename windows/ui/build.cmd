@echo off
setlocal
if not exist .local\product mkdir .local\product
set "versionArgs="
if /I "%~1"=="package" set "versionArgs=/define:PACKAGE_VERSION .local\product\Version.cs"
"%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /target:winexe /platform:x64 /optimize+ /win32manifest:windows\ui\app.manifest /win32icon:windows\ui\SpatialPC.ico /out:.local\product\SpatialPC.exe /reference:System.Windows.Forms.dll /reference:System.Drawing.dll /reference:System.Web.Extensions.dll /reference:Microsoft.CSharp.dll %versionArgs% windows\ui\SpatialPC.cs windows\ui\FocusQr.cs windows\ui\NetworkPolicy.cs windows\ui\FirewallPolicy.cs windows\ui\AssemblyInfo.cs
exit /b %errorlevel%
