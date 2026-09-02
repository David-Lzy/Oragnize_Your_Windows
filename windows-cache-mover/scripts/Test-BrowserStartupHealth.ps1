#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Chrome', 'ChromeBeta', 'Brave', 'Edge')][string]$Browser = 'Chrome',
    [ValidateRange(0, 2147483647)][int]$ProcessId = 0,
    [ValidateRange(0, 3600)][int]$WaitForStartSeconds = 120,
    [ValidateRange(1, 3600)][int]$MonitorSeconds = 90,
    [ValidateRange(100, 60000)][int]$SampleMilliseconds = 500,
    [ValidateRange(1, 2147483647)][int]$HandleWarningThreshold = 12000,
    [ValidateRange(1, 2147483647)][int]$PrivateMemoryWarningMB = 2048,
    [ValidateRange(1, 100)][int]$ConsecutiveWarningSamples = 3,
    [string]$LocalAppData = $env:LOCALAPPDATA,
    [string]$JsonPath,
    [switch]$FailOnUnhealthy
)

$ErrorActionPreference = 'Stop'
$modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'src\WindowsCacheMover.psd1'
Import-Module $modulePath -Force

$report = Test-BrowserStartupHealth `
    -Browser $Browser `
    -ProcessId $ProcessId `
    -WaitForStartSeconds $WaitForStartSeconds `
    -MonitorSeconds $MonitorSeconds `
    -SampleMilliseconds $SampleMilliseconds `
    -HandleWarningThreshold $HandleWarningThreshold `
    -PrivateMemoryWarningMB $PrivateMemoryWarningMB `
    -ConsecutiveWarningSamples $ConsecutiveWarningSamples `
    -LocalAppData $LocalAppData

if ($JsonPath) {
    $fullJsonPath = [System.IO.Path]::GetFullPath($JsonPath)
    $parent = Split-Path -Parent $fullJsonPath
    if ($parent) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $fullJsonPath -Encoding UTF8
}

$report | Select-Object Browser, ProcessId, Healthy, Status, StartedAt, MonitoredSeconds,
    SampleCount, PeakHandleCount, PeakPrivateMemoryMB, FinalHandleCount,
    FinalPrivateMemoryMB, Guidance

if ($FailOnUnhealthy -and -not $report.Healthy) {
    throw "Browser startup health check failed with status '$($report.Status)'."
}
