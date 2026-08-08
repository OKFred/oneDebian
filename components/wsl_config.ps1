# ==============================================================================
# components/wsl_config.ps1
# Description: WSL 引导式配置向导（增量更新 .wslconfig 与 wsl.conf）
# ==============================================================================

param(
    [string]$DefaultWslRoot = 'D:\wsl'
)

. "$PSScriptRoot\wsl_common.ps1"

function Get-IniValue {
    param(
        [string]$Content,
        [string]$Section,
        [string]$Key
    )

    if ([string]::IsNullOrEmpty($Content)) { return $null }

    $insideSection = $false
    $escapedKey = [regex]::Escape($Key)
    foreach ($line in ($Content -split "`r?`n")) {
        if ($line -match '^\s*\[(?<name>[^\]]+)\]\s*(?:[;#].*)?$') {
            $insideSection = $Matches['name'].Trim() -ieq $Section
            continue
        }

        if ($insideSection -and $line -match "^\s*$escapedKey\s*=\s*(?<value>.*)$") {
            return $Matches['value'].Trim()
        }
    }

    return $null
}

function Set-IniValue {
    param(
        [string]$Content,
        [string]$Section,
        [string]$Key,
        [AllowNull()][string]$Value,
        [switch]$Remove
    )

    $lines = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrEmpty($Content)) {
        foreach ($line in ($Content -split "`r?`n")) { $lines.Add($line) }
    }

    $sectionStart = -1
    $sectionEnd = $lines.Count
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*\[(?<name>[^\]]+)\]\s*(?:[;#].*)?$') {
            if ($sectionStart -ge 0) {
                $sectionEnd = $i
                break
            }
            if ($Matches['name'].Trim() -ieq $Section) {
                $sectionStart = $i
            }
        }
    }

    if ($sectionStart -lt 0) {
        if ($Remove) { return ($lines -join "`n") }
        if ($lines.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($lines[$lines.Count - 1])) {
            $lines.Add('')
        }
        $lines.Add("[$Section]")
        $lines.Add("$Key=$Value")
        return ($lines -join "`n")
    }

    $escapedKey = [regex]::Escape($Key)
    $keyIndexes = New-Object System.Collections.Generic.List[int]
    for ($i = $sectionStart + 1; $i -lt $sectionEnd; $i++) {
        if ($lines[$i] -match "^\s*$escapedKey\s*=") { $keyIndexes.Add($i) }
    }

    if ($Remove) {
        for ($i = $keyIndexes.Count - 1; $i -ge 0; $i--) {
            $lines.RemoveAt($keyIndexes[$i])
        }
        return ($lines -join "`n")
    }

    if ($keyIndexes.Count -gt 0) {
        $lines[$keyIndexes[0]] = "$Key=$Value"
        for ($i = $keyIndexes.Count - 1; $i -ge 1; $i--) {
            $lines.RemoveAt($keyIndexes[$i])
        }
    } else {
        $lines.Insert($sectionEnd, "$Key=$Value")
    }

    return ($lines -join "`n")
}

function Read-ConfigPrompt {
    param(
        [string]$Message,
        [AllowNull()][object]$CurrentValue,
        [string]$HintText = '',
        [string[]]$AllowedValues = @(),
        [scriptblock]$Validator,
        [scriptblock]$Normalizer
    )

    while ($true) {
        if ($HintText) { Write-Host "`n提示: $HintText" -ForegroundColor Gray }
        $currentDisplay = if ($null -eq $CurrentValue) { '<未设置，使用 WSL 默认值>' } else { $CurrentValue }
        $inputValue = Read-Host "$Message`n  当前值: $currentDisplay`n  [回车/--: 保持不变 | unset: 删除此配置键]"

        if ([string]::IsNullOrWhiteSpace($inputValue) -or $inputValue.Trim() -eq '--') {
            return [pscustomobject]@{ Action = 'Keep'; Value = $CurrentValue }
        }

        $trimmed = $inputValue.Trim()
        if ($trimmed -ieq 'unset') {
            return [pscustomobject]@{ Action = 'Remove'; Value = $null }
        }

        $valid = $true
        if ($AllowedValues.Count -gt 0) {
            $valid = $AllowedValues -icontains $trimmed
        }
        if ($valid -and $Validator) {
            $valid = [bool](& $Validator $trimmed)
        }

        if (-not $valid) {
            $allowedHint = if ($AllowedValues.Count -gt 0) { "  允许值: $($AllowedValues -join ', ')" } else { '  输入格式无效。' }
            Write-Host "[!] $allowedHint" -ForegroundColor Red
            continue
        }

        $normalized = if ($Normalizer) { & $Normalizer $trimmed } else { $trimmed }
        return [pscustomobject]@{ Action = 'Set'; Value = [string]$normalized }
    }
}

