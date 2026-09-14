@echo off
setlocal
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul
if errorlevel 1 exit /b %errorlevel%
if not exist .local mkdir .local
cl /nologo /std:c++20 /EHsc /O2 /W4 tests\input_engine.cpp /Fe:.local\input_engine.exe /Fo:.local\input_engine.obj
if errorlevel 1 exit /b %errorlevel%
.local\input_engine.exe
if errorlevel 1 exit /b %errorlevel%
set "fixture=.local\input_fixture.exe"
if not "%~1"=="" set "fixture=%~1"
cl /nologo /std:c++20 /EHsc /O2 /W4 tests\input_fixture.cpp /Fe:"%fixture%" /Fo:"%fixture%.obj"
exit /b %errorlevel%
