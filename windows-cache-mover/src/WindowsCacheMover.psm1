Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-NormalizedPath {
    param([Parameter(Mandatory)][string]$Path)
    $full = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($full)
    if ($full.TrimEnd('\') -ieq $root.TrimEnd('\')) {
        return $root
    }
    return $full.TrimEnd('\')
}

function Test-PathWithinRoot {
    param(
        [Parameter(Mandatory)][string]$Candidate,
        [Parameter(Mandatory)][string]$Root
    )
    $candidateFull = (Get-NormalizedPath -Path $Candidate).TrimEnd('\')
    $rootFull = (Get-NormalizedPath -Path $Root).TrimEnd('\')
    return $candidateFull -ieq $rootFull -or
        $candidateFull.StartsWith($rootFull + '\', [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-TreeStats {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$LiteralPath)

    $bytes = [int64]0
    $files = [int64]0
    $errors = [int64]0
    if (-not (Test-Path -LiteralPath $LiteralPath)) {
        return [pscustomobject]@{ Bytes = $bytes; Files = $files; Errors = $errors }
    }

    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push((Get-NormalizedPath -Path $LiteralPath))
    while ($pending.Count -gt 0) {
        $current = $pending.Pop()
        try {
            foreach ($entry in [System.IO.Directory]::EnumerateFileSystemEntries($current)) {
                try {
                    $attributes = [System.IO.File]::GetAttributes($entry)
                    if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                        continue
                    }
                    if (($attributes -band [System.IO.FileAttributes]::Directory) -ne 0) {
                        $pending.Push($entry)
                    } else {
                        $bytes += (New-Object System.IO.FileInfo($entry)).Length
                        $files++
                    }
                } catch {
                    $errors++
                }
            }
        } catch {
            $errors++
        }
    }

    return [pscustomobject]@{ Bytes = $bytes; Files = $files; Errors = $errors }
}

function Get-LinkTarget {
    param([Parameter(Mandatory)]$Item)
    if ($null -eq $Item.Target) {
        return $null
    }
    return (@($Item.Target) -join ';')
}

function Remove-DirectoryJunction {
    param([Parameter(Mandatory)][string]$LiteralPath)
    $item = Get-Item -LiteralPath $LiteralPath -Force -ErrorAction Stop
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) {
        throw "Refusing to remove a normal directory as a junction: $LiteralPath"
    }
    [System.IO.Directory]::Delete((Get-NormalizedPath -Path $LiteralPath), $false)
}

function Send-EnvironmentChange {
    if (-not ('WindowsCacheMover.NativeMethods' -as [type])) {
        Add-Type @'
using System;
using System.Runtime.InteropServices;

namespace WindowsCacheMover
{
    public static class NativeMethods
    {
        [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
        public static extern IntPtr SendMessageTimeout(
            IntPtr hWnd,
            uint message,
            UIntPtr wParam,
            string lParam,
            uint flags,
            uint timeout,
            out UIntPtr result);
    }
}
'@
    }
    $result = [UIntPtr]::Zero
    [void][WindowsCacheMover.NativeMethods]::SendMessageTimeout(
        [IntPtr]0xffff,
        0x001A,
        [UIntPtr]::Zero,
        'Environment',
        0x0002,
        5000,
        [ref]$result)
}

function New-CacheRecord {
    param(
        [string]$Name,
        [string]$Kind,
        [string]$Source,
        [string]$Target,
        [string]$ProcessName,
        [string]$EnvironmentVariable
    )
    [pscustomobject]@{
        Name = $Name
        Kind = $Kind
        Source = Get-NormalizedPath -Path $Source
        Target = Get-NormalizedPath -Path $Target
        ProcessName = $ProcessName
        EnvironmentVariable = $EnvironmentVariable
    }
}

function Get-CacheCatalog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DestinationRoot,
        [string]$HomePath = $HOME,
        [string]$LocalAppData = $env:LOCALAPPDATA,
        [switch]$IncludeMissing
    )

    $destination = Get-NormalizedPath -Path $DestinationRoot
    $browserSpecs = @(
        [pscustomobject]@{
            Name = 'Chrome'
            ProcessName = 'chrome'
            Root = Join-Path $LocalAppData 'Google\Chrome\User Data'
        },
        [pscustomobject]@{
            Name = 'Brave'
            ProcessName = 'brave'
            Root = Join-Path $LocalAppData 'BraveSoftware\Brave-Browser\User Data'
        },
        [pscustomobject]@{
            Name = 'Edge'
            ProcessName = 'msedge'
            Root = Join-Path $LocalAppData 'Microsoft\Edge\User Data'
        }
    )
    $commonRootCaches = @(
        'extensions_crx_cache',
        'component_crx_cache'
    )
    $chromeRootCaches = @(
        'OptGuideOnDeviceModel',
        'OptGuideOnDeviceClassifierModel',
        'optimization_guide_model_store'
    )
    $profileCaches = @(
        'Cache',
        'Code Cache',
        'GPUCache',
        'DawnWebGPUCache',
        'DawnGraphiteCache',
        'Media Cache',
        'Shared Dictionary',
        'Service Worker\CacheStorage',
        'Service Worker\ScriptCache'
    )

    $records = New-Object System.Collections.Generic.List[object]
    foreach ($browser in $browserSpecs) {
        if (-not $IncludeMissing -and -not (Test-Path -LiteralPath $browser.Root)) {
            continue
        }
        $browserTarget = Join-Path $destination (Join-Path 'BrowserCache' $browser.Name)
        $browserRootCaches = @($commonRootCaches)
        if ($browser.Name -eq 'Chrome') {
            $browserRootCaches += $chromeRootCaches
        }
        foreach ($relative in $browserRootCaches) {
            $source = Join-Path $browser.Root $relative
            if ($IncludeMissing -or (Test-Path -LiteralPath $source)) {
                $records.Add((New-CacheRecord -Name "$($browser.Name):$relative" -Kind 'Browser' -Source $source -Target (Join-Path $browserTarget $relative) -ProcessName $browser.ProcessName -EnvironmentVariable ''))
            }
        }

        $profiles = @()
        if (Test-Path -LiteralPath $browser.Root) {
            $profiles = @(Get-ChildItem -LiteralPath $browser.Root -Force -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -eq 'Default' -or $_.Name -eq 'Guest Profile' -or $_.Name -like 'Profile *' })
        }
        if ($IncludeMissing -and $profiles.Count -eq 0) {
            $profiles = @([pscustomobject]@{ Name = 'Default'; FullName = Join-Path $browser.Root 'Default' })
        }
        foreach ($profile in $profiles) {
            foreach ($relative in $profileCaches) {
                $source = Join-Path $profile.FullName $relative
                if ($IncludeMissing -or (Test-Path -LiteralPath $source)) {
                    $target = Join-Path (Join-Path $browserTarget $profile.Name) $relative
                    $records.Add((New-CacheRecord -Name "$($browser.Name):$($profile.Name):$relative" -Kind 'Browser' -Source $source -Target $target -ProcessName $browser.ProcessName -EnvironmentVariable ''))
                }
            }
        }
    }

    $developerCaches = @(
        [pscustomobject]@{ Name = 'pip'; Source = Join-Path $LocalAppData 'pip\cache'; Target = 'DevCache\pip'; Variable = 'PIP_CACHE_DIR' },
        [pscustomobject]@{ Name = 'npm'; Source = Join-Path $LocalAppData 'npm-cache'; Target = 'DevCache\npm'; Variable = 'NPM_CONFIG_CACHE' },
        [pscustomobject]@{ Name = 'Conda packages'; Source = Join-Path $HomePath '.conda\pkgs'; Target = 'DevCache\conda\pkgs'; Variable = 'CONDA_PKGS_DIRS' },
        [pscustomobject]@{ Name = 'Hugging Face hub'; Source = Join-Path $HomePath '.cache\huggingface\hub'; Target = 'DevCache\huggingface\hub'; Variable = 'HF_HUB_CACHE' },
        [pscustomobject]@{ Name = 'Hugging Face Xet'; Source = Join-Path $HomePath '.cache\huggingface\xet'; Target = 'DevCache\huggingface\xet'; Variable = 'HF_XET_CACHE' },
        [pscustomobject]@{ Name = 'PyTorch'; Source = Join-Path $HomePath '.cache\torch'; Target = 'DevCache\torch'; Variable = 'TORCH_HOME' },
        [pscustomobject]@{ Name = 'uv'; Source = Join-Path $LocalAppData 'uv\cache'; Target = 'DevCache\uv'; Variable = 'UV_CACHE_DIR' }
    )
    foreach ($cache in $developerCaches) {
        if ($IncludeMissing -or (Test-Path -LiteralPath $cache.Source)) {
            $records.Add((New-CacheRecord -Name $cache.Name -Kind 'Developer' -Source $cache.Source -Target (Join-Path $destination $cache.Target) -ProcessName '' -EnvironmentVariable $cache.Variable))
        }
    }

    return $records.ToArray()
}

function Get-CacheAudit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DestinationRoot,
        [string[]]$Browser = @('Chrome', 'Brave', 'Edge'),
        [switch]$IncludeDeveloper,
        [switch]$IncludeMissing,
        [switch]$Fast,
        [string]$HomePath = $HOME,
        [string]$LocalAppData = $env:LOCALAPPDATA
    )

    $catalog = Get-CacheCatalog -DestinationRoot $DestinationRoot -HomePath $HomePath -LocalAppData $LocalAppData -IncludeMissing:$IncludeMissing
    foreach ($record in $catalog) {
        if ($record.Kind -eq 'Browser' -and $Browser -notcontains ($record.Name -split ':')[0]) {
            continue
        }
        if ($record.Kind -eq 'Developer' -and -not $IncludeDeveloper) {
            continue
        }

        $item = Get-Item -LiteralPath $record.Source -Force -ErrorAction SilentlyContinue
        $isLink = $false
        $linkTarget = $null
        if ($null -ne $item) {
            $isLink = (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
            if ($isLink) {
                $linkTarget = Get-LinkTarget -Item $item
            }
        }
        $statsPath = if ($isLink -and $linkTarget) { $linkTarget } else { $record.Source }
        $stats = if ($Fast) {
            [pscustomobject]@{ Bytes = [int64]0; Files = [int64]0; Errors = [int64]0 }
        } else {
            Get-TreeStats -LiteralPath $statsPath
        }
        $running = if ($record.ProcessName) { @(Get-Process -Name $record.ProcessName -ErrorAction SilentlyContinue).Count } else { 0 }
        $managedRoot = if ($record.Kind -eq 'Browser') {
            Join-Path (Get-NormalizedPath -Path $DestinationRoot) 'BrowserCache'
        } else {
            Join-Path (Get-NormalizedPath -Path $DestinationRoot) 'DevCache'
        }
        $status = if ($isLink -and (Test-PathWithinRoot -Candidate $linkTarget -Root $managedRoot)) {
            'Migrated'
        } elseif ($isLink) {
            'OtherLink'
        } elseif ($null -eq $item) {
            'Missing'
        } elseif ($running -gt 0) {
            'InUse'
        } else {
            'Ready'
        }

        [pscustomobject]@{
            Name = $record.Name
            Kind = $record.Kind
            Status = $status
            GB = [math]::Round($stats.Bytes / 1GB, 3)
            Files = $stats.Files
            Errors = $stats.Errors
            RunningProcesses = $running
            Source = $record.Source
            Target = $record.Target
            ActualTarget = $linkTarget
            EnvironmentVariable = $record.EnvironmentVariable
        }
    }
}

