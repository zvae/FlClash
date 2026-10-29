#Requires -Version 7
<#
.SYNOPSIS
    Signs the Windows release bundle with Authenticode, packages it, and proves
    every published executable is signed, timestamped, and chained to the
    release certificate.

.DESCRIPTION
    SIGNING_MODE=official    expects a certificate issued by a public CA.
    SIGNING_MODE=self-signed trusts the release certificate for this run only,
    so the signatures verify here while Windows still shows an unknown
    publisher to anyone who has not installed that certificate.
#>

[CmdletBinding()]
param(
    [ValidateSet('sign')]
    [string]$Mode = 'sign'
)

$ErrorActionPreference = 'Stop'

foreach ($name in 'APP_NAME', 'VERSION', 'TAG', 'SOURCE_COMMIT', 'UPSTREAM_COMMIT', 'DIST_DIR',
    'WINDOWS_PRODUCT_NAME', 'WINDOWS_COMPANY_NAME', 'WINDOWS_PUBLISHER_URL',
    'WINDOWS_CERTIFICATE_PFX_BASE64', 'WINDOWS_CERTIFICATE_PASSWORD') {
    if (-not [Environment]::GetEnvironmentVariable($name)) {
        throw "windows_sign.ps1: $name is not set"
    }
}
if (-not $env:TIMESTAMP_URL) {
    $env:TIMESTAMP_URL = 'http://timestamp.digicert.com'
}
$signingMode = if ($env:SIGNING_MODE) { $env:SIGNING_MODE } else { 'self-signed' }
if ($signingMode -notin 'self-signed', 'official') {
    throw "SIGNING_MODE must be self-signed or official, not '$signingMode'"
}
$selfSigned = $signingMode -eq 'self-signed'

$bundleDir = Join-Path $env:GITHUB_WORKSPACE 'build/windows/x64/runner/Release'
$distDir = $env:DIST_DIR
$exeName = "$env:WINDOWS_PRODUCT_NAME.exe"
$installerBase = "$env:APP_NAME-$env:VERSION-windows-amd64"
$zipPath = Join-Path $distDir "$installerBase.zip"
$installerPath = Join-Path $distDir "$installerBase.exe"

function Get-SignTool {
    $roots = @("${env:ProgramFiles(x86)}\Windows Kits\10\bin", "$env:ProgramFiles\Windows Kits\10\bin")
    foreach ($root in $roots) {
        if (-not (Test-Path $root)) { continue }
        $found = Get-ChildItem $root -Directory | Sort-Object Name -Descending |
            ForEach-Object { Join-Path $_.FullName 'x64\signtool.exe' } |
            Where-Object { Test-Path $_ } | Select-Object -First 1
        if ($found) { return $found }
    }
    throw 'signtool.exe was not found; the Windows SDK is missing from this runner.'
}

function Get-PeFiles {
    param([string]$Path)
    Get-ChildItem -Path $Path -Recurse -File |
        Where-Object { $_.Extension -in '.exe', '.dll' } |
        Sort-Object FullName
}

$signTool = Get-SignTool
$thumbprint = $null
$pfxPath = Join-Path $env:RUNNER_TEMP 'windows-signing.pfx'
$cerPath = Join-Path $env:RUNNER_TEMP 'windows-signing.cer'

