# Configuration and discovery only. Dot-sourcing this file has no side effects.
# PowerShell 5.1 compatible; SSH itself remains the authority for effective options.

function Test-TunnelAlias {
    param([AllowNull()][AllowEmptyString()][string]$Alias)
    return ($null -ne $Alias -and $Alias -cmatch '\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z' -and
        $Alias -notmatch '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)')
}

function Get-TunnelUserHomeDirectory {
    $userDirectory = [Environment]::GetEnvironmentVariable('USERPROFILE')
    if ([string]::IsNullOrWhiteSpace($userDirectory)) {
        $userDirectory = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    }
    if ([string]::IsNullOrWhiteSpace($userDirectory)) { throw 'Cannot locate the user profile directory.' }
    return $userDirectory
}

function Expand-TunnelPathString {
    param([Parameter(Mandatory = $true)][string]$Value)
    $expanded = $Value.Trim()
    if ($expanded.Length -ge 2 -and $expanded[0] -eq '"' -and $expanded[$expanded.Length - 1] -eq '"') {
        $expanded = $expanded.Substring(1, $expanded.Length - 2)
    }
    if ([string]::IsNullOrWhiteSpace($expanded) -or $expanded -match '[\x00-\x1f"]') {
        throw 'A path must be nonempty and contain no control characters or quotes.'
    }
    # Expand common Windows and OpenSSH environment notation without evaluating code.
    $expanded = [regex]::Replace($expanded, '%([A-Za-z_][A-Za-z0-9_]*)%|\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$env:([A-Za-z_][A-Za-z0-9_]*)', {
        param($match)
        $name = $match.Groups[1].Value + $match.Groups[2].Value + $match.Groups[3].Value
        $value = [Environment]::GetEnvironmentVariable($name)
        if ($null -eq $value) { throw "Environment variable '$name' is not defined." }
        return $value
    })
    if ($expanded -eq '~') { return Get-TunnelUserHomeDirectory }
    if ($expanded.StartsWith('~/') -or $expanded.StartsWith('~\')) {
        $expanded = Join-Path (Get-TunnelUserHomeDirectory) $expanded.Substring(2)
    }
    if ($expanded.StartsWith('~')) { throw 'Only ~ for the current user is supported; use an absolute path for another user.' }
    if ($expanded -match '[\x00-\x1f"]') { throw 'An expanded path contains unsupported characters.' }
    return $expanded
}

function Resolve-TunnelPath {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$BaseDirectory, [switch]$AllowWildcard)
    $expanded = Expand-TunnelPathString $Path
    if (-not [IO.Path]::IsPathRooted($expanded)) { $expanded = Join-Path $BaseDirectory $expanded }
    if ($AllowWildcard) {
        # .NET Framework GetFullPath rejects wildcard characters; protect them
        # while normalizing the path, then let the filesystem provider expand them.
        $marker = [guid]::NewGuid().ToString('N')
        $protected = $expanded.Replace('*', ($marker + 'STAR')).Replace('?', ($marker + 'ANY'))
        return [IO.Path]::GetFullPath($protected).Replace(($marker + 'STAR'), '*').Replace(($marker + 'ANY'), '?')
    }
    return [IO.Path]::GetFullPath($expanded)
}

function Split-TunnelSshWords {
    param([AllowEmptyString()][string]$Text)
    $words = New-Object 'System.Collections.Generic.List[string]'
    $word = New-Object Text.StringBuilder
    $quoted = $false
    for ($index = 0; $index -lt $Text.Length; $index++) {
        $character = $Text[$index]
        if ($character -eq '\' -and $index + 1 -lt $Text.Length -and $Text[$index + 1] -eq '"') {
            [void]$word.Append('"'); $index++; continue
        }
        if ($character -eq '"') { $quoted = -not $quoted; continue }
        if (-not $quoted -and $character -eq '#') { break }
        if (-not $quoted -and [char]::IsWhiteSpace($character)) {
            if ($word.Length -gt 0) { $words.Add($word.ToString()); [void]$word.Clear() }
        }
        else { [void]$word.Append($character) }
    }
    if ($quoted) { throw 'Unclosed quote in an SSH Host or Include directive.' }
    if ($word.Length -gt 0) { $words.Add($word.ToString()) }
    return $words.ToArray()
}

