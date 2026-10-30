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

function New-TestApk {
    param([string]$Name, [System.Collections.IDictionary]$Resources)
    $path = Join-Path $testRoot $Name
    $archive = [System.IO.Compression.ZipFile]::Open($path, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($name in $Resources.Keys) {
            $entry = $archive.CreateEntry($name)
            $writer = [System.IO.StreamWriter]::new($entry.Open(), $encoding)
            try { $writer.Write([string]$Resources[$name]) } finally { $writer.Dispose() }
        }
    } finally {
        $archive.Dispose()
    }
    return $path
}

$validJson = $valid | ConvertTo-Json -Depth 12
$apkPath = New-TestApk 'fixture.apk' ([ordered]@{ 'res/raw/aboutlibraries.json' = $validJson })
& $helper -ApkPath $apkPath
$script:passed++
Write-Host 'PASS: validator checks the actual manifest inside the APK archive'

$missingApk = New-TestApk 'missing-resource.apk' ([ordered]@{})
Assert-Rejected 'APK missing its license resource fails' { & $helper -ApkPath $missingApk } 'exactly one AboutLibraries JSON resource'

$renamedApk = New-TestApk 'optimized-resources.apk' ([ordered]@{
    'res/M7.json' = $validJson
    'res/unrelated.json' = '{"version":1,"name":"unrelated application data"}'
})
& $helper -ApkPath $renamedApk
$script:passed++
Write-Host 'PASS: optimized resource name is discovered while unrelated JSON is ignored'

$ambiguousApk = New-TestApk 'ambiguous-resources.apk' ([ordered]@{
    'res/raw/aboutlibraries.json' = $validJson
    'res/M7.json' = $validJson
})
Assert-Rejected 'named and renamed license resources are ambiguous' { & $helper -ApkPath $ambiguousApk } 'found 2'

$invalidNamedApk = New-TestApk 'invalid-named-resource.apk' ([ordered]@{
    'res/raw/aboutlibraries.json' = '{invalid json'
    'res/M7.json' = $validJson
})
Assert-Rejected 'malformed named manifest is not hidden by a valid fallback' { & $helper -ApkPath $invalidNamedApk } 'is invalid'

$incompleteJson = New-Manifest -Text '' | ConvertTo-Json -Depth 12
$incompleteApk = New-TestApk 'incomplete-renamed-resource.apk' ([ordered]@{ 'res/M7.json' = $incompleteJson })
Assert-Rejected 'renamed resource still requires full license text' { & $helper -ApkPath $incompleteApk } 'has no full text'

$ambiguousIncompleteApk = New-TestApk 'ambiguous-incomplete-resources.apk' ([ordered]@{
    'res/M7.json' = $validJson
    'res/Z1.json' = $incompleteJson
})
Assert-Rejected 'incomplete alternative manifest still causes ambiguity' { & $helper -ApkPath $ambiguousIncompleteApk } 'found 2'

Write-Host "$script:passed license helper regression checks passed."
