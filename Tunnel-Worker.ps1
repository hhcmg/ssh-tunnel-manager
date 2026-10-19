[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Alias,
    [Parameter(Mandatory=$true)][string]$SshConfigPath,
    [Parameter(Mandatory=$true)][string]$SshExecutable,
    [string]$LocalProxyHost = '127.0.0.1',
    [ValidateRange(1,65535)][int]$LocalProxyPort = 7897,
    [ValidateRange(1,65535)][int]$RemotePort = 7897,
    [string]$ProbeHost = 'www.microsoft.com',
    [ValidateRange(1,65535)][int]$ProbePort = 443,
    [Parameter(Mandatory=$true)][string]$DataDirectory,
    [Parameter(Mandatory=$true)][ValidatePattern('^[0-9a-f]{24}$')][string]$ContextId
)

# Snapshot settings before loading the shared library. Running workers keep
# these values even if the user later edits the JSON configuration.
$startup = @{
    Alias = $Alias; ConfigFile = $SshConfigPath; SshExe = $SshExecutable
    LocalProxyHost = $LocalProxyHost; LocalProxyPort = $LocalProxyPort
    RemotePort = $RemotePort; ProbeHost = $ProbeHost; ProbePort = $ProbePort
    DataRoot = $DataDirectory; ContextId = $ContextId
}
. (Join-Path $PSScriptRoot 'Start-Tunnels.ps1') -LibraryOnly
foreach ($key in $startup.Keys) { Set-Variable -Scope Script -Name $key -Value $startup[$key] }
if (-not (Test-TunnelAlias $Alias)) { throw 'Invalid tunnel alias.' }
foreach ($endpoint in @($script:LocalProxyHost, $script:ProbeHost)) {
    if (-not (Test-TunnelEndpointHost $endpoint)) { throw 'Worker endpoints must be DNS names or IP addresses without a scheme, port, or whitespace.' }
}
$expectedDataRoot = [IO.Path]::GetFullPath((Join-Path (Join-Path $script:Root '.runtime') $script:ContextId))
if (-not [IO.Path]::GetFullPath($script:DataRoot).Equals($expectedDataRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Worker data directory does not match its project and configuration context.'
}
$script:Targets = @($Alias)
$script:LogRoot = Join-Path $script:DataRoot 'logs'
[void][IO.Directory]::CreateDirectory($script:LogRoot)
$script:EventLog = Join-Path $script:LogRoot "$Alias.worker.log"
$script:StateWriteWarning = $false
$mutex = New-Object Threading.Mutex($false, ('Local\SshTunnelWorker-' + $script:UserSid + '-' + $script:ContextId + '-' + $Alias.ToLowerInvariant()))
$locked = $false
$session = $null
$self = Get-Process -Id $PID
$status = [pscustomobject]@{
    Version = 2; Alias = $Alias; ContextId = $script:ContextId
    WorkerToken = [guid]::NewGuid().ToString('N'); WorkerPid = $PID
    WorkerStartUtcTicks = $self.StartTime.ToUniversalTime().Ticks.ToString(); WorkerExe = $self.Path
    State = 'starting'; SshPid = 0; SshStartUtcTicks = ''; Token = ''; Guard = $null
    UpdatedUtc = [DateTime]::UtcNow.ToString('o'); LastError = ''; Log = ''
}

function Publish-State([string]$State, [string]$ErrorText = '') {
    $status.State = $State
    $status.LastError = $ErrorText
    $status.UpdatedUtc = [DateTime]::UtcNow.ToString('o')
    if (Write-WorkerStatus $Alias $status) {
        if ($script:StateWriteWarning) { Write-Status 'INFO' "$Alias status file updates resumed." }
        $script:StateWriteWarning = $false
    }
    elseif (-not $script:StateWriteWarning) {
        $script:StateWriteWarning = $true
        Write-Status 'WARN' "$Alias status file could not be updated; keeping the SSH session and retrying the status update."
    }
}

function Wait-WorkerDelay([int]$Milliseconds) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        if (Receive-TunnelRequest $Alias 'stop' $status.WorkerToken) { return $true }
        $remaining = $Milliseconds - [int]$timer.ElapsedMilliseconds
        if ($remaining -gt 0) { Start-Sleep -Milliseconds ([Math]::Min(250, $remaining)) }
    } while ($timer.ElapsedMilliseconds -lt $Milliseconds)
    return $false
}