try {
    [IO.File]::WriteAllBytes($pfxPath, [Convert]::FromBase64String($env:WINDOWS_CERTIFICATE_PFX_BASE64))
    $secure = ConvertTo-SecureString -String $env:WINDOWS_CERTIFICATE_PASSWORD -AsPlainText -Force
    $cert = Import-PfxCertificate -FilePath $pfxPath -CertStoreLocation 'Cert:\CurrentUser\My' -Password $secure
    $thumbprint = $cert.Thumbprint
    if (-not $cert.HasPrivateKey) { throw 'the imported PFX holds no private key' }
    if ($env:WINDOWS_SIGNER_SUBJECT) {
        # Windows prints the subject in its own attribute order, so compare the common name.
        $expected = $env:WINDOWS_SIGNER_SUBJECT
        if ($expected -match 'CN=([^,]+)') { $expected = $matches[1].Trim() }
        $actual = $cert.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)
        if ($actual -ne $expected) {
            throw "the PFX common name is '$actual', expected '$expected'"
        }
    }
    if ($selfSigned) {
        Export-Certificate -Cert $cert -FilePath $cerPath -Type CERT | Out-Null
        Import-Certificate -FilePath $cerPath -CertStoreLocation 'Cert:\CurrentUser\Root' | Out-Null
        Write-Host 'trusted the self-signed release certificate for this run only'
    }
    Write-Host "signing as $($cert.Subject) [$thumbprint] ($signingMode)"

    function Invoke-SignFile {
        param([string]$Path)
        & $signTool sign /sha1 $thumbprint /s My /fd SHA256 /tr $env:TIMESTAMP_URL /td SHA256 $Path
        if ($LASTEXITCODE -ne 0) { throw "signtool sign failed for $Path" }
    }

    function Assert-SignedFile {
        param([string]$Path, [switch]$Redistributable)
        & $signTool verify /pa /all $Path | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "signtool verify failed for $Path" }
        $signature = Get-AuthenticodeSignature -FilePath $Path
        if ($signature.Status -ne 'Valid') { throw "${Path}: signature status is $($signature.Status)" }
        if (-not $signature.TimeStamperCertificate) { throw "${Path}: no timestamp countersignature" }
        if (-not $Redistributable -and $signature.SignerCertificate.Thumbprint -ne $thumbprint) {
            throw "${Path}: signed by $($signature.SignerCertificate.Thumbprint), not the release certificate"
        }
        if ($signature.SignerCertificate.NotAfter -le (Get-Date)) { throw "${Path}: the signing certificate has expired" }
        $chain = [System.Security.Cryptography.X509Certificates.X509Chain]::new()
        $chain.ChainPolicy.RevocationMode = 'Online'
        $chain.ChainPolicy.RevocationFlag = 'ExcludeRoot'
        if (-not $chain.Build($signature.SignerCertificate)) {
            $fatal = $chain.ChainStatus |
                Where-Object { $_.Status -notin 'RevocationStatusUnknown', 'OfflineRevocation' }
            if ($fatal) {
                throw "${Path}: certificate chain did not validate: $($fatal | ForEach-Object { $_.Status })"
            }
        }
    }

    if (-not (Test-Path (Join-Path $bundleDir $exeName))) { throw "build output $bundleDir has no $exeName" }
    $binaries = Get-PeFiles $bundleDir
    if (-not $binaries) { throw "no executables or libraries under $bundleDir" }

    # The MSVC redistributables keep the Microsoft signature they ship with.
    $redistributables = @('msvcp140.dll', 'msvcp140_1.dll', 'msvcp140_2.dll', 'vcruntime140.dll',
        'vcruntime140_1.dll', 'concrt140.dll')
    $toSign = $binaries | Where-Object { $_.Name -notin $redistributables }
    $kept = $binaries | Where-Object { $_.Name -in $redistributables }

    foreach ($file in $toSign) { Invoke-SignFile $file.FullName }
    foreach ($file in $toSign) { Assert-SignedFile $file.FullName }
    foreach ($file in $kept) { Assert-SignedFile $file.FullName -Redistributable }
    Write-Host "signed and verified $($toSign.Count) file(s), kept $($kept.Count) redistributable signature(s)"

    New-Item -ItemType Directory -Force -Path $distDir | Out-Null
    Compress-Archive -Path (Join-Path $bundleDir '*') -DestinationPath $zipPath -Force

    $env:BRAND_APP_NAME = $env:APP_NAME
    $env:BRAND_VERSION = $env:VERSION
    $env:BRAND_PUBLISHER = $env:WINDOWS_COMPANY_NAME
    $env:BRAND_PUBLISHER_URL = $env:WINDOWS_PUBLISHER_URL
    $env:BRAND_EXE_NAME = $exeName
    $env:BRAND_SOURCE_DIR = $bundleDir
    $env:BRAND_OUTPUT_DIR = $distDir
    $env:BRAND_OUTPUT_BASENAME = $installerBase
    $env:BRAND_ICON = Join-Path $env:GITHUB_WORKSPACE 'windows/runner/resources/app_icon.ico'

    $iscc = @('C:\Program Files (x86)\Inno Setup 6\ISCC.exe', 'C:\Program Files\Inno Setup 6\ISCC.exe') |
        Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $iscc) { throw 'ISCC.exe was not found; install Inno Setup 6 on the runner.' }
    & $iscc '/Qp' (Join-Path $env:GITHUB_WORKSPACE '.github/custom/installer.iss')
    if ($LASTEXITCODE -ne 0) { throw 'ISCC failed to build the installer' }
    if (-not (Test-Path $installerPath)) { throw "the installer was not written to $installerPath" }

    Invoke-SignFile $installerPath
    Assert-SignedFile $installerPath
    Write-Host 'installer signed and verified'

    $expanded = Join-Path $env:RUNNER_TEMP 'zipcheck'
    Remove-Item $expanded -Recurse -Force -ErrorAction SilentlyContinue
    Expand-Archive -Path $zipPath -DestinationPath $expanded -Force
    $zipped = Get-PeFiles $expanded
    if ($zipped.Count -ne $binaries.Count) {
        throw "the archive holds $($zipped.Count) executable(s), the signed bundle has $($binaries.Count)"
    }
    foreach ($file in $zipped) {
        Assert-SignedFile $file.FullName -Redistributable:($file.Name -in $redistributables)
    }
    Write-Host "verified $($zipped.Count) signed executable(s) inside the archive"

    $verification = [ordered]@{
        platform       = 'windows'
        arch           = 'amd64'
        tag            = $env:TAG
        version        = $env:VERSION
        sourceCommit   = $env:SOURCE_COMMIT
        upstreamCommit = $env:UPSTREAM_COMMIT
        signed         = $true
        signingMode    = $signingMode
        selfSigned     = $selfSigned
        signing        = [ordered]@{
            tool              = 'signtool'
            mode              = 'Authenticode'
            subject           = $cert.Subject
            thumbprint        = $thumbprint
            selfSigned        = $selfSigned
            trustedForRunOnly = $selfSigned
            timestamped       = $true
            chainValidated    = $true
            signedExecutables = $toSign.Count
        }
        files          = @((Split-Path $installerPath -Leaf), (Split-Path $zipPath -Leaf))
    }
    $verification | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $distDir 'verification-windows.json') -Encoding utf8
}
finally {
    if ($thumbprint) {
        Remove-Item "Cert:\CurrentUser\My\$thumbprint" -Force -ErrorAction SilentlyContinue
        Remove-Item "Cert:\CurrentUser\Root\$thumbprint" -Force -ErrorAction SilentlyContinue
    }
    Remove-Item $pfxPath -Force -ErrorAction SilentlyContinue
    Remove-Item $cerPath -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $env:RUNNER_TEMP 'zipcheck') -Recurse -Force -ErrorAction SilentlyContinue
}
