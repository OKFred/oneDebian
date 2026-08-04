# ==============================================================================
# components/wsl_uninstall.ps1
# Description: 注销/卸载指定 WSL 发行版（支持全选及二次确认防误删）
# ==============================================================================

param(
    [string]$DefaultWslRoot = 'D:\wsl'
)

. "$PSScriptRoot\wsl_common.ps1"

function Select-Uninstall-Distros {
    $distros = Get-WslDistros
    if ($distros.Count -eq 0) {
        Write-Host "未检测到任何已安装的 WSL 发行版。" -ForegroundColor Red
        return @()
    }

    Write-Host "`n=== 选择要卸载注销的 WSL 发行版 ===" -ForegroundColor Cyan
    for ($i = 0; $i -lt $distros.Count; $i++) {
        Write-Host " [$($i + 1)] $($distros[$i])" -ForegroundColor Yellow
    }
    Write-Host " [A] 全选 (All - 选择所有发行版)" -ForegroundColor Magenta
    Write-Host " [0] 取消操作" -ForegroundColor Gray

    $inputChoice = Read-Host "`n请输入序号 [1-$($distros.Count)], 全选 [A], 或 取消 [0]"
    if ($inputChoice -eq '0' -or -not $inputChoice) {
        return @()
    }

    if ($inputChoice -in 'A', 'a', 'ALL', 'all') {
        return $distros
    }

    if ([int]::TryParse($inputChoice, [ref]$null)) {
        $idx = [int]$inputChoice
        if ($idx -ge 1 -and $idx -le $distros.Count) {
            return @($distros[$idx - 1])
        }
    }

    Write-Host "`n[!] 输入 '$inputChoice' 未匹配到有效选项，请正确输入！" -ForegroundColor Red
    Start-Sleep -Seconds 1
    return @()

}

function Invoke-WslUninstall {
    Write-Host "`n==========================================" -ForegroundColor Red
    Write-Host "          5. 卸载 (注销) WSL 发行版        " -ForegroundColor Red
    Write-Host "==========================================" -ForegroundColor Red

    $selectedDistros = Select-Uninstall-Distros
    if ($selectedDistros.Count -eq 0) { return }

    # --------------------------------------------------------------------------
    # 第一次确认 (Step 1 Confirmation)
    # --------------------------------------------------------------------------
    Write-Host "`n[!] ⚠️ 警告: 准备注销卸载以下 WSL 发行版:" -ForegroundColor Red
    foreach ($d in $selectedDistros) {
        Write-Host "   • $d" -ForegroundColor Yellow
    }
    Write-Host "注销后系统内部所有数据将彻底删除且无法恢复！" -ForegroundColor Red
    $confirm1 = Read-Host "`n[1/2 第一次确认] 确认要继续吗？(输入 Y 确认继续)"

    if ($confirm1 -ne 'Y' -and $confirm1 -ne 'y') {
        Write-Host "操作已取消。" -ForegroundColor Gray
        return
    }

    # --------------------------------------------------------------------------
    # 第二次确认 (Step 2 Double Confirmation)
    # --------------------------------------------------------------------------
    Write-Host "`n[!] 🚨 最终二次确认: 该操作不可逆！" -ForegroundColor Red
    $confirm2 = Read-Host "[2/2 第二次确认] 请手动输入大写 'DELETE' 以最终执行"

    if ($confirm2 -ne 'DELETE') {
        Write-Host "二次确认未通过，删除操作已安全取消。" -ForegroundColor Yellow
        return
    }

    # --------------------------------------------------------------------------
    # 执行批量注销/卸载
    # --------------------------------------------------------------------------
    Write-Host "`n正在执行注销操作..." -ForegroundColor Red
    foreach ($distro in $selectedDistros) {
        Write-Host "`n正在注销 $distro ..." -ForegroundColor Yellow
        & wsl.exe --unregister $distro
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[✓] 发行版 $distro 已成功注销卸载！" -ForegroundColor Green

            # 检查是否有残留的本地数据文件夹
            $potentialPath = Join-Path $DefaultWslRoot $distro
            if (Test-Path -LiteralPath $potentialPath) {
                $cleanFolder = Read-Host "检测到本地残留文件夹 '$potentialPath'，是否一并彻底删除？[Y/N]"
                if ($cleanFolder -eq 'Y' -or $cleanFolder -eq 'y') {
                    Remove-Item -LiteralPath $potentialPath -Recurse -Force
                    Write-Host "[✓] 本地文件夹已清理。" -ForegroundColor Green
                }
            }
        } else {
            Write-Host "[✗] 注销 $distro 失败，退出代码: $LASTEXITCODE" -ForegroundColor Red
        }
    }
}

Invoke-WslUninstall
