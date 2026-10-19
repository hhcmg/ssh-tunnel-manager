[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$SshConfig,
    [Alias('Servers')][string[]]$Targets,
    [switch]$Configure,
    [switch]$ListHosts,
    [switch]$CheckOnly,
    [switch]$NonInteractive,
    [switch]$RequireProxySuccess,
    [switch]$LibraryOnly
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$entryOptions = @{}
foreach ($name in @('ConfigPath', 'SshConfig', 'Targets', 'Configure', 'ListHosts', 'CheckOnly', 'NonInteractive')) {
    if ($PSBoundParameters.ContainsKey($name)) { $entryOptions[$name] = $PSBoundParameters[$name] }
}
$script:Root = $PSScriptRoot
$script:DataRoot = Join-Path $script:Root '.runtime'
$script:LogRoot = Join-Path $script:DataRoot 'logs'
$script:EventLog = Join-Path $script:LogRoot 'tunnels.log'
$script:SshExe = Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
$script:ConfigFile = Join-Path $env:USERPROFILE '.ssh\config'
$script:UserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$script:ContextId = 'uninitialized'
$script:Targets = @($Targets)
$script:LocalProxyHost = '127.0.0.1'
$script:LocalProxyPort = 7897
$script:RemotePort = 7897
$script:ProbeHost = 'www.microsoft.com'
$script:ProbePort = 443
$script:CheckOnly = [bool]$CheckOnly
$script:RequireProxySuccess = [bool]$RequireProxySuccess

function Initialize-TunnelApplication {
    param([string]$ConfigPath, [string]$SshConfig, [string[]]$Targets,
        [switch]$Configure, [switch]$ListHosts, [switch]$CheckOnly, [switch]$NonInteractive)
    $resolveOptions = @{ Root = $script:Root }
    foreach ($key in $PSBoundParameters.Keys) { $resolveOptions[$key] = $PSBoundParameters[$key] }
    $settings = Resolve-TunnelSettings @resolveOptions
    $script:ConfigFile = $settings.SshConfigPath
    $script:SshExe = $settings.SshExecutable
    $script:Targets = @($settings.Targets)
    $script:LocalProxyHost = $settings.LocalProxyHost
    $script:LocalProxyPort = $settings.LocalProxyPort
    $script:RemotePort = $settings.RemotePort
    $script:ProbeHost = $settings.ProbeHost
    $script:ProbePort = $settings.ProbePort
    # Selection and probe destination do not change the identity of a tunnel.
    $identity = @($script:ConfigFile.ToLowerInvariant(), $script:SshExe.ToLowerInvariant(),
        $script:LocalProxyHost.ToLowerInvariant(), $script:LocalProxyPort, $script:RemotePort) -join "`n"
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $script:ContextId = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($identity))).Replace('-', '').ToLowerInvariant()).Substring(0, 24) }
    finally { $sha.Dispose() }
    $script:DataRoot = Join-Path (Join-Path $script:Root '.runtime') $script:ContextId
    $script:LogRoot = Join-Path $script:DataRoot 'logs'
    $script:EventLog = Join-Path $script:LogRoot 'tunnels.log'
    return $settings
}

function Write-Status([string]$Level, [string]$Message) {
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    $color = switch ($Level) { 'ERROR' { 'Red' } 'WARN' { 'Yellow' } 'OK' { 'Green' } default { 'Cyan' } }
    Write-Host $line -ForegroundColor $color
    # Diagnostic storage must never tear down a working SSH session.
    try {
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($script:EventLog))
        if ([IO.File]::Exists($script:EventLog) -and (Get-Item -LiteralPath $script:EventLog).Length -ge 1MB) {
            [IO.File]::Delete($script:EventLog + '.1')
            [IO.File]::Move($script:EventLog, $script:EventLog + '.1')
        }
        Add-Content -LiteralPath $script:EventLog -Value $line -Encoding UTF8
    }
    catch { Write-Host "Log write skipped: $($_.Exception.Message)" -ForegroundColor Yellow }
}

