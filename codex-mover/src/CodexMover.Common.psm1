Set-StrictMode -Version Latest

function Get-CodexNormalizedPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $fullPath = [IO.Path]::GetFullPath($Path)
    $rootPath = [IO.Path]::GetPathRoot($fullPath)
    if ($fullPath.Equals($rootPath, [StringComparison]::OrdinalIgnoreCase)) {
        return $rootPath
    }
    $fullPath.TrimEnd('\')
}

function Test-CodexAdministrator {
    [CmdletBinding()]
    param()

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Initialize-CodexMoverNative {
    [CmdletBinding()]
    param()

    if (-not ('CodexMoverNative' -as [type])) {
        $nativePath = Join-Path $PSScriptRoot 'CodexMover.Native.cs'
        Add-Type -Path $nativePath
    }
}

function Get-CodexPathSummary {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item) {
        return [pscustomobject]@{
            Path = $Path
            Exists = $false
            LinkType = $null
            Target = $null
            Files = 0
            LogicalBytes = 0
        }
    }

    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        return [pscustomobject]@{
            Path = $item.FullName
            Exists = $true
            LinkType = if ($item.LinkType) { $item.LinkType } else { 'ReparsePoint' }
            Target = ($item.Target -join ';')
            Files = 0
            LogicalBytes = 0
        }
    }

    $files = @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue)
    [pscustomobject]@{
        Path = $item.FullName
        Exists = $true
        LinkType = $null
        Target = $null
        Files = $files.Count
        LogicalBytes = [long](($files | Measure-Object -Property Length -Sum).Sum)
    }
}

function Write-CodexJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$InputObject,
        [Parameter(Mandatory)][string]$Path,
        [ValidateRange(2, 20)][int]$Depth = 10
    )

    $parent = Split-Path -Parent $Path
    if ($parent) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $InputObject | ConvertTo-Json -Depth $Depth | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Invoke-CodexRobocopy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][ValidateSet('Union', 'Mirror')][string]$Mode,
        [Parameter(Mandatory)][string]$LogPath,
        [switch]$Verify
    )

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $modeArguments = if ($Mode -eq 'Union') { @('/E', '/XO') } else { @('/MIR') }
    $restartableMode = if (Test-CodexAdministrator) { '/ZB' } else { '/Z' }
    $commonArguments = @(
        '/XJ', '/COPY:DAT', '/DCOPY:DAT', '/R:5', '/W:2', $restartableMode,
        '/NP', '/NFL', '/NDL', "/LOG+:$LogPath"
    )

    $copyArguments = @($Source, $Destination) + @($modeArguments) + @($commonArguments)
    Write-Verbose ("robocopy.exe `"{0}`" `"{1}`" {2}" -f $Source, $Destination, (($modeArguments + $commonArguments) -join ' '))
    $copyOutput = & robocopy.exe @copyArguments
    $copyCode = $LASTEXITCODE
    if ($copyCode -gt 7) {
        throw "Robocopy failed for $Source with exit code $copyCode`n$($copyOutput -join "`n")"
    }

    if (-not $Verify) {
        return $copyCode
    }

    $verifyArguments = @(
        '/L', '/XJ', '/COPY:DAT', '/DCOPY:DAT', '/R:0', '/W:0',
        '/NP', '/NFL', '/NDL', "/LOG+:$LogPath"
    )
    $verificationCommandArguments = @($Source, $Destination) + @($modeArguments) + @($verifyArguments)
    $verifyOutput = & robocopy.exe @verificationCommandArguments
    $verifyCode = $LASTEXITCODE
    $allowedCodes = if ($Mode -eq 'Union') { @(0, 2) } else { @(0) }
    if ($verifyCode -notin $allowedCodes) {
        throw "Robocopy verification failed for $Source with exit code $verifyCode`n$($verifyOutput -join "`n")"
    }
    $verifyCode
}

function Get-CodexCoreProcesses {
    [CmdletBinding()]
    param()

    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -in @('ChatGPT.exe', 'codex.exe', 'codex-code-mode-host.exe') -and
            $_.ExecutablePath -match 'OpenAI\.Codex|OpenAI\\Codex'
        }
}

function Wait-CodexDesktopExit {
    [CmdletBinding()]
    param(
        [ValidateRange(30, 7200)][int]$TimeoutSeconds = 1800,
        [scriptblock]$OnProgress
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastNotice = [datetime]::MinValue
    while ($true) {
        $processes = @(Get-CodexCoreProcesses)
        if ($processes.Count -eq 0) {
            return
        }
        if ((Get-Date) -gt $deadline) {
            throw 'Timed out waiting for Codex Desktop to exit.'
        }
        if ($OnProgress -and ((Get-Date) - $lastNotice).TotalSeconds -ge 15) {
            & $OnProgress (($processes.ProcessId | Sort-Object) -join ', ')
            $lastNotice = Get-Date
        }
        Start-Sleep -Seconds 2
    }
}

function Resolve-CodexSessionFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CodexHome,
        [string]$ThreadId
    )

    $sessionsRoot = Join-Path $CodexHome 'sessions'
    if (-not (Test-Path -LiteralPath $sessionsRoot)) {
        return $null
    }

    $files = Get-ChildItem -LiteralPath $sessionsRoot -Recurse -File -Force -Filter '*.jsonl'
    if ($ThreadId) {
        return $files | Where-Object { $_.Name -like "*$ThreadId*.jsonl" } | Select-Object -First 1
    }
    $files | Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

function Get-CodexFileId {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $output = & fsutil.exe file queryfileid $Path 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to read file ID for $Path"
    }
    $match = [regex]::Match(($output -join ' '), '0x[0-9A-Fa-f]+')
    if (-not $match.Success) {
        throw "Unable to parse file ID for $Path"
    }
    $match.Value.ToLowerInvariant()
}

function Test-CodexSameFileId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FirstPath,
        [Parameter(Mandatory)][string]$SecondPath
    )

    (Get-CodexFileId -Path $FirstPath) -eq (Get-CodexFileId -Path $SecondPath)
}

function Test-CodexJunction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedTarget
    )

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item -or $item.LinkType -ne 'Junction') {
        return $false
    }
    $actual = Get-CodexNormalizedPath -Path ([string]($item.Target | Select-Object -First 1))
    $expected = Get-CodexNormalizedPath -Path $ExpectedTarget
    $actual.Equals($expected, [StringComparison]::OrdinalIgnoreCase)
}

Export-ModuleMember -Function @(
    'Get-CodexNormalizedPath',
    'Test-CodexAdministrator',
    'Initialize-CodexMoverNative',
    'Get-CodexPathSummary',
    'Write-CodexJson',
    'Invoke-CodexRobocopy',
    'Get-CodexCoreProcesses',
    'Wait-CodexDesktopExit',
    'Resolve-CodexSessionFile',
    'Get-CodexFileId',
    'Test-CodexSameFileId',
    'Test-CodexJunction'
)
