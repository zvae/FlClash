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
# DigiCert rejects /tr https on some signtool builds with "Invalid Timestamp URL",
# so the documented http endpoints are tried first.
$timestampCandidates = @(
    $env:TIMESTAMP_URL
    'http://timestamp.digicert.com'
    'http://timestamp.sectigo.com'
    'http://timestamp.globalsign.com/tsa/r6advanced1'
    'https://timestamp.digicert.com'
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
    $safeArguments = $Arguments | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
    }
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
    param([string]$SignedProbe)
    foreach ($url in $timestampCandidates) {
        Copy-Item $SignedProbe "$SignedProbe.probe" -Force
        $result = Invoke-Tool -FilePath $signTool -TimeoutSeconds 90 -Arguments @(
            'timestamp', '/tr', $url, '/td', 'SHA256', "$SignedProbe.probe")
        Remove-Item "$SignedProbe.probe" -Force -ErrorAction SilentlyContinue
        if ($result.ExitCode -eq 0) {
            Write-Phase "timestamp server $url answered"
            return $url
        }
        Write-Warning "timestamp server $url failed (exit $($result.ExitCode)): $($result.Output)"
    }
    return $null
}

try {
    Write-Phase 'loading the release certificate'
    [IO.File]::WriteAllBytes($pfxPath, [Convert]::FromBase64String($env:WINDOWS_CERTIFICATE_PFX_BASE64))
    # EphemeralKeySet keeps the key off disk and out of the user profile, which is
    # where a hostile or slow store could stall the run.
    $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
        $pfxPath,
        $env:WINDOWS_CERTIFICATE_PASSWORD,
        [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet)
    $thumbprint = $cert.Thumbprint
    if (-not $cert.HasPrivateKey) { throw 'the PFX holds no private key' }
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
        $result = Invoke-Tool -FilePath $signTool -TimeoutSeconds 120 -Arguments @(
            'sign', '/f', $signingPfx, '/p', $env:WINDOWS_CERTIFICATE_PASSWORD, '/fd', 'SHA256', $Path)
        if ($result.ExitCode -ne 0) {
            throw "signtool sign failed for $Path (exit $($result.ExitCode)): $($result.Output)"
        }
        $stamped = Invoke-Tool -FilePath $signTool -TimeoutSeconds 120 -Arguments @(
            'timestamp', '/tr', $timestampUrl, '/td', 'SHA256', $Path)
        if ($stamped.ExitCode -ne 0) {
            throw "timestamping failed for $Path with $timestampUrl (exit $($stamped.ExitCode)): $($stamped.Output)"
        }
    }

    function Assert-SignedFile {
        param([string]$Path, [switch]$Redistributable)
        $signature = Get-AuthenticodeSignature -FilePath $Path
        if (-not $signature.SignerCertificate) { throw "${Path}: no signer certificate" }
        if (-not $signature.TimeStamperCertificate) { throw "${Path}: no timestamp countersignature" }

        if ($Redistributable) {
            # Microsoft ships these timestamped by a certificate that expired long
            # ago; the timestamp, not the certificate, is what keeps them valid.
            if ($signature.SignerCertificate.Subject -notmatch 'Microsoft') {
                throw "${Path}: signed by $($signature.SignerCertificate.Subject), not Microsoft"
            }
            return
        }

        if ($signature.SignerCertificate.Thumbprint -ne $thumbprint) {
            throw "${Path}: signed by $($signature.SignerCertificate.Thumbprint), not the release certificate"
        }
        if ($signature.SignerCertificate.NotAfter -le (Get-Date)) { throw "${Path}: the signing certificate has expired" }

        $chain = [System.Security.Cryptography.X509Certificates.X509Chain]::new()
        $chain.ChainPolicy.RevocationMode = 'NoCheck'
        $chain.ChainPolicy.DisableCertificateDownloads = $true
        if ($selfSigned) {
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

    # Anything Microsoft already signed keeps that signature: re-signing the VC
    # redistributables would replace a publisher the user can verify.
    $toSign = @()
    $kept = @()
    foreach ($file in $binaries) {
        $existing = Get-AuthenticodeSignature -FilePath $file.FullName
        if ($existing.SignerCertificate -and $existing.SignerCertificate.Subject -match 'Microsoft') {
            $kept += $file
        } else {
            $toSign += $file
        }
    }
    $keptNames = $kept | ForEach-Object { $_.Name }
    Write-Phase "$($binaries.Count) executable(s), $($toSign.Count) to sign, $($kept.Count) keeping Microsoft's signature"

    $probe = Join-Path $env:RUNNER_TEMP 'tsa-probe.exe'
    $signingPfx = $pfxPath
    Copy-Item ($toSign | Sort-Object Length | Select-Object -First 1).FullName $probe -Force
    Write-Phase 'checking that signtool accepts the certificate'
    $probeSign = Invoke-Tool -FilePath $signTool -TimeoutSeconds 120 -Arguments @(
        'sign', '/f', $signingPfx, '/p', $env:WINDOWS_CERTIFICATE_PASSWORD, '/fd', 'SHA256', $probe)
    if ($probeSign.ExitCode -ne 0) {
        Write-Warning "signtool rejected the PFX (exit $($probeSign.ExitCode)): $($probeSign.Output)"
        Write-Phase 're-exporting the key material and retrying'
        $signingPfx = Join-Path $env:RUNNER_TEMP 'windows-signing-rebuilt.pfx'
        [IO.File]::WriteAllBytes($signingPfx, $cert.Export(
            [System.Security.Cryptography.X509Certificates.X509ContentType]::Pkcs12,
            $env:WINDOWS_CERTIFICATE_PASSWORD))
        Copy-Item ($toSign | Sort-Object Length | Select-Object -First 1).FullName $probe -Force
        $retry = Invoke-Tool -FilePath $signTool -TimeoutSeconds 120 -Arguments @(
            'sign', '/f', $signingPfx, '/p', $env:WINDOWS_CERTIFICATE_PASSWORD, '/fd', 'SHA256', $probe)
        if ($retry.ExitCode -ne 0) {
            throw "signtool cannot sign with this PFX (exit $($retry.ExitCode)): $($retry.Output)"
        }
        Write-Phase 'signed with the re-exported PFX'
    }
    Write-Phase 'certificate accepted, probing timestamp servers'
    $timestampUrl = Select-TimestampUrl -SignedProbe $probe
    Remove-Item $probe, "$probe.probe" -Force -ErrorAction SilentlyContinue
    if (-not $timestampUrl) {
        throw 'no timestamp server answered; refusing to publish signatures without a timestamp'
    }
    Write-Phase "timestamping $($toSign.Count) file(s) with $timestampUrl"

    foreach ($file in $toSign) {
        Invoke-SignFile $file.FullName
        Write-Phase "signed $($file.Name)"
    }
    foreach ($file in $toSign) { Assert-SignedFile $file.FullName }
    foreach ($file in $kept) { Assert-SignedFile $file.FullName -Redistributable }
    Write-Phase "signed and verified $($toSign.Count) file(s), kept $($kept.Count) redistributable signature(s)"

    New-Item -ItemType Directory -Force -Path $distDir | Out-Null
    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
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
    Write-Phase 'building the installer'
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
        Assert-SignedFile $file.FullName -Redistributable:($file.Name -in $keptNames)
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
    Remove-Item $pfxPath -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $env:RUNNER_TEMP 'windows-signing-rebuilt.pfx') -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $env:RUNNER_TEMP 'tsa-probe.exe') -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $env:RUNNER_TEMP 'tsa-probe.exe.probe') -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $env:RUNNER_TEMP 'zipcheck') -Recurse -Force -ErrorAction SilentlyContinue
}
