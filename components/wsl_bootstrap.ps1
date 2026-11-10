# Reuse the Bash menu's initialization without depending on Windows drive mounts.

function Get-WslBootstrapScript {
    $root = Split-Path -Parent $PSScriptRoot
    $parts = foreach ($file in @('components/the_os_release.sh', 'components/the_repo_localization.sh', 'components/the_basic_setup.sh', 'bootstrap.sh')) {
        [IO.File]::ReadAllText((Join-Path $root $file), [Text.Encoding]::UTF8).TrimStart([char]0xFEFF).Replace("`r`n", "`n")
    }
    return "set -e`n" + ($parts -join "`n") + "`nthe_bootstrap`n"
}

function Invoke-WslBootstrap {
    param([Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Distro)
    Write-Host $(if ($global:CurrentLang -eq 'zh-CN') {
        "[$Distro] 正在应用 Bash 01、02：更换国内源、升级系统包、安装基础工具..."
    } else {
        "[$Distro] Applying Bash 01 and 02: local mirrors, package upgrades and basic tools..."
    }) -ForegroundColor Cyan

    $result = Invoke-WslShellScript -Arguments @('--distribution', $Distro, '--user', 'root', '--exec', '/bin/bash', '--noprofile', '--norc', '-c', (Get-WslBootstrapScript))
    if ($result.Text) { Write-Host $result.Text.TrimEnd() }
    if ($result.ErrorText) { Write-Host $result.ErrorText.TrimEnd() }
    if ($result.ExitCode -ne 0 -or -not $result.IsDecoded -or $result.Text.TrimEnd() -notmatch '(?:\A|\r?\n)ONEDEBIAN_BOOTSTRAP_OK\z') {
        throw $(if ($global:CurrentLang -eq 'zh-CN') {
            "[$Distro] 初始化未完成（退出码 $($result.ExitCode)）。请查看上述日志后重试。"
        } else {
            "[$Distro] Initialization did not complete (exit $($result.ExitCode)). Review the logs above before retrying."
        })
    }
    Write-Host $(if ($global:CurrentLang -eq 'zh-CN') { "[$Distro] 换源、升级与基础工具验证完成。" } else { "[$Distro] Mirrors, upgrades and basic tools verified." }) -ForegroundColor Green
}
