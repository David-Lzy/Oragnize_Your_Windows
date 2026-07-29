#requires -Version 5.1
<#
.SYNOPSIS
Repairs the Windows Codex Desktop project/host route for a migrated remote task.

.DESCRIPTION
This script does not move the remote rollout or edit remote SQLite state. It
updates only the Windows Desktop route cache after the task has already been
migrated to another SSH-backed CODEX_HOME.

The default mode is read-only. Pass -Apply only after every Codex Desktop
window in every Windows session has been closed.

.PARAMETER TargetRemotePath
The absolute POSIX path of the remote project already saved by Codex Desktop.

.PARAMETER TargetCwd
The task's absolute POSIX working directory. It may equal TargetRemotePath or
be one of its descendants. When omitted, TargetRemotePath is used.

.EXAMPLE
.\Repair-CodexRemoteThreadRoute.ps1 `
    -ThreadId '<task UUID>' `
    -TargetHost 'personal-account' `
    -TargetRemotePath '/srv/projects/personal' `
    -TargetCwd '/srv/projects/personal/site'

.EXAMPLE
.\Repair-CodexRemoteThreadRoute.ps1 `
    -ThreadId '<task UUID>' `
    -TargetHost 'remote-ssh-discovered:personal-account' `
    -TargetRemotePath '/srv/projects/personal' `
    -StatePath 'E:\CodexData\home\.codex-global-state.json' `
    -Apply
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
    [string]$ThreadId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$TargetHost,

    [Parameter(Mandatory)]
    [ValidatePattern('^/')]
    [string]$TargetRemotePath,

    [ValidatePattern('^/')]
    [string]$TargetCwd,

    [ValidatePattern('^[0-9a-fA-F-]+$')]
    [string]$TargetProjectId,

    [string]$StatePath,

    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Get-CodexPropertyValue {
    param(
        [Parameter(Mandatory)]$InputObject,
        [Parameter(Mandatory)][string]$Name
    )

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

function Set-CodexPropertyValue {
    param(
        [Parameter(Mandatory)]$InputObject,
        [Parameter(Mandatory)][string]$Name,
        $Value
    )

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        $InputObject | Add-Member -MemberType NoteProperty -Name $Name -Value $Value
        return
    }
    $property.Value = $Value
}

function Get-CodexNormalizedRemotePath {
    param([Parameter(Mandatory)][string]$Path)

    if ($Path -eq '/') {
        return '/'
    }
    return $Path.TrimEnd('/')
}

function Assert-CodexAbsoluteRemotePath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name
    )

    if (-not $Path.StartsWith('/', [StringComparison]::Ordinal)) {
        throw "$Name must be an absolute POSIX path: $Path"
    }
    foreach ($segment in $Path.Split('/')) {
        if ($segment -in @('.', '..')) {
            throw "$Name must not contain '.' or '..' path segments: $Path"
        }
    }
}

function Test-CodexRemotePathWithinProject {
    param(
        [Parameter(Mandatory)][string]$ProjectPath,
        [Parameter(Mandatory)][string]$Path
    )

    if ($ProjectPath -eq '/') {
        return $true
    }
    return (
        $Path -eq $ProjectPath -or
        $Path.StartsWith(($ProjectPath + '/'), [StringComparison]::Ordinal)
    )
}

function Get-CodexDesktopProcesses {
    return @(Get-Process -Name 'ChatGPT' -ErrorAction SilentlyContinue)
}

function Assert-CodexDesktopStopped {
    $processes = @(Get-CodexDesktopProcesses)
    if ($processes.Count -eq 0) {
        return
    }

    $details = $processes |
        Sort-Object SessionId, Id |
        ForEach-Object { 'PID={0}, SessionId={1}' -f $_.Id, $_.SessionId }
    throw "Codex Desktop is still running. Close every window in every Windows session, then retry. $($details -join '; ')"
}

function Write-CodexAtomicText {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$SwapBackupPath
    )

    $directory = Split-Path -Parent $Path
    $temporaryPath = Join-Path $directory ('.codex-route-' + [guid]::NewGuid().ToString('N') + '.tmp')
    [IO.File]::WriteAllText($temporaryPath, $Text, $utf8NoBom)

    try {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            [IO.File]::Replace($temporaryPath, $Path, $SwapBackupPath, $true)
        }
        else {
            [IO.File]::Move($temporaryPath, $Path)
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

function Assert-CodexPatchedRoute {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$ExpectedProjectId,
        [Parameter(Mandatory)][string]$ExpectedHostId,
        [Parameter(Mandatory)][string]$ExpectedProjectPath,
        [Parameter(Mandatory)][string]$ExpectedCwd
    )

    $assignments = Get-CodexPropertyValue -InputObject $State -Name 'thread-project-assignments'
    $assignment = Get-CodexPropertyValue -InputObject $assignments -Name $ThreadId
    if ($null -eq $assignment) {
        throw 'The target task assignment is missing after serialization.'
    }
    if ($assignment.projectId -ne $ExpectedProjectId -or
        $assignment.hostId -ne $ExpectedHostId -or
        (Get-CodexNormalizedRemotePath -Path ([string]$assignment.path)) -ne $ExpectedProjectPath -or
        (Get-CodexNormalizedRemotePath -Path ([string]$assignment.cwd)) -ne $ExpectedCwd) {
        throw 'The target task assignment failed post-write validation.'
    }

    $atoms = Get-CodexPropertyValue -InputObject $State -Name 'electron-persisted-atom-state'
    $workspace = Get-CodexPropertyValue -InputObject $atoms -Name "thread-workspace-state-v1:$ThreadId"
    if ($null -eq $workspace) {
        throw 'The target task workspace state is missing after serialization.'
    }
    if ($workspace.project.projectId -ne $ExpectedProjectId -or
        $workspace.project.hostId -ne $ExpectedHostId -or
        (Get-CodexNormalizedRemotePath -Path ([string]$workspace.project.path)) -ne $ExpectedProjectPath) {
        throw 'The target task workspace project failed post-write validation.'
    }

    $applied = Get-CodexPropertyValue -InputObject $workspace -Name 'applied'
    if ($null -eq $applied) {
        throw 'The target task applied workspace state is missing after serialization.'
    }
    $projectSources = @($applied.projectSources)
    $runtimeWorkspaceRoots = @($applied.runtimeWorkspaceRoots)
    if ($projectSources.Count -ne 1 -or
        (Get-CodexNormalizedRemotePath -Path ([string]$projectSources[0])) -ne $ExpectedProjectPath -or
        (Get-CodexNormalizedRemotePath -Path ([string]$applied.cwd)) -ne $ExpectedCwd -or
        $runtimeWorkspaceRoots.Count -ne 1 -or
        (Get-CodexNormalizedRemotePath -Path ([string]$runtimeWorkspaceRoots[0])) -ne $ExpectedProjectPath) {
        throw 'The target task applied workspace paths failed post-write validation.'
    }

    $sidebar = Get-CodexPropertyValue -InputObject $State -Name 'sidebar-project-thread-orders'
    $targetOrder = Get-CodexPropertyValue -InputObject $sidebar -Name $ExpectedProjectId
    if ($null -eq $targetOrder -or @($targetOrder.threadIds) -notcontains $ThreadId) {
        throw 'The target task is missing from the destination sidebar order.'
    }
    foreach ($property in $sidebar.PSObject.Properties) {
        if ($property.Name -ne $ExpectedProjectId -and @($property.Value.threadIds) -contains $ThreadId) {
            throw "The target task remains in another sidebar project: $($property.Name)"
        }
    }

    $writableRoots = Get-CodexPropertyValue -InputObject $State -Name 'thread-writable-roots'
    $taskWritableRoots = @(Get-CodexPropertyValue -InputObject $writableRoots -Name $ThreadId)
    if ($taskWritableRoots.Count -ne 1 -or
        (Get-CodexNormalizedRemotePath -Path ([string]$taskWritableRoots[0])) -ne $ExpectedProjectPath) {
        throw 'The target task writable roots failed post-write validation.'
    }
}

if (-not $StatePath) {
    $stateHome = $env:CODEX_HOME
    if (-not $stateHome) {
        $stateHome = Join-Path $env:USERPROFILE '.codex'
    }
    $StatePath = Join-Path $stateHome '.codex-global-state.json'
}
$StatePath = [IO.Path]::GetFullPath($StatePath)
if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
    throw "Codex Desktop state file was not found: $StatePath"
}

$targetHostId = if ($TargetHost -like 'remote-ssh-*:*') {
    $TargetHost
}
else {
    "remote-ssh-discovered:$TargetHost"
}
$targetPath = Get-CodexNormalizedRemotePath -Path $TargetRemotePath
$targetCwd = if ($TargetCwd) {
    Get-CodexNormalizedRemotePath -Path $TargetCwd
}
else {
    $targetPath
}
Assert-CodexAbsoluteRemotePath -Path $targetPath -Name 'TargetRemotePath'
Assert-CodexAbsoluteRemotePath -Path $targetCwd -Name 'TargetCwd'
if (-not (Test-CodexRemotePathWithinProject -ProjectPath $targetPath -Path $targetCwd)) {
    throw "TargetCwd must be the target project path or one of its descendants. Project='$targetPath'; Cwd='$targetCwd'"
}

$originalText = [IO.File]::ReadAllText($StatePath, $utf8NoBom)
$state = $originalText | ConvertFrom-Json

$remoteProjects = @(Get-CodexPropertyValue -InputObject $state -Name 'remote-projects')
$projectMatches = @($remoteProjects | Where-Object {
    $_.hostId -eq $targetHostId -and
    (Get-CodexNormalizedRemotePath -Path ([string]$_.remotePath)) -eq $targetPath -and
    (-not $TargetProjectId -or $_.id -eq $TargetProjectId)
})
if ($projectMatches.Count -eq 0) {
    throw "No saved remote project matches host '$targetHostId' and path '$targetPath'. Open that SSH project once in Codex Desktop, close Desktop completely, and retry."
}
if ($projectMatches.Count -gt 1) {
    $ids = $projectMatches | ForEach-Object { $_.id }
    throw "Multiple saved remote projects match. Retry with -TargetProjectId using one of: $($ids -join ', ')"
}
$targetProject = $projectMatches[0]

$assignments = Get-CodexPropertyValue -InputObject $state -Name 'thread-project-assignments'
if ($null -eq $assignments) {
    $assignments = [pscustomobject][ordered]@{}
    Set-CodexPropertyValue -InputObject $state -Name 'thread-project-assignments' -Value $assignments
}
$currentAssignment = Get-CodexPropertyValue -InputObject $assignments -Name $ThreadId
$currentProjectId = if ($null -ne $currentAssignment) { [string]$currentAssignment.projectId } else { $null }
$currentHostId = if ($null -ne $currentAssignment) { [string]$currentAssignment.hostId } else { $null }
$currentProjectPath = if ($null -ne $currentAssignment) { [string]$currentAssignment.path } else { $null }
$currentCwd = if ($null -ne $currentAssignment) { [string]$currentAssignment.cwd } else { $null }

$pendingCoreUpdate = $false
if ($null -ne $currentAssignment -and
    $null -ne $currentAssignment.PSObject.Properties['pendingCoreUpdate']) {
    $pendingCoreUpdate = [bool]$currentAssignment.pendingCoreUpdate
}
$newAssignment = [ordered]@{
    projectKind = 'remote'
    projectId = [string]$targetProject.id
    path = $targetPath
    cwd = $targetCwd
    hostId = $targetHostId
    pendingCoreUpdate = $pendingCoreUpdate
}
Set-CodexPropertyValue -InputObject $assignments -Name $ThreadId -Value ([pscustomobject]$newAssignment)

$atoms = Get-CodexPropertyValue -InputObject $state -Name 'electron-persisted-atom-state'
if ($null -eq $atoms) {
    $atoms = [pscustomobject][ordered]@{}
    Set-CodexPropertyValue -InputObject $state -Name 'electron-persisted-atom-state' -Value $atoms
}
$workspaceKey = "thread-workspace-state-v1:$ThreadId"
$workspace = Get-CodexPropertyValue -InputObject $atoms -Name $workspaceKey
$workspaceCreated = $null -eq $workspace
if ($workspaceCreated) {
    $workspace = [pscustomobject][ordered]@{}
    Set-CodexPropertyValue -InputObject $atoms -Name $workspaceKey -Value $workspace
}
$workspaceProject = [pscustomobject][ordered]@{
    projectKind = 'remote'
    projectId = [string]$targetProject.id
    path = $targetPath
    hostId = $targetHostId
}
$appliedWorkspace = [pscustomobject][ordered]@{
    projectSources = [object[]]@($targetPath)
    cwd = $targetCwd
    runtimeWorkspaceRoots = [object[]]@($targetPath)
}
Set-CodexPropertyValue -InputObject $workspace -Name 'project' -Value $workspaceProject
Set-CodexPropertyValue -InputObject $workspace -Name 'revision' -Value ([guid]::NewGuid().ToString())
Set-CodexPropertyValue -InputObject $workspace -Name 'applied' -Value $appliedWorkspace
Set-CodexPropertyValue -InputObject $workspace -Name 'pending' -Value $null

$sidebar = Get-CodexPropertyValue -InputObject $state -Name 'sidebar-project-thread-orders'
if ($null -eq $sidebar) {
    $sidebar = [pscustomobject][ordered]@{}
    Set-CodexPropertyValue -InputObject $state -Name 'sidebar-project-thread-orders' -Value $sidebar
}
foreach ($property in $sidebar.PSObject.Properties) {
    $property.Value.threadIds = @($property.Value.threadIds | Where-Object { $_ -ne $ThreadId })
}
$targetSidebar = Get-CodexPropertyValue -InputObject $sidebar -Name ([string]$targetProject.id)
if ($null -eq $targetSidebar) {
    $targetSidebar = [pscustomobject]@{ threadIds = @() }
    Set-CodexPropertyValue -InputObject $sidebar -Name ([string]$targetProject.id) -Value $targetSidebar
}
$targetSidebar.threadIds = @($ThreadId) + @($targetSidebar.threadIds | Where-Object { $_ -ne $ThreadId })

$projectless = Get-CodexPropertyValue -InputObject $state -Name 'projectless-thread-ids'
if ($null -ne $projectless) {
    Set-CodexPropertyValue -InputObject $state -Name 'projectless-thread-ids' -Value @(
        $projectless | Where-Object { $_ -ne $ThreadId }
    )
}

$writableRoots = Get-CodexPropertyValue -InputObject $state -Name 'thread-writable-roots'
if ($null -eq $writableRoots) {
    $writableRoots = [pscustomobject][ordered]@{}
    Set-CodexPropertyValue -InputObject $state -Name 'thread-writable-roots' -Value $writableRoots
}
Set-CodexPropertyValue `
    -InputObject $writableRoots `
    -Name $ThreadId `
    -Value ([object[]]@($targetPath))