function Assert-DestinationVolume {
    param([Parameter(Mandatory)][string]$DestinationRoot)
    $root = [System.IO.Path]::GetPathRoot((Get-NormalizedPath -Path $DestinationRoot))
    if ($root -notmatch '^[A-Za-z]:\\$') {
        throw "Destination must be a local drive path: $DestinationRoot"
    }
    $driveLetter = $root.Substring(0, 1)
    $volume = Get-Volume -DriveLetter $driveLetter -ErrorAction Stop
    if ($volume.FileSystem -ne 'NTFS' -or $volume.HealthStatus -ne 'Healthy') {
        throw "Destination volume must be healthy NTFS: $root"
    }
}

function Copy-CacheTree {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Target
    )
    & robocopy.exe $Source $Target /E /COPY:DAT /DCOPY:DAT /Z /XJ /R:2 /W:1 /NP /NFL /NDL /NJH /NJS | Out-Null
    $exitCode = $LASTEXITCODE
    if ($exitCode -gt 7) {
        throw "Robocopy failed with exit code $exitCode while copying '$Source'."
    }
}

function Invoke-CacheMigration {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][string]$DestinationRoot,
        [string[]]$Browser = @('Chrome', 'Brave', 'Edge'),
        [switch]$IncludeDeveloper,
        [switch]$DiscardExisting,
        [string]$HomePath = $HOME,
        [string]$LocalAppData = $env:LOCALAPPDATA,
        [switch]$SkipEnvironmentChanges
    )

    Assert-DestinationVolume -DestinationRoot $DestinationRoot
    $destination = Get-NormalizedPath -Path $DestinationRoot
    $catalog = @(Get-CacheCatalog -DestinationRoot $destination -HomePath $HomePath -LocalAppData $LocalAppData -IncludeMissing)
    $selected = @($catalog | Where-Object {
        ($_.Kind -eq 'Browser' -and $Browser -contains ($_.Name -split ':')[0]) -or
        ($_.Kind -eq 'Developer' -and $IncludeDeveloper)
    })

    $processes = @($selected.ProcessName | Where-Object { $_ } | Sort-Object -Unique)
    foreach ($processName in $processes) {
        $running = @(Get-Process -Name $processName -ErrorAction SilentlyContinue)
        if ($running.Count -gt 0) {
            throw "Close '$processName' before migration. Running PIDs: $($running.Id -join ', ')."
        }
    }

    $manifestMappings = New-Object System.Collections.Generic.List[object]
    $environmentChanged = $false
    foreach ($record in $selected) {
        $source = Get-NormalizedPath -Path $record.Source
        $target = Get-NormalizedPath -Path $record.Target
        if (-not (Test-PathWithinRoot -Candidate $target -Root $destination)) {
            throw "Refusing target outside destination root: $target"
        }
        if ($source -ieq $target) {
            throw "Source and target are identical: $source"
        }

        $existing = Get-Item -LiteralPath $source -Force -ErrorAction SilentlyContinue
        if ($null -ne $existing -and (($existing.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) {
            $existingTarget = Get-LinkTarget -Item $existing
            $managedRoot = if ($record.Kind -eq 'Browser') { Join-Path $destination 'BrowserCache' } else { Join-Path $destination 'DevCache' }
            if (Test-PathWithinRoot -Candidate $existingTarget -Root $managedRoot) {
                continue
            }
            throw "Source is already a different reparse point: $source -> $existingTarget"
        }

        $previousEnvironment = $null
        if ($record.EnvironmentVariable -and -not $SkipEnvironmentChanges) {
            $previousEnvironment = [Environment]::GetEnvironmentVariable($record.EnvironmentVariable, 'User')
        }
        if (-not $PSCmdlet.ShouldProcess($source, "Migrate cache to $target")) {
            continue
        }

        $sourceStats = Get-TreeStats -LiteralPath $source
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        if (-not $DiscardExisting -and $sourceStats.Files -gt 0) {
            Copy-CacheTree -Source $source -Target $target
        }
        if (Test-Path -LiteralPath $source) {
            Remove-Item -LiteralPath $source -Recurse -Force
        }
        New-Item -ItemType Directory -Path (Split-Path -Parent $source) -Force | Out-Null
        $junction = New-Item -ItemType Junction -Path $source -Target $target
        if ($junction.LinkType -ne 'Junction') {
            throw "Failed to create junction: $source"
        }
        if ($record.EnvironmentVariable -and -not $SkipEnvironmentChanges) {
            [Environment]::SetEnvironmentVariable($record.EnvironmentVariable, $target, 'User')
            $environmentChanged = $true
        }

        $manifestMappings.Add([pscustomobject]@{
            Name = $record.Name
            Kind = $record.Kind
            Source = $source
            Target = $target
            ProcessName = $record.ProcessName
            EnvironmentVariable = if ($SkipEnvironmentChanges) { '' } else { $record.EnvironmentVariable }
            PreviousEnvironmentValue = $previousEnvironment
            OriginalBytes = $sourceStats.Bytes
            OriginalFiles = $sourceStats.Files
            ExistingDataDiscarded = [bool]$DiscardExisting
        })
    }

    if ($manifestMappings.Count -eq 0) {
        return [pscustomobject]@{ Changed = $false; ManifestPath = $null; Mappings = @() }
    }
    if ($environmentChanged) {
        Send-EnvironmentChange
    }
    $manifestDirectory = Join-Path $destination '.cache-mover'
    New-Item -ItemType Directory -Path $manifestDirectory -Force | Out-Null
    $manifestPath = Join-Path $manifestDirectory ("manifest-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $manifest = [ordered]@{
        SchemaVersion = 1
        CreatedAt = (Get-Date).ToString('o')
        ComputerName = $env:COMPUTERNAME
        UserName = [Environment]::UserName
        DestinationRoot = $destination
        Mappings = $manifestMappings.ToArray()
    }
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    return [pscustomobject]@{ Changed = $true; ManifestPath = $manifestPath; Mappings = $manifestMappings.ToArray() }
}

function Test-CacheMigration {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ManifestPath)

    $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
    foreach ($mapping in $manifest.Mappings) {
        $item = Get-Item -LiteralPath $mapping.Source -Force -ErrorAction SilentlyContinue
        $linkTarget = if ($null -ne $item) { Get-LinkTarget -Item $item } else { $null }
        $linkOk = $null -ne $item -and (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) -and $linkTarget -ieq $mapping.Target
        $environmentOk = $true
        if ($mapping.EnvironmentVariable) {
            $environmentOk = [Environment]::GetEnvironmentVariable($mapping.EnvironmentVariable, 'User') -ieq $mapping.Target
        }
        [pscustomobject]@{
            Name = $mapping.Name
            LinkOK = $linkOk
            EnvironmentOK = $environmentOk
            Source = $mapping.Source
            Target = $mapping.Target
        }
    }
}

