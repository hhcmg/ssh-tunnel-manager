# Shared runtime for the launcher and its per-host background workers.
$script:PowerShellExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'

function ConvertFrom-GuardReady([string]$Line, [string]$ExpectedToken) {
    if (-not $Line -or -not $Line.StartsWith('TUNNEL_GUARD ')) { return $null }
    try {
        $ready = $Line.Substring(13) | ConvertFrom-Json
        if ($ready.event -cne 'ready' -or $ready.token -cne $ExpectedToken -or
            [int]$ready.guardpid -le 1 -or [int]$ready.sshdpid -le 1 -or
            [int]$ready.guardpid -eq [int]$ready.sshdpid -or
            [string]$ready.startticks -notmatch '^[1-9][0-9]*$' -or
            [string]$ready.bootid -notmatch '^[0-9a-fA-F-]{36}$') { return $null }
        return $ready
    }
    catch { return $null }
}

function Start-GuardedSsh([string]$Alias, [string]$Token, [int]$LeaseSeconds = 30, [string]$LogPath,
    [switch]$TestForward, [int]$RemotePort = $script:RemotePort) {
    if (-not (Test-TunnelAlias $Alias)) { throw 'Invalid tunnel alias.' }
    if ($Token -notmatch '^[0-9a-f]{32}$' -or $LeaseSeconds -lt 5 -or $LeaseSeconds -gt 300) { throw 'Invalid tunnel lease parameters.' }
    if ($TestForward) {
        if ($RemotePort -lt 1024 -or $RemotePort -gt 65535 -or $RemotePort -eq $script:RemotePort) { throw 'Use an isolated high port for fault injection.' }
        $config = Invoke-SshProbe -Arguments @('-G', '-F', $script:ConfigFile, '-o', 'ClearAllForwardings=no', $Alias)
        if ($config.ExitCode -ne 0 -or $config.Output -match '(?m)^(remote|local|dynamic)forward ') { throw 'Test alias must not configure any port forwarding.' }
    }
    else { $config = Get-TargetConfig $Alias }
    $source = [IO.File]::ReadAllText((Join-Path $script:Root 'tunnel_guard.py'))
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($source))
    $loader = 'import base64;exec(base64.b64decode("{0}"))' -f $encoded
    $remote = "exec python3 -u -c '$loader' $Token $LeaseSeconds"
    # A guard must own a dedicated SSH connection, never a multiplexed editor session.
    $arguments = @('-T', '-F', $script:ConfigFile, '-S', 'none', '-o', 'ControlMaster=no',
        '-o', 'ControlPersist=no', '-o', 'BatchMode=yes', '-o', 'ExitOnForwardFailure=yes',
        '-o', 'ClearAllForwardings=no', '-o', 'RemoteCommand=none', '-o', 'SessionType=default',
        '-o', 'ForwardAgent=no', '-o', 'ForwardX11=no',
        '-o', 'ForkAfterAuthentication=no', '-o', 'StdinNull=no',
        '-o', 'ServerAliveInterval=10', '-o', 'ServerAliveCountMax=3',
        '-o', 'ConnectTimeout=8', '-o', 'ConnectionAttempts=1', '-E', $LogPath)
    if ($TestForward -or -not $config.HasRemoteForward) {
        $forwardHost = $script:LocalProxyHost
        if ($forwardHost.Contains(':')) { $forwardHost = '[' + $forwardHost + ']' }
        $arguments += @('-R', ('127.0.0.1:{0}:{1}:{2}' -f $RemotePort, $forwardHost, $script:LocalProxyPort))
    }
    $arguments += @($Alias, $remote)
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $script:SshExe
    $info.Arguments = ($arguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' '
    if ($info.Arguments.Length -gt 30000) { throw 'Remote guard exceeds the Windows command-line limit.' }
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    try {
        [void]$process.Start()
        [void]$process.Handle
        $process.StandardInput.AutoFlush = $true
        return [pscustomobject]@{
            Process = $process; Token = $Token; OutputTask = $process.StandardOutput.ReadLineAsync()
            ErrorTask = $process.StandardError.ReadToEndAsync(); Guard = $null; Ready = $false; LogPath = $LogPath
        }
    }
    catch { $process.Dispose(); throw }
}

