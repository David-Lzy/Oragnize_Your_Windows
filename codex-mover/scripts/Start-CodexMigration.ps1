#requires -Version 5.1
<#
.SYNOPSIS
Pre-copies Codex data and launches the elevated finalizer.

.EXAMPLE
.\Start-CodexMigration.ps1 -DestinationRoot 'E:\CodexData' -CurrentThreadId 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'

.EXAMPLE
.\Start-CodexMigration.ps1 -DestinationRoot 'E:\CodexData' -StageOnly
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$DestinationRoot,
    [string]$SourceProfile = $env:USERPROFILE,
    [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')][string]$CurrentThreadId,
    # Retained for command-line compatibility. AppX migration is now always skipped.
    [switch]$SkipMsix,
    [switch]$StageOnly,
    [switch]$Force
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
            throw "Migration path traverses a reparse point: $current"
        }
        $parent = Split-Path -Parent $current
        if (-not $parent -or $parent -eq $current) {
            break
        }
        $current = $parent
    }
}

$sourceProfilePath = Get-CodexNormalizedPath -Path $SourceProfile
$destinationPath = Get-CodexNormalizedPath -Path $DestinationRoot
$destinationRootPath = [IO.Path]::GetPathRoot($destinationPath)
if ($destinationRootPath -notmatch '^[A-Za-z]:\\$') {
    throw 'DestinationRoot must be on a local drive with a drive letter.'
}
$currentProfilePath = Get-CodexNormalizedPath -Path $env:USERPROFILE
if (-not $sourceProfilePath.Equals($currentProfilePath, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'SourceProfile must be the profile of the current Windows user. Use Remove-CodexSidecarUser.ps1 for a separate account.'
}
$sourceHome = Join-Path $sourceProfilePath '.codex'
$sourceRuntime = Join-Path $sourceProfilePath '.cache\codex-runtimes'
$sourceLocal = Join-Path $sourceProfilePath 'AppData\Local\OpenAI\Codex'

$appxPlacement = Get-CodexAppxPlacement
if (-not $appxPlacement.Safe) {
    throw "Codex AppX safety check failed: $($appxPlacement.Reason) Keep the Windows-managed AppX package on the system drive and see docs\TROUBLESHOOTING.md before migrating Codex data."
}

if (-not (Test-Path -LiteralPath $sourceHome)) {
    throw "CODEX_HOME does not exist: $sourceHome"
}
$sourceHomeItem = Get-Item -LiteralPath $sourceHome -Force
if ($sourceHomeItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
    throw "CODEX_HOME is already a reparse point: $sourceHome"
}

foreach ($candidate in @($sourceRuntime, $sourceLocal)) {
    $candidateItem = Get-Item -LiteralPath $candidate -Force -ErrorAction SilentlyContinue
    if ($candidateItem -and ($candidateItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Source path is already a reparse point: $candidate"
    }
}

$sourceDrive = [IO.Path]::GetPathRoot($sourceHome).Substring(0, 1)
$destinationDrive = [IO.Path]::GetPathRoot($destinationPath).Substring(0, 1)
if ($sourceDrive -ieq $destinationDrive) {
    throw 'DestinationRoot must be on a different drive from the source profile.'
}
$volume = Get-Volume -DriveLetter $destinationDrive -ErrorAction Stop
if ($volume.FileSystem -ne 'NTFS') {
    throw "Destination drive must be NTFS; found $($volume.FileSystem)."
}

$targetHome = Join-Path $destinationPath 'home'
$targetRuntime = Join-Path $destinationPath 'cache\codex-runtimes'
$targetLocal = Join-Path $destinationPath 'local\OpenAI\Codex'
$migrationDirectory = Join-Path $destinationPath 'migration'
$runtimeDirectory = Join-Path $migrationDirectory 'runtime'
$logPath = Join-Path $migrationDirectory 'stage.log'
$statePath = Join-Path $migrationDirectory 'migration-state.json'
$statusPath = Join-Path $migrationDirectory 'migration-status.json'

foreach ($validatedPath in @(
    $sourceHome,
    $sourceRuntime,
    $sourceLocal,
    $destinationPath,
    $targetHome,
    $targetRuntime,
    $targetLocal,
    $migrationDirectory
)) {
    Assert-NoReparseComponents -Path $validatedPath
}

if ((Test-Path -LiteralPath $statePath) -and -not $Force) {
    throw "Migration state already exists. Inspect it or rerun with -Force: $statePath"
}
$existingTargets = @(@($targetHome, $targetRuntime, $targetLocal) | Where-Object { Test-Path -LiteralPath $_ })
if ($existingTargets.Count -gt 0 -and -not $Force) {
    throw "Migration target data already exists. Inspect it or explicitly resume with -Force: $($existingTargets -join ', ')"
}

$sessionFile = Resolve-CodexSessionFile -CodexHome $sourceHome -ThreadId $CurrentThreadId
$explicitSessionMissing = $CurrentThreadId -and -not $sessionFile
if ($explicitSessionMissing) {
    throw "No session JSONL matched CurrentThreadId '$CurrentThreadId'."
}
$sessionRelativePath = $null
if ($sessionFile) {
    $sessionRelativePath = $sessionFile.FullName.Substring($sourceHome.Length).TrimStart('\')
}

New-Item -ItemType Directory -Path $migrationDirectory, $runtimeDirectory -Force | Out-Null
if (Test-Path -LiteralPath $logPath) {
    Remove-Item -LiteralPath $logPath -Force
}

Write-Host 'Pre-copying CODEX_HOME...'
Invoke-CodexRobocopy -Source $sourceHome -Destination $targetHome -Mode Union -LogPath $logPath | Out-Null
if (Test-Path -LiteralPath $sourceRuntime) {
    Write-Host 'Pre-copying bundled runtime cache...'
    Invoke-CodexRobocopy -Source $sourceRuntime -Destination $targetRuntime -Mode Mirror -LogPath $logPath | Out-Null
}
if (Test-Path -LiteralPath $sourceLocal) {
    Write-Host 'Pre-copying Local OpenAI Codex data...'
    Invoke-CodexRobocopy -Source $sourceLocal -Destination $targetLocal -Mode Mirror -LogPath $logPath | Out-Null
}

$supportFiles = @(
    [pscustomobject]@{ Source = Join-Path $PSScriptRoot 'Finalize-CodexMigration.ps1'; Destination = Join-Path $migrationDirectory 'Finalize-CodexMigration.ps1' },
    [pscustomobject]@{ Source = Join-Path $PSScriptRoot '..\src\CodexMover.Common.psm1'; Destination = Join-Path $runtimeDirectory 'CodexMover.Common.psm1' },
    [pscustomobject]@{ Source = Join-Path $PSScriptRoot '..\src\CodexMover.Native.cs'; Destination = Join-Path $runtimeDirectory 'CodexMover.Native.cs' }
)
foreach ($file in $supportFiles) {
    Copy-Item -LiteralPath $file.Source -Destination $file.Destination -Force
}

$state = [ordered]@{
    schema_version = 1
    staged_at = (Get-Date).ToString('o')
    source_profile = $sourceProfilePath
    destination_root = $destinationPath
    source = [ordered]@{
        home = $sourceHome
        runtime = $sourceRuntime
        local_codex = $sourceLocal
    }
    target = [ordered]@{
        home = $targetHome
        runtime = $targetRuntime
        local_codex = $targetLocal
    }
    current_thread_id = $CurrentThreadId
    current_session_relative_path = $sessionRelativePath
    appx_strategy = 'keep_system_volume'
    skip_msix = $true
    log = $logPath
    status = $statusPath
}
Write-CodexJson -InputObject $state -Path $statePath

Write-Host ''
Write-Host "Stage completed: $statePath" -ForegroundColor Green
if ($StageOnly) {
    Write-Host 'StageOnly was requested; elevated finalization was not launched.'
    return
}

$finalizerPath = Join-Path $migrationDirectory 'Finalize-CodexMigration.ps1'
$argumentLine = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -StatePath "{1}"' -f $finalizerPath, $statePath
$powerShellHost = Get-Command 'pwsh.exe' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -First 1
if (-not $powerShellHost) {
    $powerShellHost = 'powershell.exe'
}
$process = Start-Process -FilePath $powerShellHost -Verb RunAs -ArgumentList $argumentLine -PassThru
Write-Host "Elevated finalizer launched (PID $($process.Id))." -ForegroundColor Yellow
Write-Host 'Approve UAC, then completely exit Codex Desktop. The finalizer will wait.' -ForegroundColor Yellow