function Restore-CacheMigration {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][string]$ManifestPath,
        [switch]$CopyBack
    )

    $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
    $processes = @($manifest.Mappings.ProcessName | Where-Object { $_ } | Sort-Object -Unique)
    foreach ($processName in $processes) {
        $running = @(Get-Process -Name $processName -ErrorAction SilentlyContinue)
        if ($running.Count -gt 0) {
            throw "Close '$processName' before restore. Running PIDs: $($running.Id -join ', ')."
        }
    }

    $environmentChanged = $false
    foreach ($mapping in @($manifest.Mappings) | Sort-Object { $_.Source.Length } -Descending) {
        $item = Get-Item -LiteralPath $mapping.Source -Force -ErrorAction SilentlyContinue
        if ($null -eq $item -or (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0)) {
            throw "Expected junction is missing: $($mapping.Source)"
        }
        $linkTarget = Get-LinkTarget -Item $item
        if ($linkTarget -ine $mapping.Target) {
            throw "Refusing unexpected junction: $($mapping.Source) -> $linkTarget"
        }
        if (-not $PSCmdlet.ShouldProcess($mapping.Source, 'Restore cache path to the system drive')) {
            continue
        }
        Remove-DirectoryJunction -LiteralPath $mapping.Source
        New-Item -ItemType Directory -Path $mapping.Source -Force | Out-Null
        if ($CopyBack -and (Test-Path -LiteralPath $mapping.Target)) {
            Copy-CacheTree -Source $mapping.Target -Target $mapping.Source
        }
        if ($mapping.EnvironmentVariable) {
            [Environment]::SetEnvironmentVariable($mapping.EnvironmentVariable, $mapping.PreviousEnvironmentValue, 'User')
            $environmentChanged = $true
        }
        [pscustomobject]@{ Name = $mapping.Name; Restored = $true; Source = $mapping.Source; CopiedBack = [bool]$CopyBack }
    }
    if ($environmentChanged) {
        Send-EnvironmentChange
    }
}