function ConvertTo-NativeArgument([string]$Value) {
    # Windows CreateProcess quoting; never pass command text through cmd.exe.
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function Invoke-SshProbe([string[]]$Arguments, [string]$InputText = '', [int]$TimeoutMs = 18000) {
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $script:SshExe
    $info.Arguments = ($Arguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' '
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $info
    try {
        [void]$process.Start()
        $outTask = $process.StandardOutput.ReadToEndAsync()
        $errTask = $process.StandardError.ReadToEndAsync()
        if ($InputText) { $process.StandardInput.Write($InputText) }
        $process.StandardInput.Close()
        if (-not $process.WaitForExit($TimeoutMs)) {
            $process.Kill()
            [void]$process.WaitForExit(3000)
            return [pscustomobject]@{ ExitCode = 124; Output = ''; Error = 'SSH check timed out.' }
        }
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $outTask.Result; Error = $errTask.Result }
    }
    finally { $process.Dispose() }
}

function ConvertFrom-TunnelEndpoint([string]$Value, [switch]$AllowPortOnly) {
    if ($AllowPortOnly -and $Value -match '^([0-9]+)$') {
        return [pscustomobject]@{ Host = ''; Port = [int]$Matches[1] }
    }
    if ($Value -match '^\[([^\]]+)\]:([0-9]+)$' -or $Value -match '^([^:]+):([0-9]+)$') {
        return [pscustomobject]@{ Host = $Matches[1].ToLowerInvariant(); Port = [int]$Matches[2] }
    }
    return $null
}

function Get-TargetConfig([string]$Alias) {
    if (-not (Test-TunnelAlias $Alias)) { throw 'Invalid SSH alias.' }
    $result = Invoke-SshProbe -Arguments @('-G', '-F', $script:ConfigFile, '-o', 'ClearAllForwardings=no', $Alias)
    if ($result.ExitCode -ne 0) { throw "Cannot read SSH config for ${Alias}: $($result.Error.Trim())" }
    $lines = $result.Output -split '\r?\n'
    $hostLine = @($lines | Where-Object { $_ -match '^hostname\s+\S+' })
    if ($hostLine.Count -ne 1) { throw "SSH did not resolve a hostname for $Alias." }
    if (@($lines | Where-Object { $_ -match '^(local|dynamic)forward\s+' }).Count -gt 0) {
        throw "$Alias config includes local/dynamic forwarding. Use a dedicated alias without these forwards."
    }
    $forwards = @($lines | Where-Object { $_ -match '^remoteforward\s+' })
    if ($forwards.Count -gt 1) { throw "$Alias config includes multiple remote forwards. Only this tool's one proxy forward is allowed." }
    if ($forwards.Count -eq 1) {
        $parts = $forwards[0] -split '\s+'
        if ($parts.Count -ne 3) { throw "$Alias config contains an unsupported remote forward." }
        $listen = ConvertFrom-TunnelEndpoint $parts[1] -AllowPortOnly
        $destination = ConvertFrom-TunnelEndpoint $parts[2]
        if (-not $listen -or -not $destination -or $listen.Host -notin @('', '127.0.0.1', 'localhost') -or
            $listen.Port -ne $script:RemotePort -or $destination.Host -ine $script:LocalProxyHost -or
            $destination.Port -ne $script:LocalProxyPort) {
            throw "$Alias has a conflicting RemoteForward. Remove it or match loopback:$($script:RemotePort) to $($script:LocalProxyHost):$($script:LocalProxyPort)."
        }
    }
    return [pscustomobject]@{ HasRemoteForward = ($forwards.Count -eq 1) }
}

function New-TunnelProxyClient {
    if ([Net.Sockets.Socket]::OSSupportsIPv6) {
        $client = New-Object Net.Sockets.TcpClient([Net.Sockets.AddressFamily]::InterNetworkV6)
        $client.Client.DualMode = $true
        return $client
    }
    return New-Object Net.Sockets.TcpClient
}

function Test-LocalProxyConnection([ValidateRange(1, 10000)][int]$TimeoutMs = 2000) {
    $client = New-TunnelProxyClient
    try {
        $task = $client.ConnectAsync($script:LocalProxyHost, $script:LocalProxyPort)
        if (-not $task.Wait($TimeoutMs)) {
            return [pscustomobject]@{
                TcpConnected = $false; Error = "TCP connection timed out after $TimeoutMs ms."
                SocketError = 'TimedOut'; NativeErrorCode = [int][Net.Sockets.SocketError]::TimedOut
            }
        }
        return [pscustomobject]@{ TcpConnected = $true; Error = ''; SocketError = ''; NativeErrorCode = 0 }
    }
    catch {
        $cause = $_.Exception.GetBaseException()
        $socketError = 'Unknown'
        $nativeCode = 0
        if ($cause -is [Net.Sockets.SocketException]) {
            $socketError = $cause.SocketErrorCode.ToString()
            $nativeCode = $cause.NativeErrorCode
        }
        return [pscustomobject]@{ TcpConnected = $false; Error = $cause.Message; SocketError = $socketError; NativeErrorCode = $nativeCode }
    }
    finally { $client.Dispose() }
}

function Test-LocalProxy {
    return [bool](Test-LocalProxyConnection).TcpConnected
}

function Wait-LocalProxy([ValidateRange(1, 10)][int]$MaxAttempts = 6, [ValidateRange(0, 5000)][int]$RetryDelayMs = 2000) {
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $probe = Test-LocalProxyConnection
        if ($probe.TcpConnected) {
            if ($attempt -gt 1) { Write-Status 'OK' "Local proxy $($script:LocalProxyHost):$($script:LocalProxyPort) is ready after $attempt checks." }
            return $true
        }
        $details = "$($probe.SocketError), code=$($probe.NativeErrorCode): $($probe.Error)"
        if ($attempt -lt $MaxAttempts) {
            Write-Status 'WARN' "Local proxy $($script:LocalProxyHost):$($script:LocalProxyPort) check $attempt/$MaxAttempts failed ($details); retrying in $RetryDelayMs ms."
            Start-Sleep -Milliseconds $RetryDelayMs
        }
        else {
            Write-Status 'ERROR' "Local proxy $($script:LocalProxyHost):$($script:LocalProxyPort) is unavailable after $MaxAttempts checks ($details). Check that your proxy application is running and its HTTP/mixed port matches $script:LocalProxyPort. Existing tunnels were left unchanged."
        }
    }
    return $false
}

