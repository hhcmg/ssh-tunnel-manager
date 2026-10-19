[CmdletBinding()]
param()

# Offline file-sharing regressions. No SSH, production state, or real process
# operations; every written file belongs to this run's unique temporary folder.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$runtimePath = Join-Path $PSScriptRoot 'Tunnel-Runtime.ps1'
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('tunnel-state-io-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixtureRoot)
. (Join-Path $PSScriptRoot 'Tunnel-Config.ps1')
. $runtimePath
$script:DataRoot = $fixtureRoot
$script:Targets = @('server-a', 'server-b')
$script:ContextId = '111111111111111111111111'
$script:Passed = 0
$script:Failed = 0
$statusPath = Join-Path $fixtureRoot 'server-a.worker.json'

function Assert-True($Value, [string]$Message) { if (-not $Value) { throw $Message } }
function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ($Expected -cne $Actual) { throw "$Message Expected <$Expected>; actual <$Actual>." }
}
function New-StateFixture([int]$Sequence) {
    return [pscustomobject]@{
        Version = 2; Alias = 'server-a'; ContextId = $script:ContextId; Sequence = $Sequence
        State = 'ready'; UpdatedUtc = [DateTime]::UtcNow.ToString('o')
        Payload = ('P' * 4096)
    }
}
function Reset-Fixture {
    $script:DataRoot = $fixtureRoot
    foreach ($path in [IO.Directory]::GetFiles($fixtureRoot)) {
        [IO.File]::SetAttributes($path, [IO.FileAttributes]::Normal)
        [IO.File]::Delete($path)
    }
}
function Assert-NoTemporaryFiles {
    Assert-Equal 0 @([IO.Directory]::GetFiles($fixtureRoot, '*.new')).Count 'Clean temporary state files after success or failure.'
}
function Invoke-TestCase([string]$Name, [scriptblock]$Body) {
    try { Reset-Fixture; & $Body; $script:Passed++; Write-Host "PASS $Name" -ForegroundColor Green }
    catch { $script:Failed++; Write-Host "FAIL $Name : $($_.Exception.Message)" -ForegroundColor Red }
}

