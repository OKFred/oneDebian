# ==============================================================================
# components/wsl_config.ps1
# Description: WSL 引导式配置向导 (.wslconfig 与 wsl.conf)
#              支持 [回车=默认值 | Tab=不填] 的高级交互逻辑、Git Diff 预览
# ==============================================================================

param(
    [string]$DefaultWslRoot = 'D:\wsl'
)

. "$PSScriptRoot\wsl_common.ps1"

# ------------------------------------------------------------------------------
# 辅助函数: 统一问答处理 (回车=默认值, Tab=不填)
# ------------------------------------------------------------------------------
function Read-ConfigPrompt {
    param(
        [string]$Message,
        [string]$DefaultValue = "",
        [string]$HintText = ""
    )

    if ($HintText) {
        Write-Host "`n提示: $HintText" -ForegroundColor Gray
    }

    $promptText = if ($DefaultValue) {
        "$Message `n  [按回车: 应用默认值 ($DefaultValue) | 输入 '--': 不填/跳过] "
    } else {
        "$Message `n  [按回车/输入 '--': 不填/跳过] "
    }

    $inputVal = Read-Host $promptText

    # 1. 输入 '--' / '-' / 'none' / 'skip' / 'n' 表示用户选择 "不填/忽略"
    if ($inputVal.Trim() -in '--', '-', 'none', 'skip', 'n') {
        Write-Host "  -> 已选择 [不填/保持缺省]" -ForegroundColor DarkYellow
        return $null
    }


    # 2. 空文本 (直接按回车)，使用 "默认值"
    if ([string]::IsNullOrWhiteSpace($inputVal)) {
        if ($DefaultValue) {
            Write-Host "  -> 使用默认值 [$DefaultValue]" -ForegroundColor DarkCyan
            return $DefaultValue
        } else {
            Write-Host "  -> 已跳过" -ForegroundColor DarkYellow
            return $null
        }
    }

    # 3. 自定义文本
    $trimmed = $inputVal.Trim()
    Write-Host "  -> 已设定 [$trimmed]" -ForegroundColor Green
    return $trimmed
}



# ------------------------------------------------------------------------------
# 辅助函数: 彩色 Git Diff 配置预览
# ------------------------------------------------------------------------------
function Show-ConfigDiff {
    param(
        [string]$OldContent = "",
        [string]$NewContent = "",
        [string]$TargetTitle = "配置文件"
    )

    Write-Host "`n==========================================" -ForegroundColor Cyan
    Write-Host "    $TargetTitle 变更对比 (Git Diff 预览)   " -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan

    if (-not $OldContent) {
        Write-Host "[全新新建文件] 当前不存在旧配置文件，即将新建:" -ForegroundColor Green
        $lines = $NewContent -split "`r?`n"
        foreach ($line in $lines) {
            Write-Host "+ $line" -ForegroundColor Green
        }
        Write-Host "==========================================" -ForegroundColor Cyan
        return
    }

    $oldLines = @($OldContent -split "`r?`n")
    $newLines = @($NewContent -split "`r?`n")

    $diffResult = Compare-Object -ReferenceObject $oldLines -DifferenceObject $newLines -IncludeEqual

    foreach ($item in $diffResult) {
        if ($item.SideIndicator -eq '==') {
            Write-Host "  $($item.InputObject)" -ForegroundColor Gray
        } elseif ($item.SideIndicator -eq '=>') {
            Write-Host "+ $($item.InputObject)" -ForegroundColor Green
        } elseif ($item.SideIndicator -eq '<=') {
            Write-Host "- $($item.InputObject)" -ForegroundColor Red
        }
    }
    Write-Host "==========================================" -ForegroundColor Cyan
}

