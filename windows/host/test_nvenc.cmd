@echo off
setlocal
if "%~1"=="" exit /b 2
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul
if errorlevel 1 exit /b %errorlevel%
if not exist .local mkdir .local
for %%T in (nvenc_ownership nvenc_config nvenc_deadline) do (
 cl /nologo /std:c++20 /EHsc /W4 /WX /O2 /I"%~f1\Interface" tests\%%T.cpp /Fe:.local\%%T.exe /Fo:.local\%%T.obj
 if errorlevel 1 exit /b 1
 .local\%%T.exe
 if errorlevel 1 exit /b 1
)
