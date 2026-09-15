@echo off
setlocal
if not exist .local mkdir .local
"C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\MSBuild\Current\Bin\Roslyn\csc.exe" /nologo /target:exe /platform:x64 /optimize+ /warnaserror+ /out:.local\focus_bridge.exe /reference:System.Web.Extensions.dll windows\focus\FocusBridge.cs windows\focus\ContainedChild.cs windows\focus\ProcessJobObject.cs windows\focus\FixturePolicy.cs windows\focus\NvCloudXR.cs
exit /b %errorlevel%
