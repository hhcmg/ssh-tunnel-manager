[CmdletBinding()]
param()

# Offline fixtures only: no SSH command is executed and no tunnel is started.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Tunnel-Config.ps1')
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('tunnel-config-' + [guid]::NewGuid().ToString('N'))
$originalUserProfile = $env:USERPROFILE
$originalFixtureEnv = $env:TUNNEL_CONFIG_FIXTURE
$script:Passed = 0
$script:Failed = 0
$script:Answers = @()
$script:PromptCount = 0
$utf8 = New-Object Text.UTF8Encoding($false)

function Assert-True($Value, [string]$Message) { if (-not $Value) { throw $Message } }
function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ($Expected -cne $Actual) { throw "$Message Expected <$Expected>; actual <$Actual>." }
}
function Assert-Throws([scriptblock]$Body, [string]$Pattern) {
    $caught = $false
    try { & $Body | Out-Null }
    catch {
        $caught = $true
        if ($_.Exception.Message -notmatch $Pattern) { throw "Unexpected error: $($_.Exception.Message)" }
    }
    if (-not $caught) { throw "Expected an error matching: $Pattern" }
}
function Write-Fixture([string]$Path, [string]$Text) {
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    [IO.File]::WriteAllText($Path, $Text, $utf8)
}
function New-SettingsFixture([hashtable]$Changes = @{}) {
    $values = [ordered]@{ Version = 1; SshConfigPath = 'config'; SshExecutable = 'ssh.exe'; Targets = @('server-a') }
    foreach ($name in $Changes.Keys) { $values[$name] = $Changes[$name] }
    Write-Fixture $settingsPath ($values | ConvertTo-Json -Depth 5)
}
function Read-Host([string]$Prompt) {
    $script:PromptCount++
    if ($script:Answers.Count -eq 0) { throw 'Unexpected interactive prompt in offline test.' }
    $answer = $script:Answers[0]
    if ($script:Answers.Count -eq 1) { $script:Answers = @() }
    else { $script:Answers = @($script:Answers[1..($script:Answers.Count - 1)]) }
    return $answer
}
function Reset-Fixture {
    if ([IO.Directory]::Exists($fixtureRoot)) {
        # Delete only this run's resolved, unique temporary fixture directory.
        $resolved = [IO.Path]::GetFullPath($fixtureRoot)
        $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        if (-not $resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'tunnel-config-*') {
            throw 'Refusing to remove a path outside this test fixture.'
        }
        [IO.Directory]::Delete($resolved, $true)
    }
    [void][IO.Directory]::CreateDirectory($fixtureRoot)
    $script:Answers = @()
    $script:PromptCount = 0
    $env:USERPROFILE = Join-Path $fixtureRoot 'profile'
    $env:TUNNEL_CONFIG_FIXTURE = $fixtureRoot
    Write-Fixture $sshConfig "Host server-a server-b`nHost * !excluded pattern-?`n"
    Write-Fixture $fakeSsh 'offline test executable placeholder; never executed'
    Write-Fixture (Join-Path $env:USERPROFILE '.ssh\config') "Host home-host`n"
}
function Invoke-TestCase([string]$Name, [scriptblock]$Body) {
    try { Reset-Fixture; & $Body; $script:Passed++; Write-Host "PASS $Name" -ForegroundColor Green }
    catch { $script:Failed++; Write-Host "FAIL $Name : $($_.Exception.Message)" -ForegroundColor Red }
}

