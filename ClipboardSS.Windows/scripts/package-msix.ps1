[CmdletBinding()]
param(
    [string[]] $Architecture = @('x64', 'arm64'),
    [ValidatePattern('^\d+\.\d+\.\d+\.\d+$')]
    [string] $Version = '1.0.0.0',
    [string] $Publisher = 'CN=ClipboardSS Development',
    # Thumbprint of a code-signing certificate (with private key) in the Personal store. signtool
    # selects it with /sha1, so no PFX password ever appears on a command line or in process lists.
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9A-Fa-f]{40}$')]
    [string] $CertificateThumbprint,
    [ValidateSet('CurrentUser', 'LocalMachine')]
    [string] $CertificateStoreLocation = 'CurrentUser',
    [ValidateSet('Debug', 'Release')]
    [string] $Configuration = 'Release'
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$project = Join-Path $projectRoot 'src\ClipboardSS.WinApp\ClipboardSS.App.csproj'
$manifestTemplate = Join-Path $projectRoot 'Packaging\AppxManifest.xml'
$assets = Join-Path $projectRoot 'Packaging\Assets'
$artifactRoot = Join-Path $projectRoot 'artifacts'
$stageRoot = Join-Path $projectRoot '.msix-staging'

if ($Architecture | Where-Object { $_ -notin @('x64', 'arm64') }) {
    throw 'Architecture must be x64, arm64, or both.'
}
$CertificateThumbprint = $CertificateThumbprint.ToUpperInvariant()
$certificate = Get-Item -LiteralPath "Cert:\$CertificateStoreLocation\My\$CertificateThumbprint" -ErrorAction SilentlyContinue
if (-not $certificate) {
    throw "No certificate with thumbprint $CertificateThumbprint in Cert:\$CertificateStoreLocation\My. Import the PFX first with Import-PfxCertificate."
}
if (-not $certificate.HasPrivateKey) {
    throw "The certificate $CertificateThumbprint has no private key in Cert:\$CertificateStoreLocation\My."
}
if ($certificate.Subject -ne $Publisher) {
    throw "The certificate subject '$($certificate.Subject)' must exactly match manifest publisher '$Publisher'."
}

$sdkRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
$makeAppx = Get-ChildItem -Path $sdkRoot -Recurse -Filter MakeAppx.exe |
    Where-Object { $_.FullName -match '\\x64\\MakeAppx\.exe$' } |
    Select-Object -First 1 -ExpandProperty FullName
$signTool = Get-ChildItem -Path $sdkRoot -Recurse -Filter SignTool.exe |
    Where-Object { $_.FullName -match '\\x64\\SignTool\.exe$' } |
    Select-Object -First 1 -ExpandProperty FullName
if (-not $makeAppx -or -not $signTool) {
    throw 'Windows SDK MakeAppx.exe and SignTool.exe (x64 host tools) are required.'
}

New-Item -ItemType Directory -Force -Path $artifactRoot | Out-Null
New-Item -ItemType Directory -Force -Path $stageRoot | Out-Null

foreach ($ridArchitecture in $Architecture) {
    $publish = Join-Path $stageRoot "publish-$ridArchitecture"
    $stage = Join-Path $stageRoot "package-$ridArchitecture"
    $package = Join-Path $artifactRoot "ClipboardSS_$Version`_$ridArchitecture.msix"
    Remove-Item -Recurse -Force -LiteralPath $publish, $stage -ErrorAction SilentlyContinue

    dotnet publish $project --configuration $Configuration --runtime "win-$ridArchitecture" --self-contained true --output $publish `
        /p:PublishSingleFile=false /p:PublishTrimmed=false /p:PlatformTarget=$ridArchitecture /p:WindowsAppSDKSelfContained=true
    if ($LASTEXITCODE -ne 0) { throw "Publish failed for $ridArchitecture." }

    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    Copy-Item -Recurse -Force -Path (Join-Path $publish '*') -Destination $stage
    Copy-Item -Recurse -Force -Path $assets -Destination $stage
    $manifest = Get-Content -LiteralPath $manifestTemplate -Raw
    $manifest = $manifest.Replace('Version="1.0.0.0"', "Version=`"$Version`"")
    $manifest = $manifest.Replace('Publisher="CN=ClipboardSS Development"', "Publisher=`"$Publisher`"")
    $manifest = $manifest.Replace('ProcessorArchitecture="x64"', "ProcessorArchitecture=`"$ridArchitecture`"")
    [System.IO.File]::WriteAllText(
        (Join-Path $stage 'AppxManifest.xml'),
        $manifest,
        [System.Text.UTF8Encoding]::new($false))

    Remove-Item -Force -LiteralPath $package -ErrorAction SilentlyContinue
    & $makeAppx pack /d $stage /p $package /o
    if ($LASTEXITCODE -ne 0) { throw "MakeAppx failed for $ridArchitecture." }
    $storeArguments = @('/s', 'My')
    if ($CertificateStoreLocation -eq 'LocalMachine') { $storeArguments += '/sm' }
    & $signTool sign /fd SHA256 /sha1 $CertificateThumbprint @storeArguments /v $package
    if ($LASTEXITCODE -ne 0) { throw "SignTool failed for $ridArchitecture." }
    & $signTool verify /pa /v $package
    if ($LASTEXITCODE -ne 0) {
        if ($certificate.Subject -eq $certificate.Issuer) {
            Write-Warning "Package was signed, but Windows policy does not trust this self-signed development certificate yet. Import its .cer into Trusted Root Certification Authorities to validate or install it."
        }
        else {
            throw "Signature verification failed for $ridArchitecture."
        }
    }
    Write-Host "Created $package"
}
