#requires -Version 5.1
<#
.SYNOPSIS
Deletes only the exact source backup paths recorded by a successful migration.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]$DestinationRoot
)

$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot '..\src\CodexMover.Common.psm1'
Import-Module $modulePath -Force

function Assert-NoReparseComponents {
    param([Parameter(Mandatory)][string]$Path)

    $current = Get-CodexNormalizedPath -Path $Path
    $root = [IO.Path]::GetPathRoot($current)
    while ($current -and -not $current.Equals($root, [StringComparison]::OrdinalIgnoreCase)) {
        $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Refusing cleanup because a destination path traverses a reparse point: $current"
        }
        $parent = Split-Path -Parent $current
        if (-not $parent -or $parent -eq $current) {
            break
        }
        $current = $parent
    }
}

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
if ([string]$state.appx_strategy -ne 'keep_system_volume') {
    throw 'Refusing cleanup because the migration was not staged with the required keep_system_volume AppX strategy.'
}
$appxPlacement = Get-CodexAppxPlacement
if (-not $appxPlacement.Safe) {
    throw "Refusing cleanup because Codex AppX is not safely stored on the Windows system volume: $($appxPlacement.Reason)"
}
$stateDestination = Get-CodexNormalizedPath -Path ([string]$state.destination_root)
if (-not $stateDestination.Equals($destinationPath, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'DestinationRoot does not match the recorded migration state.'
}
$sourceProfile = Get-CodexNormalizedPath -Path ([string]$state.source_profile)
$currentProfile = Get-CodexNormalizedPath -Path $env:USERPROFILE
if (-not $sourceProfile.Equals($currentProfile, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The migration state does not belong to the current Windows user profile.'
}

$expectedSources = @(
    [pscustomobject]@{ Source = Join-Path $sourceProfile '.codex'; Target = Join-Path $destinationPath 'home' },
    [pscustomobject]@{ Source = Join-Path $sourceProfile '.cache\codex-runtimes'; Target = Join-Path $destinationPath 'cache\codex-runtimes' },
    [pscustomobject]@{ Source = Join-Path $sourceProfile 'AppData\Local\OpenAI\Codex'; Target = Join-Path $destinationPath 'local\OpenAI\Codex' }
)
$recordedPairs = @(
    [pscustomobject]@{ Source = [string]$state.source.home; Target = [string]$state.target.home },
    [pscustomobject]@{ Source = [string]$state.source.runtime; Target = [string]$state.target.runtime },
    [pscustomobject]@{ Source = [string]$state.source.local_codex; Target = [string]$state.target.local_codex }
)
for ($index = 0; $index -lt $expectedSources.Count; $index++) {
    foreach ($property in @('Source', 'Target')) {
        $actualPath = Get-CodexNormalizedPath -Path ([string]$recordedPairs[$index].$property)
        $expectedPath = Get-CodexNormalizedPath -Path ([string]$expectedSources[$index].$property)
        if (-not $actualPath.Equals($expectedPath, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Unexpected $property path in migration state: $actualPath"
        }
    }
    Assert-NoReparseComponents -Path $expectedSources[$index].Target
}
Assert-NoReparseComponents -Path $statePath
Assert-NoReparseComponents -Path $statusPath
$expectedStatusPath = Get-CodexNormalizedPath -Path (Join-Path $migrationDirectory 'migration-status.json')
if (-not (Get-CodexNormalizedPath -Path ([string]$state.status)).Equals($expectedStatusPath, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Unexpected status path in migration state.'
}

$allowedStatuses = @('success_pending_cleanup', 'success_pending_cleanup_with_warnings', 'completed')
if ([string]$status.status -notin $allowedStatuses) {
    throw "Backups cannot be deleted while migration status is '$($status.status)'."
}

if ($state.current_session_relative_path) {
    $sessionRelativePath = [string]$state.current_session_relative_path
    if ([IO.Path]::IsPathRooted($sessionRelativePath)) {
        throw 'Refusing cleanup because the protected current-session path is rooted.'
    }
    $logicalSession = Get-CodexNormalizedPath -Path (Join-Path ([string]$state.source.home) $sessionRelativePath)
    $physicalSession = Get-CodexNormalizedPath -Path (Join-Path ([string]$state.target.home) $sessionRelativePath)
    if (-not $logicalSession.StartsWith((Get-CodexNormalizedPath -Path ([string]$state.source.home)) + '\', [StringComparison]::OrdinalIgnoreCase) -or
        -not $physicalSession.StartsWith((Get-CodexNormalizedPath -Path ([string]$state.target.home)) + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Refusing cleanup because the protected current-session path escapes CODEX_HOME.'
    }
    if (-not (Test-Path -LiteralPath $logicalSession) -or -not (Test-Path -LiteralPath $physicalSession)) {
        throw 'Refusing cleanup because the protected current-session file is missing.'
    }
    if (-not (Test-CodexSameFileId -FirstPath $logicalSession -SecondPath $physicalSession)) {
        throw 'Refusing cleanup because the protected current-session paths do not resolve to the same file.'
    }
}

$sourcePrefix = $sourceProfile + '\'
$backupPaths = @($status.backup_paths | Where-Object { $_ })
$validated = @()
foreach ($backupPathValue in $backupPaths) {
    $backupPath = Get-CodexNormalizedPath -Path ([string]$backupPathValue)
    if (-not $backupPath.StartsWith($sourcePrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing backup outside source profile: $backupPath"
    }
    if ($backupPath -notmatch '\.pre-codex-mover-\d{8}-\d{6}$') {
        throw "Refusing path without the Codex Mover backup suffix: $backupPath"
    }
    $matchingPair = $expectedSources | Where-Object {
        $expectedBackupPrefix = (Get-CodexNormalizedPath -Path $_.Source) + '.pre-codex-mover-'
        $backupPath.StartsWith($expectedBackupPrefix, [StringComparison]::OrdinalIgnoreCase)
    } | Select-Object -First 1
    if (-not $matchingPair) {
        throw "Refusing a backup that does not belong to a known Codex source: $backupPath"
    }
    if (-not (Test-CodexJunction -Path $matchingPair.Source -ExpectedTarget $matchingPair.Target)) {
        throw "Refusing cleanup because the corresponding junction is invalid: $($matchingPair.Source)"
    }
    $item = Get-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
    if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Refusing to recursively delete a reparse-point backup root: $backupPath"
    }
    if ($item -and -not $item.PSIsContainer) {
        throw "Refusing non-directory backup path: $backupPath"
    }
    $validated += $backupPath
}

if ($validated.Count -eq 0) {
    Write-Host 'No recorded migration backups remain.'
    return
}

Initialize-CodexMoverNative
$removed = @($status.removed_source_backups | Where-Object { $_ })
$remaining = @($validated)
foreach ($backupPath in $validated) {
    if (-not (Test-Path -LiteralPath $backupPath)) {
        $removed += $backupPath
        $remaining = @($remaining | Where-Object { $_ -ne $backupPath })
        continue
    }
    if ($PSCmdlet.ShouldProcess($backupPath, 'Permanently delete verified Codex migration backup')) {
        [CodexMoverNative]::DeleteTreeNoFollow($backupPath)
        if (Test-Path -LiteralPath $backupPath) {
            throw "Backup deletion did not complete: $backupPath"
        }
        $removed += $backupPath
        $remaining = @($remaining | Where-Object { $_ -ne $backupPath })
        Write-Host "Deleted: $backupPath" -ForegroundColor Yellow
    }
}

if ($remaining.Count -ne $validated.Count) {
    $status.backup_paths = $remaining
    $status | Add-Member -NotePropertyName removed_source_backups -NotePropertyValue @($removed | Select-Object -Unique) -Force
    $status | Add-Member -NotePropertyName cleanup_at -NotePropertyValue (Get-Date).ToString('o') -Force
    if ($remaining.Count -eq 0) {
        $status.status = 'completed'
    }
    Write-CodexJson -InputObject $status -Path $statusPath -Depth 12
}

if ($remaining.Count -eq 0) {
    Write-Host 'All recorded source backups were deleted. Migration status is completed.' -ForegroundColor Green
}
else {
    Write-Host ("Backups retained: {0}" -f ($remaining -join ', ')) -ForegroundColor Yellow
}
