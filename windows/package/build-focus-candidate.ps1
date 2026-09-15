param(
    [Parameter(Mandatory=$true)][string]$BaseApp,
    [Parameter(Mandatory=$true)][string]$NvencHeaderRoot
)
$ErrorActionPreference='Stop'
$project=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$base=(Resolve-Path -LiteralPath $BaseApp).Path
$manifest=Get-Content -LiteralPath (Join-Path $base 'bundle-manifest.json') -Raw | ConvertFrom-Json
if($manifest.sourceCommit -ne '94cef1bb072bbf6952464d7751ec69ba41fda8e6' -or $manifest.files.Count -ne 325){throw 'Expected preserved consumer1.0.1 source94cef1b manifest'}
# Read only the manifest-listed base files. Never copy identities, uninstallers,
# session logs, arbitrary extra DLLs or credentials from an installed directory.
$listed=@()
foreach($entry in $manifest.files){
    if($entry.path -match '(^/|\\|:|(^|/)\.\.(/|$))'){throw 'Unsafe base manifest path'}
    $source=Join-Path $base $entry.path
    $actual=Get-Item -LiteralPath $source
    if($actual.Length -ne $entry.bytes -or (Get-FileHash -LiteralPath $source).Hash -ne $entry.sha256){throw ('Base file changed: '+$entry.path)}
    $listed+=$entry.path
}
$destination=Join-Path $project ('.local/focus-candidate-'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))
if(Test-Path -LiteralPath $destination){throw 'Candidate directory already exists'}
New-Item -ItemType Directory -Path $destination | Out-Null
Push-Location $project
try {
    & cmd /c windows\ui\build.cmd
    if($LASTEXITCODE -ne 0){throw 'UI build failed'}
    & cmd /c windows\focus\build.cmd
    if($LASTEXITCODE -ne 0){throw 'Focus bridge build failed'}
    & cmd /c windows\host\build_nvenc.cmd $NvencHeaderRoot
    if($LASTEXITCODE -ne 0){throw 'Optional NVENC build failed'}
    foreach($relative in $listed){
        $target=Join-Path $destination $relative
        New-Item -ItemType Directory -Path (Split-Path $target) -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $base $relative) -Destination $target
    }
    Copy-Item windows/host/product/*.py -Destination (Join-Path $destination 'host/product')
    Copy-Item windows/host/input_server.py -Destination (Join-Path $destination 'host/input_server.py')
    Copy-Item .local/product/SpatialPC.exe -Destination (Join-Path $destination 'SpatialPC.exe')
    Copy-Item .local/focus_bridge.exe,.local/capture_nvenc.exe -Destination (Join-Path $destination 'native')
    New-Item -ItemType Directory -Path (Join-Path $destination 'licenses/apple-streaming-session') -Force | Out-Null
    Copy-Item windows/focus/APPLE-LICENSE.txt -Destination (Join-Path $destination 'licenses/apple-streaming-session/LICENSE.txt')
    Add-Content -LiteralPath (Join-Path $destination 'THIRD-PARTY-NOTICES.txt') -Value "`r`nOptional Focus lifecycle bindings contain Apple StreamingSession MIT source; see licenses/apple-streaming-session/LICENSE.txt. No NVIDIA CloudXR runtime or Stream Manager binaries included."
    # No focus/deployment.json: incomplete runtime/security review stays disabled.
    $files=@(Get-ChildItem -LiteralPath $destination -File -Recurse | ForEach-Object {
        [ordered]@{path=$_.FullName.Substring($destination.Length+1).Replace('\','/');bytes=$_.Length;sha256=(Get-FileHash -LiteralPath $_.FullName).Hash.ToLowerInvariant()}
    })
    [ordered]@{product='Spatial PC';distribution='unsigned-internal-focus-candidate';sourceCommit=(git rev-parse HEAD);workingTreeDirty=[bool](git status --porcelain);baseSource=$manifest.sourceCommit;desktopDefault='mf';focusConfigured=$false;remoteFocusControl=$false;files=$files} |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $destination 'bundle-manifest.json') -Encoding UTF8
    & (Join-Path $destination 'runtime/python.exe') -I -B -c 'import product.main,product.focus,product.media_owner'
    if($LASTEXITCODE -ne 0){throw 'Candidate import validation failed'}
    Write-Output $destination
}finally{Pop-Location}
