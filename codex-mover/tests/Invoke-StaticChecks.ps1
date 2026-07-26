#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$expectedFiles = @(
    'README.md',
    'docs\TROUBLESHOOTING.md',
    'docs\APPX-PLUGIN-INCIDENT.md',
    'docs\SSH-REMOTE-SESSION-WINDOWS-COMPATIBILITY.md',
    'src\CodexMover.Native.cs',
    'src\CodexMover.Common.psm1',
    'scripts\Get-CodexStorageReport.ps1',
    'scripts\Start-CodexMigration.ps1',
    'scripts\Finalize-CodexMigration.ps1',
    'scripts\Test-CodexMigration.ps1',
    'scripts\Remove-CodexMigrationBackups.ps1',
    'scripts\Remove-CodexSidecarUser.ps1',
    'scripts\Repair-CodexRemoteThreadRoute.ps1'
)

foreach ($relativePath in $expectedFiles) {
    $fullPath = Join-Path $projectRoot $relativePath
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "Expected project file is missing: $relativePath"
    }
}

$parseFailures = @()
$powerShellFiles = @(Get-ChildItem -LiteralPath $projectRoot -Recurse -File | Where-Object { $_.Extension -in @('.ps1', '.psm1') })
foreach ($file in $powerShellFiles) {
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    foreach ($parseError in @($errors)) {
        $parseFailures += '{0}:{1}:{2} {3}' -f $file.FullName, $parseError.Extent.StartLineNumber, $parseError.Extent.StartColumnNumber, $parseError.Message
    }
}
if ($parseFailures.Count -gt 0) {
    throw "PowerShell parser failures:`n$($parseFailures -join "`n")"
}

$codeFiles = @(Get-ChildItem -LiteralPath $projectRoot -Recurse -File | Where-Object { $_.Extension -in @('.ps1', '.psm1', '.cs') })
$forbiddenPatterns = @(
    '(?i)C:\\Users\\[A-Za-z0-9._-]+',
    '(?i)S-1-5-21-(\d+-){3}\d+',
    '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\b'
)
foreach ($file in $codeFiles) {
    $content = Get-Content -LiteralPath $file.FullName -Raw
    foreach ($pattern in $forbiddenPatterns) {
        if ($content -match $pattern) {
            throw "Machine-specific absolute value matched '$pattern' in $($file.FullName)"
        }
    }
}

$forbiddenAppxMutationPattern = '(?i)\b(?:Move-' + 'AppxPackage|Add-' + 'AppxVolume)\b'
foreach ($file in $codeFiles) {
    $content = Get-Content -LiteralPath $file.FullName -Raw
    if ($content -match $forbiddenAppxMutationPattern) {
        throw "Codex AppX relocation command found in $($file.FullName). The AppX package must stay on the Windows system volume."
    }
}

$startScriptContent = Get-Content -LiteralPath (Join-Path $projectRoot 'scripts\Start-CodexMigration.ps1') -Raw
$finalizeScriptContent = Get-Content -LiteralPath (Join-Path $projectRoot 'scripts\Finalize-CodexMigration.ps1') -Raw
$testScriptContent = Get-Content -LiteralPath (Join-Path $projectRoot 'scripts\Test-CodexMigration.ps1') -Raw
$cleanupScriptContent = Get-Content -LiteralPath (Join-Path $projectRoot 'scripts\Remove-CodexMigrationBackups.ps1') -Raw
if ($startScriptContent -notmatch "appx_strategy\s*=\s*'keep_system_volume'") {
    throw 'Start-CodexMigration.ps1 does not record the required keep_system_volume AppX strategy.'
}
foreach ($scriptCheck in @(
    [pscustomobject]@{ Name = 'Start'; Content = $startScriptContent },
    [pscustomobject]@{ Name = 'Finalize'; Content = $finalizeScriptContent },
    [pscustomobject]@{ Name = 'Test'; Content = $testScriptContent },
    [pscustomobject]@{ Name = 'Cleanup'; Content = $cleanupScriptContent }
)) {
    if ($scriptCheck.Content -notmatch '\bGet-CodexAppxPlacement\b') {
        throw "$($scriptCheck.Name) migration script does not enforce Codex AppX placement."
    }
}

$routeScriptPath = Join-Path $projectRoot 'scripts\Repair-CodexRemoteThreadRoute.ps1'
$routeScriptContent = Get-Content -LiteralPath $routeScriptPath -Raw
$routeRequirements = [ordered]@{
    'saved remote project lookup' = '\bremote-projects\b'
    'task assignment update' = '\bthread-project-assignments\b'
    'workspace state update' = 'thread-workspace-state-v1'
    'sidebar order update' = '\bsidebar-project-thread-orders\b'
    'writable root update' = '\bthread-writable-roots\b'
    'Desktop process guard' = "Get-Process\s+-Name\s+'ChatGPT'"
    'explicit apply switch' = '\[switch\]\$Apply'
    'timestamped route backup' = '\.route-fix-backups'
}
foreach ($requirement in $routeRequirements.GetEnumerator()) {
    if ($routeScriptContent -notmatch $requirement.Value) {
        throw "Remote task route repair is missing $($requirement.Key)."
    }
}

$routeTestRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-route-test-' + [guid]::NewGuid().ToString('N'))
$routeStatePath = Join-Path $routeTestRoot '.codex-global-state.json'
$routeThreadId = [guid]::NewGuid().ToString()
$routeSourceProjectId = [guid]::NewGuid().ToString()
$routeTargetProjectId = [guid]::NewGuid().ToString()
$routeSourceHost = 'remote-ssh-discovered:source-account'
$routeTargetHost = 'remote-ssh-discovered:target-account'
$routeSourcePath = '/srv/projects/source'
$routeTargetPath = '/srv/projects/target'

$routeAssignments = [ordered]@{}
$routeAssignments[$routeThreadId] = [ordered]@{
    projectKind = 'remote'
    projectId = $routeSourceProjectId
    path = $routeSourcePath
    cwd = $routeSourcePath
    hostId = $routeSourceHost
    pendingCoreUpdate = $false
}
$routeAtoms = [ordered]@{}
$routeAtoms["thread-workspace-state-v1:$routeThreadId"] = [ordered]@{
    revision = [guid]::NewGuid().ToString()
    project = [ordered]@{
        projectKind = 'remote'
        projectId = $routeSourceProjectId
        path = $routeSourcePath
        hostId = $routeSourceHost
    }
    applied = [ordered]@{
        projectSources = @($routeSourcePath)
        cwd = $routeSourcePath
        runtimeWorkspaceRoots = @($routeSourcePath)
    }
    pending = $null
}
$routeSidebar = [ordered]@{}
$routeSidebar[$routeSourceProjectId] = [ordered]@{ threadIds = @($routeThreadId) }
$routeSidebar[$routeTargetProjectId] = [ordered]@{ threadIds = @() }
$routeWritableRoots = [ordered]@{}
$routeWritableRoots[$routeThreadId] = $routeSourcePath
$routeState = [ordered]@{
    'remote-projects' = @(
        [ordered]@{
            id = $routeSourceProjectId
            hostId = $routeSourceHost
            remotePath = $routeSourcePath
            label = 'source'
        },
        [ordered]@{
            id = $routeTargetProjectId
            hostId = $routeTargetHost
            remotePath = $routeTargetPath
            label = 'target'
        }
    )
    'thread-project-assignments' = $routeAssignments
    'electron-persisted-atom-state' = $routeAtoms
    'sidebar-project-thread-orders' = $routeSidebar
    'projectless-thread-ids' = @($routeThreadId)
    'thread-writable-roots' = $routeWritableRoots
}

New-Item -ItemType Directory -Path $routeTestRoot -Force | Out-Null
try {
    [IO.File]::WriteAllText(
        $routeStatePath,
        ($routeState | ConvertTo-Json -Depth 20 -Compress),
        (New-Object Text.UTF8Encoding($false))
    )
    $routeHashBefore = (Get-FileHash -LiteralPath $routeStatePath -Algorithm SHA256).Hash
    $routeDryRunOutput = & $routeScriptPath `
        -ThreadId $routeThreadId `
        -TargetHost 'target-account' `
        -TargetRemotePath $routeTargetPath `
        -StatePath $routeStatePath 6>&1 | Out-String
    $routeHashAfter = (Get-FileHash -LiteralPath $routeStatePath -Algorithm SHA256).Hash
    if ($routeHashBefore -ne $routeHashAfter -or $routeDryRunOutput -notmatch 'DRY RUN') {
        throw 'Remote task route dry-run changed its input or omitted the dry-run result.'
    }

    & {
        param(
            [string]$ScriptPath,
            [string]$TaskId,
            [string]$RemotePath,
            [string]$DesktopStatePath
        )

        function Get-Process {
            param(
                [string[]]$Name,
                $ErrorAction
            )
            return @()
        }

        & $ScriptPath `
            -ThreadId $TaskId `
            -TargetHost 'target-account' `
            -TargetRemotePath $RemotePath `
            -StatePath $DesktopStatePath `
            -Apply | Out-Null
    } $routeScriptPath $routeThreadId $routeTargetPath $routeStatePath

    $routePatchedState = Get-Content -LiteralPath $routeStatePath -Raw | ConvertFrom-Json
    $routePatchedAssignment = $routePatchedState.'thread-project-assignments'.$routeThreadId
    $routePatchedWorkspace = $routePatchedState.'electron-persisted-atom-state'."thread-workspace-state-v1:$routeThreadId"
    $routeSourceOrder = @($routePatchedState.'sidebar-project-thread-orders'.$routeSourceProjectId.threadIds)
    $routeTargetOrder = @($routePatchedState.'sidebar-project-thread-orders'.$routeTargetProjectId.threadIds)
    if ($routePatchedAssignment.projectId -ne $routeTargetProjectId -or
        $routePatchedAssignment.hostId -ne $routeTargetHost -or
        $routePatchedWorkspace.project.projectId -ne $routeTargetProjectId -or
        $routeSourceOrder -contains $routeThreadId -or
        $routeTargetOrder -notcontains $routeThreadId -or
        $routePatchedState.'thread-writable-roots'.$routeThreadId -ne $routeTargetPath) {
        throw 'Remote task route apply test did not update every required route field.'
    }
    if (-not (Test-Path -LiteralPath "$routeStatePath.bak" -PathType Leaf) -or
        @(Get-ChildItem -LiteralPath (Join-Path $routeTestRoot '.route-fix-backups') -Recurse -File).Count -lt 1) {
        throw 'Remote task route apply test did not create its recovery files.'
    }
    Write-Host 'PASS remote task Windows route dry-run, apply, validation, and backup test'
}
finally {
    if (Test-Path -LiteralPath $routeTestRoot) {
        Remove-Item -LiteralPath $routeTestRoot -Recurse -Force
    }
}

