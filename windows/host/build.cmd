@echo off
setlocal
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul
if errorlevel 1 exit /b %errorlevel%
if not exist .local mkdir .local
set "optimization=/O2 /DNDEBUG"
if /I "%~1"=="debug" set "optimization=/Od /Zi"
set "output=.local\capture_probe.exe"
if not "%~2"=="" set "output=%~2"
cl /nologo /std:c++20 /EHsc /W4 %optimization% /DUNICODE /D_UNICODE windows\host\capture_probe.cpp /Fe:"%output%" /Fo:"%output%.obj" /Fd:"%output%.pdb" /link d3dcompiler.lib d3d11.lib dxgi.lib mf.lib mfplat.lib mfreadwrite.lib mfuuid.lib ole32.lib oleaut32.lib