function Find-LargeFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [double]$MinimumGB = 1,
        [int]$Top = 50
    )

    $minimumBytes = [int64]($MinimumGB * 1GB)
    $matches = New-Object System.Collections.Generic.List[object]
    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push((Get-NormalizedPath -Path $Path))
    while ($pending.Count -gt 0) {
        $current = $pending.Pop()
        try {
            foreach ($entry in [System.IO.Directory]::EnumerateFileSystemEntries($current)) {
                try {
                    $attributes = [System.IO.File]::GetAttributes($entry)
                    if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                        continue
                    }
                    if (($attributes -band [System.IO.FileAttributes]::Directory) -ne 0) {
                        $pending.Push($entry)
                    } else {
                        $file = New-Object System.IO.FileInfo($entry)
                        if ($file.Length -ge $minimumBytes) {
                            $matches.Add([pscustomobject]@{
                                GB = [math]::Round($file.Length / 1GB, 3)
                                LastWriteTime = $file.LastWriteTime
                                Path = $file.FullName
                            })
                        }
                    }
                } catch { }
            }
        } catch { }
    }
    return @($matches | Sort-Object GB -Descending | Select-Object -First $Top)
}

Export-ModuleMember -Function Get-CacheCatalog,Get-CacheAudit,Invoke-CacheMigration,Test-CacheMigration,Restore-CacheMigration,Find-LargeFile
