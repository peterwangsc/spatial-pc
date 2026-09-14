@echo off
setlocal
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul
if errorlevel 1 exit /b %errorlevel%
if not exist .local mkdir .local
cl /nologo /std:c++20 /EHsc /W4 /DUNICODE /D_UNICODE windows\host\capture_probe.cpp /Fe:.local\capture_probe.exe /Fo:.local\capture_probe.obj /link d3dcompiler.lib d3d11.lib dxgi.lib mf.lib mfplat.lib mfreadwrite.lib mfuuid.lib ole32.lib
