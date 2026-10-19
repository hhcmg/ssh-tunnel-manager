# SSH session-log retention only. Call while holding the alias worker mutex.
# Fixed worker/launcher logs and state files are outside this filename allowlist.

function Test-TunnelLogDirectoryPath([string]$Directory) {
    try {
        $root = [IO.Path]::GetFullPath($script:DataRoot).TrimEnd([char[]]'\/')
        $path = [IO.Path]::GetFullPath($Directory).TrimEnd([char[]]'\/')
        if (-not $path.Equals($root, [StringComparison]::OrdinalIgnoreCase) -and
            -not $path.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { return $false }
        while ($true) {
            $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
            if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $false }
            if ($path.Equals($root, [StringComparison]::OrdinalIgnoreCase)) { return $true }
            $path = [IO.Path]::GetDirectoryName($path)
        }
    }
    catch { return $false }
}

function Invoke-TunnelLogRetention([string]$Directory, [string]$Alias, [string]$ActiveLogPath, [int]$KeepClosedLogs = 2) {
    $result = [pscustomobject]@{ Deleted = 0; Skipped = 0; Retained = 0; Rejected = $false; Reason = '' }
    try {
        if (-not (Test-TunnelAlias $Alias) -or $KeepClosedLogs -lt 0) {
            throw 'Invalid alias or retention count.'
        }
        if ([string]::IsNullOrWhiteSpace($Directory) -or [string]::IsNullOrWhiteSpace($ActiveLogPath)) {
            throw 'The log directory and active log path are required.'
        }
        $directoryPath = [IO.Path]::GetFullPath($Directory).TrimEnd([char[]]'\/')
        $activePath = [IO.Path]::GetFullPath($ActiveLogPath)
        if (-not (Test-TunnelLogDirectoryPath $directoryPath)) { throw 'The log directory is outside the workspace, inaccessible, or a reparse path.' }
        if (-not [IO.Path]::GetDirectoryName($activePath).Equals($directoryPath, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'The active log must be a direct child of the log directory.'
        }
        $pattern = '^' + [regex]::Escape($Alias) + '\.(?<stamp>[0-9]{8}-[0-9]{6}-[0-9]{3})\.log$'
        $activeMatch = [regex]::Match([IO.Path]::GetFileName($activePath), $pattern)
        $activeDate = [datetime]::MinValue
        if (-not $activeMatch.Success -or -not [datetime]::TryParseExact($activeMatch.Groups['stamp'].Value,
            'yyyyMMdd-HHmmss-fff', [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::None, [ref]$activeDate)) { throw 'The active log name does not identify this alias session.' }
        if (Test-Path -LiteralPath $activePath) {
            $active = Get-Item -LiteralPath $activePath -Force -ErrorAction Stop
            if ($active.PSIsContainer -or ($active.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'The active log is not a regular file.' }
        }

        $closed = New-Object 'Collections.Generic.List[object]'
        foreach ($entry in @(Get-ChildItem -LiteralPath $directoryPath -Force -ErrorAction Stop)) {
            $match = [regex]::Match($entry.Name, $pattern)
            $stamp = [datetime]::MinValue
            if (-not $match.Success -or -not [datetime]::TryParseExact($match.Groups['stamp'].Value,
                'yyyyMMdd-HHmmss-fff', [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::None, [ref]$stamp)) { continue }
            if ($entry.FullName.Equals($activePath, [StringComparison]::OrdinalIgnoreCase)) { continue }
            if ($entry.PSIsContainer -or ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $result.Skipped++; continue }
            $stream = $null
            try {
                # Locked or still-open session logs are not ended logs and do
                # not use up either of the retained closed-log positions.
                $stream = [IO.File]::Open($entry.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
                [void]$closed.Add([pscustomobject]@{
                    Path = $entry.FullName; Name = $entry.Name; Length = $stream.Length
                    Changed = [IO.File]::GetLastWriteTimeUtc($entry.FullName).Ticks
                    Created = [IO.File]::GetCreationTimeUtc($entry.FullName).Ticks
                })
            }
            catch { $result.Skipped++ }
            finally { if ($null -ne $stream) { $stream.Dispose() } }
        }

        foreach ($candidate in @($closed | Sort-Object Name -Descending)) {
            if ($candidate.Length -gt 0 -and $result.Retained -lt $KeepClosedLogs) { $result.Retained++; continue }
            $deleteHandle = $null
            try {
                # Revalidate immediately before removal. Same-alias session
                # creation and active-path changes must share the worker mutex.
                if (-not (Test-TunnelLogDirectoryPath $directoryPath)) { $result.Skipped++; continue }
                if ($candidate.Path.Equals($activePath, [StringComparison]::OrdinalIgnoreCase)) { continue }
                $current = Get-Item -LiteralPath $candidate.Path -Force -ErrorAction Stop
                if ($current.PSIsContainer -or ($current.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
                    $current.Length -ne $candidate.Length -or $current.LastWriteTimeUtc.Ticks -ne $candidate.Changed -or
                    $current.CreationTimeUtc.Ticks -ne $candidate.Created) { $result.Skipped++; continue }
                # Opening and deleting use one exclusive handle. A competing
                # writer/reader or denied delete access makes the open fail;
                # there is no unlocked Remove-Item after a lock check.
                $deleteHandle = New-Object IO.FileStream($candidate.Path, [IO.FileMode]::Open,
                    [IO.FileAccess]::Read, [IO.FileShare]::None, 4096, [IO.FileOptions]::DeleteOnClose)
                $deleteHandle.Dispose()
                $deleteHandle = $null
                $result.Deleted++
            }
            catch { $result.Skipped++ }
            finally { if ($null -ne $deleteHandle) { try { $deleteHandle.Dispose() } catch { } } }
        }
    }
    catch { $result.Rejected = $true; $result.Reason = $_.Exception.Message }
    return $result
}
