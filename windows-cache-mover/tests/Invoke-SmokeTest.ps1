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
    $largeFilePath = Join-Path $homePath 'large-file.bin'
    $largeFile = [System.IO.File]::Open($largeFilePath, [System.IO.FileMode]::CreateNew)
    try {
        $largeFile.SetLength(1MB)
    } finally {
        $largeFile.Dispose()
    }

    $catalog = @(Get-CacheCatalog -DestinationRoot $destination -HomePath $homePath -LocalAppData $localAppData -IncludeMissing)
    if (@($catalog | Where-Object Kind -eq 'Developer').Count -ne 7) {
        throw 'The developer cache catalog is incomplete.'
    }
    $chromeBetaCache = @($catalog | Where-Object Name -eq 'ChromeBeta:Default:Cache')
    $expectedChromeBetaSource = Join-Path $localAppData 'Google\Chrome Beta\User Data\Default\Cache'
    $expectedChromeBetaTarget = Join-Path $destination 'BrowserCache\ChromeBeta\Default\Cache'
    if ($chromeBetaCache.Count -ne 1 -or
        $chromeBetaCache[0].Source -ine $expectedChromeBetaSource -or
        $chromeBetaCache[0].Target -ine $expectedChromeBetaTarget -or
        $chromeBetaCache[0].MigrationClass -ne 'BrowserRestoreHotPath' -or
        $chromeBetaCache[0].DefaultMigration) {
        throw 'The Chrome Beta cache catalog mapping is incorrect.'
    }
    $chromeBetaModel = @($catalog | Where-Object Name -eq 'ChromeBeta:OptGuideOnDeviceModel')
    if ($chromeBetaModel.Count -ne 1 -or
        $chromeBetaModel[0].MigrationClass -ne 'BrowserColdModel' -or
        -not $chromeBetaModel[0].DefaultMigration) {
        throw 'The Chrome Beta cold-model classification is incorrect.'
    }

    $module = Get-Module WindowsCacheMover
    $defaultBrowserSelection = @(& $module {
        param([object[]]$Records)
        Select-CacheMigrationRecords `
            -Catalog $Records `
            -Browser @('ChromeBeta') `
            -IncludeDeveloper $false `
            -IncludeBrowserRuntimeCaches $false
    } $catalog)
    if ($defaultBrowserSelection.Count -ne 3 -or
        @($defaultBrowserSelection | Where-Object MigrationClass -ne 'BrowserColdModel').Count -ne 0) {
        throw 'Default browser selection must contain only Chrome cold-model caches.'
    }

    $explicitBrowserSelection = @(& $module {
        param([object[]]$Records)
        Select-CacheMigrationRecords `
            -Catalog $Records `
            -Browser @('ChromeBeta') `
            -IncludeDeveloper $false `
            -IncludeBrowserRuntimeCaches $true
    } $catalog)
    if (@($explicitBrowserSelection | Where-Object MigrationClass -eq 'BrowserRestoreHotPath').Count -eq 0 -or
        @($explicitBrowserSelection | Where-Object MigrationClass -eq 'BrowserPackageCache').Count -eq 0) {
        throw 'Explicit browser runtime selection did not include protected cache classes.'
    }

    $blockedProfile = [pscustomobject]@{
        MediaType = 'Unknown'
        ConfirmedSSD = $false
        Reason = 'Synthetic fail-closed test profile.'
    }
    $destinationBlocked = $false
    try {
        & $module {
            param([object[]]$Records, $Profile)
            Assert-BrowserDestinationSafety `
                -SelectedRecords $Records `
                -DestinationStorage $Profile `
                -Destination 'X:\' `
                -AllowSlowOrUnknownBrowserDestination $false
        } $explicitBrowserSelection $blockedProfile
    } catch {
        if ($_.Exception.Message -like 'Refusing browser runtime/package cache migration*') {
            $destinationBlocked = $true
        } else {
            throw
        }
    }
    if (-not $destinationBlocked) {
        throw 'Unknown browser runtime-cache destinations must fail closed.'
    }
    & $module {
        param([object[]]$Records, $Profile)
        Assert-BrowserDestinationSafety `
            -SelectedRecords $Records `
            -DestinationStorage $Profile `
            -Destination 'X:\' `
            -AllowSlowOrUnknownBrowserDestination $true
    } $explicitBrowserSelection $blockedProfile

    $destinationProfile = Get-DestinationStorageProfile -DestinationRoot $destination
    foreach ($property in @('MediaType', 'ConfirmedSSD', 'BusType', 'PhysicalDiskCount', 'Reason')) {
        if ($destinationProfile.PSObject.Properties.Name -notcontains $property) {
            throw "Destination storage profile is missing '$property'."
        }
    }

    $audit = @(Get-CacheAudit `
        -DestinationRoot $destination `
        -Browser ChromeBeta `
        -IncludeMissing `
        -Fast `
        -HomePath $homePath `
        -LocalAppData $localAppData)
    $hotAudit = @($audit | Where-Object Name -eq 'ChromeBeta:Default:Cache')
    $modelAudit = @($audit | Where-Object Name -eq 'ChromeBeta:OptGuideOnDeviceModel')
    if ($hotAudit.Count -ne 1 -or $hotAudit[0].SelectedForMigration -or
        $modelAudit.Count -ne 1 -or -not $modelAudit[0].SelectedForMigration) {
        throw 'Audit selection flags do not reflect the safe browser defaults.'
    }
    $largeFileReport = @(Find-LargeFile -Path $homePath -MinimumGB 0.0005 -Top 5 | Where-Object Path -eq $largeFilePath)
    if ($largeFileReport.Count -ne 1 -or
        $largeFileReport[0].PSObject.Properties.Name -notcontains 'AllocatedGB' -or
        $largeFileReport[0].PSObject.Properties.Name -notcontains 'Sparse') {
        throw 'The large-file report is missing allocation metadata.'
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
        DefaultBrowserMappings = $defaultBrowserSelection.Count
        ExplicitBrowserMappings = $explicitBrowserSelection.Count
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
