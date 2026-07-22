#requires -Version 5.1
#requires -RunAsAdministrator
<#
.SYNOPSIS
Completes a staged Codex migration after Codex Desktop exits.

.DESCRIPTION
This script is copied to the destination drive by Start-CodexMigration.ps1 and
launched through UAC. Do not run it directly unless a valid migration state
file already exists.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$StatePath,
    [ValidateRange(30, 7200)][int]$WaitTimeoutSeconds = 1800
)

$ErrorActionPreference = 'Stop'
$stateFile = [IO.Path]::GetFullPath($StatePath)
$migrationDirectory = Split-Path -Parent $stateFile
$runtimeDirectory = Join-Path $migrationDirectory 'runtime'
$modulePath = Join-Path $runtimeDirectory 'CodexMover.Common.psm1'
Import-Module $modulePath -Force
Initialize-CodexMoverNative

function Assert-NoReparseComponents {
    param([Parameter(Mandatory)][string]$Path)

    $current = Get-CodexNormalizedPath -Path $Path
    $root = [IO.Path]::GetPathRoot($current)
    while ($current -and -not $current.Equals($root, [StringComparison]::OrdinalIgnoreCase)) {
        $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Migration path traverses a reparse point: $current"
        }
        $parent = Split-Path -Parent $current
        if (-not $parent -or $parent -eq $current) {
            break
        }
        $current = $parent
    }
}

