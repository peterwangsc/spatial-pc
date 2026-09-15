@echo off
setlocal
if "%~1"=="" exit /b 2
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul
if errorlevel 1 exit /b %errorlevel%
set "PATH=C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin;C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja;%PATH%"
cmake -S windows\pairing -B .local\pake-build -G Ninja -DCMAKE_BUILD_TYPE=Release "-DBORINGSSL_SOURCE=%~1"
if errorlevel 1 exit /b %errorlevel%
cmake --build .local\pake-build --target spatial_pake crypto_test --parallel 2
if errorlevel 1 exit /b %errorlevel%
.local\pake-build\boringssl\crypto_test.exe --gtest_filter=SPAKE25519Test.*
if errorlevel 1 exit /b %errorlevel%
copy /y .local\pake-build\spatial_pake.dll .local\spatial_pake.dll >nul
exit /b %errorlevel%
