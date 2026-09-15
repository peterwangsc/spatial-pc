param(
    [Parameter(Mandatory=$true)][string]$Candidate,
    [Parameter(Mandatory=$true)][string]$ArtifactRoot,
    [Parameter(Mandatory=$true)][string]$PlainSceneDirectory,
    [Parameter(Mandatory=$true)][string]$QrLibrary
)
# Private internal staging only. No execution, firewall, identity or installation.
$ErrorActionPreference='Stop'
$project=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$candidateRoot=(Resolve-Path -LiteralPath $Candidate).Path
$artifact=(Resolve-Path -LiteralPath $ArtifactRoot).Path
$bundle=Get-Content -LiteralPath (Join-Path $candidateRoot 'bundle-manifest.json') -Raw | ConvertFrom-Json
if($bundle.distribution -ne 'unsigned-internal-focus-candidate'){throw 'Expected internal Focus candidate'}
foreach($entry in $bundle.files){
    $path=Join-Path $candidateRoot $entry.path
    if((Get-Item -LiteralPath $path).Length -ne $entry.bytes -or (Get-FileHash -LiteralPath $path).Hash -ne $entry.sha256){throw 'Candidate changed before staging'}
}
if(Test-Path -LiteralPath (Join-Path $candidateRoot 'focus')){throw 'Focus already staged; preserve that candidate'}
$archives=@{
    'Stream-Manager-6.1.0-win64.zip'='11b13a5b3414094fbaded0cba78844ce1552fc138dfa1f01fe0dee345ac02fe9'
    'CloudXR-6.2.3-Win64-sdk.zip'='1d372ae4b8d98dda16b467707067e506a964f2a2a3054de20d66aab5b752fb31'
}
foreach($name in $archives.Keys){if((Get-FileHash -LiteralPath (Join-Path $artifact $name)).Hash -ne $archives[$name]){throw 'Official archive hash mismatch'}}
if((Get-FileHash -LiteralPath $QrLibrary).Hash -ne '5ae2792c76262943a4e34140bbd64b2aa7d9ed5c5822680c00d9eaa322412680'){throw 'QRCoder1.6.0 net40 mismatch'}
if((Get-FileHash -LiteralPath (Join-Path $PlainSceneDirectory 'StreamingSession-OpenXRSample.exe')).Hash -ne 'ae1691acab8d6e38e9ad4f58797e72c1da7980440122d1ae13b8ce52e686dacb'){throw 'Expected reviewed plain scene build'}
if((Get-FileHash -LiteralPath (Join-Path $PlainSceneDirectory 'openxr_loader.dll')).Hash -ne 'f7d6eb54c79bd923e9f008b81b89d4b0b5893fd33599e9591ff62becba936dac'){throw 'Expected OpenXR.Loader1.0.6.2 x64'}
$focus=Join-Path $candidateRoot 'focus'
New-Item -ItemType Directory -Path (Join-Path $focus 'releases/6.2.3') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $focus 'scene') -Force | Out-Null
# Exact files are verified against their signed archive entries, not a mutable report.
Add-Type -AssemblyName System.IO.Compression.FileSystem
function Copy-ArchiveFile($zip,$name,$destination){
    $entry=$zip.GetEntry($name)
    if($null -eq $entry -or $entry.Length -gt 536870912){throw 'Missing/bounded archive file'}
    $inputStream=$entry.Open()
    try{$outputStream=[IO.File]::Create($destination);try{$inputStream.CopyTo($outputStream)}finally{$outputStream.Dispose()}}finally{$inputStream.Dispose()}
    if($destination -match '\.(exe|dll)$'){
        $signature=Get-AuthenticodeSignature -LiteralPath $destination
        if($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'NVIDIA Corporation'){throw 'NVIDIA signature rejected'}
    }
}
$managerZip=[IO.Compression.ZipFile]::OpenRead((Join-Path $artifact 'Stream-Manager-6.1.0-win64.zip'))
$runtimeZip=[IO.Compression.ZipFile]::OpenRead((Join-Path $artifact 'CloudXR-6.2.3-Win64-sdk.zip'))
try {
    foreach($name in @('NvStreamManager.exe','CloudXrService.exe')){Copy-ArchiveFile $managerZip ('Server/'+$name) (Join-Path $focus $name)}
    Copy-ArchiveFile $managerZip 'SampleClient/NvStreamManagerClient.dll' (Join-Path $focus 'NvStreamManagerClient.dll')
    Copy-ArchiveFile $managerZip 'LICENSE.txt' (Join-Path $focus 'MANAGER-LICENSE.txt')
    foreach($entry in $runtimeZip.Entries){
        if($entry.FullName -notmatch '/' -and ($entry.FullName -match '\.dll$' -or $entry.FullName -in @('openxr_cloudxr.json','VERSION','LICENSE.txt'))){
            Copy-ArchiveFile $runtimeZip $entry.FullName (Join-Path (Join-Path $focus 'releases/6.2.3') $entry.FullName)
        }
    }
}finally{$managerZip.Dispose();$runtimeZip.Dispose()}
Copy-Item -LiteralPath (Join-Path $PlainSceneDirectory 'StreamingSession-OpenXRSample.exe') -Destination (Join-Path $focus 'scene/SpatialPC.FocusScene.exe')
Copy-Item -LiteralPath (Join-Path $PlainSceneDirectory 'openxr_loader.dll') -Destination (Join-Path $focus 'scene/openxr_loader.dll')
Copy-Item -LiteralPath (Join-Path $project 'windows/focus/runtime-development.yaml') -Destination (Join-Path $focus 'runtime-development.yaml')
Copy-Item -LiteralPath $QrLibrary -Destination (Join-Path $candidateRoot 'QRCoder.dll')
Copy-Item -LiteralPath (Join-Path $project 'windows/focus/QRCODER-LICENSE.txt') -Destination (Join-Path $candidateRoot 'licenses/QRCODER-LICENSE.txt')
Copy-Item -LiteralPath (Join-Path $project 'windows/focus/OPENXR-LOADER-LICENSE.txt') -Destination (Join-Path $candidateRoot 'licenses/OPENXR-LOADER-LICENSE.txt')
$inventory=[ordered]@{}
Get-ChildItem -LiteralPath $focus -Recurse -File | Sort-Object FullName | ForEach-Object {
    $inventory[$_.FullName.Substring($focus.Length+1).Replace('\','/')]=(Get-FileHash -LiteralPath $_.FullName).Hash.ToLowerInvariant()
}
[ordered]@{version=1;runtimeVersion='6.2.3';managerVersion='6.1.0';reviewed=$false;mediaSecurity='development-only-unencrypted';manager='NvStreamManager.exe';clientLibrary='NvStreamManagerClient.dll';manifest='releases/6.2.3/openxr_cloudxr.json';scene='scene/SpatialPC.FocusScene.exe';runtimeConfig='runtime-development.yaml';files=$inventory} |
    ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $focus 'deployment.json') -Encoding UTF8
# Strict Python UTF8 input: omit the Windows PowerShell UTF8 BOM.
$deployment=Join-Path $focus 'deployment.json'
[IO.File]::WriteAllText($deployment,[IO.File]::ReadAllText($deployment),(New-Object Text.UTF8Encoding $false))
Add-Content -LiteralPath (Join-Path $candidateRoot 'THIRD-PARTY-NOTICES.txt') -Value "`r`nThis private development staging includes user-supplied NVIDIA Manager6.1.0/Runtime6.2.3 under their included license. No redistribution clearance is implied. QRCoder1.6.0 MIT: licenses/QRCODER-LICENSE.txt. OpenXR.Loader1.0.6.2 by Khronos Group (unmodified x64 loader): licenses/OPENXR-LOADER-LICENSE.txt, Apache2.0 per package nuspec. No virtual audio driver installed or staged."
$bundle.files=@(Get-ChildItem -LiteralPath $candidateRoot -Recurse -File | Where-Object {$_.FullName -ne (Join-Path $candidateRoot 'bundle-manifest.json')} | Sort-Object FullName | ForEach-Object {
    [ordered]@{path=$_.FullName.Substring($candidateRoot.Length+1).Replace('\','/');bytes=$_.Length;sha256=(Get-FileHash -LiteralPath $_.FullName).Hash.ToLowerInvariant()}
})
$bundle | Add-Member -NotePropertyName focusStaged -NotePropertyValue $true
$bundle | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $candidateRoot 'bundle-manifest.json') -Encoding UTF8
Write-Output 'Staged private vendor files; reviewed=false. No host/runtime/listener launched.'