try {
    try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) { exit 0 }
    Publish-State 'starting'
    Write-Status 'INFO' "$Alias worker started; PID=$PID."
    $failures = 0
    $lastReported = ''
    :workerLoop while ($true) {
        if (Receive-TunnelRequest $Alias 'stop' $status.WorkerToken) { break }
        if (-not (Test-LocalProxy)) {
            Publish-State 'waiting' ("Waiting for local proxy {0}:{1}." -f $script:LocalProxyHost, $script:LocalProxyPort)
            if ($lastReported -ne $status.LastError) { Write-Status 'WARN' $status.LastError; $lastReported = $status.LastError }
            if (Wait-WorkerDelay 5000) { break }
            continue
        }
        try {
            $status.Token = [guid]::NewGuid().ToString('N')
            $status.Log = Join-Path $script:LogRoot ("$Alias." + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '.log')
            [void](Invoke-TunnelLogRetention -Directory $script:LogRoot -Alias $Alias -ActiveLogPath $status.Log)
            $status.Guard = $null
            Publish-State 'connecting'
            $session = Start-GuardedSsh -Alias $Alias -Token $status.Token -LeaseSeconds 30 -LogPath $status.Log
            $status.SshPid = $session.Process.Id
            $status.SshStartUtcTicks = $session.Process.StartTime.ToUniversalTime().Ticks.ToString()
            Publish-State 'connecting'
            $timer = [Diagnostics.Stopwatch]::StartNew()
            $lastHeartbeat = -5000L
            $lastPublish = -10000L
            $readyReported = $false
            while ($true) {
                if (Receive-TunnelRequest $Alias 'stop' $status.WorkerToken) { break workerLoop }
                $session.Process.Refresh()
                if ($session.Process.HasExited) {
                    $reason = "SSH exited with code $($session.Process.ExitCode)."
                    if ($session.ErrorTask.IsCompleted) { $reason += ' ' + $session.ErrorTask.GetAwaiter().GetResult().Trim() }
                    throw $reason
                }
                if ($timer.ElapsedMilliseconds - $lastHeartbeat -ge 5000) {
                    Send-TunnelHeartbeat $session
                    $lastHeartbeat = $timer.ElapsedMilliseconds
                }
                if (-not $session.Ready -and (Receive-GuardReady $session)) {
                    $status.Guard = $session.Guard
                    Publish-State 'ready'
                    $failures = 0
                    $lastReported = ''
                    $readyReported = $true
                    Write-Status 'OK' "$Alias guarded SSH ready; PID=$($session.Process.Id); remote cleanup deadline=30s."
                }
                if (-not $session.Ready -and $timer.Elapsed.TotalSeconds -gt 20) { throw 'Remote guard did not confirm its session identity.' }
                if ($readyReported -and $timer.ElapsedMilliseconds - $lastPublish -ge 10000) {
                    Publish-State 'ready'
                    $lastPublish = $timer.ElapsedMilliseconds
                }
                if (Receive-TunnelRequest $Alias 'reconnect' $session.Token) { throw 'Launcher requested recovery of this tunnel.' }
                Start-Sleep -Milliseconds 250
            }
        }
        catch {
            $reason = $_.Exception.Message.Trim()
            if ($session) { try { Stop-GuardedSsh $session } catch { }; $session = $null }
            $status.SshPid = 0
            $status.SshStartUtcTicks = ''
            $status.Guard = $null
            Publish-State 'waiting' $reason
            if ($reason -ne $lastReported) { Write-Status 'WARN' "$Alias will reconnect automatically: $reason"; $lastReported = $reason }
            $failures++
            if (Wait-WorkerDelay ([math]::Min(10000, 2000 * $failures))) { break }
        }
    }
}
finally {
    if ($session) { try { Stop-GuardedSsh $session } catch { } }
    if ($locked) {
        $status.SshPid = 0
        $status.SshStartUtcTicks = ''
        $status.Guard = $null
        try { Publish-State 'stopped' 'Worker stopped; remote guard will release this session.' } catch { }
        $mutex.ReleaseMutex()
    }
    $mutex.Dispose()
}
