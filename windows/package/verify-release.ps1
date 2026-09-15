param(
    [Parameter(Mandatory=$true)][string]$Installer,
    [Parameter(Mandatory=$true)][string]$BundleDirectory,
    [Parameter(Mandatory=$true)][string]$PublisherSubject
)
$ErrorActionPreference='Stop'
if ([string]::IsNullOrWhiteSpace($PublisherSubject)) { throw 'A verified publisher certificate subject is required' }
$bundle=(Resolve-Path -LiteralPath $BundleDirectory).Path
$manifest=Get-Content -LiteralPath (Join-Path $bundle 'bundle-manifest.json') -Raw | ConvertFrom-Json
if ($manifest.workingTreeDirty -or $manifest.sourceCommit -notmatch '^[0-9a-f]{40}$') { throw 'Release requires a clean source commit' }
function Assert-PublisherSignature([string]$Target) {
    $signature=Get-AuthenticodeSignature -LiteralPath $Target
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -ne $PublisherSubject -or $null -eq $signature.TimeStamperCertificate) {
        throw ('Missing valid timestamped publisher signature: '+(Split-Path $Target -Leaf))
    }
}
foreach ($relative in @('SpatialPC.exe','native/capture.exe','native/input_bridge.exe','native/spatial_pake.dll')) {
    Assert-PublisherSignature (Join-Path $bundle $relative)
}
Assert-PublisherSignature (Resolve-Path -LiteralPath $Installer).Path
# Signing changes file bytes. Release engineering must regenerate the inventory
# from the signed payload BEFORE compiling and signing the final installer.
$expected=@($manifest.files.path)+@('bundle-manifest.json')
foreach ($actual in (Get-ChildItem -LiteralPath $bundle -File -Recurse)) {
    $relative=$actual.FullName.Substring($bundle.Length+1).Replace('\','/')
    if ($relative -notin $expected) { throw ('Unmanifested release file: '+$relative) }
}
foreach ($file in $manifest.files) {
    $target=[IO.Path]::GetFullPath((Join-Path $bundle $file.path))
    if (-not $target.StartsWith($bundle+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid manifest path' }
    if ((Get-FileHash -LiteralPath $target).Hash -ne $file.sha256) { throw ('Signed payload manifest mismatch: '+$file.path) }
}
if ($manifest.distribution -ne 'signed-candidate') { throw 'Bundle has not completed signed-candidate preparation' }
[ordered]@{installer=(Split-Path $Installer -Leaf);bytes=(Get-Item -LiteralPath $Installer).Length;
    sha256=(Get-FileHash -LiteralPath $Installer).Hash.ToLowerInvariant();publisher=$PublisherSubject;sourceCommit=$manifest.sourceCommit;
    qualification='Signature and payload checks only; clean-machine and integrated release validation are separate gates.'} | ConvertTo-Json