function Receive-GuardReady($Session) {
    if ($Session.Ready) { return $true }
    while ($Session.OutputTask -and $Session.OutputTask.IsCompleted) {
        $line = $Session.OutputTask.GetAwaiter().GetResult()
        if ($null -eq $line) { return $false }
        $ready = ConvertFrom-GuardReady $line $Session.Token
        if ($ready) { $Session.Guard = $ready; $Session.Ready = $true; return $true }
        $Session.OutputTask = $Session.Process.StandardOutput.ReadLineAsync()
    }
    return $false
}

function Send-TunnelHeartbeat($Session) {
    $write = $Session.Process.StandardInput.WriteLineAsync($Session.Token)
    if (-not $write.Wait(2000)) { throw 'SSH heartbeat pipe did not accept data within 2 seconds.' }
    [void]$write.GetAwaiter().GetResult()
}

function Stop-GuardedSsh($Session) {
    if (-not $Session) { return }
    try { $Session.Process.StandardInput.Close() } catch { }
    try {
        if (-not $Session.Process.WaitForExit(2000)) {
            $Session.Process.Kill()
            [void]$Session.Process.WaitForExit(2000)
        }
        if ($Session.ErrorTask.IsCompleted) {
            $errorText = $Session.ErrorTask.GetAwaiter().GetResult()
            if ($errorText) { try { Add-Content -LiteralPath $Session.LogPath -Value $errorText -Encoding UTF8 } catch { } }
        }
    }
    finally { $Session.Process.Dispose() }
}

