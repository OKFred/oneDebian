# ==============================================================================
# components/wsl_purge.ps1
# Description: 08. WSL 环境全量彻底清理与重置 (带 PURGE 双重确认)
# ==============================================================================

param(
    [string]$DefaultWslRoot = 'D:\wsl'
)

. "$PSScriptRoot\wsl_i18n.ps1"
. "$PSScriptRoot\wsl_common.ps1"

function Invoke-WslPurge {
    Write-Host "`n==========================================" -ForegroundColor Red
    Write-Host " 8. WSL 环境全量彻底清理与重置 (Purge)   " -ForegroundColor Red
    Write-Host "==========================================" -ForegroundColor Red

    $distros = Get-WslDistros
    $archiveDir = Join-Path $DefaultWslRoot 'images'
    $backupDir = Join-Path $DefaultWslRoot 'backups'

    Write-Host "`n[!] 当前 WSL 环境扫描清单:" -ForegroundColor Yellow
    Write-Host "  • 检测到的 WSL 发行版: $(if ($distros.Count -gt 0) { $distros -join ', ' } else { '无' })" -ForegroundColor Cyan
    Write-Host "  • 安装根目录路径:     $DefaultWslRoot" -ForegroundColor Cyan
    Write-Host "  • 镜像缓存目录:       $archiveDir" -ForegroundColor Gray
    Write-Host "  • 备份文件目录:       $backupDir" -ForegroundColor Gray

    Write-Host "`n请选择清理重置范围:" -ForegroundColor Yellow
    Write-Host " [A] 全量彻底清理 - 注销所有发行版、删除存储文件夹与镜像缓存 (All Purge)" -ForegroundColor Red
    Write-Host " [S] 仅注销清理指定的单个发行版及其存储文件夹" -ForegroundColor Yellow
    Write-Host " [0] 取消操作" -ForegroundColor Gray

    $modeChoice = Read-Host "`n请输入选项 [A / S / 0]"
    if ($modeChoice -eq '0' -or -not $modeChoice) { return }

    $targetDistros = @()
    $cleanImages = $false
    $cleanBackups = $false

    if ($modeChoice -in 'A', 'a', 'ALL', 'all') {
        $targetDistros = $distros
        $cleanImages = $true
        $cleanBackups = $true
    } elseif ($modeChoice -in 'S', 's') {
        $single = Select-WslDistro -Title "选择要彻底清理注销的单个发行版"
        if (-not $single) { return }
        $targetDistros = @($single)
    } else {
        Write-Host "`n[!] 输入未匹配到有效选项，操作已取消。" -ForegroundColor Red
        return
    }

    # --------------------------------------------------------------------------
    # 第一次确认 (Step 1 Confirmation)
    # --------------------------------------------------------------------------
    Write-Host "`n==========================================" -ForegroundColor Red
    Write-Host "       [!] ⚠️ 极高危险操作警告          " -ForegroundColor Red
    Write-Host "==========================================" -ForegroundColor Red
    Write-Host " 即将彻底清理与重置以下资源:" -ForegroundColor Red
    if ($targetDistros.Count -gt 0) {
        foreach ($d in $targetDistros) {
            Write-Host "   • 注销发行版并物理删除目录: $DefaultWslRoot\$d" -ForegroundColor Yellow
        }
    }
    if ($cleanImages -and (Test-Path -LiteralPath $archiveDir)) {
        Write-Host "   • 删除全部 Rootfs 镜像缓存: $archiveDir" -ForegroundColor Yellow
    }
    if ($cleanBackups -and (Test-Path -LiteralPath $backupDir)) {
        Write-Host "   • 删除全部导出的备份文件: $backupDir" -ForegroundColor Yellow
    }
    Write-Host " 所有关联数据将被彻底销毁且无法撤销！" -ForegroundColor Red

    $confirm1 = Read-Host "`n[1/2 第一次确认] 确认要继续彻底清理吗？[Y/N]"
    if ($confirm1 -ne 'Y' -and $confirm1 -ne 'y') {
        Write-Host "操作已取消。" -ForegroundColor Gray
        return
    }

    # --------------------------------------------------------------------------
    # 第二次确认 (Step 2 Double Confirmation)
    # --------------------------------------------------------------------------
    Write-Host "`n[!] 🚨 终极安全确认: 该全量清理操作不可逆！" -ForegroundColor Red
    $confirm2 = Read-Host "[2/2 第二次确认] 请手动输入大写字符串 'PURGE' 以最终执行清空"

    if ($confirm2 -ne 'PURGE') {
        Write-Host "二次确认未通过，全量清理操作已安全取消。" -ForegroundColor Yellow
        return
    }

    # --------------------------------------------------------------------------
    # 执行彻底清理与重置
    # --------------------------------------------------------------------------
    Write-Host "`n正在关闭全局 WSL 进程..." -ForegroundColor Red
    & wsl.exe --shutdown 2>$null

    # 1. 彻底注销发行版
    foreach ($d in $targetDistros) {
        Write-Host "`n[1/3] 正在注销 WSL 发行版: $d ..." -ForegroundColor Red
        & wsl.exe --unregister $d 2>$null

        $distroDir = Join-Path $DefaultWslRoot $d
        if (Test-Path -LiteralPath $distroDir) {
            Write-Host "     正在物理删除存储目录: $distroDir ..." -ForegroundColor Yellow
            Remove-Item -LiteralPath $distroDir -Recurse -Force 2>$null
        }
    }

    # 2. 清理镜像缓存
    if ($cleanImages -and (Test-Path -LiteralPath $archiveDir)) {
        Write-Host "`n[2/3] 正在清理镜像缓存目录: $archiveDir ..." -ForegroundColor Red
        Remove-Item -LiteralPath $archiveDir -Recurse -Force 2>$null
    }

    # 3. 清理备份文件
    if ($cleanBackups -and (Test-Path -LiteralPath $backupDir)) {
        Write-Host "`n[3/3] 正在清理备份目录: $backupDir ..." -ForegroundColor Red
        Remove-Item -LiteralPath $backupDir -Recurse -Force 2>$null
    }

    Write-Host "`n重新初始化 WSL 核心堆栈..." -ForegroundColor Green
    & wsl.exe --shutdown 2>$null

    Write-Host "`n==========================================" -ForegroundColor Green
    Write-Host "       [✓] 全量 WSL 环境清理重置完成！    " -ForegroundColor Green
    Write-Host "==========================================" -ForegroundColor Green
    Write-Host " 所有选中的 WSL 实例及磁盘残留已被彻底清除。" -ForegroundColor Cyan
}

Invoke-WslPurge
