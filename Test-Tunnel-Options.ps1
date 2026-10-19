[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Start-Tunnels.ps1') -LibraryOnly
$projectRoot = $PSScriptRoot
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('ssh-options-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
$sshConfigFixture = Join-Path $fixture 'ssh config'
$jsonFixture = Join-Path $fixture 'settings.json'
[IO.File]::WriteAllText($sshConfigFixture, "Host server-a server-b`n    HostName example.invalid`n    User testuser`n")
$configData = @{
    Version = 1; SshConfigPath = $sshConfigFixture; SshExecutable = $script:PowerShellExe
    Targets = @('server-a', 'server-b'); LocalProxyHost = '127.0.0.1'; LocalProxyPort = 18080
    RemotePort = 18081; ProbeHost = 'example.invalid'; ProbePort = 8443
}
[IO.File]::WriteAllText($jsonFixture, ($configData | ConvertTo-Json))
$script:Passed = 0
$script:Failed = 0

function Assert-True($Value, [string]$Message) { if (-not $Value) { throw $Message } }
function Assert-Equal($Expected, $Actual, [string]$Message) { if ($Expected -cne $Actual) { throw "$Message Expected <$Expected>; actual <$Actual>." } }
function Assert-Throws([scriptblock]$Body, [string]$Message) {
    $threw = $false
    try { & $Body } catch { $threw = $true }
    Assert-True $threw $Message
}
function Invoke-Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; $script:Passed++; Write-Host "PASS $Name" }
    catch { $script:Failed++; Write-Host "FAIL $Name : $($_.Exception.Message)" }
}
function Read-Host { throw 'Tests must never prompt.' }
function Invoke-SshProbe {
    param($Arguments, $InputText, $TimeoutMs)
    $script:ProbeArguments = $Arguments
    $script:ProbeInput = $InputText
    return [pscustomobject]@{ ExitCode = 0; Output = $script:EffectiveConfig; Error = '' }
}

