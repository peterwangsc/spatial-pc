@echo off
setlocal
if not exist .local\wizard-fixtures mkdir .local\wizard-fixtures
"%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /define:UI_FIXTURE /main:WizardFixtures /target:exe /platform:x64 /optimize+ /out:.local\wizard-fixtures\WizardFixtures.exe /reference:System.Windows.Forms.dll /reference:System.Drawing.dll /reference:System.Web.Extensions.dll /reference:Microsoft.CSharp.dll tests\WizardFixtures.cs windows\ui\HostWindow.cs windows\ui\WizardView.cs windows\ui\FocusQr.cs windows\ui\NetworkPolicy.cs windows\ui\FirewallPolicy.cs
exit /b %errorlevel%
