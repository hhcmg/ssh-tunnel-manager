[CmdletBinding()]
param()

# Offline discovery/wrapper tests. All files and subprocesses are fixtures;
# nothing inspects or stops a production worker or connects to SSH.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$packageRoot = $PSScriptRoot
. (Join-Path $packageRoot 'Tunnel-Config.ps1')
. (Join-Path $packageRoot 'Tunnel-Runtime.ps1')
$stopImplementation = (Get-Item Function:\Stop-TunnelWorkers).ScriptBlock
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('tunnel-stop-all-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($scratch)
$script:Passed = 0
$script:Failed = 0
$script:Case = 0
$script:Calls = @()
function Write-Status([string]$Level, [string]$Message) { }
function Test-TunnelWorkerMutex([string]$Alias) { return $true }
function Initialize-TunnelApplication { throw 'Unexpected SSH settings resolution.' }
function Stop-TunnelWorkers([string[]]$Aliases, [int]$TimeoutSeconds) {
    $script:Calls += [pscustomobject]@{ ContextId = $script:ContextId; DataRoot = $script:DataRoot; Aliases = $Aliases }
    return $true
}
function Assert-True($Value, [string]$Message) { if (-not $Value) { throw $Message } }
function Invoke-Case([string]$Name, [scriptblock]$Body) {
    $script:Case++
    $script:Root = Join-Path $scratch ('project-' + $script:Case)
    [void][IO.Directory]::CreateDirectory($script:Root)
    $script:Calls = @()
    try { & $Body; $script:Passed++; Write-Host "PASS $Name" -ForegroundColor Green }
    catch { $script:Failed++; Write-Host "FAIL $Name : $($_.Exception.Message)" -ForegroundColor Red }
}
function Add-State([string]$Context, [string]$Alias = 'server-a') {
    $directory = Join-Path (Join-Path $script:Root '.runtime') $Context
    [void][IO.Directory]::CreateDirectory($directory)
    [IO.File]::WriteAllText((Join-Path $directory "$Alias.worker.json"), '{}')
    return $directory
}
function Remove-FixtureTree([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $full.Equals($scratch, [StringComparison]::OrdinalIgnoreCase) -and
        -not $full.StartsWith($scratch + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected fixture cleanup path.' }
    $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        if ($item.PSIsContainer) { [IO.Directory]::Delete($full, $false) } else { [IO.File]::Delete($full) }
    }
    elseif ($item.PSIsContainer) {
        foreach ($entry in @(Get-ChildItem -LiteralPath $full -Force)) { Remove-FixtureTree $entry.FullName }
        [IO.Directory]::Delete($full, $false)
    }
    else { [IO.File]::Delete($full) }
}

try {
    Invoke-Case 'missing runtime succeeds without reading SSH settings' {
        Assert-True (Stop-AllTunnelWorkers) 'A new installation has nothing to stop.'
        Assert-True ($script:Calls.Count -eq 0) 'Do not call stop without recorded workers.'
    }
    Invoke-Case 'discover only direct valid contexts and safe worker aliases' {
        $first = Add-State ('1' * 24)
        [void](Add-State ('2' * 24) 'server-b')
        [void](Add-State 'invalid-context' 'ignored')
        [void](Add-State ((Join-Path 'nested' ('3' * 24))) 'ignored-nested')
        [IO.File]::WriteAllText((Join-Path $first '-unsafe.worker.json'), '{}')
        [IO.File]::WriteAllText((Join-Path $first 'other.log'), '{}')
        Assert-True (Stop-AllTunnelWorkers) 'Valid contexts must be processed.'
        Assert-True ($script:Calls.Count -eq 2) 'Only two direct valid contexts should be processed.'
        Assert-True (($script:Calls.Aliases -join ',') -eq 'server-a,server-b') 'Only safe state filenames become aliases.'
        Assert-True ($script:Calls[0].ContextId -eq ('1' * 24)) 'Use the directory context for identity validation.'
    }
    Invoke-Case 'reject context and runtime junctions without traversing their targets' {
        $outside = Join-Path $script:Root 'outside'
        [void][IO.Directory]::CreateDirectory($outside)
        [IO.File]::WriteAllText((Join-Path $outside 'server-a.worker.json'), '{}')
        $runtime = Join-Path $script:Root '.runtime'
        [void][IO.Directory]::CreateDirectory($runtime)
        [void](New-Item -ItemType Junction -Path (Join-Path $runtime ('4' * 24)) -Target $outside)
        Assert-True (-not (Stop-AllTunnelWorkers)) 'A reparse context must be reported as skipped.'
        Assert-True ($script:Calls.Count -eq 0) 'Never pass a linked context to stop.'
        $script:Root = Join-Path $script:Root 'another-project'
        [void][IO.Directory]::CreateDirectory($script:Root)
        [void](New-Item -ItemType Junction -Path (Join-Path $script:Root '.runtime') -Target $outside)
        $rejected = $false
        try { [void](Stop-AllTunnelWorkers) } catch { $rejected = $true }
        Assert-True $rejected 'A reparse runtime root must be rejected before enumeration.'
        Assert-True ([IO.File]::ReadAllText((Join-Path $outside 'server-a.worker.json')) -eq '{}') 'Linked outside state must remain unchanged.'
    }
    Invoke-Case 'All wrapper bypasses settings resolution and rejects mixed selectors' {
        [IO.File]::Copy((Join-Path $packageRoot 'Stop-Tunnels.ps1'), (Join-Path $script:Root 'Stop-Tunnels.ps1'))
        $library = @'
param([switch]$LibraryOnly)
function Initialize-TunnelApplication { throw 'RESOLVER_MUST_NOT_RUN' }
function Stop-AllTunnelWorkers { Write-Host 'ALL_CALLED'; return $true }
'@
        [IO.File]::WriteAllText((Join-Path $script:Root 'Start-Tunnels.ps1'), $library)
        $output = & $script:PowerShellExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:Root 'Stop-Tunnels.ps1') -All 2>&1
        Assert-True ($LASTEXITCODE -eq 0 -and ($output -join '') -match 'ALL_CALLED') 'All must work without a settings resolver or SSH file.'
        foreach ($selector in @('-ConfigPath', '-SshConfig', '-Targets')) {
            $output = & $script:PowerShellExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:Root 'Stop-Tunnels.ps1') -All $selector 'unused' 2>&1
            Assert-True ($LASTEXITCODE -eq 1 -and ($output -join '') -match 'cannot be combined') "Reject -All with $selector."
        }
    }
    Invoke-Case 'recovery wrapper preserves saved SSH source when override is omitted' {
        [IO.File]::Copy((Join-Path $packageRoot 'Test-Tunnel-Recovery.ps1'), (Join-Path $script:Root 'Test-Tunnel-Recovery.ps1'))
        $library = @'
param([switch]$LibraryOnly)
$script:RemotePort = 27997
function Test-TunnelAlias($Alias) { return $true }
function Initialize-TunnelApplication {
    param($ConfigPath, $SshConfig, $Targets, [switch]$CheckOnly, [switch]$NonInteractive)
    if ($PSBoundParameters.ContainsKey('SshConfig') -or $PSBoundParameters.ContainsKey('ConfigPath')) { Write-Host 'UNEXPECTED_SOURCE_OVERRIDE'; exit 9 }
    Write-Host 'SAVED_SOURCE_PRESERVED'
    exit 0
}
'@
        [IO.File]::WriteAllText((Join-Path $script:Root 'Start-Tunnels.ps1'), $library)
        $output = & $script:PowerShellExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:Root 'Test-Tunnel-Recovery.ps1') -Run -Alias server-a 2>&1
        Assert-True ($LASTEXITCODE -eq 0 -and ($output -join '') -match 'SAVED_SOURCE_PRESERVED') 'Omitted source overrides must remain unbound.'
        Assert-True (($output -join '') -notmatch 'UNEXPECTED_SOURCE_OVERRIDE') 'Do not replace saved settings with empty strings.'
    }
    Invoke-Case 'unverified state plus a held worker mutex fails instead of claiming stopped' {
        Set-Item Function:\Stop-TunnelWorkers $stopImplementation
        [void](Add-State ('5' * 24))
        Assert-True (-not (Stop-AllTunnelWorkers -TimeoutSeconds 1)) 'Corrupt state with an active mutex must remain an explicit failure.'
    }
}
finally { Remove-FixtureTree $scratch }
Write-Host ("Stop-all tests ({0}): {1} passed, {2} failed." -f $PSVersionTable.PSVersion, $script:Passed, $script:Failed)
if ($script:Failed -gt 0) { exit 1 }
exit 0
