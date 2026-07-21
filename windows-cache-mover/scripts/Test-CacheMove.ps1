#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$DestinationRoot = 'F:\',
    [string]$ManifestPath
)

$modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'src\WindowsCacheMover.psd1'
Import-Module $modulePath -Force

if (-not $ManifestPath) {
    $manifestDirectory = Join-Path $DestinationRoot '.cache-mover'
    $latest = Get-ChildItem -LiteralPath $manifestDirectory -Filter 'manifest-*.json' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if (-not $latest) {
        throw "No migration manifest was found under '$manifestDirectory'."
    }
    $ManifestPath = $latest.FullName
}

Test-CacheMigration -ManifestPath $ManifestPath
