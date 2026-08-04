# ==============================================================================
# components/wsl_restore.ps1
# Description: 从 .tar / .vhdx 备份镜像导入/还原 WSL 发行版
# ==============================================================================

param(
    [string]$DefaultWslRoot = 'D:\wsl'
)

. "$PSScriptRoot\wsl_common.ps1"

function Invoke-WslRestore {
    Write-Host "`n==========================================" -ForegroundColor Cyan
    Write-Host "          4. 还原 (导入) WSL 发行版        " -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan

    try {
        $defaultBackupDir = Join-Path $DefaultWslRoot 'backups'
        $backupFiles = @()
        if (Test-Path -LiteralPath $defaultBackupDir) {
            $backupFiles = @(Get-ChildItem -LiteralPath $defaultBackupDir -File | Where-Object { $_.Extension -in '.tar', '.vhdx' })
        }

        $selectedBackupPath = ""

        if ($backupFiles.Count -gt 0) {
            Write-Host "在默认备份目录中检测到以下备份文件:" -ForegroundColor Yellow
            for ($i = 0; $i -lt $backupFiles.Count; $i++) {
                Write-Host " [$($i + 1)] $($backupFiles[$i].Name) ($([math]::Round($backupFiles[$i].Length / 1MB, 2)) MB)"
            }
            Write-Host " [M] 手动输入其他路径"
            Write-Host " [0] 取消操作"

            $fileChoice = Read-Host "`n请选择序号 [1-$($backupFiles.Count) 或 M]"
            if ($fileChoice -eq '0') { return }
            if ($fileChoice -in 'M', 'm') {
                # 手动输入其他路径
            } elseif ([int]::TryParse($fileChoice, [ref]$null)) {
                $idx = [int]$fileChoice
                if ($idx -ge 1 -and $idx -le $backupFiles.Count) {
                    $selectedBackupPath = $backupFiles[$idx - 1].FullName
                } else {
                    Write-Host "`n[!] 输入序号 '$fileChoice' 超出有效范围 [1-$($backupFiles.Count)]，请正确输入！" -ForegroundColor Red
                    Start-Sleep -Seconds 1
                    return
                }
            } else {
                Write-Host "`n[!] 输入 '$fileChoice' 未匹配到有效选项，请正确输入！" -ForegroundColor Red
                Start-Sleep -Seconds 1
                return
            }
        }

        if (-not $selectedBackupPath) {
            $selectedBackupPath = Read-Host "`n请输入备份文件的完整路径 (.tar 或 .vhdx)"
        }

        if (-not $selectedBackupPath -or -not (Test-Path -LiteralPath $selectedBackupPath)) {
            Write-Host "`n[!] 错误: 备份文件不存在 -> '$selectedBackupPath'" -ForegroundColor Red
            return
        }

        $defaultDistroName = "Debian-Restored"
        $distroName = Read-Host "`n请输入要还原的发行版名称 (默认 $defaultDistroName)"
        if (-not $distroName) { $distroName = $defaultDistroName }

        # 检查同名发行版
        $existing = Get-WslDistros
        if ($existing -contains $distroName) {
            Write-Host "`n[!] 错误: 已存在同名的 WSL 发行版 '$distroName'！" -ForegroundColor Red
            return
        }

        $defaultInstallPath = Join-Path $DefaultWslRoot $distroName
        $installPath = Read-Host "请输入安装目录 (默认 $defaultInstallPath)"
        if (-not $installPath) { $installPath = $defaultInstallPath }

        if (Test-Path -LiteralPath $installPath) {
            Write-Host "`n[!] 错误: 安装目录已存在 -> '$installPath'" -ForegroundColor Red
            return
        }

        Write-Host "`n[!] 还原导入参数确认:" -ForegroundColor Yellow
        Write-Host "    备份源文件:   $selectedBackupPath" -ForegroundColor Cyan
        Write-Host "    还原发行版名: $distroName" -ForegroundColor Cyan
        Write-Host "    目标安装目录: $installPath" -ForegroundColor Cyan

        $confirm = Read-Host "`n确认开始导入还原 $distroName 吗？[Y/N]"
        if ($confirm -ne 'Y' -and $confirm -ne 'y') {
            Write-Host "操作已取消。" -ForegroundColor Gray
            return
        }

        Write-Host "`n正在导入发行版 $distroName ..." -ForegroundColor Green
        & wsl.exe --import $distroName $installPath $selectedBackupPath --version 2
        if ($LASTEXITCODE -eq 0) {
            Write-Host "`n[✓] 还原成功！" -ForegroundColor Green
            Write-Host "    发行版名称: $distroName" -ForegroundColor Gray
            Write-Host "    安装位置:   $installPath" -ForegroundColor Gray
            Write-Host "    启动命令:   wsl -d $distroName" -ForegroundColor Yellow
        } else {
            Write-Host "`n[✗] 还原导入失败，退出代码: $LASTEXITCODE" -ForegroundColor Red
        }
    } catch {
        Write-Host "`n[!] 还原出现异常: $($_.Exception.Message)" -ForegroundColor Red
    }
}

Invoke-WslRestore