function Get-SshHostAliases {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    $initialPath = Resolve-TunnelPath -Path $Path -BaseDirectory (Get-Location).Path
    if (-not [IO.File]::Exists($initialPath)) { throw "SSH configuration file does not exist: $initialPath" }
    $visited = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $aliases = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    # OpenSSH resolves relative Include names against ~/.ssh, not the containing
    # file's directory, including when the main user configuration is passed by -F.
    $includeBase = Join-Path (Get-TunnelUserHomeDirectory) '.ssh'
    $readFile = {
        param([string]$FilePath, [int]$Depth)
        if ($Depth -gt 64) { throw 'SSH Include nesting exceeds the discovery limit of 64.' }
        $fullPath = [IO.Path]::GetFullPath($FilePath)
        if (-not $visited.Add($fullPath)) { return }
        foreach ($line in [IO.File]::ReadAllLines($fullPath)) {
            if ($line -notmatch '^\s*(Host|Include)(?:\s*=\s*|\s+)(.*)$') { continue }
            $directive = $Matches[1]
            $arguments = @(Split-TunnelSshWords $Matches[2])
            if ($directive -ieq 'Host') {
                foreach ($candidate in $arguments) {
                    if (Test-TunnelAlias $candidate) { [void]$aliases.Add($candidate) }
                }
                continue
            }
            foreach ($include in $arguments) {
                # Host-dependent tokens cannot be resolved during static discovery.
                # SSH evaluates them later for an explicitly selected alias.
                if ($include -match '%[A-Za-z%]' -and $include -notmatch '%[A-Za-z_][A-Za-z0-9_]*%') {
                    Write-Verbose "Skipping host-dependent Include during discovery: $include"
                    continue
                }
                $includePath = Resolve-TunnelPath -Path $include -BaseDirectory $includeBase -AllowWildcard
                $matchedPaths = @()
                if ([Management.Automation.WildcardPattern]::ContainsWildcardCharacters($includePath)) {
                    $matchedPaths = @(Get-ChildItem -Path $includePath -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
                }
                elseif ([IO.File]::Exists($includePath)) { $matchedPaths = @($includePath) }
                [Array]::Sort($matchedPaths, [StringComparer]::Ordinal)
                foreach ($includedPath in $matchedPaths) { & $readFile $includedPath ($Depth + 1) }
            }
        }
    }
    & $readFile $initialPath 0
    $result = @($aliases | ForEach-Object { $_ })
    [Array]::Sort($result, [StringComparer]::OrdinalIgnoreCase)
    return $result
}

function Test-TunnelEndpointHost {
    param([AllowNull()][AllowEmptyString()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value.Length -gt 253 -or $Value -match '[^A-Za-z0-9.:-]') { return $false }
    $address = $null
    if ([Net.IPAddress]::TryParse($Value, [ref]$address)) { return $true }
    if ($Value.Contains(':')) { return $false }
    return ($Value -cmatch '^(?=.{1,253}\.?$)[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*\.?$')
}

function Resolve-TunnelSshExecutable {
    param([AllowEmptyString()][string]$Path, [string]$BaseDirectory)
    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        $resolved = Resolve-TunnelPath -Path $Path -BaseDirectory $BaseDirectory
        if (-not [IO.File]::Exists($resolved)) { throw "SSH executable does not exist: $resolved" }
        if ([IO.Path]::GetExtension($resolved) -ine '.exe') { throw 'SshExecutable must name a Windows executable (.exe).' }
        return $resolved
    }
    $windowsDirectory = [Environment]::GetEnvironmentVariable('WINDIR')
    if (-not [string]::IsNullOrWhiteSpace($windowsDirectory)) {
        foreach ($relativePath in @('Sysnative\OpenSSH\ssh.exe', 'System32\OpenSSH\ssh.exe')) {
            $candidate = Join-Path $windowsDirectory $relativePath
            if ([IO.File]::Exists($candidate)) { return $candidate }
        }
    }
    $command = Get-Command ssh.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    throw 'OpenSSH ssh.exe was not found. Install Windows OpenSSH Client or set SshExecutable in your settings JSON.'
}

function Select-TunnelTargets {
    param([string[]]$AvailableHosts, [string[]]$CurrentTargets)
    Write-Host 'Discovered literal SSH Host aliases (conditional Host/Match rules are evaluated by SSH):'
    if ($AvailableHosts.Count -eq 0) { Write-Host '  No literal aliases found; enter aliases manually.' }
    for ($index = 0; $index -lt $AvailableHosts.Count; $index++) { Write-Host ('  {0}. {1}' -f ($index + 1), $AvailableHosts[$index]) }
    $defaultText = if ($CurrentTargets.Count -gt 0) { ' [' + ($CurrentTargets -join ', ') + ']' } else { '' }
    while ($true) {
        $choice = Read-Host "Select numbers (1,3), all, aliases, or m for manual entry$defaultText"
        if ([string]::IsNullOrWhiteSpace($choice) -and $CurrentTargets.Count -gt 0) { return $CurrentTargets }
        $manual = $choice.Trim() -ieq 'm'
        if ($manual) { $choice = Read-Host 'Enter explicit SSH aliases separated by commas or spaces' }
        $selected = New-Object 'System.Collections.Generic.List[string]'
        $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        try {
            if (-not $manual -and $choice.Trim() -ieq 'all') {
                foreach ($item in $AvailableHosts) { $selected.Add($item) }
            }
            else {
                foreach ($part in @($choice -split '[,\s]+' | Where-Object { $_ })) {
                    $alias = $part
                    if (-not $manual -and $part -match '^\d+$') {
                        $number = 0
                        if (-not [int]::TryParse($part, [ref]$number) -or $number -lt 1 -or $number -gt $AvailableHosts.Count) {
                            throw "Selection number is outside the displayed list: $part"
                        }
                        $alias = $AvailableHosts[$number - 1]
                    }
                    if (-not (Test-TunnelAlias $alias)) { throw "Invalid SSH alias: $alias" }
                    if ($seen.Add($alias)) { $selected.Add($alias) }
                }
            }
            if ($selected.Count -eq 0) { throw 'Select at least one SSH alias; no server is selected automatically.' }
            return $selected.ToArray()
        }
        catch { Write-Host $_.Exception.Message -ForegroundColor Yellow }
    }
}

function Save-TunnelSettings {
    param([Parameter(Mandatory = $true)]$Settings)
    $persisted = [ordered]@{}
    foreach ($name in @('Version', 'SshConfigPath', 'SshExecutable', 'Targets', 'LocalProxyHost', 'LocalProxyPort', 'RemotePort', 'ProbeHost', 'ProbePort')) {
        $persisted[$name] = $Settings.$name
    }
    $directory = [IO.Path]::GetDirectoryName($Settings.ConfigPath)
    [void][IO.Directory]::CreateDirectory($directory)
    $temporary = $Settings.ConfigPath + '.' + [guid]::NewGuid().ToString('N') + '.new'
    try {
        [IO.File]::WriteAllText($temporary, ($persisted | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))
        if ([IO.File]::Exists($Settings.ConfigPath)) { [IO.File]::Replace($temporary, $Settings.ConfigPath, [System.Management.Automation.Language.NullString]::Value) }
        else { [IO.File]::Move($temporary, $Settings.ConfigPath) }
    }
    finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}

function Resolve-TunnelSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [string]$ConfigPath,
        [string]$SshConfig,
        [string[]]$Targets,
        [switch]$Configure,
        [switch]$ListHosts,
        [switch]$CheckOnly,
        [switch]$NonInteractive
    )
    if ($Configure -and ($ListHosts -or $CheckOnly)) { throw '-Configure cannot be combined with -ListHosts or -CheckOnly.' }
    $rootPath = Resolve-TunnelPath -Path $Root -BaseDirectory (Get-Location).Path
    $explicitConfig = -not [string]::IsNullOrWhiteSpace($ConfigPath)
    if (-not $explicitConfig) { $ConfigPath = Join-Path $rootPath 'tunnels.local.json' }
    $resolvedConfig = Resolve-TunnelPath -Path $ConfigPath -BaseDirectory $rootPath
    $configDirectory = [IO.Path]::GetDirectoryName($resolvedConfig)
    $configExists = [IO.File]::Exists($resolvedConfig)
    if ($explicitConfig -and -not $configExists -and -not $Configure) { throw "Settings file does not exist: $resolvedConfig" }
    $values = [ordered]@{
        Version = 1
        SshConfigPath = (Join-Path (Get-TunnelUserHomeDirectory) '.ssh\config')
        SshExecutable = ''
        Targets = @()
        LocalProxyHost = '127.0.0.1'
        LocalProxyPort = 7897
        RemotePort = 7897
        ProbeHost = 'www.microsoft.com'
        ProbePort = 443
    }
    if ($configExists) {
        try { $loaded = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($resolvedConfig)) -ErrorAction Stop }
        catch { throw "Invalid settings JSON in ${resolvedConfig}: $($_.Exception.Message)" }
        if ($null -eq $loaded -or $loaded -isnot [pscustomobject]) { throw 'Settings JSON must be a single object.' }
        if ($null -eq $loaded.PSObject.Properties['Version'] -or
            ($loaded.Version -isnot [int] -and $loaded.Version -isnot [long]) -or $loaded.Version -ne 1) {
            throw 'Unsupported settings Version. The JSON must declare "Version": 1.'
        }
        foreach ($property in $loaded.PSObject.Properties) {
            if (-not $values.Contains($property.Name)) { throw "Unknown settings key: $($property.Name)" }
            $values[$property.Name] = $property.Value
        }
    }
    foreach ($name in @('SshConfigPath', 'SshExecutable', 'LocalProxyHost', 'ProbeHost')) {
        if ($values[$name] -isnot [string]) { throw "$name must be a string." }
    }
    if ($values.Targets -isnot [array]) { throw 'Targets must be a JSON array of SSH alias strings.' }
    if ($PSBoundParameters.ContainsKey('SshConfig')) { $values.SshConfigPath = $SshConfig }
    if ($PSBoundParameters.ContainsKey('Targets')) {
        # powershell.exe -File and CMD pass -Targets a,b as one string. Normalize
        # CLI inputs only; persisted JSON must remain an array of individual aliases.
        $cliTargets = New-Object 'System.Collections.Generic.List[string]'
        foreach ($element in $Targets) {
            if ($null -eq $element -or $element -match '[\x00-\x1f]') { throw 'CLI Targets must contain safe SSH aliases without control characters.' }
            foreach ($part in $element.Split(',')) {
                $alias = $part.Trim()
                if ([string]::IsNullOrWhiteSpace($alias)) { throw 'CLI Targets contains an empty alias; remove extra commas or supply at least one target.' }
                $cliTargets.Add($alias)
            }
        }
        $values.Targets = @($cliTargets.ToArray())
    }
    foreach ($name in @('LocalProxyPort', 'RemotePort', 'ProbePort')) {
        if (($values[$name] -isnot [int] -and $values[$name] -isnot [long]) -or $values[$name] -lt 1 -or $values[$name] -gt 65535) {
            throw "$name must be an integer between 1 and 65535."
        }
    }
    foreach ($name in @('LocalProxyHost', 'ProbeHost')) {
        if (-not (Test-TunnelEndpointHost $values[$name])) { throw "$name must be a DNS name or an IP address without a scheme, port, or whitespace." }
    }
    $targetList = New-Object 'System.Collections.Generic.List[string]'
    $targetSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($alias in $values.Targets) {
        if ($alias -isnot [string] -or -not (Test-TunnelAlias $alias)) {
            throw 'Each target must be a safe SSH alias: 1-128 ASCII letters, digits, dots, underscores or hyphens, beginning with a letter or digit; Windows device names are excluded.'
        }
        if ($targetSet.Add($alias)) { $targetList.Add($alias) }
    }
    $values.Targets = @($targetList.ToArray())
    $wizard = -not ($ListHosts -or $CheckOnly -or $NonInteractive) -and ($Configure -or $values.Targets.Count -eq 0)
    if ($wizard) {
        Write-Host 'Choose the SSH configuration file and the servers to manage.'
        $choice = Read-Host "SSH configuration path [$($values.SshConfigPath)]"
        if (-not [string]::IsNullOrWhiteSpace($choice)) { $values.SshConfigPath = $choice }
    }
    # Stored and command-line relative SSH paths share the settings-file directory.
    $values.SshConfigPath = Resolve-TunnelPath -Path $values.SshConfigPath -BaseDirectory $configDirectory
    if (-not [IO.File]::Exists($values.SshConfigPath)) { throw "SSH configuration file does not exist: $($values.SshConfigPath)" }
    $values.SshExecutable = Resolve-TunnelSshExecutable -Path $values.SshExecutable -BaseDirectory $configDirectory
    $available = @(Get-SshHostAliases -Path $values.SshConfigPath)
    if ($wizard) { $values.Targets = @(Select-TunnelTargets -AvailableHosts $available -CurrentTargets $values.Targets) }
    if (-not $ListHosts -and $values.Targets.Count -eq 0) {
        throw 'No targets selected. Run -Configure interactively, set Targets in your settings JSON, or pass -Targets server-a,server-b.'
    }
    $settings = [pscustomobject]$values
    Add-Member -InputObject $settings -NotePropertyName ConfigPath -NotePropertyValue $resolvedConfig
    Add-Member -InputObject $settings -NotePropertyName AvailableHosts -NotePropertyValue $available
    if ($Configure -or $wizard) {
        Save-TunnelSettings $settings
        Write-Host "Saved tunnel settings: $resolvedConfig"
    }
    return $settings
}
