#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Chrome', 'ChromeBeta', 'Brave', 'Edge')]
    [string[]]$Browser = @('Chrome', 'ChromeBeta', 'Brave', 'Edge'),
    [string]$LocalAppData = $env:LOCALAPPDATA,
    [ValidateRange(1, 128)][int]$MaximumScriptMB = 16,
    [ValidateRange(256, 65536)][int]$MaximumSignalSpanCharacters = 4096,
    [string]$JsonPath
)

$ErrorActionPreference = 'Stop'
$modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'src\WindowsCacheMover.psd1'
Import-Module $modulePath -Force

$report = @(Get-ChromiumExtensionRiskReport `
    -Browser $Browser `
    -LocalAppData $LocalAppData `
    -MaximumScriptMB $MaximumScriptMB `
    -MaximumSignalSpanCharacters $MaximumSignalSpanCharacters |
    Sort-Object Browser, Profile, ExtensionName, Version, ScriptPath)

if ($JsonPath) {
    $fullJsonPath = [System.IO.Path]::GetFullPath($JsonPath)
    $parent = Split-Path -Parent $fullJsonPath
    if ($parent) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    ConvertTo-Json -InputObject $report -Depth 6 | Set-Content -LiteralPath $fullJsonPath -Encoding UTF8
}

$report