function Update-IniFromPromptResult {
    param(
        [string]$Content,
        [string]$Section,
        [string]$Key,
        [psobject]$Result
    )

    switch ($Result.Action) {
        'Set' { return Set-IniValue -Content $Content -Section $Section -Key $Key -Value $Result.Value }
        'Remove' { return Set-IniValue -Content $Content -Section $Section -Key $Key -Remove }
        default { return $Content }
    }
}

function Show-ConfigDiff {
    param(
        [string]$OldContent = '',
        [string]$NewContent = '',
        [string]$TargetTitle = '配置文件'
    )

    Write-Host "`n==========================================" -ForegroundColor Cyan
    Write-Host "    $TargetTitle 变更对比 (Git Diff)" -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan

    if ($OldContent -ceq $NewContent) {
        Write-Host '  无变更。' -ForegroundColor Gray
        return
    }

    $git = Get-Command git.exe -ErrorAction SilentlyContinue
    if (-not $git) { $git = Get-Command git -ErrorAction SilentlyContinue }
    if (-not $git) {
        Write-Host '[!] 未找到 Git，显示完整替换预览。' -ForegroundColor Yellow
        foreach ($line in ($OldContent -split "`r?`n")) { Write-Host "- $line" -ForegroundColor Red }
        foreach ($line in ($NewContent -split "`r?`n")) { Write-Host "+ $line" -ForegroundColor Green }
        return
    }

    $oldPath = [System.IO.Path]::GetTempFileName()
    $newPath = [System.IO.Path]::GetTempFileName()
    $oldErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $hasNativeErrorPreference = Test-Path Variable:PSNativeCommandUseErrorActionPreference
    if ($hasNativeErrorPreference) {
        $oldNativeErrorPreference = $PSNativeCommandUseErrorActionPreference
        $PSNativeCommandUseErrorActionPreference = $false
    }
    try {
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($oldPath, $OldContent, $utf8NoBom)
        [System.IO.File]::WriteAllText($newPath, $NewContent, $utf8NoBom)
        $diffLines = & $git.Source -c core.autocrlf=false -c core.safecrlf=false diff --no-index --no-color --unified=3 -- $oldPath $newPath 2>$null
        $diffExitCode = $LASTEXITCODE
        if ($diffExitCode -notin 0, 1) {
            throw "Git diff failed (Exit Code: $diffExitCode)."
        }
        foreach ($line in $diffLines) {
            if ($line.StartsWith('+') -and -not $line.StartsWith('+++')) {
                Write-Host $line -ForegroundColor Green
            } elseif ($line.StartsWith('-') -and -not $line.StartsWith('---')) {
                Write-Host $line -ForegroundColor Red
            } elseif ($line.StartsWith('@@')) {
                Write-Host $line -ForegroundColor Cyan
            } else {
                Write-Host $line -ForegroundColor Gray
            }
        }
    } finally {
        $ErrorActionPreference = $oldErrorActionPreference
        if ($hasNativeErrorPreference) {
            $PSNativeCommandUseErrorActionPreference = $oldNativeErrorPreference
        }
        Remove-Item -LiteralPath $oldPath, $newPath -Force -ErrorAction SilentlyContinue
    }
}

