#Requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'src\WindowsCacheMover.psd1'
Import-Module $modulePath -Force

$testRoot = Join-Path $env:TEMP ("windows-cache-mover-test-{0}" -f ([guid]::NewGuid().ToString('N')))
$homePath = Join-Path $testRoot 'home'
$localAppData = Join-Path $testRoot 'local'
$destination = Join-Path $testRoot 'destination'

try {
    $condaCache = Join-Path $homePath '.conda\pkgs'
    $pipCache = Join-Path $localAppData 'pip\cache'
    New-Item -ItemType Directory -Path $condaCache,$pipCache -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $condaCache 'package.bin') -Value 'conda-cache-test' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $pipCache 'wheel.bin') -Value 'pip-cache-test' -Encoding ASCII

    $catalog = @(Get-CacheCatalog -DestinationRoot $destination -HomePath $homePath -LocalAppData $localAppData -IncludeMissing)
    if (@($catalog | Where-Object Kind -eq 'Developer').Count -ne 7) {
        throw 'The developer cache catalog is incomplete.'
    }

    $migration = Invoke-CacheMigration `
        -DestinationRoot $destination `
        -Browser @() `
        -IncludeDeveloper `
        -HomePath $homePath `
        -LocalAppData $localAppData `
        -SkipEnvironmentChanges `
        -Confirm:$false
    if (-not $migration.Changed -or -not (Test-Path -LiteralPath $migration.ManifestPath)) {
        throw 'Migration did not produce a manifest.'
    }

    $verification = @(Test-CacheMigration -ManifestPath $migration.ManifestPath)
    if (@($verification | Where-Object { -not $_.LinkOK -or -not $_.EnvironmentOK }).Count -gt 0) {
        throw 'Migration verification failed.'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $destination 'DevCache\conda\pkgs\package.bin'))) {
        throw 'Existing Conda cache content was not preserved.'
    }

    $restored = @(Restore-CacheMigration -ManifestPath $migration.ManifestPath -CopyBack -Confirm:$false)
    if ($restored.Count -ne 7) {
        throw 'Restore did not process every developer cache mapping.'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $condaCache 'package.bin'))) {
        throw 'Restore did not copy cache content back.'
    }

    [pscustomobject]@{
        Passed = $true
        CatalogRecords = $catalog.Count
        MigratedMappings = $migration.Mappings.Count
        RestoredMappings = $restored.Count
    }
} finally {
    $fullTestRoot = [System.IO.Path]::GetFullPath($testRoot)
    $fullTempRoot = [System.IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
    if ($fullTestRoot.StartsWith($fullTempRoot, [System.StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $fullTestRoot) -like 'windows-cache-mover-test-*' -and
        (Test-Path -LiteralPath $fullTestRoot)) {
        Remove-Item -LiteralPath $fullTestRoot -Recurse -Force
    }
}
