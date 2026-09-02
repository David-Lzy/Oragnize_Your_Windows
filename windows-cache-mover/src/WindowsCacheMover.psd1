@{
    RootModule = 'WindowsCacheMover.psm1'
    ModuleVersion = '0.3.0'
    GUID = 'd982528e-8be3-4da0-9800-a7e7a2b7c19d'
    Author = 'David-Lzy'
    CompanyName = ''
    Copyright = '(c) David-Lzy. All rights reserved.'
    Description = 'Audits, relocates, verifies, and restores selected Windows caches, and diagnoses Chromium startup resource storms.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Get-CacheCatalog',
        'Get-CacheAudit',
        'Get-DestinationStorageProfile',
        'Invoke-CacheMigration',
        'Test-CacheMigration',
        'Restore-CacheMigration',
        'Get-ChromiumExtensionRiskReport',
        'Test-BrowserStartupHealth',
        'Find-LargeFile'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = @{
        PSData = @{
            Tags = @('Windows', 'Cache', 'Storage', 'Junction', 'Chromium', 'Diagnostics')
            ProjectUri = 'https://github.com/David-Lzy/Oragnize_Your_Windows'
        }
    }
}