function Save-WindowsConfig {
    param([string]$Path, [string]$Content)

    if (Test-Path -LiteralPath $Path) {
        $backupPath = "$Path.bak_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
        Copy-Item -LiteralPath $Path -Destination $backupPath -Force
        Write-Host "[✓] 原配置文件已备份至: $backupPath" -ForegroundColor Gray
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Configure-WslConfig {
    Write-Host "`n------------------------------------------" -ForegroundColor Yellow
    Write-Host '   Windows 全局配置向导 (~/.wslconfig)' -ForegroundColor Yellow
    Write-Host '------------------------------------------' -ForegroundColor Yellow

    $wslConfigPath = Join-Path $env:USERPROFILE '.wslconfig'
    $existingContent = if (Test-Path -LiteralPath $wslConfigPath) {
        [System.IO.File]::ReadAllText($wslConfigPath)
    } else { '' }
    $newContent = $existingContent

    Write-Host '交互说明: 回车或 -- 保留当前配置；unset 删除配置键。未设置的资源项会继续使用 WSL 官方自适应默认值。' -ForegroundColor Cyan

    $positiveSizeValidator = { param($value) $value -match '^[1-9]\d*(?:KB|MB|GB|TB)?$' }
    $swapSizeValidator = { param($value) $value -match '^(?:0|[1-9]\d*(?:KB|MB|GB|TB)?)$' }
    $positiveIntegerValidator = { param($value) $value -match '^[1-9]\d*$' }
    $lowerNormalizer = { param($value) $value.ToLowerInvariant() }
    $boolValues = @('true', 'false')

    Write-Host "`n--- [1/3 资源限制] ---" -ForegroundColor Yellow
    $changes = @(
        @{ Section = 'wsl2'; Key = 'memory'; Result = Read-ConfigPrompt -Message '最大内存（如 8GB）' -CurrentValue (Get-IniValue $newContent 'wsl2' 'memory') -Validator $positiveSizeValidator },
        @{ Section = 'wsl2'; Key = 'processors'; Result = Read-ConfigPrompt -Message 'CPU 逻辑处理器数量（如 4）' -CurrentValue (Get-IniValue $newContent 'wsl2' 'processors') -Validator $positiveIntegerValidator },
        @{ Section = 'wsl2'; Key = 'swap'; Result = Read-ConfigPrompt -Message 'Swap 大小（如 4GB，0 表示禁用）' -CurrentValue (Get-IniValue $newContent 'wsl2' 'swap') -Validator $swapSizeValidator }
    )
    foreach ($change in $changes) {
        $newContent = Update-IniFromPromptResult $newContent $change.Section $change.Key $change.Result
    }

    Write-Host "`n--- [2/3 网络] ---" -ForegroundColor Yellow
    $networkMode = Read-ConfigPrompt -Message '网络模式' -CurrentValue (Get-IniValue $newContent 'wsl2' 'networkingMode') `
        -AllowedValues @('nat', 'mirrored', 'virtioproxy', 'none') -Normalizer $lowerNormalizer `
        -HintText 'NAT 是官方默认值；mirrored 可改善 VPN 兼容性，但入站访问仍受 Hyper-V 防火墙控制。'
    $newContent = Update-IniFromPromptResult $newContent 'wsl2' 'networkingMode' $networkMode

    foreach ($item in @(
        @{ Key = 'localhostForwarding'; Label = 'Windows localhost 转发'; Hint = '仅用于 NAT；这是所有 WSL 2 发行版共享的全局设置。' },
        @{ Key = 'dnsTunneling'; Label = 'DNS 隧道'; Hint = 'Windows 11 22H2+ 默认启用，可改善 VPN 和复杂 DNS 环境兼容性。' },
        @{ Key = 'autoProxy'; Label = '自动同步 Windows HTTP 代理'; Hint = 'Windows 11 可用。' },
        @{ Key = 'firewall'; Label = '启用 Windows/Hyper-V 防火墙过滤'; Hint = 'Windows 11 22H2+ 默认启用。' }
    )) {
        $result = Read-ConfigPrompt -Message "$($item.Label) [true/false]" -CurrentValue (Get-IniValue $newContent 'wsl2' $item.Key) `
            -AllowedValues $boolValues -Normalizer $lowerNormalizer -HintText $item.Hint
        $newContent = Update-IniFromPromptResult $newContent 'wsl2' $item.Key $result
    }

    Write-Host "`n--- [3/3 实验特性] ---" -ForegroundColor Yellow
    $sparse = Read-ConfigPrompt -Message '新建 VHD 自动使用稀疏模式 [true/false]' -CurrentValue (Get-IniValue $newContent 'experimental' 'sparseVhd') `
        -AllowedValues $boolValues -Normalizer $lowerNormalizer -HintText '仅影响启用后新创建或显式转换的 VHD。'
    $newContent = Update-IniFromPromptResult $newContent 'experimental' 'sparseVhd' $sparse

    $reclaimNormalizer = {
        param($value)
        if ($value -ieq 'dropCache') { 'dropCache' } else { $value.ToLowerInvariant() }
    }
    $reclaim = Read-ConfigPrompt -Message '内存回收策略' -CurrentValue (Get-IniValue $newContent 'experimental' 'autoMemoryReclaim') `
        -AllowedValues @('dropCache', 'gradual', 'disabled') -Normalizer $reclaimNormalizer
    $newContent = Update-IniFromPromptResult $newContent 'experimental' 'autoMemoryReclaim' $reclaim

    Show-ConfigDiff -OldContent $existingContent -NewContent $newContent -TargetTitle 'Windows 全局 .wslconfig'
    if ($existingContent -ceq $newContent) { return }

    $confirmSave = Read-Host "`n确认将上述增量变更写入 $wslConfigPath 吗？[Y/N]"
    if ($confirmSave -notin 'Y', 'y') {
        Write-Host '配置保存已取消。' -ForegroundColor Gray
        return
    }

    Save-WindowsConfig -Path $wslConfigPath -Content $newContent
    Write-Host "`n[✓] .wslconfig 已成功更新。" -ForegroundColor Green
    Write-Host "[!] 需执行 'wsl --shutdown' 使全局配置生效；这会终止所有运行中的发行版。" -ForegroundColor Yellow
}

function Test-DistroUserExists {
    param([string]$Distro, [string]$UserName)

    & wsl.exe -d $Distro -u root -- sh -c "id -u -- '$UserName' >/dev/null 2>&1" 2>$null
    return $LASTEXITCODE -eq 0
}

function Test-DistroNetworkManagerConflict {
    param([string]$Distro)

    $result = (& wsl.exe -d $Distro -u root -- sh -c "systemctl is-enabled NetworkManager.service 2>/dev/null; systemctl is-enabled systemd-networkd.service 2>/dev/null" 2>$null) -join "`n"
    if ($LASTEXITCODE -ne 0 -and -not $result) { return $false }
    $enabledCount = @(($result -split "`r?`n") | Where-Object { $_.Trim() -in 'enabled', 'enabled-runtime' }).Count
    return $enabledCount -ge 2
}

function Configure-SingleDistroConf {
    $oldErrorPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        Write-Host "`n------------------------------------------" -ForegroundColor Yellow
        Write-Host '   分发内部配置向导 (/etc/wsl.conf)' -ForegroundColor Yellow
        Write-Host '------------------------------------------' -ForegroundColor Yellow

        $targetDistro = Select-WslDistro -Title '选择要配置 wsl.conf 的 Debian 发行版'
        if (-not $targetDistro) { return }

        $existingContent = (& wsl.exe -d $targetDistro -u root -- sh -c 'if [ -f /etc/wsl.conf ]; then cat /etc/wsl.conf; fi' 2>$null) -join "`n"
        $readExitCode = $LASTEXITCODE
        if ($readExitCode -ne 0) {
            Write-Host "[!] 无法读取 /etc/wsl.conf (Exit Code: $readExitCode)。" -ForegroundColor Red
            return
        }
        $newContent = $existingContent

        Write-Host '交互说明: 回车或 -- 保留当前配置；unset 删除配置键。向导不会覆盖未涉及的节或键。' -ForegroundColor Cyan
        $boolValues = @('true', 'false')
        $lowerNormalizer = { param($value) $value.ToLowerInvariant() }

        $systemd = Read-ConfigPrompt -Message '启用 systemd [true/false]' -CurrentValue (Get-IniValue $newContent 'boot' 'systemd') `
            -AllowedValues $boolValues -Normalizer $lowerNormalizer
        $newContent = Update-IniFromPromptResult $newContent 'boot' 'systemd' $systemd

        $userValidator = { param($value) $value -match '^[a-z_][a-z0-9_-]*\$?$' }
        $defaultUser = Read-ConfigPrompt -Message '默认登录用户' -CurrentValue (Get-IniValue $newContent 'user' 'default') -Validator $userValidator
        if ($defaultUser.Action -eq 'Set' -and -not (Test-DistroUserExists $targetDistro $defaultUser.Value)) {
            Write-Host "[!] 用户 '$($defaultUser.Value)' 在 $targetDistro 中不存在，配置已取消。" -ForegroundColor Red
            return
        }
        $newContent = Update-IniFromPromptResult $newContent 'user' 'default' $defaultUser

        $hostnameValidator = {
            param($value)
            $value.Length -le 253 -and $value -match '^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$' -and $value -notmatch '\.\.'
        }
        $hostname = Read-ConfigPrompt -Message 'Linux 主机名' -CurrentValue (Get-IniValue $newContent 'network' 'hostname') -Validator $hostnameValidator
        $newContent = Update-IniFromPromptResult $newContent 'network' 'hostname' $hostname

        foreach ($item in @(
            @{ Section = 'network'; Key = 'generateHosts'; Label = '自动生成 /etc/hosts' },
            @{ Section = 'network'; Key = 'generateResolvConf'; Label = '自动生成 /etc/resolv.conf' },
            @{ Section = 'interop'; Key = 'enabled'; Label = '启用 Windows 进程互操作' },
            @{ Section = 'interop'; Key = 'appendWindowsPath'; Label = '将 Windows PATH 追加到 Linux PATH' },
            @{ Section = 'automount'; Key = 'enabled'; Label = '自动挂载 Windows 固定磁盘' },
            @{ Section = 'automount'; Key = 'mountFsTab'; Label = '启动时处理 /etc/fstab' }
        )) {
            $result = Read-ConfigPrompt -Message "$($item.Label) [true/false]" -CurrentValue (Get-IniValue $newContent $item.Section $item.Key) `
                -AllowedValues $boolValues -Normalizer $lowerNormalizer
            $newContent = Update-IniFromPromptResult $newContent $item.Section $item.Key $result
        }

        $mountOptions = Read-ConfigPrompt -Message 'DrvFs automount options' -CurrentValue (Get-IniValue $newContent 'automount' 'options') `
            -HintText '默认留空即可让 WSL 根据默认用户决定 uid/gid；不要硬编码不存在的 uid=1000。'
        $newContent = Update-IniFromPromptResult $newContent 'automount' 'options' $mountOptions

        $effectiveSystemd = Get-IniValue $newContent 'boot' 'systemd'
        if ($effectiveSystemd -ieq 'true' -and (Test-DistroNetworkManagerConflict $targetDistro)) {
            Write-Host "`n[!] 检测到 NetworkManager 与 systemd-networkd 均已启用。" -ForegroundColor Red
            Write-Host '    启用 systemd 后两者可能覆盖 WSL 注入的 eth0 地址和默认路由。请先让 eth0 仅由 WSL 管理。' -ForegroundColor Yellow
            $continueChoice = Read-Host '仍要继续保存吗？[Y/N]'
            if ($continueChoice -notin 'Y', 'y') { return }
        }

        Show-ConfigDiff -OldContent $existingContent -NewContent $newContent -TargetTitle "$targetDistro (/etc/wsl.conf)"
        if ($existingContent -ceq $newContent) { return }

        $confirmSave = Read-Host "`n确认将上述增量变更写入 $targetDistro 的 /etc/wsl.conf 吗？[Y/N]"
        if ($confirmSave -notin 'Y', 'y') {
            Write-Host '配置保存已取消。' -ForegroundColor Gray
            return
        }

        & wsl.exe -d $targetDistro -u root -- sh -c '[ -f /etc/wsl.conf ] && cp /etc/wsl.conf "/etc/wsl.conf.bak_$(date +%Y%m%d_%H%M%S)"; exit 0' 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "[!] 备份 /etc/wsl.conf 失败，未写入新配置。" -ForegroundColor Red
            return
        }

        $newContent | & wsl.exe -d $targetDistro -u root -- sh -c 'cat > /etc/wsl.conf && chmod 644 /etc/wsl.conf' 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "[!] 写入 /etc/wsl.conf 失败 (Exit Code: $LASTEXITCODE)。" -ForegroundColor Red
            return
        }

        Write-Host "`n[✓] $targetDistro 的 /etc/wsl.conf 已成功更新。" -ForegroundColor Green
        Write-Host "[!] 执行 'wsl --terminate $targetDistro' 后重新启动该发行版以应用配置。" -ForegroundColor Yellow
    } finally {
        $ErrorActionPreference = $oldErrorPreference
    }
}

function Invoke-WslConfigHelper {
    Write-Host "`n==========================================" -ForegroundColor Cyan
    Write-Host '       6. WSL 引导式配置向导 (Config)' -ForegroundColor Cyan
    Write-Host '==========================================' -ForegroundColor Cyan
    Write-Host ' [1] 全局配置文件 (.wslconfig - 影响所有 WSL 2 实例)'
    Write-Host ' [2] 单个分发配置 (/etc/wsl.conf)'
    Write-Host ' [0] 返回主菜单'

    $choice = Read-Host "`n请输入选项 [0-2]"
    switch ($choice) {
        '1' { Configure-WslConfig }
        '2' { Configure-SingleDistroConf }
        '0' { return }
        default { Write-Host "`n[!] 无效选项: $choice" -ForegroundColor Red }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-WslConfigHelper
}
