#requires -Version 5.1
<#
.SYNOPSIS
Validates a completed Codex migration without changing the system.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$DestinationRoot,
    [switch]$AsJson
)

$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot '..\src\CodexMover.Common.psm1'
Import-Module $modulePath -Force

$destinationPath = Get-CodexNormalizedPath -Path $DestinationRoot
$migrationDirectory = Join-Path $destinationPath 'migration'
$statePath = Join-Path $migrationDirectory 'migration-state.json'
$statusPath = Join-Path $migrationDirectory 'migration-status.json'
if (-not (Test-Path -LiteralPath $statePath) -or -not (Test-Path -LiteralPath $statusPath)) {
    throw "Migration state or status file is missing under $migrationDirectory"
}

$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
$status = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
if ([int]$state.schema_version -ne 1 -or [int]$status.schema_version -ne 1) {
    throw 'Unsupported migration state/status schema version.'
}
if (-not (Get-CodexNormalizedPath -Path ([string]$state.destination_root)).Equals($destinationPath, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'DestinationRoot does not match the recorded migration state.'
}
$recordedProfile = Get-CodexNormalizedPath -Path ([string]$state.source_profile)
$currentProfile = Get-CodexNormalizedPath -Path $env:USERPROFILE
if (-not $recordedProfile.Equals($currentProfile, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The migration state does not belong to the current Windows user profile.'
}
$expectedHome = Get-CodexNormalizedPath -Path (Join-Path $destinationPath 'home')
if (-not (Get-CodexNormalizedPath -Path ([string]$state.target.home)).Equals($expectedHome, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Unexpected CODEX_HOME target in migration state.'
}
$results = @()

function Add-ValidationResult {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Passed,
        [Parameter(Mandatory)][string]$Detail,
        [bool]$Critical = $true
    )

    $script:results += [pscustomobject]@{
        Name = $Name
        Passed = $Passed
        Critical = $Critical
        Detail = $Detail
    }
}

$validStatuses = @('success_pending_cleanup', 'success_pending_cleanup_with_warnings', 'completed')
$statusValid = [string]$status.status -in $validStatuses
Add-ValidationResult -Name 'Migration status' -Passed $statusValid -Detail ([string]$status.status)

$junctionRecords = @($status.junctions)
if ($junctionRecords.Count -eq 0) {
    Add-ValidationResult -Name 'Migrated junctions' -Passed $false -Detail 'No junction records are present.'
}
foreach ($junction in $junctionRecords) {
    $passed = Test-CodexJunction -Path ([string]$junction.source) -ExpectedTarget ([string]$junction.target)
    Add-ValidationResult -Name ("Junction: {0}" -f $junction.source) -Passed $passed -Detail ([string]$junction.target)
}

$expectedCodexHome = Get-CodexNormalizedPath -Path ([string]$state.target.home)
$actualCodexHome = [Environment]::GetEnvironmentVariable('CODEX_HOME', 'User')
$codexHomeMatches = $false
if ($actualCodexHome) {
    $codexHomeMatches = (Get-CodexNormalizedPath -Path $actualCodexHome).Equals($expectedCodexHome, [StringComparison]::OrdinalIgnoreCase)
}
Add-ValidationResult -Name 'User CODEX_HOME' -Passed $codexHomeMatches -Detail ([string]$actualCodexHome)

if ($state.current_session_relative_path) {
    $sessionRelativePath = [string]$state.current_session_relative_path
    if ([IO.Path]::IsPathRooted($sessionRelativePath)) {
        throw 'The protected current-session path must be relative to CODEX_HOME.'
    }
    $logicalSession = Get-CodexNormalizedPath -Path (Join-Path ([string]$state.source.home) $sessionRelativePath)
    $physicalSession = Get-CodexNormalizedPath -Path (Join-Path ([string]$state.target.home) $sessionRelativePath)
    if (-not $logicalSession.StartsWith((Get-CodexNormalizedPath -Path ([string]$state.source.home)) + '\', [StringComparison]::OrdinalIgnoreCase) -or
        -not $physicalSession.StartsWith((Get-CodexNormalizedPath -Path ([string]$state.target.home)) + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The protected current-session path escapes CODEX_HOME.'
    }
    $sameSessionFile = $false
    $sessionDetail = 'One or both session paths are missing.'
    if ((Test-Path -LiteralPath $logicalSession) -and (Test-Path -LiteralPath $physicalSession)) {
        try {
            $sameSessionFile = Test-CodexSameFileId -FirstPath $logicalSession -SecondPath $physicalSession
            $sessionDetail = if ($sameSessionFile) { Get-CodexFileId -Path $physicalSession } else { 'File IDs differ.' }
        }
        catch {
            $sessionDetail = $_.Exception.Message
        }
    }
    Add-ValidationResult -Name 'Protected current session' -Passed $sameSessionFile -Detail $sessionDetail
}
else {
    Add-ValidationResult -Name 'Protected current session' -Passed $true -Detail 'No task ID/session file was recorded.' -Critical $false
}

if ([bool]$state.skip_msix) {
    Add-ValidationResult -Name 'MSIX physical payload' -Passed $true -Detail 'Skipped by migration request.' -Critical $false
}
else {
    $package = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $package) {
        Add-ValidationResult -Name 'MSIX physical payload' -Passed $false -Detail 'OpenAI.Codex is not installed.'
    }
    else {
        $destinationDrive = [IO.Path]::GetPathRoot($destinationPath).Substring(0, 1)
        $physicalRoot = Join-Path (('{0}:\WindowsApps' -f $destinationDrive)) $package.PackageFullName
        $logicalRoot = [string]$package.InstallLocation
        $physicalExists = Test-Path -LiteralPath $physicalRoot
        $logicalExecutable = Join-Path $logicalRoot 'app\ChatGPT.exe'
        $physicalExecutable = Join-Path $physicalRoot 'app\ChatGPT.exe'
        $sameExecutable = $false
        if ((Test-Path -LiteralPath $logicalExecutable) -and (Test-Path -LiteralPath $physicalExecutable)) {
            try {
                $sameExecutable = Test-CodexSameFileId -FirstPath $logicalExecutable -SecondPath $physicalExecutable
            }
            catch {
                $sameExecutable = $false
            }
        }
        $logicalOnDestination = (Get-CodexNormalizedPath -Path $logicalRoot).StartsWith(('{0}:\' -f $destinationDrive), [StringComparison]::OrdinalIgnoreCase)
        $logicalItem = Get-Item -LiteralPath $logicalRoot -Force -ErrorAction SilentlyContinue
        $junctionMatches = $false
        if ($logicalItem -and $logicalItem.LinkType -eq 'Junction') {
            $logicalTarget = [string]($logicalItem.Target | Select-Object -First 1)
            $junctionMatches = (Get-CodexNormalizedPath -Path $logicalTarget).Equals((Get-CodexNormalizedPath -Path $physicalRoot), [StringComparison]::OrdinalIgnoreCase)
        }
        $appxPassed = $physicalExists -and ($logicalOnDestination -or $junctionMatches -or $sameExecutable)
        $appxDetail = 'logical={0}; physical={1}; same-file={2}' -f $logicalRoot, $physicalRoot, $sameExecutable
        Add-ValidationResult -Name 'MSIX physical payload' -Passed $appxPassed -Detail $appxDetail
    }
}

$failedCritical = @($results | Where-Object { $_.Critical -and -not $_.Passed })
$report = [ordered]@{
    checked_at = (Get-Date).ToString('o')
    destination_root = $destinationPath
    passed = ($failedCritical.Count -eq 0)
    results = $results
}

if ($AsJson) {
    $report | ConvertTo-Json -Depth 8
}
else {
    $results | Format-Table Passed, Critical, Name, Detail -AutoSize -Wrap
    Write-Host ''
    if ($report.passed) {
        Write-Host 'Codex migration validation passed.' -ForegroundColor Green
    }
    else {
        Write-Host 'Codex migration validation failed.' -ForegroundColor Red
    }
}

if (-not $report.passed) {
    exit 1
}
