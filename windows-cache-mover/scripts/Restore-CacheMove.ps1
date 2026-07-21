#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ManifestPath,
    [switch]$CopyBack,
    [switch]$Apply
)

$modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'src\WindowsCacheMover.psd1'
Import-Module $modulePath -Force

if (-not $Apply) {
    Write-Warning 'Read-only validation. Re-run with -Apply to restore the original cache paths.'
    Test-CacheMigration -ManifestPath $ManifestPath
    return
}

Restore-CacheMigration -ManifestPath $ManifestPath -CopyBack:$CopyBack -Confirm:$false
