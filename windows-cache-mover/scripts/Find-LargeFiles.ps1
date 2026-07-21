#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Path = $HOME,
    [double]$MinimumGB = 1,
    [ValidateRange(1, 1000)][int]$Top = 50,
    [string]$JsonPath
)

$modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'src\WindowsCacheMover.psd1'
Import-Module $modulePath -Force

$report = @(Find-LargeFile -Path $Path -MinimumGB $MinimumGB -Top $Top)
if ($JsonPath) {
    $parent = Split-Path -Parent ([System.IO.Path]::GetFullPath($JsonPath))
    if ($parent) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $report | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $JsonPath -Encoding UTF8
}
$report