function Get-ProxyConnectAuthority {
    $hostPart = $script:ProbeHost
    if ($hostPart.Contains(':')) { $hostPart = '[' + $hostPart + ']' }
    return '{0}:{1}' -f $hostPart, $script:ProbePort
}

function Test-LocalProxyHttp {
    $client = New-TunnelProxyClient
    $connected = $false
    try {
        $task = $client.ConnectAsync($script:LocalProxyHost, $script:LocalProxyPort)
        if (-not $task.Wait(2000)) { throw 'TCP connection timed out.' }
        $connected = $true
        $stream = $client.GetStream()
        $stream.WriteTimeout = 2000
        $authority = Get-ProxyConnectAuthority
        $request = [Text.Encoding]::ASCII.GetBytes("CONNECT $authority HTTP/1.1`r`nHost: $authority`r`n`r`n")
        $stream.Write($request, 0, $request.Length)
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $buffer = New-Object byte[] 256
        $response = ''
        while (-not $response.Contains("`r`n") -and $response.Length -lt 2048) {
            $remaining = 6000 - [int]$timer.ElapsedMilliseconds
            if ($remaining -le 0) { throw 'HTTP proxy response timed out.' }
            $stream.ReadTimeout = $remaining
            $count = $stream.Read($buffer, 0, $buffer.Length)
            if ($count -eq 0) { break }
            $response += [Text.Encoding]::ASCII.GetString($buffer, 0, $count)
        }
        if ($response -notmatch '^HTTP/\d+(?:\.\d+)? ([1-5]\d{2})(?:\s|$)') { throw 'No valid HTTP proxy response.' }
        return [pscustomobject]@{ Responded = $true; TcpConnected = $connected; Status = [int]$Matches[1]; Error = '' }
    }
    catch {
        return [pscustomobject]@{ Responded = $false; TcpConnected = $connected; Status = 0; Error = $_.Exception.GetBaseException().Message }
    }
    finally { $client.Dispose() }
}

function Test-RemoteProxy([string]$Alias) {
    if (-not (Test-TunnelAlias $Alias)) { throw 'Invalid SSH alias.' }
    # Every diagnostic SSH connection disables forwarding.
    # An HTTP error still proves the proxy transport responded: do not restart
    # a live tunnel just because the proxy cannot reach the test destination.
    $probeConfig = @{ port = $script:RemotePort; authority = (Get-ProxyConnectAuthority) } | ConvertTo-Json -Compress
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($probeConfig))
    $python = @'
