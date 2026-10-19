[CmdletBinding()]
param()

# Offline worker/guard regression suite for Windows PowerShell 5.1.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$launcher = Join-Path $PSScriptRoot 'Start-Tunnels.ps1'
$script:Passed = 0
$script:Failed = 0
$script:FakeProcesses = New-Object Collections.ArrayList
$script:FixtureDirectory = Join-Path ([IO.Path]::GetTempPath()) ('ssh-worker-tests-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($script:FixtureDirectory)

# LibraryOnly must return without starting processes or writing production data.
function Start-Process { throw 'Process launch is forbidden during library load.' }
function Stop-Process { throw 'Real process termination is forbidden in offline tests.' }
function New-Object { throw 'Unexpected object construction during library load.' }
function Add-Content { throw 'Unexpected file write during library load.' }
function Set-Content { throw 'Unexpected file write during library load.' }
function Move-Item { throw 'Unexpected file move during library load.' }
. $launcher -LibraryOnly
$script:WriteStatusImplementation = (Get-Item Function:\Write-Status).ScriptBlock
Remove-Item Function:\New-Object

function Assert-True($Value, [string]$Message) {
    if (-not $Value) { throw $Message }
}
function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ($Expected -ne $Actual) { throw "$Message Expected <$Expected>; actual <$Actual>." }
}
function Invoke-TestCase([string]$Name, [scriptblock]$Body) {
    try { & $Body; $script:Passed++; Write-Host "PASS $Name" -ForegroundColor Green }
    catch { $script:Failed++; Write-Host "FAIL $Name : $($_.Exception.Message)" -ForegroundColor Red }
}
function New-FakeProcess([int]$ProcessId = 910001) {
    $process = New-Object Diagnostics.Process
    $process | Add-Member NoteProperty Id $ProcessId -Force
    $process | Add-Member NoteProperty StartTime ([datetime]'2026-09-14T09:00:00') -Force
    $process | Add-Member NoteProperty MainModule ([pscustomobject]@{ FileName = $script:PowerShellExe }) -Force
    $process | Add-Member NoteProperty ProcessName 'powershell' -Force
    $process | Add-Member NoteProperty TestExited $false
    $process | Add-Member ScriptProperty HasExited { $this.TestExited } -Force
    $process | Add-Member ScriptMethod Refresh { } -Force
    [void]$script:FakeProcesses.Add($process)
    return $process
}
function Reset-Harness {
    $script:Root = $script:FixtureDirectory
    $script:DataRoot = $script:FixtureDirectory
    $script:ContextId = "0123456789abcdef01234567"
    $script:RequireProxySuccess = $false
    $script:EventLog = Join-Path $script:FixtureDirectory 'events.log'
    $script:CheckOnly = $false
    $script:Harness = @{
        Started = 0; RemoteChecks = 0
        Messages = New-Object Collections.ArrayList
        Process = New-FakeProcess
        SshProcess = New-FakeProcess 910002
        Token = '0123456789abcdef0123456789abcdef'
    }
    $script:Harness.SshProcess.MainModule.FileName = $script:SshExe
}
function New-WorkerFixture {
    return [pscustomobject]@{
        Version = 2; Alias = 'server-a'; ContextId = $script:ContextId; WorkerToken = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        WorkerPid = $script:Harness.Process.Id
        WorkerStartUtcTicks = $script:Harness.Process.StartTime.ToUniversalTime().Ticks.ToString()
        WorkerExe = $script:PowerShellExe
        SshPid = 910002; State = 'ready'; Token = $script:Harness.Token
        SshStartUtcTicks = $script:Harness.SshProcess.StartTime.ToUniversalTime().Ticks.ToString()
        Guard = [pscustomobject]@{ token = $script:Harness.Token }
        UpdatedUtc = [datetime]::UtcNow.ToString('o'); LastError = ''
    }
}
function New-ReadyLine([string]$Token = '') {
    if (-not $Token) { $Token = $script:Harness.Token }
    $record = [ordered]@{
        event = 'ready'; token = $Token; guardpid = 111; sshdpid = 110
        startticks = 123456; bootid = '12345678-1234-1234-1234-123456789abc'
    }
    return 'TUNNEL_GUARD ' + ($record | ConvertTo-Json -Compress)
}
function New-ReadySession([string]$Line) {
    $completed = New-Object 'Threading.Tasks.TaskCompletionSource[string]'
    $completed.SetResult($Line)
    $script:PendingRead = New-Object 'Threading.Tasks.TaskCompletionSource[string]'
    $reader = [pscustomobject]@{}
    $reader | Add-Member ScriptMethod ReadLineAsync { return $script:PendingRead.Task }
    $process = New-FakeProcess 910002
    $process | Add-Member NoteProperty StandardOutput $reader -Force
    return [pscustomobject]@{
        Process = $process; Token = $script:Harness.Token
        OutputTask = $completed.Task; ErrorTask = $null
        Guard = $null; Ready = $false
        LogPath = Join-Path $script:FixtureDirectory 'ssh.log'
    }
}
function Write-Status([string]$Level, [string]$Message) {
    [void]$script:Harness.Messages.Add([pscustomobject]@{ Level = $Level; Message = $Message })
}
function Invoke-SshProbe { throw 'Real SSH probes are forbidden in offline tests.' }
function Get-TargetConfig { param([string]$Alias) }
function Test-TunnelWorkerMutex { param([string]$Alias) return $false }
function Test-RemoteProxy {
    param([string]$Alias)
    $script:Harness.RemoteChecks++
    return [pscustomobject]@{ Responded = $true; Status = 200; SshFailed = $false; Error = '' }
}
function Start-Process {
    $script:Harness.Started++
    throw 'A worker should not be launched in this offline test.'
}
function Start-Sleep { param([int]$Milliseconds, [int]$Seconds) }

