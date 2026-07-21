#requires -Version 5.1
<#
.SYNOPSIS
Reports Windows Codex storage without changing the system.

.EXAMPLE
.\Get-CodexStorageReport.ps1 -DestinationRoot 'E:\CodexData'

.EXAMPLE
.\Get-CodexStorageReport.ps1 -AsJson
#>
[CmdletBinding()]
param(
    [string]$UserProfile = $env:USERPROFILE,
    [string]$DestinationRoot,
    [switch]$AsJson
)

$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot '..\src\CodexMover.Common.psm1'
Import-Module $modulePath -Force

$profilePath = Get-CodexNormalizedPath -Path $UserProfile
$paths = @(
    [pscustomobject]@{ Category = 'CODEX_HOME'; Path = Join-Path $profilePath '.codex' },
    [pscustomobject]@{ Category = 'RuntimeCache'; Path = Join-Path $profilePath '.cache\codex-runtimes' },
    [pscustomobject]@{ Category = 'LocalOpenAI'; Path = Join-Path $profilePath 'AppData\Local\OpenAI\Codex' },
    [pscustomobject]@{ Category = 'PackagedData'; Path = Join-Path $profilePath 'AppData\Local\Packages\OpenAI.Codex_2p2nqsd0c76g0' }
)

$entries = @()
foreach ($path in $paths) {
    $summary = Get-CodexPathSummary -Path $path.Path
    $entries += [pscustomobject]@{
        Category = $path.Category
        Path = $summary.Path
        Exists = $summary.Exists
        LinkType = $summary.LinkType
        Target = $summary.Target
        Files = $summary.Files
        LogicalBytes = $summary.LogicalBytes
        GiB = [math]::Round($summary.LogicalBytes / 1GB, 3)
    }
}

$package = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue | Select-Object -First 1
$packageSummary = $null
if ($package) {
    $installItem = Get-Item -LiteralPath $package.InstallLocation -Force -ErrorAction SilentlyContinue
    $packageSummary = [pscustomobject]@{
        Name = $package.Name
        PackageFullName = $package.PackageFullName
        LogicalInstallLocation = $package.InstallLocation
        LinkType = $installItem.LinkType
        PhysicalTarget = ($installItem.Target -join ';')
        Status = [string]$package.Status
    }
}

$destination = $null
if ($DestinationRoot) {
    $destinationPath = Get-CodexNormalizedPath -Path $DestinationRoot
    $driveName = [IO.Path]::GetPathRoot($destinationPath).Substring(0, 1)
    $drive = Get-PSDrive -Name $driveName -ErrorAction Stop
    $volume = Get-Volume -DriveLetter $driveName -ErrorAction SilentlyContinue
    $destination = [pscustomobject]@{
        Root = $destinationPath
        Drive = $driveName
        FileSystem = $volume.FileSystem
        FreeBytes = [long]$drive.Free
        FreeGiB = [math]::Round($drive.Free / 1GB, 2)
    }
}

$sidecarProfiles = @(Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue |
    Where-Object { $_.LocalPath -and (Split-Path -Leaf $_.LocalPath) -ieq 'codex' } |
    Select-Object SID, LocalPath, Loaded, Special)

$report = [ordered]@{
    CheckedAt = (Get-Date).ToString('o')
    UserProfile = $profilePath
    Entries = $entries
    TotalLogicalBytes = [long](($entries | Measure-Object LogicalBytes -Sum).Sum)
    Package = $packageSummary
    Destination = $destination
    SidecarProfiles = $sidecarProfiles
}

if ($AsJson) {
    $report | ConvertTo-Json -Depth 8
    return
}

$entries | Format-Table Category, Exists, LinkType, GiB, Path, Target -AutoSize
if ($packageSummary) {
    Write-Host ''
    $packageSummary | Format-List
}
if ($destination) {
    Write-Host ''
    $destination | Format-List
}
if ($sidecarProfiles.Count -gt 0) {
    Write-Host ''
    Write-Warning 'A separate Windows user profile named codex exists. It is not part of the current user migration.'
    $sidecarProfiles | Format-Table -AutoSize
}
