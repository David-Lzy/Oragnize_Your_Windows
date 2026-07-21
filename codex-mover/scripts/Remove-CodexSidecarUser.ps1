#requires -Version 5.1
#requires -RunAsAdministrator
<#
.SYNOPSIS
Permanently removes a separately verified Windows account used as a Codex sidecar.

.DESCRIPTION
This operation is not part of the normal Codex data migration and creates no
backup. The account name and SID must both match before anything is removed.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$AccountName,
    [Parameter(Mandatory)][ValidatePattern('^S-1-5-21-(\d+-){3}\d+$')][string]$ExpectedSid,
    [switch]$RemoveUserTasks,
    [switch]$IUnderstandThisDeletesTheAccount
)

$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot '..\src\CodexMover.Common.psm1'
Import-Module $modulePath -Force

if (-not (Test-CodexAdministrator)) {
    throw 'This script must run in an elevated PowerShell window.'
}
if (-not $IUnderstandThisDeletesTheAccount) {
    throw 'Pass -IUnderstandThisDeletesTheAccount to acknowledge permanent deletion without backup.'
}

$account = Get-LocalUser -Name $AccountName -ErrorAction Stop
$actualSid = [string]$account.SID.Value
if (-not $actualSid.Equals($ExpectedSid, [StringComparison]::OrdinalIgnoreCase)) {
    throw "SID mismatch. Expected $ExpectedSid but account $AccountName has $actualSid."
}
if ($actualSid -match '-(500|501|503|504)$') {
    throw "Refusing to remove a built-in Windows account SID: $actualSid"
}

$currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
if ($actualSid.Equals($currentSid, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Refusing to remove the account currently running this script.'
}

$profiles = @(Get-CimInstance Win32_UserProfile -Filter ("SID='{0}'" -f $actualSid.Replace("'", "''")))
if ($profiles.Count -gt 1) {
    throw "Multiple profiles unexpectedly match SID $actualSid."
}
$profile = $profiles | Select-Object -First 1
if ($profile) {
    if ($profile.Special) {
        throw "Refusing to remove a special Windows profile: $($profile.LocalPath)"
    }
    if ($profile.Loaded) {
        throw "The profile is still loaded: $($profile.LocalPath)"
    }
    if ((Split-Path -Leaf ([string]$profile.LocalPath)) -ine $AccountName) {
        throw "Profile leaf does not match the account name: $($profile.LocalPath)"
    }
    $normalizedProfile = Get-CodexNormalizedPath -Path ([string]$profile.LocalPath)
    if ($normalizedProfile.Equals((Get-CodexNormalizedPath -Path $env:USERPROFILE), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Refusing to remove the active user profile.'
    }
}

$ownedProcesses = @()
foreach ($process in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
    try {
        $owner = Invoke-CimMethod -InputObject $process -MethodName GetOwnerSid -ErrorAction Stop
        if ($owner.Sid -and ([string]$owner.Sid).Equals($actualSid, [StringComparison]::OrdinalIgnoreCase)) {
            $ownedProcesses += $process
        }
    }
    catch {
        # Protected system processes may not expose an owner; they cannot belong to this local sidecar user.
    }
}
if ($ownedProcesses.Count -gt 0) {
    $processList = ($ownedProcesses | ForEach-Object { '{0}({1})' -f $_.Name, $_.ProcessId }) -join ', '
    throw "The sidecar account still owns running processes: $processList"
}

$serviceNames = @(
    $AccountName,
    ('.\{0}' -f $AccountName),
    ('{0}\{1}' -f $env:COMPUTERNAME, $AccountName)
)
$ownedServices = @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object {
    $_.StartName -and $_.StartName -in $serviceNames
})
if ($ownedServices.Count -gt 0) {
    throw "Services are configured to use this account: $(($ownedServices.Name) -join ', ')"
}

$taskRoot = Join-Path $env:WINDIR 'System32\Tasks'
$ownedTasks = @()
if (Test-Path -LiteralPath $taskRoot) {
    $resolvedTaskRoot = (Resolve-Path -LiteralPath $taskRoot).Path
    foreach ($taskFile in @(Get-ChildItem -LiteralPath $resolvedTaskRoot -Recurse -File -Force -ErrorAction Stop)) {
        try {
            $content = Get-Content -LiteralPath $taskFile.FullName -Raw -ErrorAction Stop
            if ($content -match [regex]::Escape($actualSid)) {
                $relative = $taskFile.FullName.Substring($resolvedTaskRoot.Length).TrimStart('\')
                $ownedTasks += ('\{0}' -f $relative)
            }
        }
        catch {
            throw "Unable to inspect scheduled task file: $($taskFile.FullName)"
        }
    }
}
if ($ownedTasks.Count -gt 0 -and -not $RemoveUserTasks) {
    throw "Scheduled tasks reference this SID. Review them or pass -RemoveUserTasks: $(($ownedTasks) -join ', ')"
}

$targetDescription = '{0} ({1})' -f $AccountName, $actualSid
if (-not $PSCmdlet.ShouldProcess($targetDescription, 'Permanently remove sidecar account, profile, AppX registration, and selected tasks')) {
    return
}

foreach ($taskName in $ownedTasks) {
    & schtasks.exe /Delete /TN $taskName /F | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to delete scheduled task: $taskName"
    }
}

$packages = @(Get-AppxPackage -User $actualSid -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue)
foreach ($package in $packages) {
    Remove-AppxPackage -Package $package.PackageFullName -User $actualSid -ErrorAction Stop
}

$profilePath = if ($profile) { [string]$profile.LocalPath } else { $null }
if ($profile) {
    Remove-CimInstance -InputObject $profile -ErrorAction Stop
    if ($profilePath -and (Test-Path -LiteralPath $profilePath)) {
        throw "Windows reported profile deletion, but the directory still exists: $profilePath"
    }
}

Remove-LocalUser -Name $AccountName -ErrorAction Stop
if (Get-LocalUser -Name $AccountName -ErrorAction SilentlyContinue) {
    throw "Account still exists after deletion: $AccountName"
}
$remainingProfile = Get-CimInstance Win32_UserProfile -Filter ("SID='{0}'" -f $actualSid.Replace("'", "''")) -ErrorAction SilentlyContinue
if ($remainingProfile) {
    throw "Profile registration still exists after deletion: $actualSid"
}

[pscustomobject]@{
    removed_at = (Get-Date).ToString('o')
    account = $AccountName
    sid = $actualSid
    profile = $profilePath
    removed_tasks = $ownedTasks
    removed_appx_registrations = @($packages.PackageFullName)
    verified_account_absent = $true
    verified_profile_absent = (-not $profilePath -or -not (Test-Path -LiteralPath $profilePath))
}