# ------------------------------------------------------------------------------
# 1. 全局配置向导 (.wslconfig)
# ------------------------------------------------------------------------------
function Configure-WslConfig {
    Write-Host "`n------------------------------------------" -ForegroundColor Yellow
    Write-Host "   Windows 全局配置向导 (~/.wslconfig)   " -ForegroundColor Yellow
    Write-Host "------------------------------------------" -ForegroundColor Yellow

    $wslConfigPath = Join-Path $env:USERPROFILE '.wslconfig'
    $existingContent = ""
    if (Test-Path -LiteralPath $wslConfigPath) {
        $existingContent = [System.IO.File]::ReadAllText($wslConfigPath)
    }

    Write-Host "交互说明: [按回车] 自动应用推荐默认值；输入双减号 [--] 则该项不填/保持缺省。`n" -ForegroundColor Cyan




    # --- 资源限制 ---
    Write-Host "--- [1/3 资源限制配置] ---" -ForegroundColor Yellow
    $mem = Read-ConfigPrompt -Message "设置最大内存 (如 8GB / 16GB)" -DefaultValue "8GB"
    $cpu = Read-ConfigPrompt -Message "设置 CPU 核数 (如 4 / 8)" -DefaultValue "4"
    $swap = Read-ConfigPrompt -Message "设置 Swap 虚拟内存 (如 4GB / 0表示禁用)" -DefaultValue "4GB"

    # --- 网络与端口隔离 ---
    Write-Host "`n--- [2/3 网络与端口隔离配置] ---" -ForegroundColor Yellow
    $lhf = Read-ConfigPrompt -Message "是否将 WSL 内部端口映射绑定到 Windows localhost？[true/false]" `
        -DefaultValue "true" `
        -HintText "若多个 WSL 跑 Node.js (如 7001 端口) 做独立 Vibe Coding，填 false 可完全隔离端口不抢占宿主机 localhost"

    Write-Host "`n--- [WSL2 网络模式详解 (networkingMode)] ---" -ForegroundColor Cyan
    Write-Host " [1] NAT 模式 (官方默认)" -ForegroundColor Yellow
    Write-Host "     • 原理: WSL2 运行在独立的 Hyper-V 虚拟网卡后，拥有私有的 172.x.x.x 内网 IP。" -ForegroundColor Gray
    Write-Host "     • 优点: 隔离性强，局域网外设备无法随意访问 WSL，安全性高且不占用宿主局域网 IP。" -ForegroundColor Gray
    Write-Host "     • 缺点: 跨 VPN / 代理网络时可能出现 DNS 或路由不通；局域网其他设备无法直接连入。" -ForegroundColor Gray

    Write-Host " [2] mirrored 镜像网络模式 (现代高级开发推荐)" -ForegroundColor Yellow
    Write-Host "     • 原理: WSL2 镜像共享 Windows 宿主机的完整网络栈与网络接口 IP 地址。" -ForegroundColor Gray
    Write-Host "     • 优点: 100% 兼容公司 VPN 与代理软件；原生支持 IPv6；局域网其他设备可直接访问 WSL。" -ForegroundColor Gray
    Write-Host "     • 缺点: 暴露在宿主网络中隔离度较低；若 WSL 监听开放端口在局域网内均可被连入。" -ForegroundColor Gray

    $netModeChoice = Read-ConfigPrompt -Message "请选择网络模式 [1: NAT (默认) | 2: mirrored]" -DefaultValue "NAT"
    $netMode = if ($netModeChoice -in '2', 'mirrored') { "mirrored" } else { "NAT" }


    $dns = Read-ConfigPrompt -Message "是否启用 DNS 隧道 (dnsTunneling)？[true/false]" `
        -DefaultValue "true" `
        -HintText "强烈建议填 true。解决在 Windows 开启公司 VPN、代理软件或切换 Wi-Fi 时，WSL 内部域名解析失败或突然断网的问题"



    # --- 高级与实验功能 ---
    Write-Host "`n--- [3/3 高级与实验特性] ---" -ForegroundColor Yellow
    $sparse = Read-ConfigPrompt -Message "是否启用 vhdx 磁盘自动回收 (sparseVhdx)？[true/false]" `
        -DefaultValue "true" `
        -HintText "强烈建议填 true。删除 WSL 内部大文件或 Docker 镜像后，自动把物理磁盘空间归还给 Windows D 盘"

    $reclaim = Read-ConfigPrompt -Message "内存自动释放策略 (autoMemoryReclaim) [dropcache/gradual/disabled]" `
        -DefaultValue "dropcache" `
        -HintText "dropcache(推荐): 任务结束后自动将 Linux 占用的内存退还给 Windows；disabled: 传统模式，常驻占用内存"


    # 组装 [wsl2] 节
    $wsl2Lines = @("[wsl2]")
    if ($mem) { $wsl2Lines += "memory=$mem" }
    if ($cpu) { $wsl2Lines += "processors=$cpu" }
    if ($swap) { $wsl2Lines += "swap=$swap" }
    if ($lhf) { $wsl2Lines += "localhostForwarding=$lhf" }
    $wsl2Lines += "nestedVirtualization=true"
    $wsl2Lines += "guiApplications=true"

    # 组装 [experimental] 节
    $expLines = @("[experimental]")
    if ($sparse) { $expLines += "sparseVhdx=$sparse" }
    if ($reclaim) { $expLines += "autoMemoryReclaim=$reclaim" }
    if ($netMode) { $expLines += "networkingMode=$netMode" }
    if ($dns) { $expLines += "dnsTunneling=$dns" }

    $newConfigContent = ($wsl2Lines + "" + $expLines) -join "`n"

    # 彩色 Git Diff 预览
    Show-ConfigDiff -OldContent $existingContent -NewContent $newConfigContent -TargetTitle "Windows 全局 .wslconfig"

    $confirmSave = Read-Host "`n确认将上述配置写入 $wslConfigPath 吗？[Y/N]"
    if ($confirmSave -in 'Y', 'y') {
        # 备份原文件
        if (Test-Path -LiteralPath $wslConfigPath) {
            $bakPath = "$wslConfigPath.bak_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
            Copy-Item -LiteralPath $wslConfigPath -Destination $bakPath -Force
            Write-Host "[✓] 原配置文件已备份至: $bakPath" -ForegroundColor Gray
        }

        [System.IO.File]::WriteAllText($wslConfigPath, $newConfigContent, [System.Text.Encoding]::UTF8)
        Write-Host "`n[✓] 全局配置文件 .wslconfig 已成功更新！" -ForegroundColor Green
        Write-Host "[!] 提示: 修改全局配置后，需在 PowerShell 执行 'wsl --shutdown' 重启 WSL 使配置生效。" -ForegroundColor Yellow
    } else {
        Write-Host "配置保存已取消。" -ForegroundColor Gray
    }
}

