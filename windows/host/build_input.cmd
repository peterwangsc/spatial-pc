@echo off
setlocal
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul
if errorlevel 1 exit /b %errorlevel%
if not exist .local mkdir .local
cl /nologo /std:c++20 /EHsc /O2 /W4 /DUNICODE /D_UNICODE windows\host\input_bridge.cpp /Fe:.local\input_bridge.exe /Fo:.local\input_bridge.obj /link user32.lib dxgi.lib
exit /b %errorlevel%
