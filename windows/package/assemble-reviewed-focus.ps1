param(
    [Parameter(Mandatory=$true)][string]$BaseApp,
    [Parameter(Mandatory=$true)][string]$BaseManifestSha256,
    [Parameter(Mandatory=$true)][string]$DeploymentSha256,
    [Parameter(Mandatory=$true)][string]$SourceCommit
)
# Compile-only private assembly. Copies only verified manifest entries; never
# executes UI/native/vendor binaries or reads per-user identity/settings.
$ErrorActionPreference='Stop'
$project=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$base=(Resolve-Path -LiteralPath $BaseApp).Path
if($SourceCommit -notmatch '^[0-9a-f]{40}$' -or $BaseManifestSha256 -notmatch '^[0-9a-f]{64}$' -or $DeploymentSha256 -notmatch '^[0-9a-f]{64}$'){throw 'Expected exact source and manifest hashes'}
$manifestPath=Join-Path $base 'bundle-manifest.json'
if((Get-FileHash -LiteralPath $manifestPath).Hash -ne $BaseManifestSha256){throw 'Base manifest hash mismatch'}
$baseline=Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if($baseline.distribution -ne 'unsigned-internal-focus-candidate' -or !$baseline.focusConfigured -or $baseline.workingTreeDirty){throw 'Expected a reviewed clean internal Focus base'}
$deployment=Join-Path $base 'focus/deployment.json'
if((Get-FileHash -LiteralPath $deployment).Hash -ne $DeploymentSha256){throw 'Reviewed deployment hash mismatch'}
$names=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach($entry in $baseline.files){
    if($entry.path -match '(^/|\\|:|(^|/)\.\.(/|$))' -or !$names.Add($entry.path) -or $entry.path -eq 'bundle-manifest.json'){throw 'Unsafe/duplicate base path'}
    $path=Join-Path $base $entry.path
    $item=Get-Item -LiteralPath $path
    if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.Length -ne $entry.bytes -or (Get-FileHash -LiteralPath $path).Hash -ne $entry.sha256){throw ('Changed base entry: '+$entry.path)}
}
$stamp=[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')
New-Item -ItemType Directory -Path (Join-Path $project '.local') -Force | Out-Null
$candidate=Join-Path $project ('.local/focus-integration-'+$stamp)
$export=Join-Path $project ('.local/focus-source-'+$stamp)
$archive=Join-Path $project ('.local/focus-source-'+$stamp+'.zip')
if((Test-Path -LiteralPath $candidate) -or (Test-Path -LiteralPath $export) -or (Test-Path -LiteralPath $archive)){throw 'Output already exists'}
Push-Location $project
try {
    $resolved=git rev-parse ($SourceCommit+'^{commit}')
    if($LASTEXITCODE -ne 0 -or $resolved -ne $SourceCommit){throw 'Source commit unavailable'}
    # This assembly may reuse native files only if their source is unchanged.
    $nativeDiff=git diff --name-only $baseline.sourceCommit $SourceCommit -- 'windows/host/*.cpp' 'windows/host/*.h' windows/focus shared windows/pairing
    if($LASTEXITCODE -ne 0 -or $nativeDiff){throw 'Native source changed: separately build/review native files first'}
    & git archive --format=zip ('--output='+$archive) $SourceCommit
    if($LASTEXITCODE -ne 0){throw 'Source export failed'}
    Expand-Archive -LiteralPath $archive -DestinationPath $export
    Push-Location $export
    try {
        & cmd /c windows\ui\build.cmd
        if($LASTEXITCODE -ne 0){throw 'Reviewed-source UI compilation failed'}
    } finally {Pop-Location}
    New-Item -ItemType Directory -Path $candidate | Out-Null
    foreach($entry in $baseline.files){
        $destination=Join-Path $candidate $entry.path
        New-Item -ItemType Directory -Path (Split-Path $destination) -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $base $entry.path) -Destination $destination
    }
    Copy-Item -LiteralPath (Join-Path $export '.local/product/SpatialPC.exe') -Destination (Join-Path $candidate 'SpatialPC.exe')
    foreach($source in Get-ChildItem -LiteralPath (Join-Path $export 'windows/host/product') -Filter '*.py' -File){
        Copy-Item -LiteralPath $source.FullName -Destination (Join-Path $candidate ('host/product/'+$source.Name))
    }
    foreach($name in @('input_protocol.py','input_server.py','transport_metrics.py')){
        Copy-Item -LiteralPath (Join-Path $export ('windows/host/'+$name)) -Destination (Join-Path $candidate ('host/'+$name))
    }
    # Import/deployment hash verification only; no Worker/Identity construction.
    & (Join-Path $candidate 'runtime/python.exe') -I -B -c 'import pathlib,product.main,product.focus_control;from product.focus import FocusDeployment;p=pathlib.Path(product.main.__file__).resolve().parents[2];FocusDeployment(p,True).load()'
    if($LASTEXITCODE -ne 0){throw 'Assembled import/inventory validation failed'}
    Write-Output 'Reviewed module/import and deployment inventory PASS; no host started'
    $files=@(Get-ChildItem -LiteralPath $candidate -Recurse -File | Sort-Object FullName | ForEach-Object {
        [ordered]@{path=$_.FullName.Substring($candidate.Length+1).Replace('\','/');bytes=$_.Length;sha256=(Get-FileHash -LiteralPath $_.FullName).Hash.ToLowerInvariant()}
    })
    $utf8=New-Object Text.UTF8Encoding $false
    $manifest=[ordered]@{product='Spatial PC';distribution='unsigned-internal-focus-integration';sourceCommit=$SourceCommit;workingTreeDirty=$false;
        nativeAndVendorBaseSource=$baseline.sourceCommit;nativeAndVendorBaseManifest=$BaseManifestSha256;deploymentSha256=$DeploymentSha256;
        desktopDefault='mf';focusConfigured=$true;remoteFocusControlCompiled=$true;remoteFocusControlEnabledByDefault=$false;
        installed=$false;files=$files}
    [IO.File]::WriteAllText((Join-Path $candidate 'bundle-manifest.json'),($manifest|ConvertTo-Json -Depth 6),$utf8)
    # The deployment and every reused native/vendor file must still match base.
    foreach($entry in $baseline.files | Where-Object {$_.path -match '^(native/|focus/)' -or $_.path -eq 'QRCoder.dll'}){
        if((Get-FileHash -LiteralPath (Join-Path $candidate $entry.path)).Hash -ne $entry.sha256){throw 'Reused native/vendor file mismatch'}
    }
    $readiness=[ordered]@{utc=[DateTime]::UtcNow.ToString('o');candidate=$candidate;sourceCommit=$SourceCommit;fileCount=$files.Count;
        bytes=($files|ForEach-Object {$_['bytes']}|Measure-Object -Sum).Sum;manifestSha256=(Get-FileHash -LiteralPath (Join-Path $candidate 'bundle-manifest.json')).Hash.ToLowerInvariant();
        uiSha256=(Get-FileHash -LiteralPath (Join-Path $candidate 'SpatialPC.exe')).Hash.ToLowerInvariant();deploymentSha256=$DeploymentSha256;
        launchArguments=@('--xr-development','--focus-control-development');controlPort=47994;appleLocalPort=55000;signalingPort=48322;
        listenerStarted=$false;installed=$false;identityAccessed=$false;firewallChanged=$false;mediaSecurity='development-only-unencrypted';consumerReady=$false}
    [IO.File]::WriteAllText(($candidate+'-readiness.json'),($readiness|ConvertTo-Json -Depth 5),$utf8)
    $readiness|ConvertTo-Json -Depth 5
} finally {Pop-Location}
