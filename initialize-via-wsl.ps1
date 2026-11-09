# Apply the same one-time initialization to explicitly selected existing instances.
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string[]]$DistroName
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\components\wsl_i18n.ps1"
. "$PSScriptRoot\components\wsl_common.ps1"
. "$PSScriptRoot\components\wsl_bootstrap.ps1"

$registered = @(Get-WslDistros)
foreach ($name in $DistroName) {
    if ([string]::IsNullOrWhiteSpace($name) -or $registered -notcontains $name) {
        throw "WSL distribution is not registered: $name"
    }
}
foreach ($name in ($DistroName | Select-Object -Unique)) {
    Invoke-WslBootstrap -Distro $name
}