import base64, errno, json, re, socket, time
settings = json.loads(base64.b64decode('__SETTINGS__'))
connected = False
try:
    with socket.create_connection(('127.0.0.1', settings['port']), 4) as connection:
        connected = True
        deadline = time.monotonic() + 6
        connection.settimeout(6)
        authority = settings['authority']
        connection.sendall(('CONNECT ' + authority + ' HTTP/1.1\r\nHost: ' + authority + '\r\n\r\n').encode('ascii'))
        data = b''
        while b'\r\n' not in data and len(data) < 2048:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError('HTTP proxy response timed out')
            connection.settimeout(remaining)
            chunk = connection.recv(256)
            if not chunk:
                break
            data += chunk
        match = re.match(rb'^HTTP/\d+(?:\.\d+)? ([1-5]\d{2})(?:\s|$)', data)
        status = int(match.group(1)) if match else 0
        print('TUNNEL_CHECK ' + json.dumps({'responded': status > 0, 'connected': connected, 'status': status, 'error': '' if status else 'No HTTP proxy response', 'refused': False}))
except Exception as error:
    print('TUNNEL_CHECK ' + json.dumps({'responded': False, 'connected': connected, 'status': 0, 'error': str(error), 'refused': not connected and getattr(error, 'errno', None) == errno.ECONNREFUSED}))
'@
    $python = $python.Replace('__SETTINGS__', $encoded)
    $arguments = @('-T', '-S', 'none', '-F', $script:ConfigFile,
        '-o', 'BatchMode=yes', '-o', 'ClearAllForwardings=yes', '-o', 'ControlMaster=no', '-o', 'ControlPersist=no',
        '-o', 'ForwardAgent=no', '-o', 'ForwardX11=no', '-o', 'RemoteCommand=none', '-o', 'SessionType=default',
        '-o', 'ForkAfterAuthentication=no', '-o', 'StdinNull=no', '-o', 'ConnectTimeout=5', '-o', 'ConnectionAttempts=1',
        $Alias, 'python3', '-')
    $result = Invoke-SshProbe -Arguments $arguments -InputText $python
    if ($result.ExitCode -ne 0) {
        return [pscustomobject]@{ Responded = $false; TcpConnected = $false; Status = 0; Error = "SSH check failed: $($result.Error.Trim())"; SshFailed = $true; ConnectionRefused = $false }
    }
    $line = @($result.Output -split '\r?\n' | Where-Object { $_.StartsWith('TUNNEL_CHECK ') }) | Select-Object -Last 1
    if (-not $line) {
        return [pscustomobject]@{ Responded = $false; TcpConnected = $false; Status = 0; Error = 'Remote check produced no result; python3 is required.'; SshFailed = $true; ConnectionRefused = $false }
    }
    $probe = $line.Substring(13) | ConvertFrom-Json
    return [pscustomobject]@{ Responded = [bool]$probe.responded; TcpConnected = [bool]$probe.connected; Status = [int]$probe.status; Error = [string]$probe.error; SshFailed = $false; ConnectionRefused = [bool]$probe.refused }
}

. (Join-Path $PSScriptRoot 'Tunnel-Config.ps1')
. (Join-Path $PSScriptRoot 'Tunnel-Logs.ps1')
. (Join-Path $PSScriptRoot 'Tunnel-Runtime.ps1')
. (Join-Path $PSScriptRoot 'Tunnel-Launcher.ps1')

if ($LibraryOnly) { return }
try {
    $settings = Initialize-TunnelApplication @entryOptions
    if ($ListHosts) {
        Write-Host "SSH configuration: $($settings.SshConfigPath)"
        foreach ($hostAlias in $settings.AvailableHosts) { Write-Output $hostAlias }
        Write-Host 'Discovery lists literal Host entries from Includes; Match and wildcard-only hosts may require an explicit -Targets alias.'
        exit 0
    }
    if ($Configure) { Write-Host "Configuration saved: $($settings.ConfigPath)"; exit 0 }
    Write-Host "SSH configuration: $script:ConfigFile"
    Write-Host "Selected servers: $($script:Targets -join ', ')"
    exit (Invoke-TunnelLauncher)
}
catch { Write-Host $_.Exception.Message -ForegroundColor Red; exit 1 }
