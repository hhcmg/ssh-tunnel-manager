[CmdletBinding()]
param()

# Real filesystem tests in a freshly created temporary workspace. The production
# log directory is never passed to the retention function.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot 'Tunnel-Logs.ps1'
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('tunnel-log-tests-' + [guid]::NewGuid().ToString('N'))
$workspace = Join-Path $scratch 'workspace'
$outside = Join-Path $scratch 'outside'
[void][IO.Directory]::CreateDirectory($workspace)
[void][IO.Directory]::CreateDirectory($outside)
$moduleCopy = Join-Path $workspace 'Tunnel-Logs.ps1'
[IO.File]::Copy($source, $moduleCopy)
. (Join-Path $PSScriptRoot 'Tunnel-Config.ps1')
. $moduleCopy
$script:DataRoot = $workspace
$script:Passed = 0
$script:Failed = 0
$script:CaseNumber = 0

function Assert-True($Value, [string]$Message) {
    if (-not $Value) { throw $Message }
}
function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ($Expected -ne $Actual) { throw "$Message Expected <$Expected>; actual <$Actual>." }
}
function Invoke-Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; $script:Passed++; Write-Host "PASS $Name" -ForegroundColor Green }
    catch { $script:Failed++; Write-Host "FAIL $Name : $($_.Exception.Message)" -ForegroundColor Red }
}
function New-CaseDirectory {
    $script:CaseNumber++
    $path = Join-Path $workspace ("logs-" + $script:CaseNumber)
    [void][IO.Directory]::CreateDirectory($path)
    return $path
}
function New-Log([string]$Directory, [int]$Second, [string]$Content = 'data', [string]$Alias = 'server-a') {
    $path = Join-Path $Directory ('{0}.20260915-1200{1:00}-001.log' -f $Alias, $Second)
    [IO.File]::WriteAllText($path, $Content, (New-Object Text.UTF8Encoding($false)))
    return $path
}
function Remove-TestFixture([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    $allowed = [IO.Path]::GetFullPath($scratch)
    if (-not $full.Equals($allowed, [StringComparison]::OrdinalIgnoreCase) -and
        -not $full.StartsWith($allowed + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Refusing to delete outside this test run.'
    }
    $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        # Unlink only the fixture junction; never follow it during cleanup.
        if ($item.PSIsContainer) { [IO.Directory]::Delete($full, $false) } else { [IO.File]::Delete($full) }
    }
    elseif ($item.PSIsContainer) {
        foreach ($child in [IO.Directory]::GetFileSystemEntries($full)) { Remove-TestFixture $child }
        [IO.Directory]::Delete($full, $false)
    }
    else {
        [IO.File]::SetAttributes($full, [IO.FileAttributes]::Normal)
        [IO.File]::Delete($full)
    }
}

try {
    Invoke-Case 'retain active log and two latest nonempty closed logs by filename' {
        $directory = New-CaseDirectory
        $oldest = New-Log $directory 1
        $older = New-Log $directory 2
        $recent = New-Log $directory 3
        $newest = New-Log $directory 4
        $empty = New-Log $directory 5 ''
        $active = New-Log $directory 6 ''
        [IO.File]::SetLastWriteTimeUtc($oldest, [datetime]::UtcNow.AddDays(1))
        $result = Invoke-TunnelLogRetention -Directory $directory -Alias 'server-a' -ActiveLogPath $active
        Assert-Equal $false $result.Rejected 'Accept the isolated workspace log directory.'
        Assert-Equal 3 $result.Deleted 'Delete two old nonempty logs and the ended empty log.'
        Assert-Equal 2 $result.Retained 'Retain exactly two nonempty closed logs.'
        foreach ($path in @($recent, $newest, $active)) { Assert-True ([IO.File]::Exists($path)) 'Preserve a retained or active log.' }
        foreach ($path in @($oldest, $older, $empty)) { Assert-Equal $false ([IO.File]::Exists($path)) 'Delete only eligible ended logs.' }
    }

    Invoke-Case 'leave state, fixed logs, other aliases and malformed names untouched' {
        $directory = New-CaseDirectory
        $active = New-Log $directory 6
        $protected = @('tunnels.log', 'server-a.worker.log', 'server-a.worker.json',
            'server-a.20261399-120000-001.log', 'server-a.20260915-120000-01.log',
            'serverXa.20260915-120000-001.log', 'server-a.20260915-120000-001.log.1',
            'server-b.20260915-120000-001.log', 'other-tool.log')
        foreach ($name in $protected) { [IO.File]::WriteAllText((Join-Path $directory $name), '') }
        $result = Invoke-TunnelLogRetention $directory 'server-a' $active
        Assert-Equal 0 $result.Deleted 'Do not touch names outside the exact session-log allowlist.'
        foreach ($name in $protected) { Assert-True ([IO.File]::Exists((Join-Path $directory $name))) "Preserve $name." }
    }

    Invoke-Case 'reject outside-workspace directories and invalid active-log protection' {
        $directory = New-CaseDirectory
        $active = New-Log $directory 6
        $empty = New-Log $directory 1 ''
        $outsideLog = New-Log $outside 1 ''
        $cousin = Join-Path $scratch 'workspace-other'
        [void][IO.Directory]::CreateDirectory($cousin)
        $cousinLog = New-Log $cousin 1 ''
        foreach ($arguments in @(
            @{ Directory = $outside; ActiveLogPath = $outsideLog; Alias = 'server-a' },
            @{ Directory = $cousin; ActiveLogPath = $cousinLog; Alias = 'server-a' },
            @{ Directory = $directory; ActiveLogPath = $outsideLog; Alias = 'server-a' },
            @{ Directory = $directory; ActiveLogPath = ''; Alias = 'server-a' },
            @{ Directory = $directory; ActiveLogPath = $active; Alias = 'server-b' },
            @{ Directory = $directory; ActiveLogPath = $active; Alias = '../other-host' }
        )) {
            $result = Invoke-TunnelLogRetention @arguments
            Assert-True $result.Rejected 'Fail closed when the workspace or active-log identity is invalid.'
            Assert-Equal 0 $result.Deleted 'Rejected cleanup must not delete files.'
        }
        foreach ($path in @($empty, $active, $outsideLog, $cousinLog)) { Assert-True ([IO.File]::Exists($path)) 'Preserve files after rejected cleanup.' }
    }

    Invoke-Case 'do not treat matching directories or an active directory as log files' {
        $directory = New-CaseDirectory
        $active = New-Log $directory 6
        $matchingDirectory = Join-Path $directory 'server-a.20260915-120001-001.log'
        [void][IO.Directory]::CreateDirectory($matchingDirectory)
        $result = Invoke-TunnelLogRetention $directory 'server-a' $active
        Assert-Equal 0 $result.Deleted 'Never remove a directory with a log-like name.'
        Assert-True ([IO.Directory]::Exists($matchingDirectory)) 'Preserve the matching directory.'
        $result = Invoke-TunnelLogRetention $directory 'server-a' $matchingDirectory
        Assert-True $result.Rejected 'Reject an active path that is a directory.'
    }

    Invoke-Case 'locked logs do not consume retention slots and are retried after release' {
        $directory = New-CaseDirectory
        $oldest = New-Log $directory 1
        $older = New-Log $directory 2
        $recent = New-Log $directory 3
        $newest = New-Log $directory 4
        $locked = New-Log $directory 5
        $active = New-Log $directory 6 ''
        $handle = [IO.File]::Open($locked, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try {
            $result = Invoke-TunnelLogRetention $directory 'server-a' $active
            Assert-Equal 2 $result.Deleted 'Delete the two oldest ended logs.'
            Assert-Equal 1 $result.Skipped 'Skip the locked candidate without throwing.'
            foreach ($path in @($recent, $newest, $locked, $active)) { Assert-True ([IO.File]::Exists($path)) 'Preserve recent ended logs and protected open logs.' }
        }
        finally { $handle.Dispose() }
        $result = Invoke-TunnelLogRetention $directory 'server-a' $active
        Assert-Equal 1 $result.Deleted 'Reconsider the formerly locked log on the next pass.'
        Assert-Equal $false ([IO.File]::Exists($recent)) 'Retain the two newest now-ended logs.'
        Assert-True ([IO.File]::Exists($locked)) 'The newest ended log is now retained.'
    }

    Invoke-Case 'read-only delete failures are skipped and never escape into SSH management' {
        $directory = New-CaseDirectory
        $denied = New-Log $directory 1
        [void](New-Log $directory 2)
        [void](New-Log $directory 3)
        $active = New-Log $directory 6
        [IO.File]::SetAttributes($denied, [IO.FileAttributes]::ReadOnly)
        $result = Invoke-TunnelLogRetention $directory 'server-a' $active
        Assert-Equal $false $result.Rejected 'An individual delete failure must not reject the worker operation.'
        Assert-Equal 1 $result.Skipped 'Report the denied candidate as skipped.'
        Assert-True ([IO.File]::Exists($denied)) 'Do not force deletion of a protected file.'
    }

    Invoke-Case 'reject junction paths and never recurse into log-like junctions' {
        $directory = New-CaseDirectory
        $outsideLog = New-Log $outside 2 ''
        $junction = Join-Path $workspace 'junction'
        [void](New-Item -ItemType Junction -Path $junction -Target $outside)
        $result = Invoke-TunnelLogRetention $junction 'server-a' (Join-Path $junction ([IO.Path]::GetFileName($outsideLog)))
        Assert-True $result.Rejected 'Reject a junction log directory even when its lexical path is within the workspace.'
        $active = New-Log $directory 6
        $candidate = Join-Path $directory 'server-a.20260915-120001-001.log'
        [void](New-Item -ItemType Junction -Path $candidate -Target $outside)
        $result = Invoke-TunnelLogRetention $directory 'server-a' $active
        Assert-Equal 1 $result.Skipped 'Skip a matching reparse entry.'
        Assert-True ([IO.File]::Exists($outsideLog)) 'Preserve the outside target.'
        Assert-True ([IO.Directory]::Exists($candidate)) 'Do not remove the reparse entry.'
    }

    Invoke-Case 'skip a candidate that changes after the closed-log snapshot' {
        $directory = New-CaseDirectory
        $script:ChangingLog = New-Log $directory 1
        [void](New-Log $directory 2)
        [void](New-Log $directory 3)
        $active = New-Log $directory 6
        $script:ChangedOnce = $false
        function Get-Item {
            param($LiteralPath, [switch]$Force, $ErrorAction)
            if ($LiteralPath -eq $script:ChangingLog -and -not $script:ChangedOnce) {
                [IO.File]::AppendAllText($LiteralPath, 'new content')
                $script:ChangedOnce = $true
            }
            Microsoft.PowerShell.Management\Get-Item -LiteralPath $LiteralPath -Force:$Force -ErrorAction Stop
        }
        $result = Invoke-TunnelLogRetention $directory 'server-a' $active
        Assert-True $script:ChangedOnce 'Exercise a concurrent update before deletion.'
        Assert-Equal 1 $result.Skipped 'Skip changed content instead of deleting a stale snapshot.'
        Assert-True ([IO.File]::Exists($script:ChangingLog)) 'Preserve the changed log.'
    }
}
finally { Remove-TestFixture $scratch }

Write-Host ("Log retention tests on PowerShell {0}: {1} passed, {2} failed." -f $PSVersionTable.PSVersion, $script:Passed, $script:Failed)
if ($script:Failed -gt 0) { exit 1 }
exit 0