try {
    Invoke-TestCase 'an unavailable diagnostic log cannot fail the tunnel operation' {
        Reset-Harness
        function Add-Content { throw 'Fixture log is locked.' }
        & $script:WriteStatusImplementation 'INFO' 'Fixture operation continues despite its locked log.'
    }
    Invoke-TestCase 'summary logs retain one bounded archive' {
        Reset-Harness
        function Add-Content {
            param($LiteralPath, $Value, $Encoding)
            Microsoft.PowerShell.Management\Add-Content -LiteralPath $LiteralPath -Value $Value -Encoding $Encoding
        }
        [IO.File]::WriteAllText($script:EventLog, ('x' * 1MB))
        & $script:WriteStatusImplementation 'INFO' 'first rotation'
        Assert-Equal 1MB (Get-Item -LiteralPath ($script:EventLog + '.1')).Length 'Archive the full preceding log.'
        Assert-True ((Get-Item -LiteralPath $script:EventLog).Length -lt 1KB) 'The new log should contain only the current message.'
        [IO.File]::WriteAllText($script:EventLog, ('y' * 1MB))
        & $script:WriteStatusImplementation 'INFO' 'second rotation'
        Assert-True ([IO.File]::ReadAllText($script:EventLog + '.1').StartsWith('y')) 'Replace the previous archive instead of accumulating archives.'
        Assert-Equal 2 @([IO.Directory]::GetFiles($script:FixtureDirectory, 'events.log*')).Count 'Keep one active summary log and one archive.'
    }
    Invoke-TestCase 'worker status replaces a complete JSON file atomically' {
        Reset-Harness
        $status = New-WorkerFixture
        Write-WorkerStatus -Alias 'server-a' -Status $status
        $saved = Get-WorkerStatus 'server-a'
        Assert-Equal 2 $saved.Version 'Retain the worker status version.'
        Assert-Equal $status.WorkerPid $saved.WorkerPid 'Retain the real worker identity.'
        $status.State = 'waiting'
        $status.LastError = 'fixture disconnect'
        Write-WorkerStatus -Alias 'server-a' -Status $status
        $saved = Get-WorkerStatus 'server-a'
        Assert-Equal 'waiting' $saved.State 'Replace previous status with valid JSON.'
        Assert-Equal 'fixture disconnect' $saved.LastError 'Persist the reconnect reason.'
        Assert-Equal 0 @([IO.Directory]::GetFiles($script:FixtureDirectory, '*.new')).Count 'Do not leave an unfinished replacement after success.'
    }
    Invoke-TestCase 'a worker status file cannot claim another configured alias' {
        Reset-Harness
        $status = New-WorkerFixture
        $status.Alias = 'server-b'
        [IO.File]::WriteAllText((Join-Path $script:Root 'server-a.worker.json'), ($status | ConvertTo-Json), [Text.Encoding]::UTF8)
        Assert-True ($null -eq (Get-WorkerStatus 'server-a')) 'Reject cross-alias state before inspecting or stopping any worker.'
    }
    Invoke-TestCase 'worker ownership rejects changed PID, creation time, executable and version' {
        Reset-Harness
        function Get-Process {
            param($Id, $ErrorAction)
            if ([int]$Id -ne $script:Harness.Process.Id) { throw 'No such fixture process.' }
            return $script:Harness.Process
        }
        Assert-True ($null -ne (Get-WorkerProcess (New-WorkerFixture))) 'Recognize a matching worker identity.'
        foreach ($field in @('Version', 'Alias', 'WorkerPid', 'WorkerStartUtcTicks', 'WorkerExe')) {
            $invalid = New-WorkerFixture
            switch ($field) {
                'Version' { $invalid.Version = 1 }
                'Alias' { $invalid.Alias = '../unrelated-host' }
                'WorkerPid' { $invalid.WorkerPid = 999999 }
                'WorkerStartUtcTicks' { $invalid.WorkerStartUtcTicks = '1' }
                'WorkerExe' { $invalid.WorkerExe = 'C:\unrelated\powershell.exe' }
            }
            Assert-True ($null -eq (Get-WorkerProcess $invalid)) "Reject a mismatched $field."
        }
    }
    Invoke-TestCase 'guard readiness requires an exact token and complete session identity' {
        Reset-Harness
        $line = New-ReadyLine
        $ready = ConvertFrom-GuardReady -Line $line -ExpectedToken $script:Harness.Token
        Assert-True ($null -ne $ready) 'Accept the exact ready message from this guard.'
        Assert-Equal 110 $ready.sshdpid 'Preserve the guarded SSH session identity.'
        $invalidLines = @(
            'unrelated server banner',
            'TUNNEL_GUARD {invalid json}',
            (New-ReadyLine -Token 'ffffffffffffffffffffffffffffffff'),
            ($line.Replace('"event":"ready"', '"event":"stopped"')),
            ($line.Replace('"sshdpid":110', '"sshdpid":0')),
            ($line.Replace('12345678-1234-1234-1234-123456789abc', 'invalid-boot-id'))
        )
        foreach ($invalid in $invalidLines) {
            Assert-True ($null -eq (ConvertFrom-GuardReady -Line $invalid -ExpectedToken $script:Harness.Token)) 'Reject malformed or unrelated readiness messages.'
        }
    }
    Invoke-TestCase 'asynchronous readiness never promotes an unrelated token' {
        Reset-Harness
        $session = New-ReadySession (New-ReadyLine -Token 'ffffffffffffffffffffffffffffffff')
        Assert-Equal $false (Receive-GuardReady $session) 'Reject a different guard token.'
        Assert-Equal $false $session.Ready 'Do not claim readiness from unrelated output.'
        $session = New-ReadySession (New-ReadyLine)
        Assert-True (Receive-GuardReady $session) 'Accept the current guard ready message.'
        Assert-True $session.Ready 'Promote readiness only after validation.'
        Assert-Equal 110 $session.Guard.sshdpid 'Attach the validated session identity.'
    }
    Invoke-TestCase 'heartbeat writes one exact token to only its session stdin' {
        Reset-Harness
        $writer = New-Object IO.StringWriter
        $process = $script:Harness.Process
        $process | Add-Member NoteProperty StandardInput $writer -Force
        $session = [pscustomobject]@{ Process = $process; Token = $script:Harness.Token }
        try {
            [void](Send-TunnelHeartbeat $session)
            Assert-Equal ($script:Harness.Token + [Environment]::NewLine) $writer.ToString() 'Send one complete exact token line.'
        }
        finally { $writer.Dispose() }
    }
    Invoke-TestCase 'ready status requires a current SSH process and matching guard token' {
        Reset-Harness
        function Get-Process {
            param($Id, $ErrorAction)
            if ([int]$Id -eq $script:Harness.Process.Id) { return $script:Harness.Process }
            if ([int]$Id -eq $script:Harness.SshProcess.Id) { return $script:Harness.SshProcess }
            throw 'No such fixture process.'
        }
        Assert-True (Test-WorkerReady (New-WorkerFixture)) 'Recognize a current guarded worker and SSH child.'
        foreach ($field in @('Guard', 'SshStartUtcTicks', 'UpdatedUtc', 'State')) {
            $invalid = New-WorkerFixture
            switch ($field) {
                'Guard' { $invalid.Guard = [pscustomobject]@{ token = 'ffffffffffffffffffffffffffffffff' } }
                'SshStartUtcTicks' { $invalid.SshStartUtcTicks = '1' }
                'UpdatedUtc' { $invalid.UpdatedUtc = [datetime]::UtcNow.AddMinutes(-5).ToString('o') }
                'State' { $invalid.State = 'connecting' }
            }
            Assert-Equal $false (Test-WorkerReady $invalid) "Reject readiness when $field no longer matches."
        }
    }
    Invoke-TestCase 'readiness preserves UTC DateTime and ISO string timestamp ages' {
        Reset-Harness
        function Get-Process {
            param($Id, $ErrorAction)
            if ([int]$Id -eq $script:Harness.Process.Id) { return $script:Harness.Process }
            if ([int]$Id -eq $script:Harness.SshProcess.Id) { return $script:Harness.SshProcess }
            throw 'No such fixture process.'
        }
        foreach ($representation in @('UtcDateTime', 'IsoString')) {
            $status = New-WorkerFixture
            $freshUtc = [datetime]::UtcNow.AddSeconds(-2)
            $status.UpdatedUtc = if ($representation -eq 'UtcDateTime') { $freshUtc } else { $freshUtc.ToString('o') }
            if ($representation -eq 'UtcDateTime') {
                Assert-Equal ([DateTimeKind]::Utc) $status.UpdatedUtc.Kind 'The fixture must retain its UTC kind.'
            }
            Assert-True (Test-WorkerReady $status) "A fresh $representation timestamp must not appear hours old."
            $staleUtc = [datetime]::UtcNow.AddMinutes(-5)
            $status.UpdatedUtc = if ($representation -eq 'UtcDateTime') { $staleUtc } else { $staleUtc.ToString('o') }
            Assert-Equal $false (Test-WorkerReady $status) "A stale $representation timestamp must still be rejected."
        }
        $status = New-WorkerFixture
        Write-WorkerStatus -Alias 'server-a' -Status $status
        $saved = Get-WorkerStatus 'server-a'
        # ConvertFrom-Json returns a string in Windows PowerShell 5.1 and may
        # return a UTC DateTime in PowerShell 7; both must pass the same check.
        Assert-True (Test-WorkerReady $saved) 'A freshly serialized status must retain its correct age after JSON parsing.'
    }
    Invoke-TestCase 'launcher does not recycle fresh UTC DateTime or ISO string workers' {
        Reset-Harness
        $script:CheckOnly = $false
        function Get-Process {
            param($Id, $ErrorAction)
            if ([int]$Id -eq $script:Harness.Process.Id) { return $script:Harness.Process }
            if ([int]$Id -eq $script:Harness.SshProcess.Id) { return $script:Harness.SshProcess }
            throw 'No such fixture process.'
        }
        function Get-WorkerStatus { param([string]$Alias) return $script:WorkerFixture }
        foreach ($representation in @('UtcDateTime', 'IsoString')) {
            $script:WorkerFixture = New-WorkerFixture
            $freshUtc = [datetime]::UtcNow.AddSeconds(-2)
            $script:WorkerFixture.UpdatedUtc = if ($representation -eq 'UtcDateTime') { $freshUtc } else { $freshUtc.ToString('o') }
            # The global Stop-Process guard throws if an incorrect timezone
            # conversion makes the launcher classify this worker as hung.
            Assert-True (Ensure-Tunnel 'server-a') "Retain a healthy worker whose timestamp is $representation."
        }
        Assert-Equal 0 $script:Harness.Started 'A timestamp representation must never trigger duplicate worker startup.'
        Assert-Equal 2 $script:Harness.RemoteChecks 'Both timestamp representations must reach the normal proxy check.'
        Assert-Equal 0 @($script:Harness.Messages | Where-Object { $_.Message -match 'stopped responding' }).Count 'Do not report a fresh worker as hung.'
    }
    Invoke-TestCase 'fault injection cannot use the production port or configured forwards' {
        Reset-Harness
        $rejected = $false
        try { [void](Start-GuardedSsh -Alias 'server-a' -Token $script:Harness.Token -TestForward -RemotePort 7897) } catch { $rejected = $true }
        Assert-True $rejected 'Reject the production remote port in test mode.'
        function Invoke-SshProbe {
            param($Arguments, $InputText, $TimeoutMs)
            return [pscustomobject]@{ ExitCode = 0; Output = 'remoteforward 7897 127.0.0.1:7897'; Error = '' }
        }
        $rejected = $false
        try { [void](Start-GuardedSsh -Alias 'server-a' -Token $script:Harness.Token -TestForward -RemotePort 27997) } catch { $rejected = $true }
        Assert-True $rejected 'Reject aliases with configured port forwarding before process creation.'
    }
    Invoke-TestCase 'healthy existing worker is retained and checked without duplicate startup' {
        Reset-Harness
        $script:CheckOnly = $true
        $script:WorkerFixture = New-WorkerFixture
        function Get-WorkerStatus { param([string]$Alias) return $script:WorkerFixture }
        function Get-WorkerProcess { param($Status) return $script:Harness.Process }
        function Test-WorkerReady { param($Status) return $true }
        Assert-True (Ensure-Tunnel 'server-a') 'An existing healthy worker should satisfy the launcher.'
        Assert-Equal 0 $script:Harness.Started 'Do not create a duplicate worker.'
        Assert-Equal 1 $script:Harness.RemoteChecks 'Check the actual proxy transport before reporting success.'
    }
    Invoke-TestCase 'a session change during the HTTP probe cannot produce a false success' {
        Reset-Harness
        $script:CheckOnly = $true
        $script:WorkerFixture = New-WorkerFixture
        function Get-WorkerStatus { param([string]$Alias) return $script:WorkerFixture }
        function Get-WorkerProcess { param($Status) return $script:Harness.Process }
        function Test-WorkerReady { param($Status) return $true }
        function Test-RemoteProxy {
            param([string]$Alias)
            $script:Harness.RemoteChecks++
            $script:WorkerFixture = New-WorkerFixture
            $script:WorkerFixture.Token = 'ffffffffffffffffffffffffffffffff'
            return [pscustomobject]@{ Responded = $true; Status = 200; Error = ''; SshFailed = $false }
        }
        Assert-Equal $false (Ensure-Tunnel 'server-a') 'An HTTP response from the previous session must not certify the current session.'
        Assert-Equal 1 $script:Harness.RemoteChecks 'Do not repeat probes in CheckOnly after a session race.'
        Assert-Equal 0 $script:Harness.Started 'CheckOnly must leave the current worker unchanged.'
        Assert-Equal 0 @($script:Harness.Messages | Where-Object { $_.Level -eq 'OK' }).Count 'Do not emit a stale success message.'
    }
    Invoke-TestCase 'strict proxy success returns failure without restarting a responsive tunnel' {
        Reset-Harness
        $script:CheckOnly = $true
        $script:WorkerFixture = New-WorkerFixture
        function Get-WorkerStatus { param([string]$Alias) return $script:WorkerFixture }
        function Get-WorkerProcess { param($Status) return $script:Harness.Process }
        function Test-WorkerReady { param($Status) return $true }
        function Test-RemoteProxy { return [pscustomobject]@{ Responded = $true; Status = 407; Error = ''; SshFailed = $false } }
        function Request-TunnelReconnect { throw 'A responsive proxy must not trigger a restart.' }
        Assert-True (Ensure-Tunnel 'server-a') 'Default mode accepts transport response with warning.'
        $script:RequireProxySuccess = $true
        Assert-Equal $false (Ensure-Tunnel 'server-a') 'Strict mode fails on CONNECT 407.'
        Assert-Equal 0 $script:Harness.Started 'Neither check starts another worker.'
    }
    Invoke-TestCase 'CheckOnly never creates a missing worker' {
        Reset-Harness
        $script:CheckOnly = $true
        function Get-WorkerStatus { param([string]$Alias) return $null }
        function Get-WorkerProcess { param($Status) return $null }
        Assert-Equal $false (Ensure-Tunnel 'server-a') 'A missing worker cannot pass CheckOnly.'
        Assert-Equal 0 $script:Harness.Started 'CheckOnly must never create a worker.'
    }
    Invoke-TestCase 'CheckOnly rejects stale ready status without replacing its worker' {
        Reset-Harness
        $script:CheckOnly = $true
        $script:WorkerFixture = New-WorkerFixture
        $script:WorkerFixture.UpdatedUtc = [datetime]::UtcNow.AddMinutes(-5).ToString('o')
        function Get-WorkerStatus { param([string]$Alias) return $script:WorkerFixture }
        function Get-WorkerProcess { param($Status) return $script:Harness.Process }
        Assert-Equal $false (Ensure-Tunnel 'server-a') 'A stale ready marker is insufficient proof of health.'
        Assert-Equal 0 $script:Harness.Started 'CheckOnly must leave the identified worker unchanged.'
        Assert-Equal 0 $script:Harness.RemoteChecks 'Do not report stale status as a ready session.'
    }
    Invoke-TestCase 'normal launch cannot kill a live worker because its status file is stale' {
        Reset-Harness
        $script:CheckOnly = $false
        $script:WorkerFixture = New-WorkerFixture
        $script:WorkerFixture.UpdatedUtc = [datetime]::UtcNow.AddMinutes(-5).ToString('o')
        function Get-WorkerStatus { param([string]$Alias) return $script:WorkerFixture }
        function Get-WorkerProcess { param($Status) return $script:Harness.Process }
        Assert-Equal $false (Ensure-Tunnel 'server-a') 'Report stale metadata without claiming ready.'
        Assert-Equal 0 $script:Harness.Started 'Do not create another worker for a blocked status file.'
        Assert-Equal 0 $script:Harness.RemoteChecks 'Do not certify an old SSH session from stale metadata.'
        Assert-Equal 1 @($script:Harness.Messages | Where-Object { $_.Message -match 'status file is stale' }).Count 'Explain why the existing worker was retained.'
    }
    Invoke-TestCase 'an unreadable status file cannot start a duplicate worker' {
        Reset-Harness
        function Get-WorkerStatus { param([string]$Alias) return $null }
        function Test-TunnelWorkerMutex { param([string]$Alias) return $true }
        Assert-Equal $false (Ensure-Tunnel 'server-a') 'Report unverifiable status while retaining the existing worker.'
        Assert-Equal 0 $script:Harness.Started 'The worker mutex prevents an unnecessary worker launch.'
        Assert-Equal 1 @($script:Harness.Messages | Where-Object { $_.Message -match 'status file cannot be verified' }).Count 'Explain why the check is inconclusive.'
    }
}
finally {
    foreach ($process in $script:FakeProcesses) { $process.Dispose() }
    # Delete only this run's direct fixtures, without recursion.
    foreach ($file in [IO.Directory]::GetFiles($script:FixtureDirectory)) {
        if ([IO.Path]::GetDirectoryName($file) -ne $script:FixtureDirectory) { throw 'Unexpected fixture path.' }
        [IO.File]::Delete($file)
    }
    [IO.Directory]::Delete($script:FixtureDirectory, $false)
}
Write-Host ("Offline regression tests: {0} passed, {1} failed." -f $script:Passed, $script:Failed)
if ($script:Failed -gt 0) { exit 1 }
exit 0
