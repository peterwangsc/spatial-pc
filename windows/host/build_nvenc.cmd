@echo off
setlocal
rem Explicit external header; never download or silently use a different SDK.
if "%~1"=="" (
  echo Usage: windows\host\build_nvenc.cmd SDK_ROOT [OUTPUT_EXE]
  exit /b 2
)
set "SPATIALPC_NVENC_HEADER=%~f1\Interface\nvEncodeAPI.h"
powershell -NoProfile -Command "if (!(Test-Path -LiteralPath $env:SPATIALPC_NVENC_HEADER)) {exit 2}; if ((Get-FileHash -Algorithm SHA256 -LiteralPath $env:SPATIALPC_NVENC_HEADER).Hash -ne '4677a397e3ec5300a6b38bf49cba42bb63a922ab26f24bc63a05ed08857cba16') {Write-Error 'Unreviewed NVENC header hash'; exit 3}"
if errorlevel 1 exit /b %errorlevel%
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul
if errorlevel 1 exit /b %errorlevel%
if not exist .local mkdir .local
set "output=.local\capture_nvenc.exe"
if not "%~2"=="" set "output=%~2"
cl /nologo /std:c++20 /EHsc /W4 /O2 /DNDEBUG /DUNICODE /D_UNICODE /DSPATIALPC_ENABLE_NVENC /I"%~f1\Interface" windows\host\capture_probe.cpp /Fe:"%output%" /Fo:"%output%.obj" /Fd:"%output%.pdb" /link d3dcompiler.lib d3d11.lib dxgi.lib mf.lib mfplat.lib mfreadwrite.lib mfuuid.lib ole32.lib oleaut32.lib
