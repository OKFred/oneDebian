# ==============================================================================
# components/wsl_purge.ps1
# Description: 08. WSL 环境全量彻底清理与重置 (100% 全量双语 i18n 兼容)
# ==============================================================================

param(
    [string]$DefaultWslRoot = 'D:\wsl'
)

. "$PSScriptRoot\wsl_i18n.ps1"
. "$PSScriptRoot\wsl_common.ps1"

function Invoke-WslPurge {
    Write-Host "`n==========================================" -ForegroundColor Red
    Write-Host "     $(Get-I18nStr 'Purge_Title')        " -ForegroundColor Red
    Write-Host "==========================================" -ForegroundColor Red

    $distros = Get-WslDistros
    $archiveDir = Join-Path $DefaultWslRoot 'images'
    $backupDir = Join-Path $DefaultWslRoot 'backups'

    Write-Host "`n$(Get-I18nStr 'Purge_Scan_Summary')" -ForegroundColor Yellow
    Write-Host "  • $(if ($global:CurrentLang -eq 'zh-CN') { '已检测到的 WSL 发行版' } else { 'Detected WSL Distros' }): $(if ($distros.Count -gt 0) { $distros -join ', ' } else { if ($global:CurrentLang -eq 'zh-CN') { '无' } else { 'None' } })" -ForegroundColor Cyan
    Write-Host "  • $(if ($global:CurrentLang -eq 'zh-CN') { '安装根目录路径' } else { 'Install Root Path' }):   $DefaultWslRoot" -ForegroundColor Cyan
    Write-Host "  • $(if ($global:CurrentLang -eq 'zh-CN') { '镜像缓存目录' } else { 'Rootfs Image Cache' }):  $archiveDir" -ForegroundColor Gray
    Write-Host "  • $(if ($global:CurrentLang -eq 'zh-CN') { '备份文件目录' } else { 'Backup Directory' }):    $backupDir" -ForegroundColor Gray

    Write-Host "`n$(Get-I18nStr 'Purge_Scope_Title')" -ForegroundColor Yellow
    Write-Host " $(Get-I18nStr 'Purge_Opt_All')" -ForegroundColor Red
    Write-Host " $(Get-I18nStr 'Purge_Opt_Single')" -ForegroundColor Yellow
    Write-Host " [0] $(Get-I18nStr 'Cancel_Operation')" -ForegroundColor Gray

    $modeChoice = Read-Host "`n$(Get-I18nStr 'Prompt_Select') [00-08, L, 99, 0] [A / S / 0]"
    if ($modeChoice -eq '0' -or -not $modeChoice) { return }

    $targetDistros = @()
    $cleanImages = $false
    $cleanBackups = $false

    if ($modeChoice -in 'A', 'a', 'ALL', 'all') {
        $targetDistros = $distros
        $cleanImages = $true
        $cleanBackups = $true
    } elseif ($modeChoice -in 'S', 's') {
        $single = Select-WslDistro -Title $(Get-I18nStr 'Select_Distro_Title')
        if (-not $single) { return }
        $targetDistros = @($single)
    } else {
        Write-Host "`n[!] $(Get-I18nStr 'Err_InvalidChoice')" -ForegroundColor Red
        return
    }

    # 1/2 第一次确认
    Write-Host "`n==========================================" -ForegroundColor Red
    Write-Host "       $(Get-I18nStr 'Purge_Warn')       " -ForegroundColor Red
    Write-Host "==========================================" -ForegroundColor Red
    if ($targetDistros.Count -gt 0) {
        foreach ($d in $targetDistros) {
            Write-Host "   • $(if ($global:CurrentLang -eq 'zh-CN') { '注销并删除文件夹' } else { 'Unregister & delete folder' }): $DefaultWslRoot\$d" -ForegroundColor Yellow
        }
    }
    if ($cleanImages -and (Test-Path -LiteralPath $archiveDir)) {
        Write-Host "   • $(if ($global:CurrentLang -eq 'zh-CN') { '删除镜像缓存' } else { 'Delete rootfs cache' }): $archiveDir" -ForegroundColor Yellow
    }
    if ($cleanBackups -and (Test-Path -LiteralPath $backupDir)) {
        Write-Host "   • $(if ($global:CurrentLang -eq 'zh-CN') { '删除全部导出备份' } else { 'Delete all backups' }): $backupDir" -ForegroundColor Yellow
    }

    $confirm1 = Read-Host "`n$(Get-I18nStr 'Purge_Confirm_Step1')"
    if ($confirm1 -ne 'Y' -and $confirm1 -ne 'y') {
        Write-Host "$(Get-I18nStr 'Operation_Cancelled')" -ForegroundColor Gray
        return
    }

    # 2/2 第二次确认
    $confirm2 = Read-Host "`n$(Get-I18nStr 'Purge_Confirm_Step2')"
    if ($confirm2 -ne 'PURGE') {
        Write-Host "`n[!] $(if ($global:CurrentLang -eq 'zh-CN') { '二次确认未通过，清理操作已安全取消。' } else { 'Confirmation failed. Purge operation cancelled.' })" -ForegroundColor Yellow
        return
    }

    # 执行清理
    Write-Host "`n$(if ($global:CurrentLang -eq 'zh-CN') { '正在关闭全局 WSL 进程...' } else { 'Shutting down WSL ...' })" -ForegroundColor Red
    & wsl.exe --shutdown 2>$null

    foreach ($d in $targetDistros) {
        Write-Host "`n[1/3] $(if ($global:CurrentLang -eq 'zh-CN') { "正在注销 WSL 发行版: $d ..." } else { "Unregistering WSL distro: $d ..." })" -ForegroundColor Red
        & wsl.exe --unregister $d 2>$null

        $distroDir = Join-Path $DefaultWslRoot $d
        if (Test-Path -LiteralPath $distroDir) {
            Write-Host "     $(if ($global:CurrentLang -eq 'zh-CN') { "正在删除存储目录: $distroDir ..." } else { "Deleting storage directory: $distroDir ..." })" -ForegroundColor Yellow
            Remove-Item -LiteralPath $distroDir -Recurse -Force 2>$null
        }
    }

    if ($cleanImages -and (Test-Path -LiteralPath $archiveDir)) {
        Write-Host "`n[2/3] $(if ($global:CurrentLang -eq 'zh-CN') { "正在删除镜像缓存: $archiveDir ..." } else { "Deleting image cache: $archiveDir ..." })" -ForegroundColor Red
        Remove-Item -LiteralPath $archiveDir -Recurse -Force 2>$null
    }

    if ($cleanBackups -and (Test-Path -LiteralPath $backupDir)) {
        Write-Host "`n[3/3] $(if ($global:CurrentLang -eq 'zh-CN') { "正在删除备份目录: $backupDir ..." } else { "Deleting backup directory: $backupDir ..." })" -ForegroundColor Red
        Remove-Item -LiteralPath $backupDir -Recurse -Force 2>$null
    }

    Write-Host "`n$(if ($global:CurrentLang -eq 'zh-CN') { '正在重新初始化 WSL 核心堆栈...' } else { 'Resetting WSL core stack...' })" -ForegroundColor Green
    & wsl.exe --shutdown 2>$null

    Write-Host "`n==========================================" -ForegroundColor Green
    Write-Host "       [✓] $(if ($global:CurrentLang -eq 'zh-CN') { '全量 WSL 环境清理重置完成！' } else { 'Full WSL Purge Complete!' })       " -ForegroundColor Green
    Write-Host "==========================================" -ForegroundColor Green
}

Invoke-WslPurge