$nativePath = Join-Path $projectRoot 'src\CodexMover.Native.cs'
if (-not ('CodexMoverNative' -as [type])) {
    Add-Type -Path $nativePath
}
$modulePath = Join-Path $projectRoot 'src\CodexMover.Common.psm1'
Import-Module $modulePath -Force
$systemRootPath = [IO.Path]::GetPathRoot($env:SystemRoot)
if ((Get-CodexNormalizedPath -Path $systemRootPath) -ne $systemRootPath) {
    throw 'Path normalization removed the separator from a drive root.'
}

$testId = [guid]::NewGuid().ToString('N')
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("codex-mover-test-$testId")
$deleteRoot = Join-Path $temporaryRoot 'delete-root'
$junctionTarget = Join-Path $temporaryRoot 'junction-target'
$rootLink = Join-Path $temporaryRoot 'root-link'
$sentinel = Join-Path $junctionTarget 'must-survive.txt'
$copySource = Join-Path $temporaryRoot 'copy-source'
$copyTarget = Join-Path $temporaryRoot 'copy-target'
$copyLog = Join-Path $temporaryRoot 'robocopy.log'
New-Item -ItemType Directory -Path $deleteRoot, $junctionTarget, $copySource, $copyTarget -Force | Out-Null
Set-Content -LiteralPath $sentinel -Value 'sentinel' -Encoding UTF8

