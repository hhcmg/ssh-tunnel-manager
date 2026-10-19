[CmdletBinding()]
param(
    [string]$Alias,
    [string]$ConfigPath,
    [string]$SshConfig,
    [ValidateRange(20000, 65535)][int]$RemotePort = 27997,
    [ValidateRange(5, 30)][int]$LeaseSeconds = 5,
    [ValidateRange(10, 60)][int]$StartupTimeoutSeconds = 30,
    [ValidateRange(10, 60)][int]$ReleaseTimeoutSeconds = 20,
    [switch]$Run
)

# Opt-in integration test. It creates only one temporary high-port forwarding
# session, withholds its guard heartbeat, and checks that the session expires.
# It does not start workers or inspect/stop the configured production remote port.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (-not $Run) {
    Write-Host "Dry run: use -Run -Alias server-a to test remote port $RemotePort with a $LeaseSeconds-second lease."
    Write-Host 'Use -SshConfig to select an SSH file or -ConfigPath for manager settings. The alias must have no configured forwarding.'
    return
}
if ([string]::IsNullOrWhiteSpace($Alias)) { throw '-Alias is required with -Run.' }
if ($ReleaseTimeoutSeconds -le $LeaseSeconds) { throw 'ReleaseTimeoutSeconds must be greater than LeaseSeconds.' }

# The shared library initializes its own script-level forwarding settings.
# Keep the isolated test's arguments separate from those production settings.
$recoveryAlias = $Alias
$recoveryPort = $RemotePort
$recoveryOptions = @{ Targets = @($Alias); CheckOnly = $true; NonInteractive = $true }
foreach ($option in @('ConfigPath', 'SshConfig')) {
    if ($PSBoundParameters.ContainsKey($option)) { $recoveryOptions[$option] = $PSBoundParameters[$option] }
}
. (Join-Path $PSScriptRoot 'Start-Tunnels.ps1') -LibraryOnly
if (-not (Test-TunnelAlias $recoveryAlias)) { throw 'Invalid recovery test alias.' }
$recoverySettings = Initialize-TunnelApplication @recoveryOptions
if ($recoveryPort -eq $script:RemotePort) { throw 'The isolated test port must differ from the configured production remote port.' }
$effective = Invoke-SshProbe -Arguments @('-G', '-F', $script:ConfigFile, '-o', 'ClearAllForwardings=no', $recoveryAlias)
if ($effective.ExitCode -ne 0 -or $effective.Output -match '(?m)^(remote|local|dynamic)forward ') {
    throw 'The recovery test requires an SSH alias with no configured port forwarding.'
}

function ConvertTo-RecoveryArgument([string]$Value) {
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function Invoke-RecoverySsh([string[]]$Arguments, [string]$InputText) {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $script:SshExe
    $info.Arguments = ($Arguments | ForEach-Object { ConvertTo-RecoveryArgument $_ }) -join ' '
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    try {
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.Write($InputText)
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(15000)) {
            $process.Kill()
            [void]$process.WaitForExit(3000)
            throw 'The read-only remote port check timed out.'
        }
        if ($process.ExitCode -ne 0) { throw "Remote port check failed: $($stderr.Result.Trim())" }
        return $stdout.Result
    }
    finally {
        # This handle belongs only to the diagnostic child created above.
        try { if (-not $process.HasExited) { $process.Kill(); [void]$process.WaitForExit(3000) } } catch { }
        $process.Dispose()
    }
}

