@echo off
setlocal
if not exist .local\product mkdir .local\product
"%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /target:winexe /platform:x64 /optimize+ /win32manifest:windows\ui\app.manifest /out:.local\product\SpatialPC.exe /reference:System.Windows.Forms.dll /reference:System.Drawing.dll /reference:System.Web.Extensions.dll /reference:Microsoft.CSharp.dll windows\ui\SpatialPC.cs
exit /b %errorlevel%
