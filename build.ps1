#Requires -Version 7.2
param(
    [switch]$Debug,
    [switch]$SkipTests,
    [string]$JavaHome,
    [string]$AndroidSdk,
    [string]$Version,
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$repoRoot = [System.IO.Path]::GetFullPath($PSScriptRoot)

# This simple parameter block reserves -Debug for the build variant.
# Reject unbound arguments explicitly instead of silently ignoring typos.
if ($args.Count -gt 0) { throw 'Unknown build argument. Use -Help to see the supported options.' }

if ($Help) {
    @'
Usage: pwsh ./build.ps1 [-Debug] [-SkipTests] [-JavaHome <jdk>] [-AndroidSdk <sdk>] [-Version <version>]

Builds a signed, optimized Release APK and runs matching unit tests by default.
Use -Debug for a Debug APK. Nothing is installed or deployed.
Requires PowerShell 7.2+ and an Android SDK with the project's compile API and build tools.
Finds a matching JDK, or downloads a verified portable Temurin JDK on Windows.
Reuses configured release signing, or creates a persistent fork key in .signing/.
Back up .signing/ for future updates; it is private and never committed or cleaned.
Cache and logs: .build/    APK, SHA256 and build information: _artifacts/

Examples:
  ./build.ps1
  ./build.ps1 -Debug
  ./build.ps1 -SkipTests
  ./build.ps1 -Version 0.20.0-alien21.1
  ./build.ps1 -JavaHome C:\Java\jdk-21 -AndroidSdk C:\Android\Sdk
'@ | Write-Output
    return
}

$configuration = if ($Debug) { 'Debug' } else { 'Release' }
$variant = $configuration.ToLowerInvariant()
$expectedApplicationId = if ($Debug) { 'org.jellyfin.androidtv.debug' } else { 'org.jellyfin.androidtv' }

function Get-OutputDirectory([string]$RelativePath) {
    $path = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $RelativePath))
    $prefix = $repoRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    if (-not $path.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Build output must remain inside the repository: $path"
    }
    if (Test-Path -LiteralPath $path) {
        if ((Get-Item -LiteralPath $path -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            throw "Build output directory must not be a link: $path"
        }
    }
    [void][System.IO.Directory]::CreateDirectory($path)
    return $path
}

function Get-JavaMajor([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return 0 }
    $java = Join-Path $Path $(if ($IsWindows) { 'bin/java.exe' } else { 'bin/java' })
    $javac = Join-Path $Path $(if ($IsWindows) { 'bin/javac.exe' } else { 'bin/javac' })
    $release = Join-Path $Path 'release'
    if (-not (Test-Path -LiteralPath $java) -or -not (Test-Path -LiteralPath $javac) -or -not (Test-Path -LiteralPath $release)) { return 0 }
    $text = [System.IO.File]::ReadAllText($release)
    if ($text -match '(?m)^JAVA_VERSION="(?<major>\d+)[.\-"]') { return [int]$Matches.major }
    return 0
}