function Test-RecoveryPort {
    $python = @'
import errno, json, socket
try:
    with socket.create_connection(('127.0.0.1', __PORT__), 2):
        result = {'connected': True, 'refused': False, 'error': ''}
except OSError as error:
    result = {'connected': False, 'refused': error.errno == errno.ECONNREFUSED, 'error': str(error)}
print('TUNNEL_RECOVERY_PORT ' + json.dumps(result))
'@
    $python = $python.Replace('__PORT__', [string]$recoveryPort)
    $arguments = @('-T', '-S', 'none', '-F', $script:ConfigFile,
        '-o', 'BatchMode=yes', '-o', 'ClearAllForwardings=yes',
        '-o', 'ControlMaster=no', '-o', 'ControlPersist=no',
        '-o', 'ForwardAgent=no', '-o', 'ForwardX11=no',
        '-o', 'RemoteCommand=none', '-o', 'RequestTTY=no',
        '-o', 'ConnectTimeout=5', '-o', 'ConnectionAttempts=1',
        $recoveryAlias, 'python3', '-')
    $output = Invoke-RecoverySsh -Arguments $arguments -InputText $python
    $lines = @($output -split '\r?\n' | Where-Object { $_.StartsWith('TUNNEL_RECOVERY_PORT ') })
    if ($lines.Count -ne 1) { throw 'The remote port check returned no unambiguous result.' }
    return $lines[0].Substring('TUNNEL_RECOVERY_PORT '.Length) | ConvertFrom-Json
}

$session = $null
$testDirectory = Join-Path ([IO.Path]::GetTempPath()) ('tunnel-recovery-' + [guid]::NewGuid().ToString('N'))
$testLog = Join-Path $testDirectory 'ssh.log'
[void][IO.Directory]::CreateDirectory($testDirectory)
$succeeded = $false
try {
    $before = Test-RecoveryPort
    if (-not $before.refused) {
        throw "Remote test port $recoveryPort is occupied or its availability is uncertain. No forwarding was started. $($before.error)"
    }
    $token = [guid]::NewGuid().ToString('N')
    Write-Host "Testing $recoveryAlias remote port $recoveryPort; configured production port $($script:RemotePort) is unchanged."
    # TestForward must validate that the plain alias has no configured forwards.
    $session = Start-GuardedSsh -Alias $recoveryAlias -Token $token -LeaseSeconds $LeaseSeconds -LogPath $testLog -TestForward -RemotePort $recoveryPort
    $startup = [Diagnostics.Stopwatch]::StartNew()
    while (-not $session.Ready -and $startup.Elapsed.TotalSeconds -lt $StartupTimeoutSeconds) {
        [void](Receive-GuardReady $session)
        $session.Process.Refresh()
        if ($session.Process.HasExited) { break }
        if (-not $session.Ready) { Start-Sleep -Milliseconds 100 }
    }
    if (-not $session.Ready) { throw "The isolated guard did not report READY within $StartupTimeoutSeconds seconds. SSH log: $testLog" }
    Write-Host "Guard READY; withholding all heartbeats and waiting for the $LeaseSeconds-second lease to expire."
    $expiry = [Diagnostics.Stopwatch]::StartNew()
    while ($expiry.Elapsed.TotalSeconds -lt $ReleaseTimeoutSeconds) {
        $session.Process.Refresh()
        if ($session.Process.HasExited) { break }
        Start-Sleep -Milliseconds 100
    }
    $session.Process.Refresh()
    if (-not $session.Process.HasExited) { throw "SSH did not exit within $ReleaseTimeoutSeconds seconds after READY." }

    # This happens before Stop-GuardedSsh, so cleanup cannot make the test pass.
    $after = Test-RecoveryPort
    if (-not $after.refused) { throw "SSH exited, but remote test port $recoveryPort did not return connection refused. $($after.error)" }
    $succeeded = $true
    Write-Host ("PASS: SSH exited after {0:N1}s without heartbeats and remote test port {1} was released." -f $expiry.Elapsed.TotalSeconds, $recoveryPort) -ForegroundColor Green
}
finally {
    if ($null -ne $session) { Stop-GuardedSsh $session }
    if ($succeeded) {
        # Delete only this run's named log and its empty temporary directory.
        if ([IO.File]::Exists($testLog)) { [IO.File]::Delete($testLog) }
        [IO.Directory]::Delete($testDirectory, $false)
    }
    else { Write-Host "Failure diagnostics retained at: $testDirectory" }
}
