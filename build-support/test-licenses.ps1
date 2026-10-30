#Requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$helper = Join-Path $PSScriptRoot 'prepare-licenses.ps1'
$repository = Split-Path $PSScriptRoot -Parent
$testRoot = Join-Path $repository ('.build/license-tests/' + [System.Guid]::NewGuid().ToString('N'))
[void][System.IO.Directory]::CreateDirectory($testRoot)
$fixtureText = [System.IO.File]::ReadAllText((Join-Path $repository 'LICENSE'))
$manifestPath = Join-Path $testRoot 'manifest.json'
$encoding = [System.Text.UTF8Encoding]::new($false)
$script:passed = 0

function New-Manifest {
    param([string]$Hash = 'Example-License', [string]$Text = $fixtureText)
    $licenseMap = [ordered]@{}
    $licenseMap[$Hash] = [ordered]@{
        name = 'Example license'
        url = 'https://example.invalid/license'
        content = $Text
        # AndroidParser uses the map key, even if the plugin recomputes this field.
        hash = 'computed-field-differs-from-map-key'
    }
    return [ordered]@{
        libraries = @([ordered]@{ uniqueId = 'example:dependency'; licenses = @($Hash) })
        licenses = $licenseMap
    }
}

function Save-Manifest {
    param([object]$Manifest)
    [System.IO.File]::WriteAllText($manifestPath, ($Manifest | ConvertTo-Json -Depth 12), $encoding)
}

function Assert-Rejected {
    param([string]$Name, [scriptblock]$Action, [string]$Expected)
    try {
        & $Action
    } catch {
        if ($_.Exception.Message -notlike "*$Expected*") {
            throw "Test '$Name' failed with an unexpected error: $($_.Exception.Message)"
        }
        $script:passed++
        Write-Host "PASS: $Name"
        return
    }
    throw "Test '$Name' incorrectly accepted an invalid manifest."
}

$valid = New-Manifest
Save-Manifest $valid
& $helper -ManifestPath $manifestPath
$script:passed++
Write-Host 'PASS: complete custom license remains linked by its original map key'

Save-Manifest (New-Manifest -Text '')
Assert-Rejected 'blank license text fails' { & $helper -ManifestPath $manifestPath } 'has no full text'

Save-Manifest (New-Manifest -Text ('<html><body>' + $fixtureText + '</body></html>'))
Assert-Rejected 'HTML download response fails' { & $helper -ManifestPath $manifestPath } 'HTML response'

$missingReference = New-Manifest
$missingReference.libraries[0].licenses = @('Missing-License')
Save-Manifest $missingReference
Assert-Rejected 'dangling dependency license reference fails' { & $helper -ManifestPath $manifestPath } 'references missing license'

$missingDeclaration = New-Manifest
$missingDeclaration.libraries[0].licenses = @()
Save-Manifest $missingDeclaration
Assert-Rejected 'dependency without license metadata fails' { & $helper -ManifestPath $manifestPath } 'has no declared licenses'

Save-Manifest (New-Manifest -Hash 'MIT' -Text 'Permission is hereby granted')
Assert-Rejected 'truncated known license fails' { & $helper -ManifestPath $manifestPath } 'incomplete'

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$apkPath = Join-Path $testRoot 'fixture.apk'
$archive = [System.IO.Compression.ZipFile]::Open($apkPath, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    $entry = $archive.CreateEntry('res/raw/aboutlibraries.json')
    $writer = [System.IO.StreamWriter]::new($entry.Open(), $encoding)
    try { $writer.Write(($valid | ConvertTo-Json -Depth 12)) } finally { $writer.Dispose() }
} finally {
    $archive.Dispose()
}
& $helper -ApkPath $apkPath
$script:passed++
Write-Host 'PASS: validator checks the actual manifest inside the APK archive'

$missingApk = Join-Path $testRoot 'missing-resource.apk'
$archive = [System.IO.Compression.ZipFile]::Open($missingApk, [System.IO.Compression.ZipArchiveMode]::Create)
$archive.Dispose()
Assert-Rejected 'APK missing its license resource fails' { & $helper -ApkPath $missingApk } 'exactly one aboutlibraries.json'

Write-Host "$script:passed license helper regression checks passed."
