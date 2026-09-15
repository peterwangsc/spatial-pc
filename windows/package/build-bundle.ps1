param(
    [Parameter(Mandatory=$true)][string]$RuntimeArchive,
    [Parameter(Mandatory=$true)][string]$Wheelhouse,
    [Parameter(Mandatory=$true)][string]$BuildPython,
    [Parameter(Mandatory=$true)][string]$ZeroconfSourceArchive,
    [Parameter(Mandatory=$true)][string]$BoringSSLSource,
    [string]$Version='1.0.0'
)
$ErrorActionPreference='Stop'
if ($Version -notmatch '^\d+\.\d+\.\d+$' -or @($Version.Split('.') | Where-Object {[int]$_ -gt 65534}).Count) { throw 'Expected three numeric version components, each below65535' }
$projectRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$bundleRoot=Join-Path $projectRoot ('.local/bundle-'+(Get-Date -Format 'yyyyMMdd-HHmmss'))
$appRoot=Join-Path $bundleRoot 'app'
if ((Get-FileHash -LiteralPath $RuntimeArchive).Hash -ne 'D297E5FF019966817AD8502465176139F2D3D840FA4ED84B13BED399A6AB1F15') { throw 'Official Python3.14.7 x64 runtime hash mismatch' }
if ((Get-FileHash -LiteralPath $ZeroconfSourceArchive).Hash -ne 'CE6C548E665759B6150CEF4DB9AB9D7BDD89857E90C513ABD6B7340BDD7DBD6A') { throw 'Corresponding zeroconf source hash mismatch' }
New-Item -ItemType Directory -Path $appRoot | Out-Null
Push-Location $projectRoot
try {
    New-Item -ItemType Directory -Path .local/product -Force | Out-Null
    ('using System.Reflection; [assembly: AssemblyVersion("'+$Version+'.0")] [assembly: AssemblyFileVersion("'+$Version+'.0")]') | Set-Content -LiteralPath .local/product/Version.cs -Encoding ASCII
    & cmd /c windows\ui\build.cmd package
    if ($LASTEXITCODE -ne 0) { throw 'Windows UI build failed' }
    & cmd /c windows\host\build.cmd
    if ($LASTEXITCODE -ne 0) { throw 'Native capture build failed' }
    & cmd /c windows\host\build_input.cmd
    if ($LASTEXITCODE -ne 0) { throw 'Native input build failed' }
    $BoringSSLSource=(Resolve-Path -LiteralPath $BoringSSLSource).Path
    & cmd /c windows\pairing\build.cmd $BoringSSLSource
    if ($LASTEXITCODE -ne 0) { throw 'Pinned PAKE build or upstream tests failed' }
    $runtime=Join-Path $appRoot 'runtime'
    Expand-Archive -LiteralPath $RuntimeArchive -DestinationPath $runtime
    & $BuildPython -m pip install --disable-pip-version-check --no-index --find-links $Wheelhouse --require-hashes --only-binary=:all: --python-version 3.14 --implementation cp --abi cp314 --platform win_amd64 --no-compile --target (Join-Path $runtime 'Lib/site-packages') -r windows/package/requirements-win-x64.lock
    if ($LASTEXITCODE -ne 0) { throw 'Isolated runtime dependency installation failed' }
    @('python314.zip','.','Lib/site-packages','../host') | Set-Content -LiteralPath (Join-Path $runtime 'python314._pth') -Encoding Ascii
    New-Item -ItemType Directory -Path (Join-Path $appRoot 'host/product'),(Join-Path $appRoot 'native') | Out-Null
    Copy-Item windows/host/product/*.py -Destination (Join-Path $appRoot 'host/product')
    Copy-Item windows/host/input_protocol.py,windows/host/input_server.py,windows/host/transport_metrics.py -Destination (Join-Path $appRoot 'host')
    Copy-Item .local/product/SpatialPC.exe,windows/package/SpatialPC.exe.config -Destination $appRoot
    Copy-Item windows/ui/SpatialPC.ico -Destination $appRoot
    Copy-Item .local/capture_probe.exe -Destination (Join-Path $appRoot 'native/capture.exe')
    Copy-Item .local/input_bridge.exe -Destination (Join-Path $appRoot 'native/input_bridge.exe')
    Copy-Item .local/spatial_pake.dll -Destination (Join-Path $appRoot 'native/spatial_pake.dll')
    Copy-Item LICENSE -Destination (Join-Path $appRoot 'LICENSE.txt')
    Copy-Item windows/package/THIRD-PARTY-NOTICES.txt -Destination $appRoot
    New-Item -ItemType Directory -Path (Join-Path $appRoot 'source') | Out-Null
    Copy-Item -LiteralPath $ZeroconfSourceArchive -Destination (Join-Path $appRoot 'source/zeroconf-0.151.3.tar.gz')
    Copy-Item shared/pairing/boringssl.lock.json -Destination (Join-Path $appRoot 'source/boringssl.lock.json')
    New-Item -ItemType Directory -Path (Join-Path $appRoot 'licenses/boringssl') | Out-Null
    Copy-Item (Join-Path $BoringSSLSource 'LICENSE') -Destination (Join-Path $appRoot 'licenses/boringssl/LICENSE.txt')
    Copy-Item (Join-Path $BoringSSLSource 'third_party/fiat/LICENSE') -Destination (Join-Path $appRoot 'licenses/boringssl/fiat-LICENSE.txt')
    $files=Get-ChildItem -LiteralPath $appRoot -File -Recurse | ForEach-Object {
        [ordered]@{path=$_.FullName.Substring($appRoot.Length+1).Replace('\','/');bytes=$_.Length;sha256=(Get-FileHash -LiteralPath $_.FullName).Hash.ToLowerInvariant()}
    }
    $manifest=[ordered]@{product='Spatial PC';version=$Version;distribution='unsigned-test';sourceCommit=(git rev-parse HEAD);workingTreeDirty=[bool](git status --porcelain);python='3.14.7';architecture='x64';minimumWindowsBuild=22000;files=@($files)}
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $appRoot 'bundle-manifest.json') -Encoding UTF8
    & (Join-Path $runtime 'python.exe') -I -B -c 'import ssl,cryptography,zeroconf,product.main; from product.pake import library; library()'
    if ($LASTEXITCODE -ne 0) { throw 'Isolated runtime import check failed' }
    Write-Output $bundleRoot
} finally { Pop-Location }
