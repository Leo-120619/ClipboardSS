[CmdletBinding()]
param(
    [string[]] $Architecture = @('x64', 'arm64'),
    [ValidatePattern('^\d+\.\d+\.\d+\.\d+$')]
    [string] $Version = '1.0.0.0',
    [string] $Publisher = 'CN=ClipboardSS Development',
    [Parameter(Mandatory)]
    [string] $CertificatePath,
    [Parameter(Mandatory)]
    [securestring] $CertificatePassword,
    [ValidateSet('Debug', 'Release')]
    [string] $Configuration = 'Release'
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$project = Join-Path $projectRoot 'src\ClipboardSS.App\ClipboardSS.App.csproj'
$manifestTemplate = Join-Path $projectRoot 'Packaging\AppxManifest.xml'
$assets = Join-Path $projectRoot 'Packaging\Assets'
$artifactRoot = Join-Path $projectRoot 'artifacts'
$stageRoot = Join-Path $projectRoot '.msix-staging'

if ($Architecture | Where-Object { $_ -notin @('x64', 'arm64') }) {
    throw 'Architecture must be x64, arm64, or both.'
}
if (-not (Test-Path -LiteralPath $CertificatePath -PathType Leaf)) {
    throw "Certificate PFX was not found: $CertificatePath"
}

$certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
    (Resolve-Path -LiteralPath $CertificatePath), $CertificatePassword)
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
$password = [System.Net.NetworkCredential]::new('', $CertificatePassword).Password

foreach ($ridArchitecture in $Architecture) {
    $publish = Join-Path $stageRoot "publish-$ridArchitecture"
    $stage = Join-Path $stageRoot "package-$ridArchitecture"
    $package = Join-Path $artifactRoot "ClipboardSS_$Version`_$ridArchitecture.msix"
    Remove-Item -Recurse -Force -LiteralPath $publish, $stage -ErrorAction SilentlyContinue

    dotnet publish $project --configuration $Configuration --runtime "win-$ridArchitecture" --self-contained true --output $publish `
        /p:PublishSingleFile=false /p:PublishTrimmed=false /p:PlatformTarget=$ridArchitecture
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
    & $signTool sign /fd SHA256 /f $CertificatePath /p $password /v $package
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
