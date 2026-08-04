# ==============================================================================
# components/wsl_update.ps1
# Description: 更新 WSL 发行版系统软件包或更新 Windows WSL 核心
# ==============================================================================

. "$PSScriptRoot\wsl_common.ps1"

function Invoke-WslUpdate {
    Write-Host "`n==========================================" -ForegroundColor Cyan
    Write-Host "          2. 更新 系统与 WSL              " -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan

    Write-Host "请选择更新内容:" -ForegroundColor Yellow
    Write-Host " 1. 更新指定 WSL Debian 的 apt 软件包"
    Write-Host " 2. 更新 Windows WSL 核心 (wsl --update)"
    Write-Host " 3. 全部更新"
    Write-Host " 0. 返回主菜单"

    $subChoice = Read-Host "`n请输入选项 [0-3]"

    switch ($subChoice) {
        '1' { Update-AptPackages }
        '2' { Update-WslCore }
        '3' { 
            Update-WslCore
            Update-AptPackages
        }
        '0' { return }
        default {
            Write-Host "`n[!] 输入 '$subChoice' 未匹配到有效选项，请正确输入！" -ForegroundColor Red
            Start-Sleep -Seconds 1
            return
        }
    }

}

function Update-AptPackages {
    $targetDistro = Select-WslDistro -Title "选择要更新软件包的 Debian 发行版"
    if (-not $targetDistro) { return }

    Write-Host "`n[!] 确认要对发行版 '$targetDistro' 执行 apt 软件包升级吗？" -ForegroundColor Yellow
    $confirm = Read-Host "确认开始更新软件包？[Y/N]"
    if ($confirm -ne 'Y' -and $confirm -ne 'y') {
        Write-Host "操作已取消。" -ForegroundColor Gray
        return
    }

    Write-Host "`n正在运行 apt update && apt upgrade -y ($targetDistro)..." -ForegroundColor Green
    & wsl.exe -d $targetDistro -u root -- bash -c "apt-get update && apt-get dist-upgrade -y && apt-get autoremove -y"
    if ($LASTEXITCODE -eq 0) {
        Write-Host "`n[✓] $targetDistro 软件包更新完成！" -ForegroundColor Green
    } else {
        Write-Host "`n[✗] 软件包更新过程中出现错误。" -ForegroundColor Red
    }
}

function Update-WslCore {
    Write-Host "`n[!] 确认要对 Windows 系统的 WSL 核心执行升级检查吗 (wsl --update)？" -ForegroundColor Yellow
    $confirm = Read-Host "确认开始更新 WSL 核心？[Y/N]"
    if ($confirm -ne 'Y' -and $confirm -ne 'y') {
        Write-Host "操作已取消。" -ForegroundColor Gray
        return
    }

    Write-Host "`n正在检查并更新 WSL 核心..." -ForegroundColor Green
    & wsl.exe --update
    if ($LASTEXITCODE -eq 0) {
        Write-Host "`n[✓] WSL 核心更新检查完成！" -ForegroundColor Green
    } else {
        Write-Host "`n[✗] WSL 核心更新失败。" -ForegroundColor Red
    }
}


Invoke-WslUpdate
