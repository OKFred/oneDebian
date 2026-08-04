# ==============================================================================
# components/wsl_status.ps1
# Description: 07. WSL 运维诊断与实例状态仪表盘
# ==============================================================================

param(
    [string]$DefaultWslRoot = 'D:\wsl'
)

. "$PSScriptRoot\wsl_i18n.ps1"
. "$PSScriptRoot\wsl_common.ps1"

function Show-WslDashboard {
    Write-Host "`n==========================================" -ForegroundColor Cyan
    Write-Host "     7. WSL 运维诊断与实例状态仪表盘      " -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan

    # 1. 读取 WSL 核心环境信息
    Write-Host "`n[1/3 WSL 基础架构环境诊断]" -ForegroundColor Yellow
    $wslVerRaw = & wsl.exe --version 2>$null
    if ($LASTEXITCODE -eq 0 -and $wslVerRaw) {
        $firstLine = ($wslVerRaw | Select-Object -First 1) -replace "`0", ""
        Write-Host "  • WSL 核心服务: 正常运行 ($firstLine)" -ForegroundColor Green
    } else {
        Write-Host "  • WSL 核心服务: 已安装 (传统 Windows WSL 模块)" -ForegroundColor Gray
    }

    # 2. 读取所有已安装的 WSL 发行版与 Disk VHDX 大小
    Write-Host "`n[2/3 已安装 WSL 发行版资源清单]" -ForegroundColor Yellow
    
    $distros = Get-WslDistros
    if ($distros.Count -eq 0) {
        Write-Host "  未检测到任何已安装的 WSL 发行版。" -ForegroundColor Red
        return
    }

    $verboseList = & wsl.exe --list --verbose 2>$null

    Write-Host " --------------------------------------------------------------------------------" -ForegroundColor Gray
    Write-Host "  序号  |  发行版名称    |  状态 (State)  |  WSL 版本  |  vhdx 物理镜像大小 " -ForegroundColor Cyan
    Write-Host " --------------------------------------------------------------------------------" -ForegroundColor Gray

    for ($i = 0; $i -lt $distros.Count; $i++) {
        $name = $distros[$i]
        
        # 获取状态
        $state = "Stopped"
        $wslVer = "2"
        if ($verboseList) {
            foreach ($line in $verboseList) {
                $cleanLine = ($line -replace "`0", "").Trim()
                if ($cleanLine -match "^\*?\s*$name\s+(?<state>Running|Stopped)\s+(?<ver>\d)") {
                    $state = $Matches['state']
                    $wslVer = $Matches['ver']
                    break
                }
            }
        }

        # 计算 vhdx 大小
        $vhdxSizeStr = "未查找到文件"
        $possiblePaths = @(
            (Join-Path $DefaultWslRoot "$name\ext4.vhdx"),
            "$env:LOCALAPPDATA\Packages\*$name*\LocalState\ext4.vhdx"
        )
        
        $foundFile = $null
        if (Test-Path -LiteralPath (Join-Path $DefaultWslRoot "$name\ext4.vhdx")) {
            $foundFile = Get-Item -LiteralPath (Join-Path $DefaultWslRoot "$name\ext4.vhdx")
        }

        if ($foundFile) {
            $sizeGB = [math]::Round($foundFile.Length / 1GB, 2)
            $vhdxSizeStr = "$sizeGB GB"
        }

        $stateColor = if ($state -eq 'Running') { 'Green' } else { 'Gray' }
        Write-Host ("  [{0}]   |  {1,-12} |  {2,-12} |  WSL {3}     |  {4}" -f ($i + 1), $name, $state, $wslVer, $vhdxSizeStr) -ForegroundColor $stateColor
    }
    Write-Host " --------------------------------------------------------------------------------" -ForegroundColor Gray

    # 3. 运维操作管理
    Write-Host "`n[3/3 实例管理操作]" -ForegroundColor Yellow
    Write-Host " [T] 强制终止某个指定的僵死发行版 (wsl --terminate)"
    Write-Host " [S] 全局软重启 WSL 堆栈 (wsl --shutdown)"
    Write-Host " [0] 返回主菜单"

    $opChoice = Read-Host "`n请输入操作选项 [T / S / 0]"
    if ($opChoice -in 'T', 't') {
        $target = Select-WslDistro -Title "选择要终止进程的 WSL 发行版"
        if ($target) {
            Write-Host "`n正在停止发行版 $target ..." -ForegroundColor Yellow
            & wsl.exe --terminate $target
            Write-Host "[✓] 已成功停止 $target" -ForegroundColor Green
        }
    } elseif ($opChoice -in 'S', 's') {
        $confirm = Read-Host "`n确认要执行全局 wsl --shutdown 重启 WSL 吗？所有运行中的 WSL 将被关闭！[Y/N]"
        if ($confirm -in 'Y', 'y') {
            Write-Host "`n正在执行全局 shutdown..." -ForegroundColor Red
            & wsl.exe --shutdown
            Write-Host "[✓] 全局 WSL 堆栈已关闭重置。" -ForegroundColor Green
        }
    }
}

Show-WslDashboard
