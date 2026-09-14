@echo off
setlocal
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul
if errorlevel 1 exit /b %errorlevel%
if not exist .local mkdir .local
cl /nologo /std:c++20 /EHsc /O2 /W4 /DUNICODE /D_UNICODE tests\input_window.cpp /Fe:.local\input_window.exe /Fo:.local\input_window.obj /link user32.lib gdi32.lib dxgi.lib
exit /b %errorlevel%