$settingsPath = Join-Path $fixtureRoot 'tunnels.local.json'
$sshConfig = Join-Path $fixtureRoot 'config'
$fakeSsh = Join-Path $fixtureRoot 'ssh.exe'
try {
    Invoke-TestCase 'alias validation rejects injection, traversal, wildcards and Windows devices' {
        foreach ($valid in @('server-a', 'node_2', 'cluster.example', '7', ('a' * 128))) {
            Assert-True (Test-TunnelAlias $valid) "Expected valid alias: $valid"
        }
        foreach ($invalid in @('', '-oProxyCommand=x', '../host', '.hidden', 'a/b', 'a\b', 'a b', 'a;whoami', 'a"b', '*', '!host', 'host?', 'CON', 'aux.txt', 'COM1', ('a' * 129), "host`n", "host`r`n")) {
            Assert-True (-not (Test-TunnelAlias $invalid)) 'Unsafe alias must fail.'
        }
    }
    Invoke-TestCase 'discovery reads literal aliases, equals syntax, quoting and comments' {
        Write-Fixture $sshConfig "Host = bravo alpha`n  hOsT `"quoted-host`" alpha # note`nHost * !excluded subnet-?`nHostName ignored-host`nMatch host hidden-host`n"
        Assert-Equal 'alpha,bravo,quoted-host' ((Get-SshHostAliases $sshConfig) -join ',') 'Discover literal Host aliases only.'
    }
    Invoke-TestCase 'recursive Include uses user .ssh base, globs and cycle protection' {
        $includeRoot = Join-Path $env:USERPROFILE '.ssh'
        Write-Fixture $sshConfig "Include parts/*.conf`nInclude `"$sshConfig`"`nHost top`n"
        Write-Fixture (Join-Path $includeRoot 'parts\20.conf') "Host second`nInclude nested.conf`n"
        Write-Fixture (Join-Path $includeRoot 'parts\10.conf') "Host first`n"
        Write-Fixture (Join-Path $includeRoot 'nested.conf') "Host nested`nInclude parts/*.conf`n"
        Write-Fixture (Join-Path $fixtureRoot 'parts\30.conf') "Host wrong-relative-base`n"
        Assert-Equal 'first,nested,second,top' ((Get-SshHostAliases $sshConfig) -join ',') 'Resolve all nested Includes without looping.'
    }
    Invoke-TestCase 'Include lexical order is deterministic and unmatched globs are harmless' {
        $includeRoot = Join-Path $env:USERPROFILE '.ssh'
        Write-Fixture $sshConfig 'Include parts/*.conf absent/*.conf'
        Write-Fixture (Join-Path $includeRoot 'parts\20.conf') 'Host Alias'
        Write-Fixture (Join-Path $includeRoot 'parts\10.conf') 'Host alias'
        Assert-Equal 'alias' ((Get-SshHostAliases $sshConfig) -join ',') 'First lexical file wins casing for duplicate aliases.'
    }
    Invoke-TestCase 'quoted Include paths and environment expansion work' {
        $included = Join-Path $fixtureRoot 'folder with spaces\hosts.conf'
        Write-Fixture $included 'Host included'
        Write-Fixture $sshConfig 'Include "%TUNNEL_CONFIG_FIXTURE%/folder with spaces/hosts.conf"'
        Assert-Equal 'included' ((Get-SshHostAliases $sshConfig) -join ',') 'Read a quoted path containing spaces.'
    }
    Invoke-TestCase 'default values and JSON-relative paths resolve correctly' {
        New-SettingsFixture
        $items = @(Resolve-TunnelSettings -Root $fixtureRoot -NonInteractive)
        Assert-Equal 1 $items.Count 'Return one settings object.'
        $settings = $items[0]
        Assert-Equal $sshConfig $settings.SshConfigPath 'Resolve SSH path against JSON directory.'
        Assert-Equal $fakeSsh $settings.SshExecutable 'Resolve executable against JSON directory.'
        Assert-Equal $settingsPath $settings.ConfigPath 'Use the project-local settings filename.'
        Assert-Equal 7897 $settings.LocalProxyPort 'Default proxy port.'
        Assert-Equal 7897 $settings.RemotePort 'Default remote port.'
        Assert-Equal 443 $settings.ProbePort 'Default probe port.'
        Assert-Equal '127.0.0.1' $settings.LocalProxyHost 'Default proxy host.'
        Assert-Equal 'www.microsoft.com' $settings.ProbeHost 'Default probe host.'
        Assert-Equal 'server-a,server-b' ($settings.AvailableHosts -join ',') 'Include discovery results.'
    }
    Invoke-TestCase 'CLI overrides targets and SSH file without persisting' {
        New-SettingsFixture
        $alternative = Join-Path $fixtureRoot 'alternative'
        Write-Fixture $alternative 'Host chosen'
        $before = [IO.File]::ReadAllText($settingsPath)
        $settings = Resolve-TunnelSettings -Root $fixtureRoot -Targets chosen -SshConfig alternative -NonInteractive
        Assert-Equal 'chosen' ($settings.Targets -join ',') 'Explicit targets override JSON.'
        Assert-Equal $alternative $settings.SshConfigPath 'Explicit SSH path overrides JSON.'
        Assert-Equal $before ([IO.File]::ReadAllText($settingsPath)) 'Transient CLI overrides must not rewrite settings.'
    }
    Invoke-TestCase 'CLI comma-separated targets support CMD and mixed PowerShell array forms' {
        New-SettingsFixture
        $before = [IO.File]::ReadAllText($settingsPath)
        $settings = Resolve-TunnelSettings -Root $fixtureRoot -Targets 'server-a, server-b' -NonInteractive
        Assert-Equal 'server-a,server-b' ($settings.Targets -join ',') 'Split comma-delimited native CLI argument.'
        $settings = Resolve-TunnelSettings -Root $fixtureRoot -Targets @(' server-b,server-a ', 'server-c', 'server-b') -NonInteractive
        Assert-Equal 'server-b,server-a,server-c' ($settings.Targets -join ',') 'Normalize CLI elements, trim whitespace and deduplicate.'
        Assert-Equal $before ([IO.File]::ReadAllText($settingsPath)) 'CLI normalization must not rewrite settings.'
    }
    Invoke-TestCase 'CLI normalization rejects blanks and injection while JSON aliases stay strict' {
        New-SettingsFixture
        foreach ($invalid in @(',server-a', 'server-a,', 'server-a,,server-b', 'server-a,   ,server-b', "server-a`n,server-b", 'server-a,-oProxyCommand=bad', 'server-a,../bad')) {
            Assert-Throws { Resolve-TunnelSettings -Root $fixtureRoot -Targets $invalid -NonInteractive } 'alias|target|Targets'
        }
        foreach ($invalid in @('server-a,server-b', ' server-a ', "server-a`n")) {
            New-SettingsFixture @{ Targets = @($invalid) }
            Assert-Throws { Resolve-TunnelSettings -Root $fixtureRoot -NonInteractive } 'target'
        }
        Assert-Equal 0 $script:PromptCount 'Invalid CLI and JSON input must fail without prompting.'
    }
    Invoke-TestCase 'tilde and environment paths expand without evaluation' {
        foreach ($path in @('~/.ssh/config', '%USERPROFILE%/.ssh/config', '${USERPROFILE}/.ssh/config', '$env:USERPROFILE/.ssh/config')) {
            New-SettingsFixture @{ SshConfigPath = $path }
            $settings = Resolve-TunnelSettings -Root $fixtureRoot -NonInteractive
            Assert-Equal ([IO.Path]::GetFullPath((Join-Path $env:USERPROFILE '.ssh\config'))) $settings.SshConfigPath 'Expand user-profile notation.'
        }
    }
    Invoke-TestCase 'manual aliases need not appear in static discovery and duplicates collapse' {
        New-SettingsFixture @{ Targets = @('wildcard-instance', 'Wildcard-Instance', 'match-host') }
        $settings = Resolve-TunnelSettings -Root $fixtureRoot -NonInteractive
        Assert-Equal 'wildcard-instance,match-host' ($settings.Targets -join ',') 'Keep explicitly configured aliases and avoid duplicate workers.'
    }
    Invoke-TestCase 'unsupported versions and unknown keys are rejected' {
        foreach ($version in @(0, 2, '1', $null)) {
            New-SettingsFixture @{ Version = $version }
            Assert-Throws { Resolve-TunnelSettings -Root $fixtureRoot -NonInteractive } 'Version'
        }
        New-SettingsFixture @{ Target = @('typo') }
        Assert-Throws { Resolve-TunnelSettings -Root $fixtureRoot -NonInteractive } 'Unknown settings key'
        Write-Fixture $settingsPath '{"Targets":[]}'
        Assert-Throws { Resolve-TunnelSettings -Root $fixtureRoot -NonInteractive } 'Version'
    }
    Invoke-TestCase 'malformed JSON and non-object roots are rejected' {
        foreach ($json in @('{bad json', 'null', '[]', 'true', '1', '"text"')) {
            Write-Fixture $settingsPath $json
            Assert-Throws { Resolve-TunnelSettings -Root $fixtureRoot -NonInteractive } 'JSON'
        }
    }
    Invoke-TestCase 'invalid target types and unsafe target strings are rejected' {
        foreach ($targets in @('server-a', 3, @('valid', 5), @('server-a', '../unsafe'), @("server-a`n"))) {
            New-SettingsFixture @{ Targets = $targets }
            Assert-Throws { Resolve-TunnelSettings -Root $fixtureRoot -NonInteractive } 'Targets|target'
        }
    }
    Invoke-TestCase 'invalid endpoint hosts and ports are rejected' {
        foreach ($name in @('LocalProxyPort', 'RemotePort', 'ProbePort')) {
            foreach ($port in @(0, 65536, '443', 1.5, $null)) {
                $changes = @{}; $changes[$name] = $port; New-SettingsFixture $changes
                Assert-Throws { Resolve-TunnelSettings -Root $fixtureRoot -NonInteractive } $name
            }
        }
        foreach ($name in @('LocalProxyHost', 'ProbeHost')) {
            foreach ($hostValue in @('https://example.com', 'example.com:443', "x`nInjected", 'x;id', '-bad', "x'quoted", '', $null)) {
                $changes = @{}; $changes[$name] = $hostValue; New-SettingsFixture $changes
                Assert-Throws { Resolve-TunnelSettings -Root $fixtureRoot -NonInteractive } $name
            }
        }
    }
    Invoke-TestCase 'IPv4, DNS and IPv6 endpoint values are supported' {
        foreach ($value in @('127.0.0.1', 'localhost', 'proxy.example.com', '::1', '2001:db8::1')) {
            New-SettingsFixture @{ LocalProxyHost = $value; ProbeHost = $value }
            $settings = Resolve-TunnelSettings -Root $fixtureRoot -NonInteractive
            Assert-Equal $value $settings.LocalProxyHost 'Preserve supported endpoint.'
        }
    }
    Invoke-TestCase 'missing SSH files and executables fail before any prompt' {
        New-SettingsFixture @{ SshConfigPath = 'missing' }
        Assert-Throws { Resolve-TunnelSettings -Root $fixtureRoot -NonInteractive } 'SSH configuration file does not exist'
        New-SettingsFixture @{ SshExecutable = 'missing.exe' }
        Assert-Throws { Resolve-TunnelSettings -Root $fixtureRoot -NonInteractive } 'SSH executable does not exist'
        Write-Fixture (Join-Path $fixtureRoot 'not-executable.txt') 'data'
        New-SettingsFixture @{ SshExecutable = 'not-executable.txt' }
        Assert-Throws { Resolve-TunnelSettings -Root $fixtureRoot -NonInteractive } 'Windows executable'
        Assert-Equal 0 $script:PromptCount 'No prompt on noninteractive failures.'
    }
    Invoke-TestCase 'ListHosts permits no targets and never writes or prompts' {
        New-SettingsFixture @{ Targets = @() }
        $before = [IO.File]::ReadAllText($settingsPath)
        $settings = Resolve-TunnelSettings -Root $fixtureRoot -ListHosts
        Assert-Equal 0 $settings.Targets.Count 'Listing does not select a server.'
        Assert-Equal 2 $settings.AvailableHosts.Count 'List discoverable hosts.'
        Assert-Equal 0 $script:PromptCount 'Listing must never prompt.'
        Assert-Equal $before ([IO.File]::ReadAllText($settingsPath)) 'Listing must not save.'
        Assert-Throws { Resolve-TunnelSettings -Root $fixtureRoot -ListHosts -Configure } 'cannot be combined'
    }
    Invoke-TestCase 'read-only first-run operations never create a settings file' {
        $settings = Resolve-TunnelSettings -Root $fixtureRoot -ListHosts
        Assert-Equal 'home-host' ($settings.AvailableHosts -join ',') 'Discover the default user SSH file without selecting it.'
        Assert-Equal 0 $settings.Targets.Count 'A discovered server is not automatically selected.'
        Assert-Throws { Resolve-TunnelSettings -Root $fixtureRoot -CheckOnly } 'No targets selected'
        Assert-Throws { Resolve-TunnelSettings -Root $fixtureRoot -NonInteractive } 'No targets selected'
        Assert-True (-not [IO.File]::Exists($settingsPath)) 'Read-only first-run operations must not save configuration.'
        Assert-Equal 0 $script:PromptCount 'Read-only first-run operations must not prompt.'
    }
    Invoke-TestCase 'CheckOnly and NonInteractive with no targets never prompt or write' {
        New-SettingsFixture @{ Targets = @() }
        $before = [IO.File]::ReadAllText($settingsPath)
        Assert-Throws { Resolve-TunnelSettings -Root $fixtureRoot -CheckOnly } 'No targets selected'
        Assert-Throws { Resolve-TunnelSettings -Root $fixtureRoot -NonInteractive } 'No targets selected'
        Assert-Equal 0 $script:PromptCount 'No interactive fallback.'
        Assert-Equal $before ([IO.File]::ReadAllText($settingsPath)) 'Do not mutate empty configuration.'
        Assert-Throws { Resolve-TunnelSettings -Root $fixtureRoot -CheckOnly -Configure } 'cannot be combined'
    }
    Invoke-TestCase 'valid CheckOnly resolves settings without writes' {
        New-SettingsFixture
        $before = [IO.File]::ReadAllText($settingsPath)
        $settings = Resolve-TunnelSettings -Root $fixtureRoot -CheckOnly
        Assert-Equal 'server-a' ($settings.Targets -join ',') 'Keep selected targets.'
        Assert-Equal $before ([IO.File]::ReadAllText($settingsPath)) 'Checking must never save.'
        Assert-Equal 0 $script:PromptCount 'Checking must never prompt.'
    }
    Invoke-TestCase 'explicit targets on first run do not prompt or create settings' {
        $settings = Resolve-TunnelSettings -Root $fixtureRoot -Targets home-host
        Assert-Equal 'home-host' ($settings.Targets -join ',') 'Use explicit selection.'
        Assert-True (-not [IO.File]::Exists($settingsPath)) 'Do not persist explicit one-off selection.'
        Assert-Equal 0 $script:PromptCount 'No first-run wizard for explicit targets.'
    }
    Invoke-TestCase 'first-run wizard requires selection and persists only schema keys' {
        $script:Answers = @($sshConfig, '', '2,1,2')
        $settings = Resolve-TunnelSettings -Root $fixtureRoot
        Assert-Equal 'server-b,server-a' ($settings.Targets -join ',') 'Choose multiple servers and deduplicate.'
        Assert-Equal 3 $script:PromptCount 'Blank selection must not mean all.'
        Assert-True ([IO.File]::Exists($settingsPath)) 'Save first-run selection.'
        $persisted = ConvertFrom-Json ([IO.File]::ReadAllText($settingsPath))
        Assert-Equal 9 @($persisted.PSObject.Properties).Count 'Save only the nine public schema keys.'
        Assert-True ($null -eq $persisted.PSObject.Properties['AvailableHosts']) 'Discovery is not persistent configuration.'
    }
    Invoke-TestCase 'Configure wizard supports explicit all and manual alias selection' {
        New-SettingsFixture
        $script:Answers = @('', 'all')
        $settings = Resolve-TunnelSettings -Root $fixtureRoot -Configure
        Assert-Equal 'server-a,server-b' ($settings.Targets -join ',') 'Explicit all selects the displayed list.'
        $script:Answers = @('', 'm', 'all 123 wildcard-node')
        $settings = Resolve-TunnelSettings -Root $fixtureRoot -Configure
        Assert-Equal 'all,123,wildcard-node' ($settings.Targets -join ',') 'Manual mode accepts numeric and reserved UI words as real aliases.'
    }
    Invoke-TestCase 'noninteractive Configure saves CLI overrides atomically without prompting' {
        New-SettingsFixture
        $settings = Resolve-TunnelSettings -Root $fixtureRoot -Configure -NonInteractive -Targets server-b
        $persisted = ConvertFrom-Json ([IO.File]::ReadAllText($settingsPath))
        Assert-Equal 'server-b' ($persisted.Targets -join ',') 'Save explicit noninteractive selection.'
        Assert-Equal 0 $script:PromptCount 'NonInteractive always prevents prompts.'
        Assert-Equal 0 @([IO.Directory]::GetFiles($fixtureRoot, '*.new')).Count 'Atomic save leaves no temporary file.'
    }
    Invoke-TestCase 'explicit missing settings path fails instead of silently using defaults' {
        Assert-Throws { Resolve-TunnelSettings -Root $fixtureRoot -ConfigPath missing.json -NonInteractive -Targets home-host } 'Settings file does not exist'
        Assert-True (-not [IO.File]::Exists((Join-Path $fixtureRoot 'missing.json'))) 'Do not create a mistyped settings path.'
    }
}
finally {
    $env:USERPROFILE = $originalUserProfile
    $env:TUNNEL_CONFIG_FIXTURE = $originalFixtureEnv
    if ([IO.Directory]::Exists($fixtureRoot)) {
        $resolved = [IO.Path]::GetFullPath($fixtureRoot)
        $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        if ($resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved) -like 'tunnel-config-*') {
            [IO.Directory]::Delete($resolved, $true)
        }
    }
}
Write-Host "Configuration tests: $script:Passed passed, $script:Failed failed."
if ($script:Failed -gt 0) { exit 1 }
