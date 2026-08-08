# ==============================================================================
# components/wsl_restore.ps1
# Description: 04. 还原 (导入) WSL 发行版 (支持 D:\wsl\backups 自动扫描、序号选择与自定义路径)
# Author: Fred
# ==============================================================================

param(
    [string]$DefaultWslRoot = 'D:\wsl'
)

. "$PSScriptRoot\wsl_i18n.ps1"
. "$PSScriptRoot\wsl_common.ps1"

function Invoke-WslRestore {
    Write-Host "`n==========================================" -ForegroundColor Cyan
    Write-Host "     $(Get-I18nStr 'Restore_Title')      " -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan

    $backupDir = Join-Path $DefaultWslRoot 'backups'
    $selectedFile = $null

    # 1. 自动扫描 D:\wsl\backups 下的备份文件
    Write-Host "`n$(if ($global:CurrentLang -eq 'zh-CN') { "默认备份来源目录: $backupDir" } else { "Default Backup Source Directory: $backupDir" })" -ForegroundColor Yellow

    if (Test-Path -LiteralPath $backupDir) {
        $backupFiles = @(Get-ChildItem -Path $backupDir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '(?i)\.(?:tar|tar\.gz|tar\.xz|vhdx)$' } |
            Sort-Object LastWriteTime -Descending)

        if ($backupFiles.Count -gt 0) {
            Write-Host "`n=== $(if ($global:CurrentLang -eq 'zh-CN') { '扫描到的本地备份文件列表' } else { 'Detected Local Backup Files' }) ===" -ForegroundColor Cyan
            for ($i = 0; $i -lt $backupFiles.Count; $i++) {
                $f = $backupFiles[$i]
                $sizeMB = [math]::Round($f.Length / 1MB, 2)
                Write-Host " [$($i + 1)] $($f.Name) ($sizeMB MB)"
            }
            Write-Host " [M] $(if ($global:CurrentLang -eq 'zh-CN') { '手动输入其他备份文件路径' } else { 'Manually type custom backup file path' })" -ForegroundColor Yellow
            Write-Host " [0] $(Get-I18nStr 'Cancel_Operation')" -ForegroundColor Gray

            $choice = Read-Host "`n$(Get-I18nStr 'Select_Index_Prompt') [1-$($backupFiles.Count), M, 0]"
            if ($choice -eq '0' -or -not $choice) { return }

            if ($choice -match '^\d+$') {
                $idx = [int]$choice - 1
                if ($idx -ge 0 -and $idx -lt $backupFiles.Count) {
                    $selectedFile = $backupFiles[$idx].FullName
                }
            }
        }
    }

    # 2. 若未从列表中选择，则允许手动输入路径
    if (-not $selectedFile) {
        $fileInput = Read-Host "`n$(if ($global:CurrentLang -eq 'zh-CN') { '请输入备份文件的完整路径 (.tar / .tar.gz / .vhdx)' } else { 'Enter full path of backup file (.tar / .tar.gz / .vhdx)' })"
        if (-not $fileInput -or -not (Test-Path -LiteralPath $fileInput)) {
            Write-Host "`n[!] $(if ($global:CurrentLang -eq 'zh-CN') { "未找到指定备份文件: $fileInput" } else { "Backup file not found: $fileInput" })" -ForegroundColor Red
            return
        }
        $selectedFile = $fileInput
    }

    if ((Get-Item -LiteralPath $selectedFile).Name -notmatch '(?i)\.(?:tar|tar\.gz|tar\.xz|vhdx)$') {
        Write-Host "`n[!] Unsupported backup format. Use .tar, .tar.gz, .tar.xz, or .vhdx." -ForegroundColor Red
        return
    }

    # 3. 智能推导默认发行版名称
    $fileItem = Get-Item -LiteralPath $selectedFile
    $baseNameWithoutArchiveExtension = $fileItem.Name -replace '(?i)\.(?:tar|tar\.gz|tar\.xz|vhdx)$', ''
    $defaultDistroName = $baseNameWithoutArchiveExtension -replace '-backup.*$', '' -replace '[^a-zA-Z0-9._-]', ''
    if (-not $defaultDistroName) { $defaultDistroName = "Debian-Restored" }

    $distroInput = Read-Host "`n$(if ($global:CurrentLang -eq 'zh-CN') { "输入还原后的 WSL 发行版名称 (按回车默认 '$defaultDistroName')" } else { "Enter restored WSL distro name (Default '$defaultDistroName')" })"
    $distroName = if ($distroInput) { ($distroInput -replace '[^a-zA-Z0-9._-]', '').Trim() } else { $defaultDistroName }

    # 检查名称重名
    $existingDistros = @(Get-WslDistros)
    if ($existingDistros -contains $distroName) {
        Write-Host "`n[!] $(if ($global:CurrentLang -eq 'zh-CN') { "错误: 发行版名称 '$distroName' 已经存在！" } else { "Error: Distro name '$distroName' already exists!" })" -ForegroundColor Red
        return
    }

    # 4. 引导输入还原目标安装目录
    $defaultInstallDir = Join-Path $DefaultWslRoot $distroName
    $dirInput = Read-Host "$(if ($global:CurrentLang -eq 'zh-CN') { "输入还原目标安装目录 (按回车默认 '$defaultInstallDir')" } else { "Enter target install directory (Default '$defaultInstallDir')" })"
    $installDir = if ($dirInput) { $dirInput.Trim() } else { $defaultInstallDir }

    if (Test-Path -LiteralPath $installDir) {
        Write-Host "`n[!] $(if ($global:CurrentLang -eq 'zh-CN') { "错误: 安装目录已存在 -> '$installDir'" } else { "Error: Install directory already exists -> '$installDir'" })" -ForegroundColor Red
        return
    }

    # 5. 参数确认
    Write-Host "`n[!] $(if ($global:CurrentLang -eq 'zh-CN') { '还原参数确认:' } else { 'Restore Parameters Confirmation:' })" -ForegroundColor Yellow
    Write-Host "    $(if ($global:CurrentLang -eq 'zh-CN') { '备份文件来源' } else { 'Backup File' }): $selectedFile" -ForegroundColor Cyan
    Write-Host "    $(if ($global:CurrentLang -eq 'zh-CN') { '还原发行版名称' } else { 'Restored Distro Name' }): $distroName" -ForegroundColor Cyan
    Write-Host "    $(if ($global:CurrentLang -eq 'zh-CN') { '目标安装物理目录' } else { 'Target Install Path' }): $installDir" -ForegroundColor Cyan

    $confirm = Read-Host "`n$(if ($global:CurrentLang -eq 'zh-CN') { "确认开始导入还原 '$distroName' 吗？[Y/N]" } else { "Confirm import restore '$distroName'? [Y/N]" })"
    if ($confirm -ne 'Y' -and $confirm -ne 'y') {
        Write-Host "$(Get-I18nStr 'Operation_Cancelled')" -ForegroundColor Gray
        return
    }

    # 6. 执行导入还原。VHDX 使用 --import --vhd 复制到目标目录，避免把备份文件直接注册为运行磁盘。
    Write-Host "`n$(if ($global:CurrentLang -eq 'zh-CN') { "正在导入备份还原 WSL 发行版 '$distroName'..." } else { "Importing backup restore '$distroName'..." })" -ForegroundColor Green

    $createdInstallDir = $false
    if (-not (Test-Path -LiteralPath $installDir)) {
        New-Item -ItemType Directory -Path $installDir -Force | Out-Null
        $createdInstallDir = $true
    }

    if ($selectedFile.EndsWith('.vhdx', [System.StringComparison]::OrdinalIgnoreCase)) {
        & wsl.exe --import $distroName $installDir $selectedFile --vhd
    } else {
        & wsl.exe --import $distroName $installDir $selectedFile --version 2
    }

    if ($LASTEXITCODE -eq 0) {
        Write-Host "`n[✓] $(if ($global:CurrentLang -eq 'zh-CN') { 'WSL 发行版还原导入成功！' } else { 'WSL Distro restored successfully!' })" -ForegroundColor Green
        & wsl.exe --list --verbose
        Write-Host "`n$(if ($global:CurrentLang -eq 'zh-CN') { "启动该发行版命令: wsl -d $distroName" } else { "Launch command: wsl -d $distroName" })" -ForegroundColor Yellow
    } else {
        Write-Host "`n[!] $(if ($global:CurrentLang -eq 'zh-CN') { "导入失败 (Exit Code: $LASTEXITCODE)。" } else { "Import failed (Exit Code: $LASTEXITCODE)." })" -ForegroundColor Red
        if ($createdInstallDir -and (Test-Path -LiteralPath $installDir)) {
            $remainingItems = @(Get-ChildItem -LiteralPath $installDir -Force -ErrorAction SilentlyContinue)
            if ($remainingItems.Count -eq 0) {
                Remove-Item -LiteralPath $installDir -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

Invoke-WslRestore
