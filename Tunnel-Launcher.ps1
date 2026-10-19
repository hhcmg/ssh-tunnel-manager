function Start-TunnelWorker([string]$Alias) {
    $arguments = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
        (Join-Path $script:Root 'Tunnel-Worker.ps1'), '-Alias', $Alias,
        '-SshConfigPath', $script:ConfigFile, '-SshExecutable', $script:SshExe,
        '-LocalProxyHost', $script:LocalProxyHost, '-LocalProxyPort', [string]$script:LocalProxyPort,
        '-RemotePort', [string]$script:RemotePort, '-ProbeHost', $script:ProbeHost, '-ProbePort', [string]$script:ProbePort,
        '-DataDirectory', $script:DataRoot, '-ContextId', $script:ContextId)
    return Start-Process -FilePath $script:PowerShellExe -ArgumentList (($arguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ') -WindowStyle Hidden -PassThru
}

function Test-TunnelWorkerMutex([string]$Alias) {
    $mutex = $null
    $taken = $false
    try {
        $mutex = [Threading.Mutex]::OpenExisting('Local\SshTunnelWorker-' + $script:UserSid + '-' + $script:ContextId + '-' + $Alias.ToLowerInvariant())
        try { $taken = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $taken = $true }
        return -not $taken
    }
    catch [Threading.WaitHandleCannotBeOpenedException] { return $false }
    finally {
        if ($taken) { $mutex.ReleaseMutex() }
        if ($mutex) { $mutex.Dispose() }
    }
}

function Ensure-Tunnel([string]$Alias) {
    [void](Get-TargetConfig $Alias)
    $status = Get-WorkerStatus $Alias
    for ($readAttempt = 0; -not $status -and $readAttempt -lt 2; $readAttempt++) {
        Start-Sleep -Milliseconds 50
        $status = Get-WorkerStatus $Alias
    }
    $worker = Get-WorkerProcess $status
    if ($worker -and -not $CheckOnly) {
        $age = ([DateTime]::UtcNow - ([DateTime]$status.UpdatedUtc).ToUniversalTime()).TotalSeconds
        if ($age -gt 60) {
            # A locked status file is not evidence that its live worker is hung.
            Write-Status 'WARN' "$Alias status file is stale, but its worker is still running. Keeping the worker; check access to $Alias.worker.json."
            return $false
        }
    }
    if (-not $worker) {
        if (Test-TunnelWorkerMutex $Alias) {
            Write-Status 'WARN' "$Alias worker is running but its status file cannot be verified. Keeping the worker; retry the check after the file becomes available."
            return $false
        }
        if ($CheckOnly) { Write-Status 'ERROR' "$Alias has no active background worker."; return $false }
        $worker = Start-TunnelWorker $Alias
        Write-Status 'INFO' "$Alias recovery worker starting; PID=$($worker.Id)."
    }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $reconnectRequested = $false
    $lastError = 'Waiting for the remote guard to become ready.'
    while ($timer.Elapsed.TotalSeconds -lt 60) {
        $status = Get-WorkerStatus $Alias
        $owner = Get-WorkerProcess $status
        if (Test-WorkerReady $status) {
            $probe = Test-RemoteProxy $Alias
            if ($probe.Responded) {
                $current = Get-WorkerStatus $Alias
                if ((Test-WorkerReady $current) -and $current.WorkerPid -eq $status.WorkerPid -and
                    $current.WorkerStartUtcTicks -eq $status.WorkerStartUtcTicks -and $current.Token -ceq $status.Token) {
                    $level = if ($probe.Status -eq 200) { 'OK' } else { 'WARN' }
                    Write-Status $level "$Alias ready; SSH PID=$($current.SshPid); worker PID=$($current.WorkerPid); proxy CONNECT HTTP $($probe.Status)."
                    if ($script:RequireProxySuccess -and $probe.Status -ne 200) { return $false }
                    return $true
                }
                $lastError = 'The worker changed SSH sessions during the check; waiting for its current session.'
                if ($CheckOnly) { break }
                Start-Sleep -Seconds 1
                continue
            }
            $lastError = $probe.Error
            if (-not $CheckOnly -and -not $reconnectRequested -and -not $probe.SshFailed) {
                $local = Test-LocalProxyHttp
                if ($local.Responded -and $local.Status -eq 200) {
                    Request-TunnelReconnect $Alias $status.Token
                    $reconnectRequested = $true
                    Write-Status 'WARN' "$Alias proxy transport did not respond; its worker is reconnecting the owned session."
                }
            }
        }
        elseif ($status -and $status.LastError) { $lastError = $status.LastError }
        if ($CheckOnly) { break }
        $worker.Refresh()
        if ($worker.HasExited -and -not $owner) {
            Write-Status 'ERROR' "$Alias background worker exited. See $Alias.worker.log in $($script:LogRoot)."
            return $false
        }
        Start-Sleep -Seconds 1
    }
    Write-Status 'WARN' "$Alias is not ready yet: $lastError The background worker will continue retrying automatically. Log: $(Join-Path $script:LogRoot "$Alias.worker.log")"
    return $false
}

function Invoke-TunnelChecks {
    if (-not (Wait-LocalProxy)) { return 1 }
    $code = 0
    foreach ($alias in $script:Targets) {
        try { if (-not (Ensure-Tunnel $alias)) { $code = 1 } }
        catch { Write-Status 'ERROR' "$alias : $($_.Exception.Message)"; $code = 1 }
    }
    Write-Host ''
    Write-Host 'Checks complete. Background workers keep the tunnels connected after this window closes.'
    Write-Host "Logs: $($script:LogRoot)"
    return $code
}

function Invoke-TunnelLauncher {
    $mutex = New-Object Threading.Mutex($false, ('Local\SshTunnelLauncher-' + $script:UserSid + '-' + $script:ContextId))
    $taken = $false
    try {
        try { $taken = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $taken = $true }
        if (-not $taken) { Write-Host 'Another tunnel check is already running; this invocation did not check the selected servers.'; return 1 }
        if (-not (Test-Path -LiteralPath $script:SshExe)) { throw "OpenSSH client not found: $($script:SshExe)" }
        if (-not (Test-Path -LiteralPath $script:ConfigFile)) { throw "SSH config not found: $($script:ConfigFile)" }
        return Invoke-TunnelChecks
    }
    catch {
        $failure = $_.Exception.Message
        try { Write-Status 'ERROR' $failure } catch { Write-Host $failure -ForegroundColor Red }
        return 1
    }
    finally { if ($taken) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
}