try {
    Invoke-TestCase 'first publication and replacement each return a single true boolean' {
        foreach ($sequence in @(1, 2)) {
            $result = @(Write-WorkerStatus 'server-a' (New-StateFixture $sequence))
            Assert-Equal 1 $result.Count 'Do not emit extra success-stream output.'
            Assert-True ($result[0] -is [bool] -and $result[0]) 'A committed snapshot must return true.'
            Assert-Equal $sequence (Get-WorkerStatus 'server-a').Sequence 'Read the complete committed state.'
        }
        Assert-NoTemporaryFiles
    }
    Invoke-TestCase 'a reader denying delete causes a fast false result and preserves old JSON' {
        Assert-True (Write-WorkerStatus 'server-a' (New-StateFixture 1)) 'Create the initial state.'
        $handle = [IO.File]::Open($statusPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            $timer = [Diagnostics.Stopwatch]::StartNew()
            $result = @(Write-WorkerStatus 'server-a' (New-StateFixture 2))
            $timer.Stop()
            Assert-Equal 1 $result.Count 'A sharing violation must return one boolean.'
            Assert-True ($result[0] -is [bool] -and -not $result[0]) 'A sharing violation must return false rather than escape to the worker.'
            Assert-True ($timer.Elapsed.TotalSeconds -lt 2) 'Do not retry a file lock long enough to stall heartbeats.'
            Assert-Equal 1 (Get-WorkerStatus 'server-a').Sequence 'The old JSON must remain readable and unchanged.'
            Assert-NoTemporaryFiles
        }
        finally { $handle.Dispose() }
        Assert-True (Write-WorkerStatus 'server-a' (New-StateFixture 2)) 'The next publication must succeed once the lock closes.'
        Assert-Equal 2 (Get-WorkerStatus 'server-a').Sequence 'Publish the new snapshot after lock release.'
        Assert-NoTemporaryFiles
    }
    Invoke-TestCase 'a delete-sharing reader retains old JSON while the pathname is replaced' {
        Assert-True (Write-WorkerStatus 'server-a' (New-StateFixture 1)) 'Create the initial state.'
        $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
        $handle = [IO.File]::Open($statusPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
        $reader = $null
        try {
            Assert-True (Write-WorkerStatus 'server-a' (New-StateFixture 2)) 'A cooperating reader must not block replacement.'
            $reader = New-Object IO.StreamReader($handle)
            $old = ConvertFrom-Json -InputObject $reader.ReadToEnd() -ErrorAction Stop
            Assert-Equal 1 $old.Sequence 'An existing reader must retain the complete old snapshot.'
            Assert-Equal 2 (Get-WorkerStatus 'server-a').Sequence 'A new reader must see the complete new snapshot.'
        }
        finally { if ($reader) { $reader.Dispose() } else { $handle.Dispose() } }
        Assert-NoTemporaryFiles
    }
    Invoke-TestCase 'exclusive and read-only locks cannot throw into tunnel management' {
        Assert-True (Write-WorkerStatus 'server-a' (New-StateFixture 1)) 'Create the initial state.'
        $handle = [IO.File]::Open($statusPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try {
            Assert-True ($null -eq (Get-WorkerStatus 'server-a')) 'An unreadable snapshot must return null.'
            Assert-Equal $false (Write-WorkerStatus 'server-a' (New-StateFixture 2)) 'An exclusive file lock must return false.'
            Assert-NoTemporaryFiles
        }
        finally { $handle.Dispose() }
        [IO.File]::SetAttributes($statusPath, [IO.FileAttributes]::ReadOnly)
        try {
            Assert-Equal $false (Write-WorkerStatus 'server-a' (New-StateFixture 2)) 'An access failure must return false.'
            Assert-Equal 1 (Get-WorkerStatus 'server-a').Sequence 'Failed writes must preserve the previous state.'
            Assert-NoTemporaryFiles
        }
        finally { [IO.File]::SetAttributes($statusPath, [IO.FileAttributes]::Normal) }
    }
    Invoke-TestCase 'missing directory and invalid JSON fail without throwing' {
        $script:DataRoot = Join-Path $fixtureRoot 'missing-directory'
        try {
            Assert-Equal $false (Write-WorkerStatus 'server-a' (New-StateFixture 1)) 'An unavailable destination must return false.'
            Assert-True ($null -eq (Get-WorkerStatus 'server-a')) 'A missing snapshot must return null.'
        }
        finally { $script:DataRoot = $fixtureRoot }
        [IO.File]::WriteAllText($statusPath, '{not valid JSON', [Text.Encoding]::UTF8)
        Assert-True ($null -eq (Get-WorkerStatus 'server-a')) 'Invalid JSON must return null.'
        Assert-NoTemporaryFiles
    }
    Invoke-TestCase 'unsafe aliases still throw before reading or writing files' {
        foreach ($operation in @('read', 'write')) {
            $rejected = $false
            try {
                if ($operation -eq 'read') { [void](Get-WorkerStatus '../unrelated-host') }
                else { [void](Write-WorkerStatus '../unrelated-host' (New-StateFixture 1)) }
            }
            catch { $rejected = $true }
            Assert-True $rejected "Reject an unsafe alias during $operation."
        }
        Assert-Equal 0 @([IO.Directory]::GetFiles($fixtureRoot)).Count 'Unsafe aliases must not create files.'
    }
    Invoke-TestCase 'concurrent production readers do not block atomic snapshots or parse partial JSON' {
        Assert-True (Write-WorkerStatus 'server-a' (New-StateFixture 0)) 'Create the initial state before concurrent reading.'
        $gate = New-Object Threading.ManualResetEventSlim($false)
        $ready = New-Object Threading.CountdownEvent(2)
        $readers = @()
        $readerCode = @'
param($RuntimePath, $ConfigModule, $FixtureRoot, $Gate, $Ready)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. $ConfigModule
. $RuntimePath
$script:DataRoot = $FixtureRoot
$script:Targets = @('server-a', 'server-b')
$script:ContextId = '111111111111111111111111'
[void]$Ready.Signal()
if (-not $Gate.Wait(5000)) { throw 'The fixture start gate timed out.' }
$lastSequence = -1
$completeReads = 0
$transientMisses = 0
for ($iteration = 0; $iteration -lt 200; $iteration++) {
    $status = Get-WorkerStatus 'server-a'
    # A pathname can transiently reject a new open while ReplaceFile commits.
    # The read contract permits null without blocking; any returned JSON must
    # still be a whole snapshot, never a partially published document.
    if ($null -eq $status) { $transientMisses++ }
    else {
        if ($status.Payload -cne ('P' * 4096)) { throw 'A concurrent read returned a partial payload.' }
        if ($status.Sequence -lt $lastSequence) { throw "A concurrent read moved backward: $lastSequence to $($status.Sequence)." }
        $lastSequence = $status.Sequence
        $completeReads++
    }
    [Threading.Thread]::Sleep(1)
}
return [pscustomobject]@{ CompleteReads = $completeReads; TransientMisses = $transientMisses }
'@
        try {
            for ($index = 0; $index -lt 2; $index++) {
                $shell = [PowerShell]::Create()
                [void]$shell.AddScript($readerCode).AddArgument($runtimePath).AddArgument((Join-Path $PSScriptRoot 'Tunnel-Config.ps1')).AddArgument($fixtureRoot).AddArgument($gate).AddArgument($ready)
                $readers += [pscustomobject]@{ Shell = $shell; Task = $shell.BeginInvoke() }
            }
            Assert-True ($ready.Wait(5000)) 'Both isolated reader runspaces must become ready.'
            $gate.Set()
            for ($sequence = 1; $sequence -le 100; $sequence++) {
                Assert-True (Write-WorkerStatus 'server-a' (New-StateFixture $sequence)) 'Shared-delete readers must not prevent publication.'
            }
            foreach ($reader in $readers) {
                $results = @($reader.Shell.EndInvoke($reader.Task))
                Assert-Equal 0 $reader.Shell.Streams.Error.Count 'Readers must not emit parsing or sharing errors.'
                Assert-Equal 1 $results.Count 'Each reader must return one completion result.'
                Assert-Equal 200 ($results[0].CompleteReads + $results[0].TransientMisses) 'Each reader must finish all 200 bounded reads.'
                Assert-True ($results[0].CompleteReads -gt 0) 'Concurrent readers must observe complete snapshots.'
                Write-Host ("  Concurrent reader: {0} complete snapshots, {1} transient null reads." -f $results[0].CompleteReads, $results[0].TransientMisses)
            }
            Assert-Equal 100 (Get-WorkerStatus 'server-a').Sequence 'The final snapshot must contain the last publication.'
            Assert-NoTemporaryFiles
        }
        finally {
            $gate.Set()
            foreach ($reader in $readers) {
                try { $reader.Shell.Stop() } catch { }
                $reader.Shell.Dispose()
            }
            $gate.Dispose()
            $ready.Dispose()
        }
    }
}
finally {
    # Only direct files in this run's resolved directory are removed, without
    # recursive traversal or touching production logs/state.
    foreach ($path in [IO.Directory]::GetFiles($fixtureRoot)) {
        if ([IO.Path]::GetDirectoryName($path) -ne $fixtureRoot) { throw 'Unexpected fixture path.' }
        [IO.File]::SetAttributes($path, [IO.FileAttributes]::Normal)
        [IO.File]::Delete($path)
    }
    [IO.Directory]::Delete($fixtureRoot, $false)
}
Write-Host ("State I/O regression tests ({0}): {1} passed, {2} failed." -f $PSVersionTable.PSVersion, $script:Passed, $script:Failed)
if ($script:Failed -gt 0) { exit 1 }
exit 0
