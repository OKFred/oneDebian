# Independent Debian Agent workstation; never implicitly targets the default WSL.
param(
    [ValidateSet('Menu', 'Create', 'Install', 'Resume', 'Status', 'Verify', 'Open', 'Uninstall', 'RelayStart', 'RelayStop', 'RelayStatus', 'CleanupPlan', 'Cleanup', 'Graphics', 'Keyring', 'Ssh', 'DesktopUpdate')][string]$Action = 'Menu',
    [string]$DistroName = '', [string]$WslRoot = 'D:\wsl',
    [ValidateSet('keep', 'tuna', 'ustc', 'official')][string]$Mirror = '',
    [int]$ViewerPort = 16080, [int]$McpPort = 18931, [int]$CdpPort = 19222, [int]$SshPort = 2222,
    [switch]$Yes, [switch]$RestartSelected, [switch]$AdoptUser, [switch]$Autostart, [switch]$NoWait, [switch]$AllowLowResources
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\components\wsl_i18n.ps1"
. "$PSScriptRoot\components\wsl_common.ps1"
. "$PSScriptRoot\components\wsl_lifecycle.ps1"
. "$PSScriptRoot\components\wsl_firstboot.ps1"
. "$PSScriptRoot\components\wsl_network.ps1"
. "$PSScriptRoot\components\wsl_agent.ps1"
. "$PSScriptRoot\components\wsl_agent_relay.ps1"
. "$PSScriptRoot\components\wsl_agent_ssh.ps1"
# Legacy command-line alias; first install and retries always stage the current payload.
if ($Action -eq 'Resume') { $PSBoundParameters['Action'] = 'Install' }
Invoke-WslAgent @PSBoundParameters
