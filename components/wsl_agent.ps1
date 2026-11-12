# Agent orchestration; dot-sourcing does not change WSL or Windows state.

function Invoke-WslAgentShell {
    param([string]$Distro, [string]$Script, [string[]]$Data = @(), [int]$Timeout = 30000, [switch]$AllowFailure)
    $result = Invoke-WslShellScript -Arguments (@('--distribution', $Distro, '--user', 'root', '--exec', '/bin/sh', '-c', $Script, '--') + $Data) -TimeoutMilliseconds $Timeout
    if (($result.ExitCode -ne 0 -and -not $AllowFailure) -or -not $result.IsDecoded) {
        throw "Agent command failed in ${Distro}: $($result.Text) $($result.ErrorText)"
    }
    return $result
}

function New-WslAgentBundle {
    param([string]$RepoRoot = (Split-Path -Parent $PSScriptRoot))
    $temp = Join-Path ([IO.Path]::GetTempPath()) ('onedebian-agent-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $temp
    try {
        $files = @('agent.sh', 'components/the_repo_localization.sh', 'components/the_os_release.sh')
        $payload = Join-Path $RepoRoot 'agent'
        if (-not (Test-Path -LiteralPath $payload -PathType Container)) { throw 'Agent payload is missing.' }
        $files += @(Get-ChildItem -LiteralPath $payload -File -Recurse | Where-Object { $_.Extension -in '.sh', '.py', '.json', '.html', '.js', '.mjs', '.css', '.desktop', '.service' } | ForEach-Object {
            $_.FullName.Substring($RepoRoot.TrimEnd('\', '/').Length + 1).Replace('\', '/')
        })
        foreach ($relative in $files) {
            $source = Join-Path $RepoRoot $relative
            $item = Get-Item -LiteralPath $source -ErrorAction Stop
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Bundle symlink rejected: $relative" }
            $target = Join-Path $temp $relative
            $null = New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force
            $text = [IO.File]::ReadAllText($source, [Text.Encoding]::UTF8).Replace("`r`n", "`n")
            [IO.File]::WriteAllText($target, $text, (New-Object Text.UTF8Encoding($false)))
        }
        $archive = Join-Path $temp 'payload.tar'
        $tar = Invoke-WslCommand -FilePath 'tar.exe' -Arguments (@('-cf', $archive, '-C', $temp, '--') + $files) -TimeoutMilliseconds 30000
        if ($tar.ExitCode -ne 0) { throw "Could not build Agent bundle: $($tar.ErrorText)" }
        return [pscustomobject]@{ Root = $temp; Archive = $archive; SHA256 = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() }
    } catch {
        Remove-WslAgentBundle -Root $temp
        throw
    }
}

function Remove-WslAgentBundle {
    param([string]$Root)
    $resolved = [IO.Path]::GetFullPath($Root)
    $parent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
    if ((Split-Path -Parent $resolved).TrimEnd('\', '/') -ine $parent -or [IO.Path]::GetFileName($resolved) -notmatch '^onedebian-agent-[a-f0-9]{32}$') {
        throw 'Unsafe bundle cleanup path.'
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction Stop
}

function Send-WslAgentBundle {
    param([string]$Distro, [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot))
    $bundle = New-WslAgentBundle -RepoRoot $RepoRoot
    try {
        $stage = (Invoke-WslAgentShell -Distro $Distro -Script 'set -eu; umask 077; mktemp -d /var/tmp/onedebian-agent.XXXXXXXXXX').Text.Trim()
        if ($stage -notmatch '^/var/tmp/onedebian-agent\.[A-Za-z0-9]{10}$') { throw 'Untrusted guest staging path.' }
        $bytes = [IO.File]::ReadAllBytes($bundle.Archive)
        for ($offset = 0; $offset -lt $bytes.Length; $offset += 16384) {
            $length = [Math]::Min(16384, $bytes.Length - $offset)
            $chunk = [Convert]::ToBase64String($bytes, $offset, $length)
            $null = Invoke-WslAgentShell -Distro $Distro -Script 'set -eu; umask 077; printf %s "$2" | base64 -d >> "$1/payload.tar"' -Data @($stage, $chunk)
        }
        $null = Invoke-WslAgentShell -Distro $Distro -Script 'set -eu; cd "$1"; printf "%s  payload.tar\n" "$2" | sha256sum -c - >/dev/null; tar --no-same-owner -xf payload.tar; chmod 700 agent.sh' -Data @($stage, $bundle.SHA256)
        return "$stage/agent.sh"
    } finally { Remove-WslAgentBundle -Root $bundle.Root }
}

function Invoke-WslAgentCommand {
    param([string]$Distro, [string]$Command, [string]$Entry = '/opt/onedebian-agent/agent.sh', [string[]]$Options = @(), [int]$Timeout = 30000, [switch]$AllowFailure)
    if ($null -eq $Options) { $Options = @() }
    return Invoke-WslAgentShell -Distro $Distro -Script 'set -eu; entry=$1; shift; exec /bin/bash "$entry" "$@"' -Data (@($Entry, $Command) + $Options) -Timeout $Timeout -AllowFailure:$AllowFailure
}

function Get-WslAgentStatus {
    param([string]$Distro)
    $result = Invoke-WslAgentCommand -Distro $Distro -Command status -Options @('--json') -AllowFailure
    try {
        $status = $result.Text | ConvertFrom-Json -ErrorAction Stop
        if (-not $status.state) { throw 'No state field.' }
        return $status
    }
    catch { throw 'Agent status was not valid JSON; the installation state is unknown.' }
}

function Get-WslAgentProgressText {
    param($Status)
    $labels = @{
        PRECHECK = '[1/5] 准备安装 / Preparing'
        PACKAGES = '[2/5] 安装系统依赖：桌面、浏览器、中文支持 / Packages'
        RUNTIME = '[3/5] 安装开发工具：fnm、Node.js、Codex CLI、浏览器 MCP / Runtime'
        SERVICES = '[4/5] 配置并启动工作环境（含图形检测） / Services'
        VERIFY = '[5/5] 检查运行时、服务、浏览器和访问入口 / Verification'
        READY_SOFTWARE = '安装完成，使用软件渲染 / Ready (Software)'
        READY_GPU = '安装完成，硬件加速已启用 / Ready (GPU)'
        ERROR = '安装失败 / Failed'
        INTERRUPTED = '安装已中断 / Interrupted'
        NOT_INSTALLED = '尚未安装 / Not installed'
        UNINSTALLED = '已卸载 / Removed'
    }
    $message = $labels[[string]$Status.state]
    if (-not $message) { $message = "未知状态 / Unknown: $($Status.state)" }
    if ($Status.state -eq 'INTERRUPTED' -and $Status.phase -and $Status.phase -ne $Status.state) {
        $previous = $labels[[string]$Status.phase]
        if (-not $previous) { $previous = "未知阶段 / Unknown: $($Status.phase)" }
        $message += "（中断前：$previous）"
    }
    return $message
}

function Wait-WslAgentInstall {
    param([string]$Distro)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        $status = Get-WslAgentStatus -Distro $Distro
        $progress = Get-WslAgentProgressText -Status $status
        Write-Host ("[{0:hh\:mm\:ss}] {1}：{2}" -f $watch.Elapsed, $Distro, $progress)
        if ($status.state -in 'READY_SOFTWARE', 'READY_GPU') { return $status }
        if ($status.state -in 'ERROR', 'INTERRUPTED') { throw "安装已停止 / Stopped：$($status.error)。日志 / Log：$($status.log)。请使用继续安装 / Resume，实例和资料已保留。" }
        if (-not $status.job_active) { throw "安装任务未运行 / Not running：$progress。请查看状态或继续安装 / Status / Resume；未启动第二个任务。" }
        Start-Sleep -Seconds 10
    }
}

function Test-WslAgentPorts {
    param([int[]]$Ports)
    if (@($Ports | Select-Object -Unique).Count -ne $Ports.Count -or @($Ports | Where-Object { $_ -lt 1024 -or $_ -gt 65535 }).Count -gt 0) { throw 'Choose three different ports between 1024 and 65535.' }
    $listeners = [Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()
    foreach ($port in $Ports) {
        if (@($listeners | Where-Object { $_.Port -eq $port }).Count -gt 0) { throw "Windows TCP port $port is already in use. Choose another Agent port group; no process was stopped." }
    }
}

function Initialize-WslAgentSystemd {
    param([string]$Distro, [string]$Entry, [string]$Mirror = 'keep', [switch]$NewInstance, [switch]$RestartSelected, [switch]$AdoptUser)
    $pid1 = (Invoke-WslAgentShell -Distro $Distro -Script 'cat /proc/1/comm').Text.Trim()
    if (-not $NewInstance -and $pid1 -ne 'systemd') {
        if (-not $RestartSelected -and (Read-Host "Enable systemd, suppress its firstboot wizard, and restart only $Distro now? [y/N]") -ne 'Y') {
            throw 'Restart deferred. No systemd or firstboot settings were changed.'
        }
        $RestartSelected = $true
        Invoke-WslFirstBootSetup -Distro $Distro
    }
    if ($NewInstance -or $pid1 -ne 'systemd') {
        $network = Get-WslNetworkState -Distro $Distro -PrepareSystemd
        if (-not $network.Known) { throw 'Cannot verify WSL network ownership before enabling systemd; no restart was attempted.' }
        if ($network.Risk -or -not $network.HasIPv4 -or -not $network.HasDefaultRoute) {
            if (-not $network.RepairSupported) { throw 'This custom WSL network requires manual review before systemd startup.' }
            Write-Host '保护 WSL 的 eth0，防止 Linux 网络管理器接管 Windows 提供的网络；配置仅写入所选实例。' -ForegroundColor Yellow
            if (-not $NewInstance -and (Read-Host "Apply WSL eth0 protection in $Distro? [y/N]") -ne 'Y') { throw 'Network protection declined; no restart was attempted.' }
            $repair = Repair-WslEth0Management -Distro $Distro
            if (-not $repair.Success) { throw "Could not protect the selected WSL network: $($repair.Error)" }
        }
    }
    $options = @('--mirror', $Mirror)
    if ($NewInstance) { $options += '--new-instance' }
    if ($AdoptUser) { $options += '--adopt-user' }
    $null = Invoke-WslAgentCommand -Distro $Distro -Entry $Entry -Command prepare-wsl -Options $options -Timeout 0
    if ($pid1 -eq 'systemd' -and -not $NewInstance) { return }
    $terminated = Invoke-WslCommand -Arguments @('--terminate', $Distro) -TimeoutMilliseconds 30000
    if ($terminated.ExitCode -ne 0) { throw "Could not stop selected instance: $($terminated.ErrorText)" }
    $pid1 = (Invoke-WslAgentShell -Distro $Distro -Script 'cat /proc/1/comm' -Timeout 60000).Text.Trim()
    if ($pid1 -ne 'systemd') { throw 'The selected instance did not start with systemd as PID 1; installation has not started.' }
}

function Confirm-WslAgentResources {
    param([string]$Distro, [string]$WslRoot, [switch]$AllowLowResources, [switch]$Yes)
    $warnings = @()
    if ($WslRoot) {
        $root = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($WslRoot))
        $drive = New-Object IO.DriveInfo($root)
        if ($drive.AvailableFreeSpace -lt 32GB) { $warnings += "Windows target volume has only $([Math]::Round($drive.AvailableFreeSpace / 1GB, 1)) GiB free; 32 GiB recommended." }
    }
    if ($Distro) {
        $resource = (Invoke-WslAgentShell -Distro $Distro -Script 'set -eu; getconf _NPROCESSORS_ONLN; awk "/^MemTotal:/ {print \$2}" /proc/meminfo; df -Pk / | awk "END {print \$4}"').Text.Trim() -split '\r?\n'
        if ($resource.Count -ne 3 -or @($resource | Where-Object { $_ -notmatch '^\d+$' }).Count -gt 0) { throw 'Cannot verify CPU, memory and disk space in the selected WSL.' }
        Write-Host ("WSL shared pool: {0} CPU / {1:N1} GiB RAM; root free {2:N1} GiB. No global limits will change." -f [int]$resource[0], ([double]$resource[1] / 1MB), ([double]$resource[2] / 1MB))
        if ([int]$resource[0] -lt 4 -or [double]$resource[1] -lt (7.5 * 1MB) -or [double]$resource[2] -lt 32MB) { $warnings += 'Selected WSL has less than the recommended 4 CPU / 8 GiB RAM / 32 GiB free.' }
    }
    if ($warnings.Count -eq 0) { return [bool]$AllowLowResources }
    Write-Host ($warnings -join "`n") -ForegroundColor Yellow
    if ($AllowLowResources) { return $true }
    if (-not $Yes -and (Read-Host 'Continue with these lower resources? [y/N]') -eq 'Y') { return $true }
    throw 'Insufficient recommended resources. Adjust the target or explicitly use -AllowLowResources; other WSL limits were not changed.'
}

function Open-WslAgentDesktop {
    param([string]$Distro)
    $result = Invoke-WslAgentShell -Distro $Distro -Script 'set -eu; exec runuser -u agent -- /usr/bin/python3 /opt/onedebian-agent/runtime.py open-url'
    $address = $result.Text.Trim()
    $uri = $null
    if (-not [Uri]::TryCreate($address, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'http' -or $uri.Host -ne '127.0.0.1' -or $uri.UserInfo -or $uri.Fragment -notmatch '^#token=[A-Za-z0-9_-]{43}$') { throw 'Viewer returned an invalid localhost URL.' }
    $access = Ensure-WslAgentAccess -Distro $Distro -Address $address
    # The token stays out of console output and persisted Windows configuration.
    Start-Process -FilePath $access.Address | Out-Null
}

function Invoke-WslAgent {
    param(
        [ValidateSet('Menu', 'Create', 'Install', 'Resume', 'Status', 'Verify', 'Open', 'Uninstall', 'RelayStart', 'RelayStop', 'RelayStatus')][string]$Action = 'Menu',
        [string]$DistroName = '', [string]$WslRoot = 'D:\wsl',
        [ValidateSet('keep', 'tuna', 'ustc', 'official')][string]$Mirror = '',
        [int]$ViewerPort = 16080, [int]$McpPort = 18931, [int]$CdpPort = 19222,
        [switch]$Yes, [switch]$RestartSelected, [switch]$AdoptUser, [switch]$Autostart, [switch]$NoWait, [switch]$AllowLowResources
    )
    if ($Action -eq 'Menu') {
        Write-Host "`n09 Agent 工作机 / Agent workstation"
        Write-Host '1. 新建独立 ai-dev / Create independent WSL (default)'
        Write-Host '2. 安装到指定已有 WSL / Install in selected WSL'
        Write-Host '3. 继续安装 / Resume    4. 状态 / Status'
        Write-Host '5. 验收 / Verify         6. 打开桌面 / Open desktop'
        Write-Host '7. 卸载工具并保留资料 / Uninstall (keep data)'
        Write-Host '8. 启动本机转发 / Relay start    9. 停止本机转发 / Relay stop'
        Write-Host '10. 本机转发状态 / Relay status    0. 返回 / Back'
        $choice = Read-Host '选择 / Select [1]'
        $actions = @{ '1' = 'Create'; '2' = 'Install'; '3' = 'Resume'; '4' = 'Status'; '5' = 'Verify'; '6' = 'Open'; '7' = 'Uninstall'; '8' = 'RelayStart'; '9' = 'RelayStop'; '10' = 'RelayStatus' }
        if (-not $choice) { $choice = '1' }
        if ($choice -eq '0') { return }
        if (-not $actions.ContainsKey($choice)) { throw 'Invalid Agent action.' }
        $Action = $actions[$choice]
        if ($Action -eq 'Create') {
            $name = Read-Host '实例名 / Distro name [ai-dev]'; $DistroName = if ($name) { $name.Trim() } else { 'ai-dev' }
            $root = Read-Host "安装根目录 / WSL root [$WslRoot]"; if ($root) { $WslRoot = $root }
        } else { $DistroName = Select-WslDistro; if (-not $DistroName) { return } }
        if ($Action -in 'Create', 'Install') {
            $defaultMirror = if ($Action -eq 'Create') { 'tuna' } else { 'keep' }
            $selection = Read-Host "客机 APT 源 / Guest mirror: keep / tuna / ustc / official [$defaultMirror]"
            $Mirror = if ($selection) { $selection.Trim() } else { $defaultMirror }
            if ($Mirror -notin 'keep', 'tuna', 'ustc', 'official') { throw 'Invalid APT mirror.' }
            foreach ($setting in @(@('ViewerPort', 'noVNC', $ViewerPort), @('McpPort', 'MCP', $McpPort), @('CdpPort', 'CDP', $CdpPort))) {
                $value = Read-Host "$($setting[1]) 端口 / port [$($setting[2])]"
                if ($value) { Set-Variable -Name $setting[0] -Value ([int]$value) }
            }
        }
    }
    if (-not $DistroName -and $Action -eq 'Create') { $DistroName = 'ai-dev' }
    if ([string]::IsNullOrWhiteSpace($DistroName) -or $DistroName.StartsWith('-') -or $DistroName -match '[\x00\r\n]') { throw 'Select an explicit valid WSL distro name.' }
    $registered = @(Get-WslDistros)
    $new = $Action -eq 'Create'
    if ($new) {
        if ($DistroName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { throw 'New distro names may contain letters, digits, dots, underscores and hyphens.' }
        if ($registered -contains $DistroName -or (Test-Path -LiteralPath (Join-Path $WslRoot $DistroName))) { throw 'Distro or installation directory already exists. Use an explicit Install, Status or Resume action instead.' }
        Test-WslAgentPorts -Ports @($ViewerPort, $McpPort, $CdpPort)
        $AllowLowResources = Confirm-WslAgentResources -WslRoot $WslRoot -AllowLowResources:$AllowLowResources -Yes:$Yes
    } elseif ($registered -notcontains $DistroName) { throw "WSL distribution is not registered: $DistroName" }
    if ($Action -eq 'RelayStart') { Write-WslAgentRelayStatus (Start-WslAgentRelay -Distro $DistroName); return }
    if ($Action -eq 'RelayStop') { Write-WslAgentRelayStatus (Stop-WslAgentRelay -Distro $DistroName); return }
    if ($Action -eq 'RelayStatus') { Write-WslAgentRelayStatus (Get-WslAgentRelayStatus -Distro $DistroName); return }
    if ($Action -eq 'Install') {
        $inventory = Get-WslDistroVersions
        $target = @($inventory.Distributions | Where-Object { $_.Name -eq $DistroName })
        if ($target.Count -ne 1 -or $target[0].Version -ne 2) { throw 'Agent workstations require a verified WSL2 instance; no automatic conversion was performed.' }
    }
    if ($Action -eq 'Open') { Open-WslAgentDesktop -Distro $DistroName; return }
    if ($Action -in 'Status', 'Verify', 'Uninstall') {
        if ($Action -eq 'Uninstall' -and -not $Yes -and (Read-Host "Remove oneDebian Agent services from $DistroName, retaining projects/profile/keyring? [y/N]") -ne 'Y') { return }
        if ($Action -eq 'Uninstall') { $null = Stop-WslAgentRelay -Distro $DistroName }
        $options = if ($Action -eq 'Uninstall') { @('--yes') } else { @() }
        $result = Invoke-WslAgentCommand -Distro $DistroName -Command $Action.ToLowerInvariant() -Options $options -Timeout 0
        Write-Host $result.Text
        return
    }
    if ($Action -eq 'Resume') {
        $pid1 = (Invoke-WslAgentShell -Distro $DistroName -Script 'cat /proc/1/comm').Text.Trim()
        if ($pid1 -ne 'systemd') { Initialize-WslAgentSystemd -Distro $DistroName -Entry '/opt/onedebian-agent/agent.sh' -RestartSelected:$RestartSelected }
        $resumeOptions = @('--json', '--viewer-port', [string]$ViewerPort, '--mcp-port', [string]$McpPort, '--cdp-port', [string]$CdpPort)
        if ($AllowLowResources) { $resumeOptions += '--allow-low-resources' }
        if ($AdoptUser) { $resumeOptions += '--adopt-user' }
        if ($Mirror) { $resumeOptions += @('--mirror', $Mirror) }
        $result = Invoke-WslAgentCommand -Distro $DistroName -Command resume -Options $resumeOptions -Timeout 0
        Write-Host "已请求继续安装 / Resume requested: $DistroName"
        if (-not $NoWait) { $null = Wait-WslAgentInstall -Distro $DistroName; Complete-WslAgentAccess -Distro $DistroName }
        return
    }
    if (-not $Mirror) { $Mirror = if ($new) { 'tuna' } else { 'keep' } }
    Write-Host "目标 / Target: $DistroName | APT: $Mirror | noVNC $ViewerPort / MCP $McpPort / CDP $CdpPort" -ForegroundColor Cyan
    Write-Host '安装依赖并创建独立浏览器桌面；不升级整个系统、不改其他 WSL 或全局 .wslconfig。' -ForegroundColor Yellow
    $globalConfig = Join-Path $env:USERPROFILE '.wslconfig'
    if (Test-Path -LiteralPath $globalConfig) {
        $content = [IO.File]::ReadAllText($globalConfig)
        if ($content -match '(?ims)^\s*\[wsl2\](?<section>.*?)(?=^\s*\[|\z)' -and $Matches.section -match '(?im)^\s*localhostForwarding\s*=\s*false\s*(?:[;#].*)?$') {
            Write-Host '【本机专用转发】全局 localhostForwarding=false；工作机就绪后自动建立专用回环转发，不改全局设置或重启其他 WSL。' -ForegroundColor Yellow
        }
    }
    if ($new) { Write-Host "新建位置: $(Join-Path $WslRoot $DistroName)；启用 systemd、默认 agent、关闭 Windows 磁盘挂载/互操作、保护 WSL 网络，并只重启新实例。" }
    if ($AdoptUser) { Write-Host '显式接纳已有 agent 用户；不更改其密码或复制凭据。' -ForegroundColor Yellow }
    if (-not $Yes -and (Read-Host '执行以上操作 / Apply? [y/N]') -ne 'Y') { return }
    if ($new) {
        & (Join-Path $PSScriptRoot 'wsl_install.ps1') -Version 13 -DistroName $DistroName -WslRoot $WslRoot -AgentImportOnly -Confirmed
        if (@(Get-WslDistros) -notcontains $DistroName) { throw 'The rootfs import did not complete. No Agent installation was started.' }
    }
    $entry = Send-WslAgentBundle -Distro $DistroName
    $AllowLowResources = Confirm-WslAgentResources -Distro $DistroName -AllowLowResources:$AllowLowResources -Yes:$Yes
    Initialize-WslAgentSystemd -Distro $DistroName -Entry $entry -Mirror $Mirror -NewInstance:$new -RestartSelected:$RestartSelected -AdoptUser:$AdoptUser
    if ($new) {
        $residency = Set-WslDistroResidency -DistroName $DistroName -KeepAlive $true
        if (-not $residency.Success) {
            throw "Background residency could not be verified for ${DistroName}: $($residency.Error) The instance and installer were retained; Agent installation has not started. Repair residency in menu 07, then Resume with the original mirror and port options."
        }
        if ($Autostart) {
            $startup = Set-WslDistroAutostart -DistroName $DistroName -Enabled $true
            if (-not $startup.Success) {
                throw "Windows sign-in startup could not be verified for ${DistroName}: $($startup.Error) The instance and installer were retained; Agent installation has not started. Repair startup in menu 07, then Resume with the original mirror and port options."
            }
        }
    }
    $options = @('--yes', '--json', '--mirror', $Mirror, '--viewer-port', [string]$ViewerPort, '--mcp-port', [string]$McpPort, '--cdp-port', [string]$CdpPort)
    if ($AdoptUser) { $options += '--adopt-user' }
    if ($AllowLowResources) { $options += '--allow-low-resources' }
    $result = Invoke-WslAgentCommand -Distro $DistroName -Entry $entry -Command install -Options $options -Timeout 0
    Write-Host "安装任务已提交 / Installation job submitted: $DistroName"
    if (-not $NoWait) { $null = Wait-WslAgentInstall -Distro $DistroName; Complete-WslAgentAccess -Distro $DistroName }
    Write-Host "后续 / Next: .\agent-via-wsl.ps1 -Action Status -DistroName $DistroName"
}
