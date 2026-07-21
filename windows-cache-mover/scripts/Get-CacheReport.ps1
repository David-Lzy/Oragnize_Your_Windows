#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$DestinationRoot = 'F:\',
    [string[]]$Browser = @('Chrome', 'ChromeBeta', 'Brave', 'Edge'),
    [bool]$IncludeDeveloper = $true,
    [switch]$IncludeMissing,
    [switch]$Fast,
    [string]$JsonPath
)

$modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'src\WindowsCacheMover.psd1'
Import-Module $modulePath -Force

$report = @(Get-CacheAudit `
    -DestinationRoot $DestinationRoot `
    -Browser $Browser `
    -IncludeDeveloper:$IncludeDeveloper `
    -IncludeMissing:$IncludeMissing `
    -Fast:$Fast |
    Sort-Object GB -Descending)

if ($JsonPath) {
    $parent = Split-Path -Parent ([System.IO.Path]::GetFullPath($JsonPath))
    if ($parent) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $JsonPath -Encoding UTF8
}

$report
