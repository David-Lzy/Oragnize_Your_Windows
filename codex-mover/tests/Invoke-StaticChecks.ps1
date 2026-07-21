#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$expectedFiles = @(
    'README.md',
    'docs\TROUBLESHOOTING.md',
    'src\CodexMover.Native.cs',
    'src\CodexMover.Common.psm1',
    'scripts\Get-CodexStorageReport.ps1',
    'scripts\Start-CodexMigration.ps1',
    'scripts\Finalize-CodexMigration.ps1',
    'scripts\Test-CodexMigration.ps1',
    'scripts\Remove-CodexMigrationBackups.ps1',
    'scripts\Remove-CodexSidecarUser.ps1'
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