function Get-WorkerStatus([string]$Alias) {
    if (-not (Test-TunnelAlias $Alias)) { throw 'Invalid tunnel alias.' }
    $file = $null
    $reader = $null
    try {
        # Readers keep a complete snapshot while allowing the worker to replace
        # the pathname. Get-Content's sharing mode can block ReplaceFile on Windows.
        $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
        $file = [IO.File]::Open((Join-Path $script:DataRoot "$Alias.worker.json"), [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
        $reader = New-Object IO.StreamReader($file)
        $status = ConvertFrom-Json -InputObject $reader.ReadToEnd() -ErrorAction Stop
        if ($status.Version -ne 2 -or $status.Alias -ine $Alias -or $status.ContextId -cne $script:ContextId) { return $null }
        return $status
    }
    catch { return $null }
    finally {
        try {
            if ($reader) { $reader.Dispose() }
            elseif ($file) { $file.Dispose() }
        }
        catch { }
    }
}

function Get-WorkerProcess($Status) {
    if (-not $Status) { return $null }
    try {
        if ($Status.Version -ne 2 -or -not (Test-TunnelAlias $Status.Alias) -or
            $Status.ContextId -cne $script:ContextId -or $Status.WorkerToken -notmatch '^[0-9a-f]{32}$' -or
            $Status.WorkerExe -ine $script:PowerShellExe) { return $null }
        $process = Get-Process -Id ([int]$Status.WorkerPid) -ErrorAction Stop
        if ($process.Path -ine $script:PowerShellExe -or
            $process.StartTime.ToUniversalTime().Ticks.ToString() -ne [string]$Status.WorkerStartUtcTicks) { return $null }
        return $process
    }
    catch { return $null }
}

function Test-WorkerReady($Status) {
    try {
        if (-not (Get-WorkerProcess $Status) -or $Status.State -ne 'ready' -or
            $Status.Token -notmatch '^[0-9a-f]{32}$' -or $Status.Guard.token -cne $Status.Token) { return $false }
        $age = ([DateTime]::UtcNow - ([DateTime]$Status.UpdatedUtc).ToUniversalTime()).TotalSeconds
        if ($age -lt -5 -or $age -ge 30) { return $false }
        $ssh = Get-Process -Id ([int]$Status.SshPid) -ErrorAction Stop
        return $ssh.Path -ieq $script:SshExe -and
            $ssh.StartTime.ToUniversalTime().Ticks.ToString() -eq [string]$Status.SshStartUtcTicks
    }
    catch { return $false }
}

function Write-WorkerStatus([string]$Alias, $Status) {
    if (-not (Test-TunnelAlias $Alias)) { throw 'Invalid tunnel alias.' }
    $temp = $null
    try {
        $path = Join-Path $script:DataRoot "$Alias.worker.json"
        $temp = $path + ".$PID." + [guid]::NewGuid().ToString('N') + '.new'
        $json = $Status | ConvertTo-Json -Depth 6 -ErrorAction Stop
        [IO.File]::WriteAllText($temp, $json, (New-Object Text.UTF8Encoding($false)))
        # Commit once. Never delete the old snapshot or wait for a reader/AV
        # lock: the next status publication can retry without delaying heartbeats.
        if ([IO.File]::Exists($path)) { [IO.File]::Replace($temp, $path, [System.Management.Automation.Language.NullString]::Value) }
        else { [IO.File]::Move($temp, $path) }
        return $true
    }
    catch { return $false }
    finally {
        if ($temp) { try { [IO.File]::Delete($temp) } catch { } }
    }
}

function Request-TunnelReconnect([string]$Alias, [string]$Token) {
    if (-not (Test-TunnelAlias $Alias) -or $Token -notmatch '^[0-9a-f]{32}$') { throw 'Invalid reconnect request.' }
    $path = Join-Path $script:DataRoot "$Alias.reconnect"
    [IO.File]::WriteAllText($path, $Token, (New-Object Text.UTF8Encoding($false)))
}

function Request-TunnelStop([string]$Alias, [string]$WorkerToken) {
    if (-not (Test-TunnelAlias $Alias) -or $WorkerToken -notmatch '^[0-9a-f]{32}$') { throw 'Invalid stop request.' }
    $status = Get-WorkerStatus $Alias
    if (-not $status -or $status.WorkerToken -cne $WorkerToken -or -not (Get-WorkerProcess $status)) {
        throw 'The worker identity changed or could not be verified; no stop request was issued.'
    }
    $path = Join-Path $script:DataRoot "$Alias.stop"
    if (Test-Path -LiteralPath $path) {
        $existing = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if ($existing.PSIsContainer -or ($existing.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Refusing to write through an unsafe stop request path.' }
    }
    [IO.File]::WriteAllText($path, $WorkerToken, (New-Object Text.UTF8Encoding($false)))
}

function Receive-TunnelRequest([string]$Alias, [ValidateSet('stop', 'reconnect')][string]$Kind, [string]$ExpectedToken) {
    if (-not (Test-TunnelAlias $Alias) -or $ExpectedToken -notmatch '^[0-9a-f]{32}$') { return $false }
    $path = Join-Path $script:DataRoot "$Alias.$Kind"
    try {
        if (-not [IO.File]::Exists($path)) { return $false }
        $request = [IO.File]::ReadAllText($path).Trim()
        [IO.File]::Delete($path)
        return $request -ceq $ExpectedToken
    }
    catch { return $false }
}

function Stop-TunnelWorkers([string[]]$Aliases = $script:Targets, [ValidateRange(1, 60)][int]$TimeoutSeconds = 15) {
    $allStopped = $true
    $pending = @()
    foreach ($alias in $Aliases) {
        $status = Get-WorkerStatus $alias
        if (-not (Get-WorkerProcess $status)) {
            if (Test-TunnelWorkerMutex $alias) {
                $allStopped = $false
                Write-Status 'WARN' "$alias has a running worker whose status cannot be verified (possibly another installation); no stop request was issued."
            }
            else { Write-Status 'INFO' "$alias has no running worker in this configuration." }
            continue
        }
        try {
            Request-TunnelStop $alias $status.WorkerToken
            $pending += $status
            Write-Status 'INFO' "$alias graceful stop requested."
        }
        catch { $allStopped = $false; Write-Status 'ERROR' "$alias stop request failed: $($_.Exception.Message)" }
    }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($pending.Count -gt 0 -and $timer.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $pending = @($pending | Where-Object { Get-WorkerProcess $_ })
        if ($pending.Count -gt 0) { Start-Sleep -Milliseconds 250 }
    }
    foreach ($status in $pending) {
        $allStopped = $false
        Write-Status 'WARN' "$($status.Alias) has not exited within $TimeoutSeconds seconds; its stop request remains pending."
    }
    return $allStopped
}

function Stop-AllTunnelWorkers([ValidateRange(1, 60)][int]$TimeoutSeconds = 15) {
    # Discover only direct children of this installation's runtime directory.
    # SSH config/executables are deliberately not resolved: they may have moved.
    $projectPath = [IO.Path]::GetFullPath($script:Root).TrimEnd([char[]]'\/')
    $runtimePath = Join-Path $projectPath '.runtime'
    $project = Get-Item -LiteralPath $projectPath -Force -ErrorAction Stop
    if (-not $project.PSIsContainer -or ($project.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Refusing to discover workers through a reparse project directory.'
    }
    if (-not (Test-Path -LiteralPath $runtimePath)) {
        Write-Host 'This project has no recorded workers.'
        return $true
    }
    $runtime = Get-Item -LiteralPath $runtimePath -Force -ErrorAction Stop
    if (-not $runtime.PSIsContainer -or ($runtime.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Refusing to discover workers through a non-directory or reparse runtime path.'
    }
    $allStopped = $true
    $recorded = 0
    foreach ($context in @(Get-ChildItem -LiteralPath $runtimePath -Force -ErrorAction Stop)) {
        if ($context.Name -cnotmatch '^[0-9a-f]{24}$' -or -not $context.PSIsContainer) { continue }
        if ($context.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            Write-Host "Skipped reparse context directory: $($context.Name)" -ForegroundColor Yellow
            $allStopped = $false
            continue
        }
        $script:ContextId = $context.Name
        $script:DataRoot = $context.FullName
        $script:LogRoot = Join-Path $script:DataRoot 'logs'
        $script:EventLog = Join-Path $script:LogRoot 'tunnels.log'
        if (Test-Path -LiteralPath $script:LogRoot) {
            $logs = Get-Item -LiteralPath $script:LogRoot -Force -ErrorAction Stop
            if (-not $logs.PSIsContainer -or ($logs.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                Write-Host "Skipped context with an unsafe log directory: $($context.Name)" -ForegroundColor Yellow
                $allStopped = $false
                continue
            }
        }
        if (Test-Path -LiteralPath $script:EventLog) {
            $eventFile = Get-Item -LiteralPath $script:EventLog -Force -ErrorAction Stop
            if ($eventFile.PSIsContainer -or ($eventFile.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                Write-Host "Skipped context with an unsafe event log: $($context.Name)" -ForegroundColor Yellow
                $allStopped = $false
                continue
            }
        }
        $aliases = @()
        foreach ($entry in @(Get-ChildItem -LiteralPath $script:DataRoot -Force -ErrorAction Stop)) {
            if ($entry.PSIsContainer -or $entry.Name -notmatch '^(.+)\.worker\.json$') { continue }
            $alias = $Matches[1]
            if (-not (Test-TunnelAlias $alias)) { continue }
            if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                Write-Host "Skipped reparse worker state: $($entry.Name)" -ForegroundColor Yellow
                $allStopped = $false
                continue
            }
            $aliases += $alias
        }
        if ($aliases.Count -gt 0) {
            $script:Targets = $aliases
            $recorded += $aliases.Count
            if (-not (Stop-TunnelWorkers -Aliases $aliases -TimeoutSeconds $TimeoutSeconds)) { $allStopped = $false }
        }
    }
    if ($recorded -eq 0 -and $allStopped) { Write-Host 'This project has no recorded workers.' }
    return $allStopped
}