function Assert-ExactPath {
    param(
        [Parameter(Mandatory)][string]$Actual,
        [Parameter(Mandatory)][string]$Expected,
        [Parameter(Mandatory)][string]$Label
    )

    $actualPath = Get-CodexNormalizedPath -Path $Actual
    $expectedPath = Get-CodexNormalizedPath -Path $Expected
    if (-not $actualPath.Equals($expectedPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Unexpected path in migration state for $Label. Expected $expectedPath but found $actualPath."
    }
}

if (-not (Test-CodexAdministrator)) {
    throw 'The finalizer must run in an elevated PowerShell window.'
}

$state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
if ([int]$state.schema_version -ne 1) {
    throw "Unsupported migration-state schema version: $($state.schema_version)"
}
if ([string]$state.appx_strategy -ne 'keep_system_volume') {
    throw 'Migration state does not contain the required keep_system_volume AppX strategy. Restage with the current Start-CodexMigration.ps1.'
}
$destinationRoot = Get-CodexNormalizedPath -Path ([string]$state.destination_root)
$destinationDriveRoot = [IO.Path]::GetPathRoot($destinationRoot)
if ($destinationDriveRoot -notmatch '^[A-Za-z]:\\$') {
    throw 'The destination in migration state must be a local drive with a drive letter.'
}
$expectedMigrationDirectory = Get-CodexNormalizedPath -Path (Join-Path $destinationRoot 'migration')
if (-not (Get-CodexNormalizedPath -Path $migrationDirectory).Equals($expectedMigrationDirectory, [StringComparison]::OrdinalIgnoreCase)) {
    throw "StatePath is outside the expected migration directory: $stateFile"
}

$stateItem = Get-Item -LiteralPath $stateFile -Force
if ($stateItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
    throw "Migration state must not be a reparse point: $stateFile"
}
$sourceProfile = Get-CodexNormalizedPath -Path ([string]$state.source_profile)
$currentProfile = Get-CodexNormalizedPath -Path $env:USERPROFILE
if (-not $sourceProfile.Equals($currentProfile, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The migration state does not belong to the current Windows user profile.'
}
if ([IO.Path]::GetPathRoot($sourceProfile).Equals($destinationDriveRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Source profile and destination must be on different drives.'
}

$expectedSourceHome = Join-Path $sourceProfile '.codex'
$expectedSourceRuntime = Join-Path $sourceProfile '.cache\codex-runtimes'
$expectedSourceLocal = Join-Path $sourceProfile 'AppData\Local\OpenAI\Codex'
$expectedTargetHome = Join-Path $destinationRoot 'home'
$expectedTargetRuntime = Join-Path $destinationRoot 'cache\codex-runtimes'
$expectedTargetLocal = Join-Path $destinationRoot 'local\OpenAI\Codex'
Assert-ExactPath -Actual ([string]$state.source.home) -Expected $expectedSourceHome -Label 'source.home'
Assert-ExactPath -Actual ([string]$state.source.runtime) -Expected $expectedSourceRuntime -Label 'source.runtime'
Assert-ExactPath -Actual ([string]$state.source.local_codex) -Expected $expectedSourceLocal -Label 'source.local_codex'
Assert-ExactPath -Actual ([string]$state.target.home) -Expected $expectedTargetHome -Label 'target.home'
Assert-ExactPath -Actual ([string]$state.target.runtime) -Expected $expectedTargetRuntime -Label 'target.runtime'
Assert-ExactPath -Actual ([string]$state.target.local_codex) -Expected $expectedTargetLocal -Label 'target.local_codex'

$initialAppxPlacement = Get-CodexAppxPlacement
if (-not $initialAppxPlacement.Safe) {
    throw "Codex AppX safety check failed before migration: $($initialAppxPlacement.Reason) Restore the package to the Windows system volume before continuing."
}

$expectedStatusPath = Join-Path $expectedMigrationDirectory 'migration-status.json'
Assert-ExactPath -Actual ([string]$state.status) -Expected $expectedStatusPath -Label 'status'
foreach ($validatedPath in @(
    $stateFile,
    $expectedMigrationDirectory,
    $expectedSourceHome,
    $expectedSourceRuntime,
    $expectedSourceLocal,
    $expectedTargetHome,
    $expectedTargetRuntime,
    $expectedTargetLocal
)) {
    Assert-NoReparseComponents -Path $validatedPath
}

if ($state.current_session_relative_path) {
    $sessionRelativePath = [string]$state.current_session_relative_path
    if ([IO.Path]::IsPathRooted($sessionRelativePath)) {
        throw 'The protected current-session path must be relative to CODEX_HOME.'
    }
    $sessionSourcePath = Get-CodexNormalizedPath -Path (Join-Path $expectedSourceHome $sessionRelativePath)
    $sessionTargetPath = Get-CodexNormalizedPath -Path (Join-Path $expectedTargetHome $sessionRelativePath)
    if (-not $sessionSourcePath.StartsWith($expectedSourceHome + '\', [StringComparison]::OrdinalIgnoreCase) -or
        -not $sessionTargetPath.StartsWith($expectedTargetHome + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The protected current-session path escapes CODEX_HOME.'
    }
}

$statusPath = [string]$state.status
$logPath = Join-Path $migrationDirectory 'finalize.log'
$oldCodexHome = [Environment]::GetEnvironmentVariable('CODEX_HOME', 'User')
$switches = @()
$warnings = @()
$sessionSourceHash = $null
$sessionTargetHash = $null
$sessionFileId = $null
$appxResult = $null

function Write-FinalizeLog {
    param([Parameter(Mandatory)][string]$Message)

    $line = '{0} {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line
    Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
}

function Write-FinalizeStatus {
    param(
        [Parameter(Mandatory)][string]$Status,
        [string]$ErrorMessage
    )

    $junctions = @($switches | ForEach-Object {
        [ordered]@{
            source = $_.Source
            target = $_.Target
            backup = $_.Backup
            verified = Test-CodexJunction -Path $_.Source -ExpectedTarget $_.Target
        }
    })
    $payload = [ordered]@{
        schema_version = 1
        status = $Status
        updated_at = (Get-Date).ToString('o')
        destination_root = $destinationRoot
        source_profile = [string]$state.source_profile
        old_user_codex_home = $oldCodexHome
        codex_home = [string]$state.target.home
        junctions = $junctions
        backup_paths = @($switches | ForEach-Object { $_.Backup })
        removed_source_backups = @()
        cleanup_at = $null
        current_thread_id = [string]$state.current_thread_id
        current_session_relative_path = [string]$state.current_session_relative_path
        current_session_source_hash = $sessionSourceHash
        current_session_target_hash = $sessionTargetHash
        current_session_file_id = $sessionFileId
        appx = $appxResult
        warnings = @($warnings)
        error = $ErrorMessage
        log = $logPath
    }
    Write-CodexJson -InputObject $payload -Path $statusPath -Depth 12
}

function Test-PathStartsWith {
    param(
        [Parameter(Mandatory)][string]$Candidate,
        [Parameter(Mandatory)][string]$Parent
    )

    $candidatePath = Get-CodexNormalizedPath -Path $Candidate
    $parentPath = (Get-CodexNormalizedPath -Path $Parent) + '\'
    $candidatePath.StartsWith($parentPath, [StringComparison]::OrdinalIgnoreCase)
}

function Stop-LingeringSourceProcesses {
    $sourceRoots = @(
        [string]$state.source.home,
        [string]$state.source.runtime,
        [string]$state.source.local_codex
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }

    foreach ($process in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
        if (-not $process.ExecutablePath) {
            continue
        }
        $usesSource = $false
        foreach ($sourceRoot in $sourceRoots) {
            try {
                if (Test-PathStartsWith -Candidate $process.ExecutablePath -Parent $sourceRoot) {
                    $usesSource = $true
                    break
                }
            }
            catch {
                $usesSource = $false
                break
            }
        }
        if ($usesSource) {
            Write-FinalizeLog ("Stopping lingering source process {0} ({1})." -f $process.Name, $process.ProcessId)
            Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
        }
    }
}

function Write-OpenHandleDiagnostics {
    param([Parameter(Mandatory)][string]$Path)

    $handleExecutable = Join-Path $runtimeDirectory 'handle64.exe'
    if (-not (Test-Path -LiteralPath $handleExecutable)) {
        return
    }

    try {
        $handleOutput = & $handleExecutable -accepteula -nobanner -a $Path 2>&1
        if ($LASTEXITCODE -eq 0 -and $handleOutput) {
            Write-FinalizeLog ("Open-handle diagnostics for {0}:" -f $Path)
            foreach ($line in @($handleOutput)) {
                Write-FinalizeLog ("  HANDLE {0}" -f $line)
            }
        }
    }
    catch {
        Write-FinalizeLog ("Open-handle diagnostics failed for {0}: {1}" -f $Path, $_.Exception.Message)
    }
}

function Move-DirectoryWithRetry {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [ValidateRange(1, 30)][int]$Attempts = 10
    )

    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            [CodexMoverNative]::MoveDirectory($Source, $Destination)
            return
        }
        catch {
            $detail = $_.Exception.Message
            if ($_.Exception.InnerException) {
                $detail = '{0}; inner={1}' -f $detail, $_.Exception.InnerException.Message
            }
            Write-FinalizeLog ("Directory rename attempt {0}/{1} failed: {2}" -f $attempt, $Attempts, $detail)
            Write-OpenHandleDiagnostics -Path $Source
            if ($attempt -eq $Attempts) {
                throw
            }
            Wait-CodexDesktopExit -TimeoutSeconds 120 -OnProgress {
                param($Ids)
                Write-FinalizeLog ("Rename retry is waiting for Codex processes: {0}" -f $Ids)
            }
            Stop-LingeringSourceProcesses
            Start-Sleep -Seconds 2
        }
    }
}

function Switch-DirectoryToJunction {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Label
    )

    if (-not (Test-Path -LiteralPath $Source)) {
        Write-FinalizeLog ("Skipping absent source: {0}" -f $Label)
        return
    }
    $sourceItem = Get-Item -LiteralPath $Source -Force
    if ($sourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Refusing to switch an existing reparse point: $Source"
    }
    if (-not (Test-Path -LiteralPath $Target)) {
        throw "Migration target is missing: $Target"
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backup = '{0}.pre-codex-mover-{1}' -f $Source, $timestamp
    if (Test-Path -LiteralPath $backup) {
        throw "Backup path already exists: $backup"
    }

    Write-FinalizeLog ("Switching to junction: {0}" -f $Label)
    Move-DirectoryWithRetry -Source $Source -Destination $backup
    $record = [pscustomobject]@{ Source = $Source; Target = $Target; Backup = $backup; Label = $Label }
    $script:switches += $record
    New-Item -ItemType Junction -Path $Source -Target $Target -Force | Out-Null
    if (-not (Test-CodexJunction -Path $Source -ExpectedTarget $Target)) {
        throw "Junction verification failed: $Source -> $Target"
    }
}

function Restart-CodexDesktop {
    $package = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $package) {
        return
    }
    $manifest = Get-AppxPackageManifest -Package $package.PackageFullName
    $applicationId = [string]($manifest.Package.Applications.Application | Select-Object -First 1).Id
    if ($applicationId) {
        $aumid = '{0}!{1}' -f $package.PackageFamilyName, $applicationId
        Start-Process -FilePath 'explorer.exe' -ArgumentList ('shell:AppsFolder\{0}' -f $aumid)
    }
}

if (Test-Path -LiteralPath $logPath) {
    Remove-Item -LiteralPath $logPath -Force
}

try {
    Write-FinalizeLog 'Elevated finalizer started. Waiting for Codex Desktop to exit.'
    Wait-CodexDesktopExit -TimeoutSeconds $WaitTimeoutSeconds -OnProgress {
        param($Ids)
        Write-FinalizeLog ("Still waiting for Codex processes: {0}" -f $Ids)
    }
    Stop-LingeringSourceProcesses
    Start-Sleep -Seconds 2

    Write-FinalizeLog 'Final synchronization started: CODEX_HOME.'
    Invoke-CodexRobocopy -Source ([string]$state.source.home) -Destination ([string]$state.target.home) -Mode Union -LogPath $logPath -Verify | Out-Null
    if (Test-Path -LiteralPath ([string]$state.source.runtime)) {
        Write-FinalizeLog 'Final synchronization started: runtime cache.'
        Invoke-CodexRobocopy -Source ([string]$state.source.runtime) -Destination ([string]$state.target.runtime) -Mode Mirror -LogPath $logPath -Verify | Out-Null
    }
    if (Test-Path -LiteralPath ([string]$state.source.local_codex)) {
        Write-FinalizeLog 'Final synchronization started: Local OpenAI Codex data.'
        Invoke-CodexRobocopy -Source ([string]$state.source.local_codex) -Destination ([string]$state.target.local_codex) -Mode Mirror -LogPath $logPath -Verify | Out-Null
    }

    $reappearedProcesses = @(Get-CodexCoreProcesses)
    if ($reappearedProcesses.Count -gt 0) {
        Write-FinalizeLog ("Codex processes reappeared during synchronization: {0}. Waiting again." -f (($reappearedProcesses.ProcessId | Sort-Object) -join ', '))
        Wait-CodexDesktopExit -TimeoutSeconds $WaitTimeoutSeconds -OnProgress {
            param($Ids)
            Write-FinalizeLog ("Still waiting before the final resynchronization: {0}" -f $Ids)
        }
        Stop-LingeringSourceProcesses
        Start-Sleep -Seconds 2

        Write-FinalizeLog 'Final resynchronization started after Codex exited again: CODEX_HOME.'
        Invoke-CodexRobocopy -Source ([string]$state.source.home) -Destination ([string]$state.target.home) -Mode Union -LogPath $logPath -Verify | Out-Null
        if (Test-Path -LiteralPath ([string]$state.source.runtime)) {
            Invoke-CodexRobocopy -Source ([string]$state.source.runtime) -Destination ([string]$state.target.runtime) -Mode Mirror -LogPath $logPath -Verify | Out-Null
        }
        if (Test-Path -LiteralPath ([string]$state.source.local_codex)) {
            Invoke-CodexRobocopy -Source ([string]$state.source.local_codex) -Destination ([string]$state.target.local_codex) -Mode Mirror -LogPath $logPath -Verify | Out-Null
        }
    }

    if ($state.current_session_relative_path) {
        $sessionSource = Join-Path ([string]$state.source.home) ([string]$state.current_session_relative_path)
        $sessionTarget = Join-Path ([string]$state.target.home) ([string]$state.current_session_relative_path)
        if (-not (Test-Path -LiteralPath $sessionSource) -or -not (Test-Path -LiteralPath $sessionTarget)) {
            throw 'The protected current-session file is missing after final synchronization.'
        }
        $sessionSourceHash = (Get-FileHash -LiteralPath $sessionSource -Algorithm SHA256).Hash
        $sessionTargetHash = (Get-FileHash -LiteralPath $sessionTarget -Algorithm SHA256).Hash
        if ($sessionSourceHash -ne $sessionTargetHash) {
            throw 'The protected current-session file differs between source and target.'
        }
        Write-FinalizeLog 'Protected current-session file verified by SHA-256.'
    }

    [Environment]::SetEnvironmentVariable('CODEX_HOME', [string]$state.target.home, 'User')
    Switch-DirectoryToJunction -Source ([string]$state.source.home) -Target ([string]$state.target.home) -Label 'CODEX_HOME'
    Switch-DirectoryToJunction -Source ([string]$state.source.runtime) -Target ([string]$state.target.runtime) -Label 'runtime cache'
    Switch-DirectoryToJunction -Source ([string]$state.source.local_codex) -Target ([string]$state.target.local_codex) -Label 'Local OpenAI Codex data'

    if ($state.current_session_relative_path) {
        $sessionLogical = Join-Path ([string]$state.source.home) ([string]$state.current_session_relative_path)
        $sessionPhysical = Join-Path ([string]$state.target.home) ([string]$state.current_session_relative_path)
        if (-not (Test-CodexSameFileId -FirstPath $sessionLogical -SecondPath $sessionPhysical)) {
            throw 'The protected current-session paths do not resolve to the same physical file.'
        }
        $sessionFileId = Get-CodexFileId -Path $sessionPhysical
        Write-FinalizeLog 'Protected current-session file verified by physical file ID.'
    }

    $finalAppxPlacement = Get-CodexAppxPlacement
    if (-not $finalAppxPlacement.Safe) {
        throw "Codex AppX moved away from the system volume during migration: $($finalAppxPlacement.Reason)"
    }
    $appxResult = [ordered]@{
        status = 'kept_on_system_volume'
        package_full_name = $finalAppxPlacement.PackageFullName
        logical_install_location = $finalAppxPlacement.LogicalInstallLocation
        system_drive = $finalAppxPlacement.SystemDrive
        is_reparse_point = $finalAppxPlacement.IsReparsePoint
        verified = $true
    }
    Write-FinalizeLog 'Codex AppX remained on the Windows system volume.'

    $finalStatus = if ($warnings.Count -eq 0) { 'success_pending_cleanup' } else { 'success_pending_cleanup_with_warnings' }
    Write-FinalizeStatus -Status $finalStatus
    Write-FinalizeLog ("Migration completed. Backups are retained until explicit cleanup: {0}" -f (@($switches.Backup) -join ', '))

    try {
        Restart-CodexDesktop
    }
    catch {
        Write-FinalizeLog ("Codex restart was not automatic: {0}" -f $_.Exception.Message)
    }
}
catch {
    $failure = $_.Exception.Message
    Write-FinalizeLog ("Migration failed: {0}" -f $failure)
    for ($index = $switches.Count - 1; $index -ge 0; $index--) {
        $record = $switches[$index]
        try {
            $sourceItem = Get-Item -LiteralPath $record.Source -Force -ErrorAction SilentlyContinue
            if ($sourceItem) {
                if (-not ($sourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                    throw "Rollback found a non-reparse source path: $($record.Source)"
                }
                [CodexMoverNative]::RemoveDirectoryLink($record.Source)
            }
            if (Test-Path -LiteralPath $record.Backup) {
                [CodexMoverNative]::MoveDirectory($record.Backup, $record.Source)
            }
        }
        catch {
            $warnings += ('Rollback warning for {0}: {1}' -f $record.Source, $_.Exception.Message)
        }
    }
    [Environment]::SetEnvironmentVariable('CODEX_HOME', $oldCodexHome, 'User')
    Write-FinalizeStatus -Status 'failed' -ErrorMessage $failure
    throw
}
