# ==============================================================================
# components/wsl_backup.ps1
# Description: 将指定 WSL 发行版导出/备份为 tar 镜像文件
# ==============================================================================

param(
    [string]$DefaultWslRoot = 'D:\wsl'
)

. "$PSScriptRoot\wsl_common.ps1"


function Invoke-WslBackup {
    Write-Host "`n==========================================" -ForegroundColor Cyan
    Write-Host "          3. 备份 (导出) WSL 发行版        " -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan

    $targetDistro = Select-WslDistro -Title "选择要备份的 WSL 发行版"
    if (-not $targetDistro) { return }

    $defaultBackupDir = Join-Path $DefaultWslRoot 'backups'
    if (-not (Test-Path -LiteralPath $defaultBackupDir)) {
        New-Item -ItemType Directory -Force -Path $defaultBackupDir | Out-Null
    }

    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $defaultFilename = "${targetDistro}_backup_${timestamp}.tar"
    $defaultPath = Join-Path $defaultBackupDir $defaultFilename

    $savePath = Read-Host "`n输入备份保存完整路径 (默认: $defaultPath)"
    if (-not $savePath) { $savePath = $defaultPath }

    # 确保保存路径的父目录存在
    $parentDir = Split-Path -Parent $savePath
    if ($parentDir -and -not (Test-Path -LiteralPath $parentDir)) {
        New-Item -ItemType Directory -Force -Path $parentDir | Out-Null
    }

    Write-Host "`n[!] 备份参数确认:" -ForegroundColor Yellow
    Write-Host "    目标发行版:   $targetDistro" -ForegroundColor Cyan
    Write-Host "    导出保存路径: $savePath" -ForegroundColor Cyan

    $confirm = Read-Host "`n确认开始导出备份 $targetDistro 吗？[Y/N]"
    if ($confirm -ne 'Y' -and $confirm -ne 'y') {
        Write-Host "操作已取消。" -ForegroundColor Gray
        return
    }

    Write-Host "`n[1/2] 正在停止发行版 $targetDistro..." -ForegroundColor Yellow

    & wsl.exe --terminate $targetDistro 2>$null

    Write-Host "[2/2] 正在导出 $targetDistro 到 $savePath ..." -ForegroundColor Green
    & wsl.exe --export $targetDistro $savePath
    if ($LASTEXITCODE -eq 0) {
        $fileInfo = Get-Item -LiteralPath $savePath
        $sizeMB = [math]::Round($fileInfo.Length / 1MB, 2)
        Write-Host "`n[✓] 备份成功！" -ForegroundColor Green
        Write-Host "    文件路径: $savePath" -ForegroundColor Gray
        Write-Host "    文件大小: $sizeMB MB" -ForegroundColor Gray
    } else {
        Write-Host "`n[✗] 备份失败，退出代码: $LASTEXITCODE" -ForegroundColor Red
    }
}

Invoke-WslBackup