try {
    Set-Content -LiteralPath (Join-Path $copySource 'source.txt') -Value 'source' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $copyTarget 'extra.txt') -Value 'extra' -Encoding UTF8
    try {
        Invoke-CodexRobocopy -Source $copySource -Destination $copyTarget -Mode Union -LogPath $copyLog -Verify | Out-Null
    }
    catch {
        if (Test-Path -LiteralPath $copyLog) {
            Write-Host (Get-Content -LiteralPath $copyLog -Raw)
        }
        throw
    }
    if (-not (Test-Path -LiteralPath (Join-Path $copyTarget 'source.txt')) -or -not (Test-Path -LiteralPath (Join-Path $copyTarget 'extra.txt'))) {
        throw 'Union robocopy test did not preserve both source and target-only files.'
    }
    Invoke-CodexRobocopy -Source $copySource -Destination $copyTarget -Mode Mirror -LogPath $copyLog -Verify | Out-Null
    if (Test-Path -LiteralPath (Join-Path $copyTarget 'extra.txt')) {
        throw 'Mirror robocopy test did not remove the target-only file.'
    }
    Write-Host 'PASS union and mirror Robocopy verification test'

    $deepPath = $deleteRoot
    $segmentCount = if ($PSVersionTable.PSVersion.Major -ge 7) { 20 } else { 3 }
    for ($index = 0; $index -lt $segmentCount; $index++) {
        $deepPath = Join-Path $deepPath (('segment-{0:D2}-abcdefghijklmnopqrstuvwxyz' -f $index))
    }
    New-Item -ItemType Directory -Path $deepPath -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $deepPath 'payload.txt') -Value 'payload' -Encoding UTF8

    try {
        New-Item -ItemType Junction -Path $rootLink -Target $junctionTarget -Force | Out-Null
        [CodexMoverNative]::DeleteTreeNoFollow($rootLink)
        if ((Test-Path -LiteralPath $rootLink) -or -not (Test-Path -LiteralPath $sentinel)) {
            throw 'Native deletion followed a root junction instead of removing only the link.'
        }

        New-Item -ItemType Junction -Path (Join-Path $deleteRoot 'do-not-follow') -Target $junctionTarget -Force | Out-Null
        $rollbackLink = Join-Path $deleteRoot 'rollback-link'
        New-Item -ItemType Junction -Path $rollbackLink -Target $junctionTarget -Force | Out-Null
        [CodexMoverNative]::RemoveDirectoryLink($rollbackLink)
        if (Test-Path -LiteralPath $rollbackLink) {
            throw 'Native rollback-link removal left the junction behind.'
        }
        if (-not (Test-Path -LiteralPath $sentinel)) {
            throw 'Native rollback-link removal followed the junction target.'
        }
        [CodexMoverNative]::DeleteTreeNoFollow($deleteRoot)
        if (Test-Path -LiteralPath $deleteRoot) {
            throw 'Native deletion test left the deletion root behind.'
        }
        if (-not (Test-Path -LiteralPath $sentinel)) {
            throw 'Native deletion followed a junction and removed the sentinel target.'
        }
        $pathCoverage = if ($segmentCount -ge 20) { 'long-path and no-follow' } else { 'no-follow (Windows PowerShell path limit)' }
        Write-Host ("PASS native {0} deletion test" -f $pathCoverage)
    }
    catch [System.UnauthorizedAccessException] {
        Write-Warning 'SKIP junction deletion test because this account cannot create a junction.'
    }
}
finally {
    if (Test-Path -LiteralPath $deleteRoot) {
        Remove-Item -LiteralPath $deleteRoot -Recurse -Force
    }
    if (Test-Path -LiteralPath $rootLink) {
        [CodexMoverNative]::RemoveDirectoryLink($rootLink)
    }
    if (Test-Path -LiteralPath $junctionTarget) {
        Remove-Item -LiteralPath $junctionTarget -Recurse -Force
    }
    if (Test-Path -LiteralPath $copySource) {
        Remove-Item -LiteralPath $copySource -Recurse -Force
    }
    if (Test-Path -LiteralPath $copyTarget) {
        Remove-Item -LiteralPath $copyTarget -Recurse -Force
    }
    if (Test-Path -LiteralPath $copyLog) {
        Remove-Item -LiteralPath $copyLog -Force
    }
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Force
    }
}

Write-Host ("PASS parsed {0} PowerShell files" -f $powerShellFiles.Count)
Write-Host ("PASS verified {0} expected project files" -f $expectedFiles.Count)
Write-Host 'PASS compiled CodexMover.Native.cs'
Write-Host 'PASS machine-specific value scan'
Write-Host 'PASS Codex AppX system-volume guard'
Write-Host 'PASS remote task Windows route guard'
