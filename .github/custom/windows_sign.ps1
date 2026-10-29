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
$timestampUrl = $null
$clock = [System.Diagnostics.Stopwatch]::StartNew()
$timestampCandidates = @(
    $env:TIMESTAMP_URL
    'https://timestamp.digicert.com'
    'http://timestamp.sectigo.com'
) | Where-Object { $_ } | Select-Object -Unique

function Write-Phase {
    param([string]$Message)
    Write-Host ("[{0,4}s] {1}" -f [int]$clock.Elapsed.TotalSeconds, $Message)
}

# signtool has no timeout of its own: an unreachable timestamp server leaves it
# waiting for as long as the TCP stack allows, so every call runs bounded.
function Invoke-Tool {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [int]$TimeoutSeconds = 180
    )
    $safeArguments = $Arguments | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }
    $log = Join-Path $env:RUNNER_TEMP ("tool-" + [guid]::NewGuid().ToString('N') + '.log')
    $process = Start-Process -FilePath $FilePath -ArgumentList $safeArguments -NoNewWindow -PassThru `
        -RedirectStandardOutput $log -RedirectStandardError "$log.err"
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        try { $process.Kill($true) } catch { }
        Remove-Item $log, "$log.err" -Force -ErrorAction SilentlyContinue
        return [pscustomobject]@{ ExitCode = 124; Output = "no result after ${TimeoutSeconds}s" }
    }
    $output = @()
    foreach ($path in @($log, "$log.err")) {
        if (Test-Path $path) { $output += Get-Content $path -ErrorAction SilentlyContinue }
    }
    Remove-Item $log, "$log.err" -Force -ErrorAction SilentlyContinue
    return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = ($output -join "`n") }
}

function Select-TimestampUrl {
    param([string]$ProbePath)
    foreach ($url in $timestampCandidates) {
        Copy-Item "$ProbePath.orig" $ProbePath -Force
        $result = Invoke-Tool -FilePath $signTool -TimeoutSeconds 90 -Arguments @(
            'sign', '/sha1', $thumbprint, '/s', 'My', '/fd', 'SHA256', '/tr', $url, '/td', 'SHA256', $ProbePath)
        if ($result.ExitCode -eq 0) {
            Write-Phase "timestamp server $url answered"
            return $url
        }
        Write-Warning "timestamp server $url failed (exit $($result.ExitCode)): $($result.Output)"
    }
    return $null
}

try {
    Write-Phase 'importing the release certificate'
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
    Write-Phase "signing as $($cert.Subject) [$thumbprint] ($signingMode)"

    function Invoke-SignFile {
        param([string]$Path)
        $result = Invoke-Tool -FilePath $signTool -TimeoutSeconds 180 -Arguments @(
            'sign', '/sha1', $thumbprint, '/s', 'My', '/fd', 'SHA256', '/tr', $timestampUrl, '/td', 'SHA256', $Path)
        if ($result.ExitCode -ne 0) {
            throw "signtool sign failed for $Path (exit $($result.ExitCode)): $($result.Output)"
        }
    }

    function Assert-SignedFile {
        param([string]$Path, [switch]$Redistributable)
        $signature = Get-AuthenticodeSignature -FilePath $Path
        if (-not $signature.SignerCertificate) { throw "${Path}: no signer certificate" }
        if (-not $signature.TimeStamperCertificate) { throw "${Path}: no timestamp countersignature" }
        if (-not $Redistributable -and $signature.SignerCertificate.Thumbprint -ne $thumbprint) {
            throw "${Path}: signed by $($signature.SignerCertificate.Thumbprint), not the release certificate"
        }
        if ($signature.SignerCertificate.NotAfter -le (Get-Date)) { throw "${Path}: the signing certificate has expired" }

        $chain = [System.Security.Cryptography.X509Certificates.X509Chain]::new()
        $chain.ChainPolicy.RevocationMode = 'NoCheck'
        $chain.ChainPolicy.DisableCertificateDownloads = $true
        if ($selfSigned -and -not $Redistributable) {
            # Trusting the certificate through a store starts Windows' automatic
            # root update, which needs the internet; anchoring the chain on the
            # release certificate itself keeps verification local.
            $chain.ChainPolicy.TrustMode =
                [System.Security.Cryptography.X509Certificates.X509ChainTrustMode]::CustomRootTrust
            $chain.ChainPolicy.CustomTrustStore.Add($cert)
        }
        if (-not $chain.Build($signature.SignerCertificate)) {
            $statuses = ($chain.ChainStatus | ForEach-Object { $_.Status }) -join ', '
            throw "${Path}: certificate chain did not validate: $statuses"
        }

        if (-not $selfSigned) {
            $result = Invoke-Tool -FilePath $signTool -TimeoutSeconds 90 -Arguments @('verify', '/pa', '/all', $Path)
            if ($result.ExitCode -ne 0) {
                throw "signtool verify failed for $Path (exit $($result.ExitCode)): $($result.Output)"
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
    Write-Phase "$($binaries.Count) executable(s) in the bundle, $($toSign.Count) to sign"

    $probe = Join-Path $env:RUNNER_TEMP 'tsa-probe.exe'
    Copy-Item ($binaries | Sort-Object Length | Select-Object -First 1).FullName "$probe.orig" -Force
    $timestampUrl = Select-TimestampUrl -ProbePath $probe
    Remove-Item $probe, "$probe.orig" -Force -ErrorAction SilentlyContinue
    if (-not $timestampUrl) {
        throw 'no timestamp server answered; refusing to publish signatures without a timestamp'
    }

    foreach ($file in $toSign) {
        Invoke-SignFile $file.FullName
        Write-Phase "signed $($file.Name)"
    }
    foreach ($file in $toSign) { Assert-SignedFile $file.FullName }
    foreach ($file in $kept) { Assert-SignedFile $file.FullName -Redistributable }
    Write-Phase "signed and verified $($toSign.Count) file(s), kept $($kept.Count) redistributable signature(s)"

    New-Item -ItemType Directory -Force -Path $distDir | Out-Null
    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::CreateFromDirectory(
        $bundleDir, $zipPath, [System.IO.Compression.CompressionLevel]::Optimal, $false)
    Write-Phase "archived the signed bundle"

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
    Write-Phase 'installer signed and verified'

    $expanded = Join-Path $env:RUNNER_TEMP 'zipcheck'
    Remove-Item $expanded -Recurse -Force -ErrorAction SilentlyContinue
    [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $expanded)
    $zipped = Get-PeFiles $expanded
    if ($zipped.Count -ne $binaries.Count) {
        throw "the archive holds $($zipped.Count) executable(s), the signed bundle has $($binaries.Count)"
    }
    foreach ($file in $zipped) {
        Assert-SignedFile $file.FullName -Redistributable:($file.Name -in $redistributables)
    }
    Write-Phase "verified $($zipped.Count) signed executable(s) inside the archive"

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
            trustedForRunOnly = $false
            chainAnchor       = if ($selfSigned) { 'release certificate' } else { 'system trust store' }
            timestamped       = $true
            timestampUrl      = $timestampUrl
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
    }
    Remove-Item $pfxPath -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $env:RUNNER_TEMP 'tsa-probe.exe') -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $env:RUNNER_TEMP 'tsa-probe.exe.orig') -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $env:RUNNER_TEMP 'zipcheck') -Recurse -Force -ErrorAction SilentlyContinue
}