function Get-SdkDirectory([int]$CompileApi) {
    $localSdk = $null
    $localProperties = Join-Path $repoRoot 'local.properties'
    if (Test-Path -LiteralPath $localProperties) {
        $properties = [System.IO.File]::ReadAllText($localProperties)
        if ($properties -match '(?m)^\s*sdk\.dir\s*=\s*(.+?)\s*$') {
            $localSdk = $Matches[1].Replace('\:', ':').Replace('\\', '\').Replace('\ ', ' ')
            if (-not [System.IO.Path]::IsPathRooted($localSdk)) { $localSdk = Join-Path $repoRoot $localSdk }
            $localSdk = [System.IO.Path]::TrimEndingDirectorySeparator([System.IO.Path]::GetFullPath($localSdk))
        }
    }
    if ($AndroidSdk -and $localSdk -and [System.IO.Path]::TrimEndingDirectorySeparator([System.IO.Path]::GetFullPath($AndroidSdk)) -ne $localSdk) {
        throw "-AndroidSdk conflicts with sdk.dir in local.properties ($localSdk). Update that local setting first; it will not be overwritten."
    }
    $candidates = @($AndroidSdk, $localSdk, $env:ANDROID_HOME, $env:ANDROID_SDK_ROOT)
    if ($IsWindows) { $candidates += Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Android/Sdk' }
    $selected = $candidates | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1
    if (-not $selected -or -not (Test-Path -LiteralPath $selected -PathType Container)) {
        throw 'Android SDK not found. Configure sdk.dir in local.properties, ANDROID_HOME, or -AndroidSdk.'
    }
    $selected = (Resolve-Path -LiteralPath $selected).Path
    $platforms = Join-Path $selected 'platforms'
    $matchingPlatforms = @()
    if (Test-Path -LiteralPath $platforms) {
        $matchingPlatforms = @(Get-ChildItem -LiteralPath $platforms -Directory | Where-Object {
            $source = Join-Path $_.FullName 'source.properties'
            (Test-Path -LiteralPath $source) -and
            ([System.IO.File]::ReadAllText($source) -match "(?m)^AndroidVersion\.ApiLevel\s*=\s*$CompileApi(?:\.0)?\s*$") -and
            (Test-Path -LiteralPath (Join-Path $_.FullName 'android.jar'))
        })
    }
    $buildTools = Join-Path $selected 'build-tools'
    if ($matchingPlatforms.Count -eq 0 -or -not (Test-Path -LiteralPath $buildTools) -or @(Get-ChildItem -LiteralPath $buildTools -Directory).Count -eq 0) {
        throw "Android SDK needs platform API $CompileApi and installed build tools. Install them using Android Studio's SDK Manager."
    }
    return $selected
}

function Get-JdkDirectory([int]$Major, [string]$ToolchainsDirectory) {
    if ($JavaHome) {
        if ((Get-JavaMajor $JavaHome) -ne $Major) { throw "-JavaHome must point to a complete JDK ${Major}: $JavaHome" }
        return (Resolve-Path -LiteralPath $JavaHome).Path
    }
    $candidates = @($env:JAVA_HOME)
    $candidates += @(Get-ChildItem -LiteralPath $ToolchainsDirectory -Directory | Select-Object -ExpandProperty FullName)
    $javaCommand = Get-Command java -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($javaCommand) { $candidates += Split-Path -Parent (Split-Path -Parent $javaCommand.Source) }
    $jdkRoots = @()
    if ($IsWindows) {
        $jdkRoots += @((Join-Path $env:ProgramFiles 'Microsoft'), (Join-Path $env:ProgramFiles 'Eclipse Adoptium'), (Join-Path $env:ProgramFiles 'Java'))
        if ($env:USERPROFILE) { $jdkRoots += Join-Path $env:USERPROFILE '.jdks' }
    }
    foreach ($jdkRoot in $jdkRoots) {
        if (Test-Path -LiteralPath $jdkRoot) { $candidates += @(Get-ChildItem -LiteralPath $jdkRoot -Directory | Select-Object -ExpandProperty FullName) }
    }
    foreach ($candidate in $candidates) {
        if ((Get-JavaMajor $candidate) -eq $Major) { return (Resolve-Path -LiteralPath $candidate).Path }
    }
    if (-not $IsWindows) { throw "Install JDK $Major and select it with JAVA_HOME or -JavaHome. Automatic bootstrap currently supports Windows."
    }
    $architecture = switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()) {
        'X64' { 'x64' }
        'Arm64' { 'aarch64' }
        default { throw 'Automatic JDK bootstrap requires Windows x64 or ARM64.' }
    }
    Write-Host "Downloading a portable JDK $Major into .build/toolchains..."
    $assets = @(Invoke-RestMethod -Uri "https://api.adoptium.net/v3/assets/latest/$Major/hotspot?architecture=$architecture&image_type=jdk&os=windows&vendor=eclipse" -TimeoutSec 30)
    if ($assets.Count -eq 0) { throw "No Temurin JDK $Major package was returned." }
    $package = $assets[0].binary.package
    $uri = [uri]$package.link
    if ($uri.Scheme -ne 'https' -or $package.checksum -notmatch '^[a-fA-F0-9]{64}$') { throw 'Invalid JDK download metadata.' }
    $staging = Get-OutputDirectory ('.build/toolchains/download-' + [guid]::NewGuid().ToString('N'))
    $zipPath = Join-Path $staging 'jdk.zip'
    Invoke-WebRequest -Uri $uri.AbsoluteUri -OutFile $zipPath -TimeoutSec 180
    if ((Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash -ne $package.checksum) { throw 'JDK SHA256 mismatch; the download will not be used.' }
    $expanded = Join-Path $staging 'expanded'
    $archive = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        $expandedPrefix = [System.IO.Path]::GetFullPath($expanded) + [System.IO.Path]::DirectorySeparatorChar
        foreach ($entry in $archive.Entries) {
            $entryPath = [System.IO.Path]::GetFullPath((Join-Path $expanded $entry.FullName))
            if (-not $entryPath.StartsWith($expandedPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
                (($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) { throw 'Unsafe path or link in JDK archive.' }
        }
    }
    finally { $archive.Dispose() }
    Expand-Archive -LiteralPath $zipPath -DestinationPath $expanded
    $jdk = @(Get-ChildItem -LiteralPath $expanded -Directory | Where-Object { (Get-JavaMajor $_.FullName) -eq $Major })
    if ($jdk.Count -ne 1) { throw "Downloaded archive did not contain one complete JDK $Major." }
    $destination = [System.IO.Path]::GetFullPath((Join-Path $ToolchainsDirectory ('temurin-' + $jdk[0].Name)))
    $toolchainsPrefix = [System.IO.Path]::GetFullPath($ToolchainsDirectory) + [System.IO.Path]::DirectorySeparatorChar
    if (-not $destination.StartsWith($toolchainsPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not $jdk[0].FullName.StartsWith($expandedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected JDK cache path.' }
    if (Test-Path -LiteralPath $destination) { throw "An invalid cached JDK already exists at $destination. Select a JDK with -JavaHome or inspect that cache directory." }
    Move-Item -LiteralPath $jdk[0].FullName -Destination $destination
    [System.IO.File]::WriteAllText((Join-Path $destination 'download.json'), ($package | ConvertTo-Json -Depth 10))
    return $destination
}

$savedEnvironment = @{}
foreach ($name in @('JAVA_HOME', 'ANDROID_HOME', 'ANDROID_SDK_ROOT')) { $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
$buildLock = $null
$locationChanged = $false
$exitCode = 0
try {
    if ($Version -and $Version -notmatch '^v?\d+\.\d+\.\d+(?:-[0-9A-Za-z-]+\.\d+)?$') {
        throw '-Version must use MAJOR.MINOR.PATCH with an optional -LABEL.NUMBER, for example 0.20.0-alien21.1.'
    }
    $catalog = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'gradle/libs.versions.toml'))
    if ($catalog -notmatch '(?m)^java-jdk\s*=\s*"(\d+)"') { throw 'Java toolchain version is missing from the version catalog.' }
    $javaMajor = [int]$Matches[1]
    if ($catalog -notmatch '(?m)^android-compileSdk\s*=\s*"(\d+)"') { throw 'Android compile SDK is missing from the version catalog.' }
    $compileApi = [int]$Matches[1]
    $sdk = Get-SdkDirectory $compileApi
    $cache = Get-OutputDirectory '.build'
    $toolchains = Get-OutputDirectory '.build/toolchains'
    $logs = Get-OutputDirectory '.build/logs'
    try { $buildLock = [System.IO.File]::Open((Join-Path $cache 'build.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
    catch { throw "Cannot acquire the checkout build lock; another build may be running. $($_.Exception.Message)" }
    $jdk = Get-JdkDirectory $javaMajor $toolchains
    $env:JAVA_HOME = $jdk
    $env:ANDROID_HOME = $sdk
    $env:ANDROID_SDK_ROOT = $sdk
    Write-Host "JDK $javaMajor`: $jdk"
    Write-Host "Android SDK: $sdk (API $compileApi)"

    $licenseHelper = Join-Path $repoRoot 'build-support/prepare-licenses.ps1'
    $licenseConfig = Join-Path $cache 'licenses'
    & $licenseHelper -CacheDirectory $licenseConfig

    Push-Location -LiteralPath $repoRoot
    $locationChanged = $true
    $gradle = Join-Path $repoRoot $(if ($IsWindows) { 'gradlew.bat' } else { 'gradlew' })
    $gradleArgs = @(':app:assemble' + $configuration)
    if (-not $SkipTests) {
        $gradleArgs += ":app:test${configuration}UnitTest"
        # AGP 9 otherwise creates unit tests only for the default tested build type.
        if (-not $Debug) { $gradleArgs += '-Pandroid.onlyEnableUnitTestForTheTestedBuildType=false' }
    }
    $gradleArgs += @('--console=plain', '--no-configuration-cache', ('-Porg.gradle.java.installations.paths=' + $jdk),
        '--init-script', (Join-Path $repoRoot 'build-support/aboutlibraries.init.gradle'),
        ('-Pandroidtv.licenseConfig=' + $licenseConfig),
        '-Dorg.gradle.jvmargs=-Xmx2048m -Dsun.net.client.defaultConnectTimeout=15000 -Dsun.net.client.defaultReadTimeout=15000')
    $signingReportPath = Join-Path $cache 'release-signing.json'
    if (-not $Debug) {
        $signingDirectory = Get-OutputDirectory '.signing'
        $keytool = Join-Path $jdk $(if ($IsWindows) { 'bin/keytool.exe' } else { 'bin/keytool' })
        $gradleArgs += @('--init-script', (Join-Path $repoRoot 'build-support/release-signing.init.gradle'),
            ('-Pandroidtv.signingDirectory=' + $signingDirectory),
            ('-Pandroidtv.signingReport=' + $signingReportPath),
            ('-Pandroidtv.keytool=' + $keytool))
    }
    if ($Version) { $gradleArgs += '-Pjellyfin.version=' + $Version }
    $logPath = Join-Path $logs ('build-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '.log')
    & $gradle @gradleArgs 2>&1 | Tee-Object -FilePath $logPath
    if ($LASTEXITCODE -ne 0) { throw "Gradle failed with exit code $LASTEXITCODE. See $logPath" }

    $apkDirectory = Join-Path $repoRoot ('app/build/outputs/apk/' + $variant)
    $metadata = [System.IO.File]::ReadAllText((Join-Path $apkDirectory 'output-metadata.json')) | ConvertFrom-Json
    if ($metadata.applicationId -ne $expectedApplicationId -or @($metadata.elements).Count -ne 1) { throw "Expected one $configuration APK in Gradle output metadata." }
    $apkElement = @($metadata.elements)[0]
    $apkPath = [System.IO.Path]::GetFullPath((Join-Path $apkDirectory $apkElement.outputFile))
    if (-not $apkPath.StartsWith([System.IO.Path]::GetFullPath($apkDirectory) + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-Path -LiteralPath $apkPath -PathType Leaf)) { throw 'APK output metadata references a missing or unexpected file.' }
    & $licenseHelper -ApkPath $apkPath
    $verificationArguments = @{ ApkPath = $apkPath; AndroidSdk = $sdk; Configuration = $configuration }
    $signingMode = 'debug'
    if (-not $Debug) {
        $signingReport = [System.IO.File]::ReadAllText($signingReportPath) | ConvertFrom-Json
        if ($signingReport.mode -notin @('managed', 'external') -or $signingReport.certificateSha256 -notmatch '^[a-fA-F0-9]{64}$') {
            throw 'Release signing report is missing a valid signing identity.'
        }
        $signingMode = $signingReport.mode
        $verificationArguments.ExpectedCertificateSha256 = $signingReport.certificateSha256
    }
    $apkVerification = & (Join-Path $repoRoot 'build-support/verify-apk.ps1') @verificationArguments

    $testSummary = $null
    if (-not $SkipTests) {
        $testSummary = [ordered]@{ tests = 0; failures = 0; errors = 0; skipped = 0 }
        $results = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot "app/build/test-results/test${configuration}UnitTest") -Filter 'TEST-*.xml')
        if ($results.Count -eq 0) { throw 'Gradle finished without app unit test results.' }
        foreach ($result in $results) {
            $xml = [xml][System.IO.File]::ReadAllText($result.FullName)
            foreach ($metric in @('tests', 'failures', 'errors', 'skipped')) { $testSummary[$metric] += [int]$xml.testsuite.$metric }
        }
        if ($testSummary.failures -gt 0 -or $testSummary.errors -gt 0) { throw 'Unit test reports contain failures.' }
    }
    $artifacts = Get-OutputDirectory '_artifacts'
    $packagedApk = Join-Path $artifacts ([System.IO.Path]::GetFileName($apkPath))
    Copy-Item -LiteralPath $apkPath -Destination $packagedApk -Force
    $hash = (Get-FileHash -LiteralPath $packagedApk -Algorithm SHA256).Hash.ToLowerInvariant()
    [System.IO.File]::WriteAllText(($packagedApk + '.sha256'), ($hash + '  ' + [System.IO.Path]::GetFileName($packagedApk) + "`n"))
    $buildInfo = [ordered]@{ createdUtc = [DateTime]::UtcNow.ToString('o'); configuration = $configuration; applicationId = $metadata.applicationId; version = $apkElement.versionName; versionCode = $apkElement.versionCode; sha256 = $hash; signingMode = $signingMode; signature = $apkVerification; jdk = $jdk; androidSdk = $sdk; testsRequested = (-not $SkipTests); tests = $testSummary; log = $logPath }
    [System.IO.File]::WriteAllText(($packagedApk + '.build.json'), ($buildInfo | ConvertTo-Json -Depth 10))
    Write-Host "APK: $packagedApk"
    Write-Host "SHA256: $hash"
    Write-Host "APK signer SHA256: $($apkVerification.certificateSha256) ($configuration)"
    if ($SkipTests) { Write-Host 'Unit tests: skipped by -SkipTests.' } else { Write-Host "Unit tests: $($testSummary.tests), failures: 0." }
}
catch {
    Write-Error -Message $_.Exception.Message -ErrorAction Continue
    $exitCode = 1
}
finally {
    if ($locationChanged) { Pop-Location }
    foreach ($name in $savedEnvironment.Keys) {
        if ($null -eq $savedEnvironment[$name]) {
            Remove-Item -LiteralPath ('Env:\' + $name) -ErrorAction SilentlyContinue
        }
        else { [Environment]::SetEnvironmentVariable($name, [string]$savedEnvironment[$name], 'Process') }
    }
    if ($null -ne $buildLock) { $buildLock.Dispose() }
}
if ($exitCode -ne 0) { exit $exitCode }
