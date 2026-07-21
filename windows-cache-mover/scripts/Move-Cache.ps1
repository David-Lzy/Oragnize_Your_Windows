#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$DestinationRoot,
    [string[]]$Browser = @('Chrome', 'ChromeBeta', 'Brave', 'Edge'),
    [bool]$IncludeDeveloper = $true,
    [switch]$DiscardExisting,
    [switch]$Apply
)

$modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'src\WindowsCacheMover.psd1'
Import-Module $modulePath -Force

if (-not $Apply) {
    Write-Warning 'Read-only preview. Re-run with -Apply to perform the migration.'
    Get-CacheAudit -DestinationRoot $DestinationRoot -Browser $Browser -IncludeDeveloper:$IncludeDeveloper |
        Sort-Object GB -Descending
    return
}

$result = Invoke-CacheMigration `
    -DestinationRoot $DestinationRoot `
    -Browser $Browser `
    -IncludeDeveloper:$IncludeDeveloper `
    -DiscardExisting:$DiscardExisting `
    -Confirm:$false

$result
if ($result.Changed) {
    Test-CacheMigration -ManifestPath $result.ManifestPath
}
