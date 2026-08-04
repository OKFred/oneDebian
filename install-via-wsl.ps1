# ==============================================================================
# install-via-wsl.ps1
# Description: 根目录安装入口脚本（代理调用 components/wsl_install.ps1）
# ==============================================================================

param(
    [ValidateSet(12, 13)]
    [int]$Version = 13,

    [string]$WslRoot = 'D:\wsl'
)

& "$PSScriptRoot\components\wsl_install.ps1" -Version $Version -WslRoot $WslRoot
