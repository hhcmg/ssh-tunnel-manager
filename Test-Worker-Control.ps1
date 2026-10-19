[CmdletBinding()]
param()

# Offline stop/identity regression tests. One child PowerShell runs the real
# worker against a fixture library whose local proxy probe always returns false.
# No SSH executable is started and no network connection is attempted.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Tunnel-Config.ps1')
. (Join-Path $PSScriptRoot 'Tunnel-Runtime.ps1')
$script:Passed = 0
$script:Failed = 0
$script:ContextId = '222222222222222222222222'
$script:Targets = @('server-a')
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('tunnel-worker-control-' + [guid]::NewGuid().ToString('N'))
$script:DataRoot = Join-Path (Join-Path $fixtureRoot '.runtime') $script:ContextId
[void][IO.Directory]::CreateDirectory($script:DataRoot)
$child = $null
$script:MockWorker = $null
$script:MockMutexHeld = $false
$script:FakeStart = [DateTime]::UtcNow
$script:StatusPath = Join-Path $script:DataRoot 'server-a.worker.json'

function Write-Status([string]$Level, [string]$Message) { }
function Test-TunnelWorkerMutex([string]$Alias) { return $script:MockMutexHeld }
function Get-Process {
    param([int]$Id, $ErrorAction)
    if ($Id -ne 4242 -or -not $script:MockWorker) { throw 'Fixture process does not exist.' }
    return $script:MockWorker
}
function Assert-True($Value, [string]$Message) { if (-not $Value) { throw $Message } }
function Invoke-Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; $script:Passed++; Write-Host "PASS $Name" -ForegroundColor Green }
    catch { $script:Failed++; Write-Host "FAIL $Name : $($_.Exception.Message)" -ForegroundColor Red }
}
function New-StatusFixture {
    return [pscustomobject]@{
        Version = 2; Alias = 'server-a'; ContextId = $script:ContextId
        WorkerToken = ('a' * 32); WorkerPid = 4242; WorkerExe = $script:PowerShellExe
        WorkerStartUtcTicks = $script:FakeStart.ToUniversalTime().Ticks.ToString()
        State = 'waiting'; Token = ('b' * 32); UpdatedUtc = [DateTime]::UtcNow.ToString('o')
    }
}
function Set-StatusFixture($Status) {
    # Direct fixture writes keep these identity tests independent of ReplaceFile.
    [IO.File]::WriteAllText($script:StatusPath, ($Status | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
}
function Remove-FixtureTree([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    $allowed = [IO.Path]::GetFullPath($fixtureRoot)
    if (-not $full.Equals($allowed, [StringComparison]::OrdinalIgnoreCase) -and
        -not $full.StartsWith($allowed + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected fixture cleanup path.' }
    foreach ($entry in @(Get-ChildItem -LiteralPath $full -Force)) {
        if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Unexpected reparse point in fixture.' }
        if ($entry.PSIsContainer) { Remove-FixtureTree $entry.FullName }
        else { [IO.File]::Delete($entry.FullName) }
    }
    [IO.Directory]::Delete($full, $false)
}

try {
    $script:MockWorker = [pscustomobject]@{ Path = $script:PowerShellExe; StartTime = $script:FakeStart }
    Invoke-Case 'generic aliases reuse state regardless of Windows path casing' {
        Set-StatusFixture (New-StatusFixture)
        Assert-True ($null -ne (Get-WorkerStatus 'SERVER-A')) 'Case-only host spelling must not hide the same worker.'
        $state = New-StatusFixture
        $state.ContextId = '333333333333333333333333'
        Set-StatusFixture $state
        Assert-True ($null -eq (Get-WorkerStatus 'server-a')) 'A foreign configuration context cannot be reused.'
    }
    Invoke-Case 'process identity requires context, worker token, executable and start time' {
        $state = New-StatusFixture
        Assert-True ($null -ne (Get-WorkerProcess $state)) 'Accept the exact fixture process identity.'
        foreach ($field in @('ContextId', 'WorkerToken', 'WorkerExe', 'WorkerStartUtcTicks')) {
            $invalid = New-StatusFixture
            $invalid.$field = 'invalid'
            Assert-True ($null -eq (Get-WorkerProcess $invalid)) "Reject altered $field."
        }
    }
    Invoke-Case 'stop requests require the current stable worker token' {
        Set-StatusFixture (New-StatusFixture)
        $rejected = $false
        try { Request-TunnelStop 'server-a' ('b' * 32) } catch { $rejected = $true }
        Assert-True $rejected 'A session token is insufficient to stop the worker.'
        Assert-True (-not [IO.File]::Exists((Join-Path $script:DataRoot 'server-a.stop'))) 'Rejected requests must not create a stop file.'
        Request-TunnelStop 'server-a' ('a' * 32)
        Assert-True (Receive-TunnelRequest 'server-a' 'stop' ('a' * 32)) 'The matching worker consumes its stop request.'
        Assert-True (-not (Receive-TunnelRequest 'server-a' 'stop' ('a' * 32))) 'A request is consumed only once.'
    }
    Invoke-Case 'stale stop and reconnect tokens cannot affect replacement workers or sessions' {
        [IO.File]::WriteAllText((Join-Path $script:DataRoot 'server-a.stop'), ('c' * 32))
        Assert-True (-not (Receive-TunnelRequest 'server-a' 'stop' ('a' * 32))) 'Discard the stale worker request.'
        Request-TunnelReconnect 'server-a' ('b' * 32)
        Assert-True (-not (Receive-TunnelRequest 'server-a' 'reconnect' ('c' * 32))) 'Discard the stale session request.'
        Request-TunnelReconnect 'server-a' ('b' * 32)
        Assert-True (Receive-TunnelRequest 'server-a' 'reconnect' ('b' * 32)) 'Accept the current session request.'
    }
    Invoke-Case 'unsafe aliases are rejected before writing control files' {
        foreach ($alias in @('../server-a', 'CON', 'server/a', '-oProxyCommand=bad')) {
            $rejected = $false
            try { Request-TunnelReconnect $alias ('b' * 32) } catch { $rejected = $true }
            Assert-True $rejected "Reject unsafe alias $alias."
        }
    }
    Invoke-Case 'stop reports absent workers and bounded timeouts without killing processes' {
        Set-StatusFixture (New-StatusFixture)
        $script:MockWorker = $null
        Assert-True (Stop-TunnelWorkers -TimeoutSeconds 1) 'An already absent worker needs no action.'
        $script:MockMutexHeld = $true
        Assert-True (-not (Stop-TunnelWorkers -TimeoutSeconds 1)) 'A held mutex with unverifiable state must not be reported as stopped.'
        $script:MockMutexHeld = $false
        $script:MockWorker = [pscustomobject]@{ Path = $script:PowerShellExe; StartTime = $script:FakeStart }
        Assert-True (-not (Stop-TunnelWorkers -TimeoutSeconds 1)) 'An unresponsive worker must report timeout.'
        Assert-True ([IO.File]::Exists((Join-Path $script:DataRoot 'server-a.stop'))) 'Keep a pending stop request after timeout.'
    }
    Invoke-Case 'real worker waiting for proxy honors stop and exits without starting SSH' {
        Remove-Item Function:\Get-Process
        foreach ($name in @('Tunnel-Worker.ps1', 'Tunnel-Runtime.ps1', 'Tunnel-Config.ps1')) {
            [IO.File]::Copy((Join-Path $PSScriptRoot $name), (Join-Path $fixtureRoot $name))
        }
        $library = @'
param([switch]$LibraryOnly)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:Root = $PSScriptRoot
$script:UserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
. (Join-Path $PSScriptRoot 'Tunnel-Config.ps1')
. (Join-Path $PSScriptRoot 'Tunnel-Runtime.ps1')
function Test-LocalProxy { return $false }
function Write-Status([string]$Level, [string]$Message) { }
function Invoke-TunnelLogRetention { throw 'Unexpected SSH connection attempt.' }
'@
        [IO.File]::WriteAllText((Join-Path $fixtureRoot 'Start-Tunnels.ps1'), $library)
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = $script:PowerShellExe
        $info.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $fixtureRoot 'Tunnel-Worker.ps1') +
            '" -Alias server-a -SshConfigPath "' + (Join-Path $fixtureRoot 'unused-config') +
            '" -SshExecutable "' + (Join-Path $fixtureRoot 'never-run-ssh.exe') +
            '" -DataDirectory "' + $script:DataRoot + '" -ContextId ' + $script:ContextId
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $script:child = [Diagnostics.Process]::Start($info)
        $childOutput = $child.StandardOutput.ReadToEndAsync()
        $childError = $child.StandardError.ReadToEndAsync()
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $state = $null
        do {
            Start-Sleep -Milliseconds 100
            $state = Get-WorkerStatus 'server-a'
            if ($child.HasExited) { throw ('Fixture worker exited early: ' + $childError.GetAwaiter().GetResult()) }
        } until (($state -and $state.WorkerPid -eq $child.Id -and $state.State -eq 'waiting') -or $timer.Elapsed.TotalSeconds -gt 10)
        Assert-True ($state -and $state.WorkerPid -eq $child.Id -and $state.State -eq 'waiting') 'Worker must publish its stable identity while waiting.'
        Assert-True ($state.SshPid -eq 0 -and $state.Token -eq '') 'The fixture worker must not start SSH.'
        Assert-True (Stop-TunnelWorkers -TimeoutSeconds 5) 'The waiting worker must acknowledge and exit promptly.'
        Assert-True ($child.WaitForExit(1000) -and $child.ExitCode -eq 0) ('Worker must exit cleanly: ' + $childError.GetAwaiter().GetResult())
        Assert-True ((Get-WorkerStatus 'server-a').State -eq 'stopped') 'Worker must publish stopped state before releasing its mutex.'
    }
    Invoke-Case 'real worker stops its simulated active session without reconnecting' {
        if ($child) { $child.Dispose(); $script:child = $null }
        $library = @'
param([switch]$LibraryOnly)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:Root = $PSScriptRoot
$script:UserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
. (Join-Path $PSScriptRoot 'Tunnel-Config.ps1')
. (Join-Path $PSScriptRoot 'Tunnel-Runtime.ps1')
function Test-LocalProxy { return $true }
function Write-Status([string]$Level, [string]$Message) { }
function Invoke-TunnelLogRetention { }
function Start-GuardedSsh($Alias, $Token, $LeaseSeconds, $LogPath) {
    [IO.File]::AppendAllText((Join-Path $script:Root 'session-starts.txt'), 'start;')
    $process = [pscustomobject]@{ Id = 4243; StartTime = [DateTime]::UtcNow; HasExited = $false }
    Add-Member -InputObject $process -MemberType ScriptMethod -Name Refresh -Value { }
    return [pscustomobject]@{
        Process = $process; Token = $Token; Ready = $false
        Guard = [pscustomobject]@{ token = $Token }; ErrorTask = [pscustomobject]@{ IsCompleted = $false }
    }
}
function Send-TunnelHeartbeat($Session) { }
function Receive-GuardReady($Session) { $Session.Ready = $true; return $true }
function Stop-GuardedSsh($Session) { [IO.File]::AppendAllText((Join-Path $script:Root 'session-stops.txt'), 'stop;') }
'@
        [IO.File]::WriteAllText((Join-Path $fixtureRoot 'Start-Tunnels.ps1'), $library)
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = $script:PowerShellExe
        $info.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $fixtureRoot 'Tunnel-Worker.ps1') +
            '" -Alias server-a -SshConfigPath "' + (Join-Path $fixtureRoot 'unused-config') +
            '" -SshExecutable "' + (Join-Path $fixtureRoot 'never-run-ssh.exe') +
            '" -DataDirectory "' + $script:DataRoot + '" -ContextId ' + $script:ContextId
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $script:child = [Diagnostics.Process]::Start($info)
        $childOutput = $child.StandardOutput.ReadToEndAsync()
        $childError = $child.StandardError.ReadToEndAsync()
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $state = $null
        do {
            Start-Sleep -Milliseconds 100
            $state = Get-WorkerStatus 'server-a'
            if ($child.HasExited) { throw ('Fixture worker exited early: ' + $childError.GetAwaiter().GetResult()) }
        } until (($state -and $state.WorkerPid -eq $child.Id -and $state.State -eq 'ready') -or $timer.Elapsed.TotalSeconds -gt 10)
        Assert-True ($state -and $state.WorkerPid -eq $child.Id -and $state.State -eq 'ready') 'Worker must enter simulated ready state.'
        Assert-True (Stop-TunnelWorkers -TimeoutSeconds 5) 'The active worker must stop promptly.'
        Assert-True ($child.WaitForExit(1000) -and $child.ExitCode -eq 0) 'The active worker must exit cleanly.'
        Assert-True ([IO.File]::ReadAllText((Join-Path $fixtureRoot 'session-starts.txt')) -eq 'start;') 'Stop must not trigger another connection attempt.'
        Assert-True ([IO.File]::ReadAllText((Join-Path $fixtureRoot 'session-stops.txt')) -eq 'stop;') 'The active session must be closed once.'
        Assert-True ((Get-WorkerStatus 'server-a').State -eq 'stopped') 'Active worker must publish stopped state.'
    }
}
finally {
    if ($child) {
        # This handle belongs exclusively to the fixture child created above.
        if (-not $child.HasExited) { $child.Kill(); [void]$child.WaitForExit(3000) }
        $child.Dispose()
    }
    Remove-FixtureTree $fixtureRoot
}
Write-Host ("Worker control tests ({0}): {1} passed, {2} failed." -f $PSVersionTable.PSVersion, $script:Passed, $script:Failed)
if ($script:Failed -gt 0) { exit 1 }
exit 0