try {
    Invoke-Case 'application initializer retains saved source and targets without CLI overrides' {
        $script:Root = $projectRoot
        $settings = Initialize-TunnelApplication -ConfigPath $jsonFixture -NonInteractive
        Assert-Equal $sshConfigFixture $settings.SshConfigPath 'Preserve stored SSH path.'
        Assert-Equal 'server-a,server-b' ($script:Targets -join ',') 'Preserve stored selection.'
        Assert-Equal 18081 $script:RemotePort 'Load configured port.'
        Assert-Equal 'example.invalid:8443' (Get-ProxyConnectAuthority) 'Load probe destination.'
        Assert-True ($script:ContextId -match '^[0-9a-f]{24}$') 'Produce a stable context identity.'
        $script:FirstContext = $script:ContextId
        Assert-True (-not [IO.Directory]::Exists($script:DataRoot)) 'Resolving settings does not create runtime files.'
    }
    Invoke-Case 'changing selection reuses context while changing connection settings isolates it' {
        [void](Initialize-TunnelApplication -ConfigPath $jsonFixture -Targets 'server-b' -NonInteractive)
        Assert-Equal $script:FirstContext $script:ContextId 'Subset selections must reuse existing worker state.'
        $different = Join-Path $fixture 'another ssh config'
        [IO.File]::Copy($sshConfigFixture, $different)
        [void](Initialize-TunnelApplication -ConfigPath $jsonFixture -SshConfig $different -NonInteractive)
        Assert-True ($script:FirstContext -ne $script:ContextId) 'A different SSH source must have distinct state.'
        [void](Initialize-TunnelApplication -ConfigPath $jsonFixture -NonInteractive)
    }
    Invoke-Case 'ordinary aliases need no configured RemoteForward' {
        $script:EffectiveConfig = "hostname server-a`nuser testuser`n"
        Assert-Equal $false (Get-TargetConfig 'server-a').HasRemoteForward 'Literal hostnames need not differ from aliases.'
        Assert-True ($script:ProbeArguments -contains $sshConfigFixture) 'Use the configured SSH file.'
    }
    Invoke-Case 'matching inherited remote forwards are accepted without duplication' {
        foreach ($listen in @('18081', '127.0.0.1:18081', '[127.0.0.1]:18081', 'localhost:18081')) {
            $script:EffectiveConfig = "hostname example.invalid`nremoteforward $listen [127.0.0.1]:18080`n"
            Assert-True (Get-TargetConfig 'server-a').HasRemoteForward 'Recognize the matching loopback forward.'
        }
    }
    Invoke-Case 'conflicting or unrelated forwards fail before process creation' {
        foreach ($forward in @(
            'localforward 8080 example.invalid:80', 'dynamicforward 1080',
            'remoteforward 0.0.0.0:18081 127.0.0.1:18080', 'remoteforward 18082 127.0.0.1:18080',
            'remoteforward 18081 127.0.0.2:18080', 'remoteforward /tmp/socket /tmp/other',
            "remoteforward 18081 127.0.0.1:18080`nremoteforward 19000 127.0.0.1:19000")) {
            $script:EffectiveConfig = "hostname example.invalid`n$forward`n"
            Assert-Throws { Get-TargetConfig 'server-a' } 'Unexpected forwards must be rejected.'
        }
        Assert-Throws { Get-TargetConfig '../escape' } 'Reject unsafe alias before evaluating SSH config.'
    }
    Invoke-Case 'guard command uses configured endpoints and quotes paths without starting a process' {
        function New-Object {
            param([string]$TypeName)
            if ($TypeName -ieq 'Diagnostics.Process') {
                $fake = [pscustomobject]@{ StartInfo = $null }
                $fake | Add-Member ScriptMethod Start { $script:CapturedStartInfo = $this.StartInfo; throw 'CAPTURE_ONLY' }
                $fake | Add-Member ScriptMethod Dispose { }
                return $fake
            }
            return Microsoft.PowerShell.Utility\New-Object -TypeName $TypeName
        }
        $script:EffectiveConfig = "hostname example.invalid`n"
        Assert-Throws { Start-GuardedSsh 'server-a' ('a' * 32) -LogPath (Join-Path $fixture 'ssh log') } 'Capture without starting SSH.'
        $arguments = $script:CapturedStartInfo.Arguments
        Assert-True ($arguments.Contains('127.0.0.1:18081:127.0.0.1:18080')) 'Use configured forward ports.'
        Assert-True ($arguments.Contains('"' + $sshConfigFixture + '"')) 'Quote the SSH config path containing spaces.'
        foreach ($option in @('ControlMaster=no', 'ControlPersist=no', 'ForwardAgent=no', 'ForwardX11=no', 'ExitOnForwardFailure=yes')) {
            Assert-True ($arguments.Contains($option)) "Retain $option."
        }
        $script:EffectiveConfig = "hostname example.invalid`nremoteforward 18081 127.0.0.1:18080`n"
        Assert-Throws { Start-GuardedSsh 'server-a' ('a' * 32) -LogPath (Join-Path $fixture 'ssh log') } 'Capture inherited forwarding.'
        Assert-True ($script:CapturedStartInfo.Arguments -notmatch '(?<!\S)-R\s') 'Do not create a second copy of an inherited forward.'
        $script:EffectiveConfig = "hostname example.invalid`n"
        $script:LocalProxyHost = '::1'
        Assert-Throws { Start-GuardedSsh 'server-a' ('a' * 32) -LogPath (Join-Path $fixture 'ssh log') } 'Capture IPv6 forwarding.'
        Assert-True ($script:CapturedStartInfo.Arguments.Contains('127.0.0.1:18081:[::1]:18080')) 'Bracket IPv6 target.'
        $script:LocalProxyHost = '127.0.0.1'
    }
    Invoke-Case 'diagnostics disable forwarding and use the selected remote port and probe destination' {
        $script:EffectiveConfig = 'TUNNEL_CHECK {"responded":true,"connected":true,"status":200,"error":"","refused":false}'
        $result = Test-RemoteProxy 'server-a'
        Assert-True $result.Responded 'Read the fake diagnostic response.'
        foreach ($option in @('ClearAllForwardings=yes', 'ControlMaster=no', 'ForwardAgent=no', 'ForwardX11=no', 'StdinNull=no')) {
            Assert-True ($script:ProbeArguments -contains $option) "Diagnostic must include $option."
        }
        Assert-True ($script:ProbeInput -match "b64decode\('([A-Za-z0-9+/=]+)'\)") 'Serialize remote settings as data.'
        $serialized = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Matches[1])) | ConvertFrom-Json
        Assert-Equal 18081 $serialized.port 'Probe the configured remote listener.'
        Assert-Equal 'example.invalid:8443' $serialized.authority 'Probe the configured destination.'
    }
    Invoke-Case 'worker launch forwards immutable settings and hides its window' {
        function Start-Process {
            param($FilePath, $ArgumentList, $WindowStyle, [switch]$PassThru)
            $script:WorkerLaunch = @{ FilePath = $FilePath; Arguments = $ArgumentList; WindowStyle = $WindowStyle }
            return [pscustomobject]@{ Id = 990001 }
        }
        [void](Start-TunnelWorker 'server-b')
        Assert-Equal 'Hidden' $script:WorkerLaunch.WindowStyle 'Background workers must not open windows.'
        foreach ($part in @('-Alias server-b', '-LocalProxyPort 18080', '-RemotePort 18081', '-ContextId ' + $script:ContextId)) {
            Assert-True ($script:WorkerLaunch.Arguments.Contains($part)) "Pass worker setting $part."
        }
    }
    Invoke-Case 'local proxy client supports loopback IPv4 and IPv6 without external connections' {
        $addresses = @([Net.IPAddress]::Loopback)
        if ([Net.Sockets.Socket]::OSSupportsIPv6) { $addresses += [Net.IPAddress]::IPv6Loopback }
        foreach ($address in $addresses) {
            $listener = New-Object Net.Sockets.TcpListener($address, 0)
            $client = $null
            $peer = $null
            try {
                $listener.Start()
                $accept = $listener.AcceptTcpClientAsync()
                $client = New-TunnelProxyClient
                Assert-True ($client.ConnectAsync($address.ToString(), $listener.LocalEndpoint.Port).Wait(2000)) 'Connect to an isolated loopback listener.'
                Assert-True ($accept.Wait(2000)) 'Accept the loopback client.'
                $peer = $accept.Result
            }
            finally {
                if ($peer) { $peer.Dispose() }
                if ($client) { $client.Dispose() }
                $listener.Stop()
            }
        }
    }
    Invoke-Case 'CMD ListHosts preserves saved settings and accepts comma-delimited target overrides' {
        $before = [IO.File]::ReadAllText($jsonFixture)
        $output = @(& (Join-Path $projectRoot 'Start-Tunnels.cmd') -ConfigPath $jsonFixture -ListHosts -Targets 'server-a,server-b' 2>&1)
        Assert-Equal 0 $LASTEXITCODE 'CMD wrapper must forward flags and return without pausing.'
        Assert-True (($output -join "`n") -match 'server-a') 'List discovered hosts.'
        Assert-Equal $before ([IO.File]::ReadAllText($jsonFixture)) 'ListHosts must not save the transient override.'
        Assert-True (-not [IO.Directory]::Exists($script:DataRoot)) 'No workers or runtime files are created by listing.'
    }
}
finally {
    foreach ($file in [IO.Directory]::GetFiles($fixture)) {
        if ([IO.Path]::GetDirectoryName($file) -ne $fixture) { throw 'Unexpected fixture path.' }
        [IO.File]::Delete($file)
    }
    [IO.Directory]::Delete($fixture, $false)
}
Write-Host "Options and entry-point tests: $script:Passed passed, $script:Failed failed."
if ($script:Failed -gt 0) { exit 1 }
exit 0
