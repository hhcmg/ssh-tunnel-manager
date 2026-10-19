[CmdletBinding()]
param([string]$ConfigPath, [string]$SshConfig, [Alias('Servers')][string[]]$Targets, [switch]$All)
$stopAll = [bool]$All
$stopHasSelection = $PSBoundParameters.ContainsKey('ConfigPath') -or $PSBoundParameters.ContainsKey('SshConfig') -or $PSBoundParameters.ContainsKey('Targets')
$stopOptions = @{ NonInteractive = $true }
foreach ($key in $PSBoundParameters.Keys) { if ($key -ne 'All') { $stopOptions[$key] = $PSBoundParameters[$key] } }
. (Join-Path $PSScriptRoot 'Start-Tunnels.ps1') -LibraryOnly
try {
    if ($stopAll) {
        if ($stopHasSelection) { throw '-All cannot be combined with -ConfigPath, -SshConfig or -Targets.' }
        if (Stop-AllTunnelWorkers) { exit 0 }
        exit 1
    }
    [void](Initialize-TunnelApplication @stopOptions)
    if (Stop-TunnelWorkers -Aliases $script:Targets) { exit 0 }
    exit 1
}
catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    if (-not $stopAll) { Write-Host 'If the SSH source or settings changed, use Stop-Tunnels.ps1 -All to stop recorded workers from this project without reading SSH configuration.' -ForegroundColor Yellow }
    exit 1
}
