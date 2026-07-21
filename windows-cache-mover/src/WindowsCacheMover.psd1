@{
    RootModule = 'WindowsCacheMover.psm1'
    ModuleVersion = '0.1.0'
    GUID = 'd982528e-8be3-4da0-9800-a7e7a2b7c19d'
    Author = 'David-Lzy'
    CompanyName = ''
    Copyright = '(c) David-Lzy. All rights reserved.'
    Description = 'Audits, relocates, verifies, and restores selected Windows application caches.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Get-CacheCatalog',
        'Get-CacheAudit',
        'Invoke-CacheMigration',
        'Test-CacheMigration',
        'Restore-CacheMigration',
        'Find-LargeFile'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = @{
        PSData = @{
            Tags = @('Windows', 'Cache', 'Storage', 'Junction')
            ProjectUri = 'https://github.com/David-Lzy/Oragnize_Your_Windows'
        }
    }
}
