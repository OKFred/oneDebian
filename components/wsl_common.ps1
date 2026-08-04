# ==============================================================================
# components/wsl_common.ps1
# Description: WSL 管理脚本公共辅助函数
# ==============================================================================

function Get-WslDistros {
    $rawList = & wsl.exe --list --quiet 2>$null
    if (-not $rawList) { return @() }
    
    $distros = @(
        $rawList | ForEach-Object { $_ -replace "`0", "" } |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ }
    )
    return $distros
}

function Pause-Menu {
    Write-Host "`nPress any key to return to menu... (按任意键返回主菜单)" -ForegroundColor Gray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

function Select-WslDistro {
    param([string]$Title = "请选择 WSL 发行版")

    $distros = Get-WslDistros
    if ($distros.Count -eq 0) {
        Write-Host "未检测到任何已安装的 WSL 发行版。" -ForegroundColor Red
        return $null
    }

    Write-Host "`n=== $Title ===" -ForegroundColor Cyan
    for ($i = 0; $i -lt $distros.Count; $i++) {
        Write-Host " [$($i + 1)] $($distros[$i])" -ForegroundColor Yellow
    }
    Write-Host " [0] 取消操作" -ForegroundColor Gray

    $choice = Read-Host "`n请输入序号 [1-$($distros.Count)]"
    if ($choice -eq '0') { return $null }

    if ([int]::TryParse($choice, [ref]$null)) {
        $idx = [int]$choice
        if ($idx -ge 1 -and $idx -le $distros.Count) {
            return $distros[$idx - 1]
        }
    }

    Write-Host "`n[!] 输入 '$choice' 未匹配到有效选项，请正确输入！" -ForegroundColor Red
    Start-Sleep -Seconds 1
    return $null

}
