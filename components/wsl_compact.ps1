# ==============================================================================
# components/wsl_compact.ps1
# Description: 08. 清理并压缩所有与 WSL 相关的物理磁盘与空间 (带 Double Confirm)
# ==============================================================================

param(
    [string]$DefaultWslRoot = 'D:\wsl'
)

. "$PSScriptRoot\wsl_i18n.ps1"
. "$PSScriptRoot\wsl_common.ps1"

function Invoke-WslCompactAll {
    Write-Host "`n==========================================" -ForegroundColor Cyan
    Write-Host " 8. 全量清理与压缩所有 WSL 相关的物理磁盘空间 " -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan

    $distros = Get-WslDistros
    if ($distros.Count -eq 0) {
        Write-Host "未检测到任何已安装的 WSL 发行版。" -ForegroundColor Red
        return
    }

    # 扫描所有 .vhdx 镜像
    $targetItems = @()
    $totalBeforeBytes = 0

    foreach ($distro in $distros) {
        $vhdxPath = Join-Path $DefaultWslRoot "$distro\ext4.vhdx"
        if (Test-Path -LiteralPath $vhdxPath) {
            $item = Get-Item -LiteralPath $vhdxPath
            $targetItems += @{
                DistroName = $distro
                Path       = $vhdxPath
                Length     = $item.Length
            }
            $totalBeforeBytes += $item.Length
        }
    }

    if ($targetItems.Count -eq 0) {
        Write-Host "[!] 在默认路径中未查找到任何 ext4.vhdx 磁盘文件。" -ForegroundColor Red
        return
    }

    $totalBeforeGB = [math]::Round($totalBeforeBytes / 1GB, 2)

    Write-Host "`n检测到以下待清理压缩的 WSL 虚拟磁盘:" -ForegroundColor Yellow
    foreach ($t in $targetItems) {
        $sizeGB = [math]::Round($t.Length / 1GB, 2)
        Write-Host "  • [$($t.DistroName)] -> $($t.Path) ($sizeGB GB)" -ForegroundColor Cyan
    }
    Write-Host "当前全部 WSL 磁盘物理总体积: $totalBeforeGB GB" -ForegroundColor Yellow

    Write-Host "`n请选择清理范围:" -ForegroundColor Yellow
    Write-Host " [A] 全选 - 清理与压缩所有 WSL 相关的磁盘空间 (All)" -ForegroundColor Magenta
    Write-Host " [S] 仅清理指定的单个 WSL 发行版" -ForegroundColor Yellow
    Write-Host " [0] 取消操作" -ForegroundColor Gray

    $modeChoice = Read-Host "`n请输入选项 [A / S / 0]"
    if ($modeChoice -eq '0' -or -not $modeChoice) { return }

    $itemsToProcess = @()
    if ($modeChoice -in 'A', 'a', 'ALL', 'all') {
        $itemsToProcess = $targetItems
    } elseif ($modeChoice -in 'S', 's') {
        $singleDistro = Select-WslDistro -Title "选择要压缩清理的单个 WSL 发行版"
        if (-not $singleDistro) { return }
        $itemsToProcess = @($targetItems | Where-Object { $_.DistroName -eq $singleDistro })
    } else {
        Write-Host "`n[!] 输入未匹配到有效选项，操作取消。" -ForegroundColor Red
        return
    }

    if ($itemsToProcess.Count -eq 0) { return }

    # --------------------------------------------------------------------------
    # 第一次确认 (Step 1 Confirmation)
    # --------------------------------------------------------------------------
    Write-Host "`n[!] ⚠️ 警告: 准备停止服务并对以下 $($itemsToProcess.Count) 个 WSL 实例执行深度磁盘清理与碎片整理压缩:" -ForegroundColor Red
    foreach ($item in $itemsToProcess) {
        Write-Host "   • $($item.DistroName) ($($item.Path))" -ForegroundColor Yellow
    }
    $confirm1 = Read-Host "`n[1/2 第一次确认] 确认要继续吗？(输入 Y 确认)"
    if ($confirm1 -ne 'Y' -and $confirm1 -ne 'y') {
        Write-Host "操作已取消。" -ForegroundColor Gray
        return
    }

    # --------------------------------------------------------------------------
    # 第二次确认 (Step 2 Double Confirmation)
    # --------------------------------------------------------------------------
    Write-Host "`n[!] 🚨 最终二次确认: 压缩过程中选中的 WSL 发行版将被安全停止！" -ForegroundColor Red
    $confirm2 = Read-Host "[2/2 第二次确认] 请手动输入大写 'COMPACT' 以最终执行全量清理"

    if ($confirm2 -ne 'COMPACT') {
        Write-Host "二次确认未通过，清理压缩操作已安全取消。" -ForegroundColor Yellow
        return
    }

    # --------------------------------------------------------------------------
    # 执行全量清理与压缩
    # --------------------------------------------------------------------------
    Write-Host "`n开始执行全量 WSL 磁盘瘦身与空间清理..." -ForegroundColor Green

    foreach ($target in $itemsToProcess) {
        $name = $target.DistroName
        $path = $target.Path

        Write-Host "`n------------------------------------------" -ForegroundColor Yellow
        Write-Host "正在处理发行版: $name" -ForegroundColor Yellow
        Write-Host "------------------------------------------" -ForegroundColor Yellow

        # 1. fstrim
        Write-Host "[1/3] 正在 Linux 内部清理零碎数据块 (fstrim)..." -ForegroundColor Green
        & wsl.exe -d $name -u root -- bash -c "fstrim -v / 2>/dev/null || true"

        # 2. terminate
        Write-Host "[2/3] 正在安全停止发行版 $name ..." -ForegroundColor Green
        & wsl.exe --terminate $name 2>$null
        Start-Sleep -Seconds 2

        # 3. diskpart compact
        Write-Host "[3/3] 正在调用 Diskpart 执行物理 VHDX 体积紧凑化..." -ForegroundColor Green
        $diskpartScript = @"
select vdisk file="$path"
attach vdisk readonly
compact vdisk
detach vdisk
"@
        $tempScriptFile = [System.IO.Path]::GetTempFileName()
        [System.IO.File]::WriteAllText($tempScriptFile, $diskpartScript, [System.Text.Encoding]::ASCII)

        try {
            & diskpart.exe /s $tempScriptFile
        } finally {
            Remove-Item -LiteralPath $tempScriptFile -Force 2>$null
        }
    }

    # --------------------------------------------------------------------------
    # 结果汇总比对
    # --------------------------------------------------------------------------
    $totalAfterBytes = 0
    foreach ($target in $itemsToProcess) {
        if (Test-Path -LiteralPath $target.Path) {
            $item = Get-Item -LiteralPath $target.Path
            $totalAfterBytes += $item.Length
        }
    }

    $afterTotalGB = [math]::Round($totalAfterBytes / 1GB, 2)
    $savedGB = [math]::Max(0, [math]::Round(($totalBeforeBytes - $totalAfterBytes) / 1GB, 2))
    $savedMB = [math]::Max(0, [math]::Round(($totalBeforeBytes - $totalAfterBytes) / 1MB, 2))

    Write-Host "`n==========================================" -ForegroundColor Green
    Write-Host "    [✓] 全量 WSL 磁盘清理与瘦身压缩完成！  " -ForegroundColor Green
    Write-Host "==========================================" -ForegroundColor Green
    Write-Host "    瘦身前总体积: $totalBeforeGB GB" -ForegroundColor Gray
    Write-Host "    瘦身后总体积: $afterTotalGB GB" -ForegroundColor Cyan
    Write-Host "    🎉 成功回收宿主物理空间: $savedGB GB ($savedMB MB)" -ForegroundColor Yellow
    Write-Host "==========================================" -ForegroundColor Green
}

Invoke-WslCompactAll