Assert-CodexPatchedRoute `
    -State $state `
    -ExpectedProjectId ([string]$targetProject.id) `
    -ExpectedHostId $targetHostId `
    -ExpectedProjectPath $targetPath `
    -ExpectedCwd $targetCwd

$projectPathChanged = $true
if ($currentProjectPath) {
    $projectPathChanged = (
        Get-CodexNormalizedRemotePath -Path $currentProjectPath
    ) -ne $targetPath
}
$cwdChanged = $true
if ($currentCwd) {
    $cwdChanged = (Get-CodexNormalizedRemotePath -Path $currentCwd) -ne $targetCwd
}
$changed = (
    $currentProjectId -ne [string]$targetProject.id -or
    $currentHostId -ne $targetHostId -or
    $projectPathChanged -or
    $cwdChanged
)

$summary = [pscustomobject]@{
    ThreadId = $ThreadId
    StatePath = $StatePath
    CurrentProjectId = $currentProjectId
    CurrentHostId = $currentHostId
    CurrentProjectPath = $currentProjectPath
    CurrentCwd = $currentCwd
    TargetProjectId = [string]$targetProject.id
    TargetHostId = $targetHostId
    TargetProjectPath = $targetPath
    TargetCwd = $targetCwd
    WorkspaceStateCreated = $workspaceCreated
    WorkspaceStateUpdated = $true
    WritableRootsUpdated = $true
    AssignmentChanged = $changed
    ApplyRequested = [bool]$Apply
}
$summary | Format-List

if (-not $Apply) {
    Write-Host 'DRY RUN: no file was changed. Close every Codex Desktop process, then rerun with -Apply.' -ForegroundColor Yellow
    return
}

Assert-CodexDesktopStopped

$stateDirectory = Split-Path -Parent $StatePath
$timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$backupDirectory = Join-Path $stateDirectory ('.route-fix-backups\{0}-{1}' -f $ThreadId, $timestamp)
New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null

$stateBackupPath = Join-Path $backupDirectory (Split-Path -Leaf $StatePath)
Copy-Item -LiteralPath $StatePath -Destination $stateBackupPath

$standardBackupPath = "$StatePath.bak"
if (Test-Path -LiteralPath $standardBackupPath -PathType Leaf) {
    Copy-Item -LiteralPath $standardBackupPath -Destination (
        Join-Path $backupDirectory (Split-Path -Leaf $standardBackupPath)
    )
}

$patchedText = $state | ConvertTo-Json -Depth 100 -Compress
$patchedText | ConvertFrom-Json | Out-Null

Assert-CodexDesktopStopped
$swapBackupPath = Join-Path $backupDirectory '.codex-global-state.swap-original.json'
Write-CodexAtomicText -Path $StatePath -Text $patchedText -SwapBackupPath $swapBackupPath

$standardSwapBackupPath = Join-Path $backupDirectory '.codex-global-state-bak.swap-original.json'
Write-CodexAtomicText -Path $standardBackupPath -Text $patchedText -SwapBackupPath $standardSwapBackupPath

$persistedState = [IO.File]::ReadAllText($StatePath, $utf8NoBom) | ConvertFrom-Json
Assert-CodexPatchedRoute `
    -State $persistedState `
    -ExpectedProjectId ([string]$targetProject.id) `
    -ExpectedHostId $targetHostId `
    -ExpectedProjectPath $targetPath `
    -ExpectedCwd $targetCwd

$hash = (Get-FileHash -LiteralPath $StatePath -Algorithm SHA256).Hash
Write-Host "UPDATED: task '$ThreadId' now routes to '$targetHostId'." -ForegroundColor Green
Write-Host "BACKUP: $backupDirectory"
Write-Host "SHA256: $hash"
Write-Host 'Start Codex Desktop and verify that the task opens under the target SSH connection.'
