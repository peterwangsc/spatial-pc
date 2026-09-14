@echo off
setlocal
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul
if errorlevel 1 exit /b %errorlevel%
if not exist .local mkdir .local
cl /nologo /std:c++20 /EHsc /W4 tests\cursor_gpu.cpp /Fe:.local\cursor_gpu.exe /Fo:.local\cursor_gpu.obj /link d3d11.lib d3dcompiler.lib dxgi.lib
if errorlevel 1 exit /b %errorlevel%
.local\cursor_gpu.exe
