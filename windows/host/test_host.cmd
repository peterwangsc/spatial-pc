@echo off
setlocal
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul
if errorlevel 1 exit /b %errorlevel%
if not exist .local mkdir .local
cl /nologo /std:c++20 /EHsc /O2 /W4 /DUNICODE /D_UNICODE tests\host_resources.cpp /Fe:.local\host_resources.exe /Fo:.local\host_resources.obj /link d3d11.lib dxgi.lib mf.lib mfplat.lib mfuuid.lib ole32.lib
if errorlevel 1 exit /b %errorlevel%
.local\host_resources.exe
if errorlevel 1 exit /b %errorlevel%
cl /nologo /std:c++20 /EHsc /O2 /W4 /DUNICODE /D_UNICODE tests\host_motion.cpp /Fe:.local\host_motion.exe /Fo:.local\host_motion.obj /link d3d11.lib dxgi.lib d3dcompiler.lib user32.lib
exit /b %errorlevel%
