#Requires -Version 5.1
[CmdletBinding(DefaultParameterSetName = 'Prepare')]
param(
    [Parameter(ParameterSetName = 'Prepare')]
    [string]$CacheDirectory,

    [Parameter(Mandatory = $true, ParameterSetName = 'Manifest')]
    [string]$ManifestPath,

    [Parameter(Mandatory = $true, ParameterSetName = 'Apk')]
    [string]$ApkPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-PropertyValue {
    param([AllowNull()][object]$Value, [string]$Name)
    if ($null -eq $Value) { return $null }
    $property = $Value.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

function Read-JsonFile {
    param([string]$Path)
    try {
        return ([System.IO.File]::ReadAllText($Path) | ConvertFrom-Json)
    } catch {
        throw "Cannot read license JSON '$Path': $($_.Exception.Message)"
    }
}

$descriptorFile = Join-Path $PSScriptRoot 'licenses.json'
$descriptors = @(Get-PropertyValue (Read-JsonFile $descriptorFile) 'licenses')
if ($descriptors.Count -eq 0) { throw "No license descriptors found in '$descriptorFile'." }
$knownLicenses = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
foreach ($descriptor in $descriptors) {
    $hash = [string](Get-PropertyValue $descriptor 'hash')
    if ($hash -notmatch '^[A-Za-z0-9._-]+$' -or $knownLicenses.ContainsKey($hash)) {
        throw "Invalid or duplicate license descriptor hash '$hash'."
    }
    $knownLicenses.Add($hash, $descriptor)
}

function Assert-LicenseText {
    param([string]$Text, [string]$Hash)
    if ([string]::IsNullOrWhiteSpace($Text)) { throw "License '$Hash' has no full text." }
    if ($Text -match '(?i)<!doctype html|<html[\s>]') { throw "License '$Hash' contains an HTML response instead of plain text." }
    if ($knownLicenses.ContainsKey($Hash)) {
        $descriptor = $knownLicenses[$Hash]
        $minimum = [int]$descriptor.minimumLength
        if ($Text.Length -lt $minimum -or -not $Text.Contains([string]$descriptor.textContains)) {
            throw "License '$Hash' text is incomplete or does not match its expected license."
        }
        if ($Hash -eq 'e0deb79316377348046c5a35d1eba645' -and -not $Text.Contains('Version 3, 29 June 2007')) {
            throw "License '$Hash' is not the expected LGPL version 3 text."
        }
    } elseif ($Text.Length -lt 500) {
        throw "New license '$Hash' has a suspiciously short text; review its dependency metadata."
    }
}

function Assert-LicenseManifest {
    param([object]$Manifest, [string]$Source)
    $libraries = @(Get-PropertyValue $Manifest 'libraries')
    $licenses = Get-PropertyValue $Manifest 'licenses'
    if ($libraries.Count -eq 0 -or $null -eq $libraries[0] -or $null -eq $licenses) {
        throw "License manifest '$Source' must contain dependency libraries and licenses."
    }
    $licenseProperties = @($licenses.PSObject.Properties)
    if ($licenseProperties.Count -eq 0) { throw "License manifest '$Source' contains no licenses." }

    $available = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($property in $licenseProperties) {
        $hash = $property.Name
        $license = $property.Value
        if ([string]::IsNullOrWhiteSpace([string](Get-PropertyValue $license 'name'))) {
            throw "License '$hash' in '$Source' has no name."
        }
        # AndroidParser uses the dictionary key; the plugin may recompute the
        # serialized hash field when local content is merged into an existing license.
        Assert-LicenseText ([string](Get-PropertyValue $license 'content')) $hash
        [void]$available.Add($hash)
    }

    foreach ($library in $libraries) {
        $id = [string](Get-PropertyValue $library 'uniqueId')
        $references = @(Get-PropertyValue $library 'licenses')
        if ($references.Count -eq 0 -or $null -eq $references[0]) {
            throw "Dependency '$id' in '$Source' has no declared licenses."
        }
        foreach ($reference in $references) {
            if (-not $available.Contains([string]$reference)) {
                throw "Dependency '$id' in '$Source' references missing license '$reference'."
            }
        }
    }
    Write-Host ("Validated {0} dependencies and {1} complete license texts in {2}." -f $libraries.Count, $available.Count, $Source)
}

if ($PSCmdlet.ParameterSetName -eq 'Manifest') {
    Assert-LicenseManifest (Read-JsonFile $ManifestPath) $ManifestPath
    return
}

if ($PSCmdlet.ParameterSetName -eq 'Apk') {
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead([System.IO.Path]::GetFullPath($ApkPath))
    try {
        $entries = @($archive.Entries | Where-Object { $_.FullName -match '(^|/)aboutlibraries\.json$' })
        if ($entries.Count -ne 1) {
            throw "APK '$ApkPath' must contain exactly one aboutlibraries.json; found $($entries.Count)."
        }
        $reader = [System.IO.StreamReader]::new($entries[0].Open())
        try { $json = $reader.ReadToEnd() } finally { $reader.Dispose() }
        try { $manifest = $json | ConvertFrom-Json } catch {
            throw "The packaged aboutlibraries.json in '$ApkPath' is invalid: $($_.Exception.Message)"
        }
        Assert-LicenseManifest $manifest "$ApkPath!/$($entries[0].FullName)"
    } finally {
        $archive.Dispose()
    }
    return
}

$cacheRoot = [System.IO.Path]::GetFullPath($(if ([string]::IsNullOrWhiteSpace($CacheDirectory)) { Join-Path (Split-Path $PSScriptRoot -Parent) '.build/licenses' } else { $CacheDirectory }))
$licensesDirectory = [System.IO.Path]::Combine($cacheRoot, 'licenses')
[void][System.IO.Directory]::CreateDirectory($licensesDirectory)
$encoding = [System.Text.UTF8Encoding]::new($false)

foreach ($descriptor in $descriptors) {
    $hash = [string]$descriptor.hash
    $outputPath = [System.IO.Path]::Combine($licensesDirectory, "$hash.json")
    $content = $null
    if ([System.IO.File]::Exists($outputPath)) {
        try {
            $cached = Read-JsonFile $outputPath
            if ((Get-PropertyValue $cached 'hash') -cne $hash -or
                (Get-PropertyValue $cached 'name') -cne $descriptor.name -or
                (Get-PropertyValue $cached 'url') -cne $descriptor.url -or
                (Get-PropertyValue $cached 'spdxId') -cne (Get-PropertyValue $descriptor 'spdxId')) {
                throw 'The cached license metadata differs from the tracked descriptor.'
            }
            $cachedText = [string](Get-PropertyValue $cached 'content')
            Assert-LicenseText $cachedText $hash
            $content = $cachedText
        } catch {
            Write-Host "Refreshing invalid license cache for $($hash): $($_.Exception.Message)"
        }
    }

    if ($null -eq $content) {
        $failures = [System.Collections.Generic.List[string]]::new()
        foreach ($uri in $descriptor.textUrls) {
            try {
                if ($uri -notmatch '^https://') { throw 'License text downloads require HTTPS.' }
                Write-Host "Downloading full license text for $hash from $uri"
                $previousProtocol = [System.Net.ServicePointManager]::SecurityProtocol
                try {
                    [System.Net.ServicePointManager]::SecurityProtocol = $previousProtocol -bor [System.Net.SecurityProtocolType]::Tls12
                    $response = Invoke-WebRequest -Uri $uri -UseBasicParsing -TimeoutSec 20 -MaximumRedirection 5
                } finally {
                    [System.Net.ServicePointManager]::SecurityProtocol = $previousProtocol
                }
                $downloaded = if ($response.Content -is [byte[]]) {
                    [System.Text.Encoding]::UTF8.GetString($response.Content)
                } else {
                    [string]$response.Content
                }
                Assert-LicenseText $downloaded $hash
                $content = $downloaded
                break
            } catch {
                $failures.Add("$uri : $($_.Exception.Message)")
            }
        }
        if ($null -eq $content) {
            throw "Cannot obtain complete text for license '$hash'. Check HTTPS access and rerun the build. $($failures -join ' | ')"
        }
    }

    # LicenseReader uses hash as internalHash. Keeping the SDK's custom LGPL hash
    # preserves dependency references when its missing content is filled locally.
    $license = [ordered]@{ name = $descriptor.name; url = $descriptor.url; content = $content; hash = $hash }
    $spdxId = Get-PropertyValue $descriptor 'spdxId'
    if ($spdxId) { $license.spdxId = $spdxId }
    [System.IO.File]::WriteAllText($outputPath, ($license | ConvertTo-Json -Depth 5), $encoding)
}

Write-Host "Prepared $($descriptors.Count) complete license overrides in '$cacheRoot'."
