param(
    [Parameter(Mandatory=$true)][string]$BundleDirectory,
    [Parameter(Mandatory=$true)][string]$ISCC
)
$ErrorActionPreference='Stop'
$bundle=(Resolve-Path -LiteralPath $BundleDirectory).Path
$manifest=Get-Content -LiteralPath (Join-Path $bundle 'bundle-manifest.json') -Raw | ConvertFrom-Json
$Version=$manifest.version
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw 'Expected numeric three-part manifest version' }
if ([Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $bundle 'SpatialPC.exe')).FileVersion -ne ($Version+'.0')) { throw 'Application and installer versions differ' }
$expected=@($manifest.files.path)+@('bundle-manifest.json')
foreach ($actual in (Get-ChildItem -LiteralPath $bundle -File -Recurse)) {
    $relative=$actual.FullName.Substring($bundle.Length+1).Replace('\','/')
    if ($relative -notin $expected) { throw ('Unmanifested bundle file: '+$relative) }
}
foreach ($file in $manifest.files) {
    $candidate=[IO.Path]::GetFullPath((Join-Path $bundle $file.path))
    if (-not $candidate.StartsWith($bundle+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid manifest path' }
    if ((Get-FileHash -LiteralPath $candidate).Hash -ne $file.sha256) { throw ('Bundle hash mismatch: '+$file.path) }
}
& $ISCC /Qp ('/DBundleDir='+$bundle) ('/DBuildVersion='+$Version) (Join-Path $PSScriptRoot 'SpatialPC.iss')
if ($LASTEXITCODE -ne 0) { throw 'Installer compilation failed' }
$artifact=Join-Path (Split-Path $bundle) ('SpatialPC-'+$Version+'-win-x64-unsigned-test.exe')
Get-Item -LiteralPath $artifact | Select-Object Name,Length
Write-Output ('SHA256 '+(Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash.ToLowerInvariant())