# ------------------------------------------------------------------------------
# 2. 单分发配置向导 (wsl.conf)
# ------------------------------------------------------------------------------
function Configure-SingleDistroConf {
    Write-Host "`n------------------------------------------" -ForegroundColor Yellow
    Write-Host "   分发内部配置向导 (/etc/wsl.conf)      " -ForegroundColor Yellow
    Write-Host "------------------------------------------" -ForegroundColor Yellow

    $targetDistro = Select-WslDistro -Title "选择要配置 wsl.conf 的 Debian 发行版"
    if (-not $targetDistro) { return }

    # 读取已有配置文件
    $existingContent = (& wsl.exe -d $targetDistro -u root -- bash -c "cat /etc/wsl.conf 2>/dev/null") -join "`n"

    Write-Host "`n正在配置发行版 '$targetDistro' 的 /etc/wsl.conf:" -ForegroundColor Cyan
    Write-Host "交互说明: [按回车] 自动应用默认值；输入双减号 [--] 则该项不填/不写入。`n" -ForegroundColor Cyan



    $systemd = Read-ConfigPrompt -Message "是否启用 Systemd 初始化服务管理器？[true/false]" -DefaultValue "true"
    $defaultUser = Read-ConfigPrompt -Message "默认登录用户名" -DefaultValue "root"
    $hostname = Read-ConfigPrompt -Message "自定义该分发的 Linux 主机名" -DefaultValue $targetDistro
    $genHosts = Read-ConfigPrompt -Message "是否自动生成 /etc/hosts？[true/false]" -DefaultValue "true"
    $genResolv = Read-ConfigPrompt -Message "是否自动生成 /etc/resolv.conf？[true/false]" -DefaultValue "true"
    $appendPath = Read-ConfigPrompt -Message "是否将 Windows PATH 路径环境变量追加到 Linux 中？[true/false]" -DefaultValue "true"

    # 组装配置
    $confLines = @()
    if ($systemd) {
        $confLines += "[boot]"
        $confLines += "systemd=$systemd"
        $confLines += ""
    }

    if ($defaultUser) {
        $confLines += "[user]"
        $confLines += "default=$defaultUser"
        $confLines += ""
    }

    if ($hostname -or $genHosts -or $genResolv) {
        $confLines += "[network]"
        if ($hostname) { $confLines += "hostname=$hostname" }
        if ($genHosts) { $confLines += "generateHosts=$genHosts" }
        if ($genResolv) { $confLines += "generateResolvConf=$genResolv" }
        $confLines += ""
    }

    if ($appendPath) {
        $confLines += "[interop]"
        $confLines += "enabled=true"
        $confLines += "appendWindowsPath=$appendPath"
        $confLines += ""
    }

    $confLines += "[automount]"
    $confLines += "enabled=true"
    $confLines += "mountFsTab=true"
    $confLines += "options=""uid=1000,gid=1000,umask=022,fmask=111"""

    $newConfContent = $confLines -join "`n"

    # 彩色 Git Diff 预览
    Show-ConfigDiff -OldContent $existingContent -NewContent $newConfContent -TargetTitle "$targetDistro (/etc/wsl.conf)"

    $confirmSave = Read-Host "`n确认将上述配置写入 $targetDistro 的 /etc/wsl.conf 吗？[Y/N]"
    if ($confirmSave -in 'Y', 'y') {
        # 1. 备份 Linux 内部原 /etc/wsl.conf
        & wsl.exe -d $targetDistro -u root -- bash -c "[ -f /etc/wsl.conf ] && cp /etc/wsl.conf /etc/wsl.conf.bak" 2>$null

        # 2. 通过 stdin 管道将 Windows 内存配置直接覆盖写入 /etc/wsl.conf
        $newConfContent | & wsl.exe -d $targetDistro -u root -- bash -c "cat > /etc/wsl.conf && chmod 644 /etc/wsl.conf"

        if ($LASTEXITCODE -eq 0) {
            Write-Host "`n[✓] 发行版 $targetDistro 的 /etc/wsl.conf 已成功更新！" -ForegroundColor Green
            Write-Host "[!] 提示: 修改后需在 PowerShell 执行 'wsl --terminate $targetDistro' 重启该分发以使配置生效。" -ForegroundColor Yellow
        } else {
            Write-Host "`n[!] 写入 /etc/wsl.conf 失败 (Exit Code: $LASTEXITCODE)。" -ForegroundColor Red
        }
    } else {
        Write-Host "配置保存已取消。" -ForegroundColor Gray
    }

}

# ------------------------------------------------------------------------------
# 主控制菜单入口
# ------------------------------------------------------------------------------
function Invoke-WslConfigHelper {
    Write-Host "`n==========================================" -ForegroundColor Cyan
    Write-Host "       6. WSL 引导式配置向导 (Config)     " -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan

    Write-Host "请选择配置目标:" -ForegroundColor Yellow
    Write-Host " [1] 全局配置文件 (.wslconfig - 影响所有 WSL 实例)"
    Write-Host " [2] 单个分发配置 (/etc/wsl.conf - 影响指定 Linux 实例)"
    Write-Host " [0] 返回主菜单"

    $choice = Read-Host "`n请输入选项 [0-2]"

    switch ($choice) {
        '1' { Configure-WslConfig }
        '2' { Configure-SingleDistroConf }
        '0' { return }
        default {
            Write-Host "`n[!] 输入 '$choice' 未匹配到有效选项，请正确输入！" -ForegroundColor Red
            Start-Sleep -Seconds 1.5
            return
        }
    }
}

Invoke-WslConfigHelper
