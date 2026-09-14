@echo off
setlocal
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul
if errorlevel 1 exit /b %errorlevel%
if not exist .local mkdir .local
cl /nologo /std:c++20 /EHsc /O2 /W4 tests\frame_trace.cpp /Fe:.local\frame_trace.exe /Fo:.local\frame_trace.obj
if errorlevel 1 exit /b %errorlevel%
.local\frame_trace.exe
exit /b %errorlevel%
