#Requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ApkPath,

    [Parameter(Mandatory = $true)]
    [string]$AndroidSdk,

    [Parameter(Mandatory = $true)]
    [ValidateSet('Release', 'Debug')]
    [string]$Configuration,

    [string]$ExpectedCertificateSha256
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-SdkTool {
    param([string]$Executable, [string[]]$Arguments)

    $start = [System.Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Executable
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(60000)) {
            $process.Kill($true)
            $process.WaitForExit()
            throw "APK verification tool '$Executable' exceeded 60 seconds."
        }
        $output = $stdout.GetAwaiter().GetResult() + [Environment]::NewLine + $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            $diagnostic = $output.Trim()
            if ($diagnostic.Length -gt 4000) { $diagnostic = $diagnostic.Substring(0, 4000) }
            throw "APK verification tool '$Executable' failed with exit code $($process.ExitCode). $diagnostic"
        }
        return $output
    } finally {
        $process.Dispose()
    }
}

$apk = [System.IO.Path]::GetFullPath($ApkPath)
if (-not (Test-Path -LiteralPath $apk -PathType Leaf)) { throw "APK does not exist: $apk" }

$expected = $null
if (-not [string]::IsNullOrWhiteSpace($ExpectedCertificateSha256)) {
    $expected = ($ExpectedCertificateSha256 -replace '[:\s]', '').ToLowerInvariant()
    if ($expected -notmatch '^[0-9a-f]{64}$') { throw 'ExpectedCertificateSha256 must be a SHA-256 certificate fingerprint.' }
}
if ($Configuration -eq 'Release' -and $null -eq $expected) {
    throw 'Release APK verification requires ExpectedCertificateSha256 from the intended signing key.'
}

if ([string]::IsNullOrWhiteSpace($env:JAVA_HOME)) { throw 'JAVA_HOME must identify the JDK used for APK verification.' }
$suffix = if ($IsWindows) { '.exe' } else { '' }
$java = Join-Path $env:JAVA_HOME ("bin/java" + $suffix)
if (-not (Test-Path -LiteralPath $java -PathType Leaf)) { throw "JAVA_HOME does not contain a Java executable: $java" }

$buildToolsDirectory = Join-Path ([System.IO.Path]::GetFullPath($AndroidSdk)) 'build-tools'
if (-not (Test-Path -LiteralPath $buildToolsDirectory -PathType Container)) {
    throw "Android SDK build-tools directory is missing: $buildToolsDirectory"
}

$candidates = @(foreach ($directory in (Get-ChildItem -LiteralPath $buildToolsDirectory -Directory)) {
    if ($directory.Name -notmatch '^(?<version>\d+\.\d+\.\d+)(?:-(?<preview>alpha|beta|rc)(?<number>\d+))?$') { continue }
    $version = [version]$Matches.version
    $preview = $Matches['preview']
    $previewNumber = if ($Matches['number']) { [int]$Matches['number'] } else { 0 }
    $rank = switch ($preview) { 'alpha' { 0 } 'beta' { 1 } 'rc' { 2 } default { 3 } }
    $signer = Join-Path $directory.FullName 'lib/apksigner.jar'
    $aapt = Join-Path $directory.FullName ("aapt2" + $suffix)
    if (-not (Test-Path -LiteralPath $aapt -PathType Leaf)) {
        $aapt = Join-Path $directory.FullName ("aapt" + $suffix)
    }
    if ((Test-Path -LiteralPath $signer -PathType Leaf) -and (Test-Path -LiteralPath $aapt -PathType Leaf)) {
        [pscustomobject]@{ Version = $version; Rank = $rank; Preview = $previewNumber; Name = $directory.Name; Signer = $signer; Aapt = $aapt }
    }
})
$tools = $candidates | Sort-Object @{ Expression = { $_.Version }; Descending = $true },
    @{ Expression = { $_.Rank }; Descending = $true },
    @{ Expression = { $_.Preview }; Descending = $true } | Select-Object -First 1
if ($null -eq $tools) { throw "No usable Android SDK build-tools with apksigner and aapt were found in '$buildToolsDirectory'." }

$badging = Invoke-SdkTool $tools.Aapt @('dump', 'badging', $apk)
$packages = [regex]::Matches($badging, "(?m)^package: name='(?<id>[^']+)'(?:\s|$)")
if ($packages.Count -ne 1 -or $badging -notmatch '(?m)^application:') {
    throw "Could not read one application manifest from APK '$apk'."
}
$applicationId = $packages[0].Groups['id'].Value
$debuggable = $badging -match '(?m)^application-debuggable\s*$'
$expectedId = if ($Configuration -eq 'Release') { 'org.jellyfin.androidtv' } else { 'org.jellyfin.androidtv.debug' }
$expectedDebuggable = $Configuration -eq 'Debug'
if ($applicationId -cne $expectedId -or $debuggable -ne $expectedDebuggable) {
    throw "APK is not the requested $Configuration variant: applicationId='$applicationId', debuggable=$debuggable."
}

$verification = Invoke-SdkTool $java @('-jar', $tools.Signer, 'verify', '--verbose', '--print-certs', $apk)
if ($verification -notmatch '(?m)^Verifies\s*$') { throw "apksigner did not confirm successful APK verification for '$apk'." }
$certificates = [regex]::Matches($verification, '(?m)^Signer #\d+ certificate SHA-256 digest:\s*(?<digest>[a-fA-F0-9:]+)\s*$')
if ($certificates.Count -ne 1) { throw "Expected exactly one APK signing certificate; found $($certificates.Count)." }
$signerCounts = [regex]::Matches($verification, '(?m)^Number of signers:\s*(?<count>\d+)\s*$')
if ($signerCounts.Count -ne 1 -or $signerCounts[0].Groups['count'].Value -ne '1') {
    throw 'apksigner did not report exactly one APK signer.'
}
$certificate = ($certificates[0].Groups['digest'].Value -replace ':', '').ToLowerInvariant()
if ($certificate -notmatch '^[0-9a-f]{64}$') { throw 'apksigner returned an invalid SHA-256 certificate fingerprint.' }
if ($null -ne $expected -and $certificate -cne $expected) {
    throw "APK signing certificate does not match the intended key. Expected $expected; found $certificate."
}

$schemes = [ordered]@{}
foreach ($match in [regex]::Matches($verification, '(?m)^Verified using (?<scheme>v[\d.]+) scheme[^:\r\n]*:\s*(?<verified>true|false)\s*$')) {
    $schemes[$match.Groups['scheme'].Value] = $match.Groups['verified'].Value -eq 'true'
}
if (@($schemes.Values | Where-Object { $_ }).Count -eq 0) { throw 'No verified APK signature scheme was reported.' }

[pscustomobject]@{
    signed = $true
    certificateSha256 = $certificate
    applicationId = $applicationId
    debuggable = [bool]$debuggable
    signatureSchemes = [pscustomobject]$schemes
    buildToolsVersion = $tools.Name
}
