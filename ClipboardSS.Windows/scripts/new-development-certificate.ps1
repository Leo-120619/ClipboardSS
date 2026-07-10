[CmdletBinding()]
param(
    [string] $Publisher = 'CN=ClipboardSS Development',
    [Parameter(Mandatory)]
    [securestring] $Password,
    [string] $OutputDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) 'artifacts\certificates')
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$certificate = New-SelfSignedCertificate -Type Custom -Subject $Publisher -KeyUsage DigitalSignature `
    -FriendlyName 'ClipboardSS Development' -CertStoreLocation 'Cert:\CurrentUser\My' `
    -NotAfter (Get-Date).AddYears(2)
$pfx = Join-Path $OutputDirectory 'ClipboardSS-development.pfx'
$cer = Join-Path $OutputDirectory 'ClipboardSS-development.cer'
Export-PfxCertificate -Cert $certificate -FilePath $pfx -Password $Password | Out-Null
Export-Certificate -Cert $certificate -FilePath $cer | Out-Null
Write-Host "Created developer certificate: $cer"
Write-Host "Created private PFX (keep private): $pfx"
Write-Host 'Import the .cer into Trusted Root Certification Authorities on development devices before sideloading.'
