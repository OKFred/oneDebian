# Stable SSH aliases use the selected WSL instance, never its changing NAT address.
function Assert-WslAgentSshPath {
    param([string]$Path)
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if ((Test-Path -LiteralPath $current) -and ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "SSH path symlink rejected: $current" }
        $parent = Split-Path -Parent $current
        if ($parent -eq $current) { break }
        $current = $parent
    }
}

function Set-WslAgentSshPrivateAcl {
    param([string]$Path, [string]$Sid, [switch]$Directory)
    # Read/persist only DACLs; Set-Acl's provider can request SACL privileges.
    $item = Get-Item -LiteralPath $Path -Force
    $extensions = 'System.IO.FileSystemAclExtensions' -as [type]
    $access = [Security.AccessControl.AccessControlSections]::Access
    $acl = if ($extensions) { $extensions::GetAccessControl($item, $access) } else { $item.GetAccessControl($access) }
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($existing in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) { $acl.RemoveAccessRuleSpecific($existing) }
    foreach ($owner in @($Sid, 'S-1-5-18')) {
        $principal = New-Object Security.Principal.SecurityIdentifier($owner)
        $rule = if ($Directory) { New-Object Security.AccessControl.FileSystemAccessRule($principal, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow') } else { New-Object Security.AccessControl.FileSystemAccessRule($principal, 'FullControl', 'Allow') }
        $null = $acl.AddAccessRule($rule)
    }
    if ($extensions) { $extensions::SetAccessControl($item, $acl) }
    else { $item.SetAccessControl($acl) }
}

function Write-WslAgentSshFile {
    param([string]$Path, [string]$Text)
    Assert-WslAgentSshPath -Path $Path
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, $Text, (New-Object Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temporary, $Path, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $Path) }
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
}

function Get-WslAgentSshPublicKey {
    param([string]$Text)
    if ($Text -cnotmatch '\Assh-ed25519[ ]+([A-Za-z0-9+/]+={0,3})(?:[ ][^\r\n]*)?\z') { throw 'Expected one Ed25519 public key; never provide a private key.' }
    return 'ssh-ed25519 ' + $Matches[1]
}

function Initialize-WslAgentSsh {
    param([Parameter(Mandatory = $true)][string]$Distro, [Parameter(Mandatory = $true)][string]$Entry, [int]$SshPort = 2222)
    if ($Distro -notmatch '\A[A-Za-z0-9][A-Za-z0-9_. -]{0,63}\z' -or $Distro.EndsWith(' ')) { throw 'Choose a simple registered WSL name for its SSH alias.' }
    if ($SshPort -lt 1024 -or $SshPort -gt 65535) { throw 'SSH port must be between 1024 and 65535.' }
    $alias = 'oneDebian-' + ($Distro.ToLowerInvariant() -replace '[^a-z0-9_.-]', '-')
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $ssh = Join-Path $env:USERPROFILE '.ssh'
    $root = Join-Path $ssh 'onedebian-agent'
    $owner = 'oneDebian-agent-ssh-v1|' + $sid
    $marker = Join-Path $root '.owner'
    $key = Join-Path $ssh 'onedebian_agent_ed25519'
    $public = $key + '.pub'
    $keyRecord = Join-Path $root 'key.json'
    $config = Join-Path $ssh 'config'
    $fragment = Join-Path $root ($alias + '.conf')
    $known = Join-Path $root ($alias + '.known_hosts')
    $recordPath = Join-Path $root ($alias + '.json')
    foreach ($path in @($root, $marker, $key, $public, $keyRecord, $config, $fragment, $known, $recordPath)) { Assert-WslAgentSshPath -Path $path }
    if ((Test-Path -LiteralPath $root) -and (-not (Test-Path -LiteralPath $marker) -or [IO.File]::ReadAllText($marker) -cne $owner)) { throw 'Existing SSH metadata is not owned by oneDebian; it was retained.' }
    $record = if (Test-Path -LiteralPath $recordPath) { [IO.File]::ReadAllText($recordPath) | ConvertFrom-Json -ErrorAction Stop } else { $null }
    if ($record -and ($record.owner -cne $owner -or $record.distro -cne $Distro -or $record.alias -cne $alias)) { throw 'SSH alias belongs to a different target; no files were replaced.' }
    foreach ($item in @(@($fragment, 'config_sha256'), @($known, 'known_sha256'))) {
        if (Test-Path -LiteralPath $item[0]) {
            if (-not $record -or (Get-FileHash -LiteralPath $item[0] -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$record.($item[1])) { throw 'Existing SSH alias or host-key file was changed; review it before retrying.' }
        }
    }
    if (-not $record) {
        if (Test-Path -LiteralPath $config) {
            foreach ($line in [IO.File]::ReadAllLines($config)) {
                if ($line -match '^\s*Host\s+(.+)$') {
                    foreach ($pattern in ($Matches[1] -split '\s+')) {
                        if ($pattern -ne '*' -and -not $pattern.StartsWith('!') -and [Management.Automation.WildcardPattern]::Get($pattern, 'IgnoreCase').IsMatch($alias)) { throw 'That SSH alias matches an existing Host entry; it was retained.' }
                    }
                }
            }
        }
        $existing = Invoke-WslCommand -FilePath 'ssh.exe' -Arguments @('-G', $alias) -TimeoutMilliseconds 15000
        if ($existing.ExitCode -ne 0 -or -not $existing.IsDecoded) { throw "Could not inspect existing SSH configuration: $($existing.ErrorText)" }
        $hostMatch = [regex]::Match($existing.Text, '(?im)^hostname (.+)\r?$')
        if (-not $hostMatch.Success -or $hostMatch.Groups[1].Value.Trim().ToLowerInvariant() -cne $alias.ToLowerInvariant() -or $existing.Text -match '(?im)^proxycommand (?!none\s*$).+') { throw 'That SSH alias already resolves through another configuration; it was retained.' }
    }
    if (-not (Test-Path -LiteralPath $ssh)) { $null = New-Item -ItemType Directory -Path $ssh }
    if (-not (Test-Path -LiteralPath $root)) {
        $null = New-Item -ItemType Directory -Path $root
        Set-WslAgentSshPrivateAcl -Path $root -Sid $sid -Directory
        Write-WslAgentSshFile -Path $marker -Text $owner
    }
    $keyMetadata = if (Test-Path -LiteralPath $keyRecord) { [IO.File]::ReadAllText($keyRecord) | ConvertFrom-Json -ErrorAction Stop } else { $null }
    if (-not $keyMetadata) {
        if ((Test-Path -LiteralPath $key) -or (Test-Path -LiteralPath $public)) { throw 'Existing dedicated SSH key is unrecorded or incomplete; it was not overwritten.' }
        $keyMetadata = [pscustomobject]@{owner = $owner; state = 'CREATING'}
        Write-WslAgentSshFile -Path $keyRecord -Text ($keyMetadata | ConvertTo-Json -Compress)
    }
    if ($keyMetadata.owner -cne $owner -or [string]$keyMetadata.state -notin @('', 'CREATING', 'READY') -or (-not $keyMetadata.state -and -not $keyMetadata.public_key)) { throw 'Dedicated SSH key ownership record is invalid; its files were retained.' }
    $pendingKey = $keyMetadata.state -ceq 'CREATING'
    if (-not $pendingKey -and (-not (Test-Path -LiteralPath $key -PathType Leaf) -or -not (Test-Path -LiteralPath $public -PathType Leaf))) { throw 'Recorded dedicated SSH key is incomplete; review before replacing its identity.' }
    if (-not (Test-Path -LiteralPath $key)) {
        if ((Test-Path -LiteralPath $public) -or -not $pendingKey) { throw 'Dedicated SSH public key has no private key; it was retained.' }
        $generated = Invoke-WslCommand -FilePath 'ssh-keygen.exe' -Arguments @('-q', '-t', 'ed25519', '-N', '', '-f', $key, '-C', 'oneDebian Agent') -TimeoutMilliseconds 30000
        if ($generated.ExitCode -ne 0) { throw "Could not generate the dedicated SSH key: $($generated.ErrorText)" }
    }
    if (-not (Test-Path -LiteralPath $key -PathType Leaf) -or (Get-Item -LiteralPath $key).Length -gt 16384) { throw 'Dedicated SSH private-key file is missing or unexpectedly large.' }
    Set-WslAgentSshPrivateAcl -Path $key -Sid $sid
    $derived = Invoke-WslCommand -FilePath 'ssh-keygen.exe' -Arguments @('-y', '-P', '', '-f', $key) -TimeoutMilliseconds 10000
    if ($derived.ExitCode -ne 0 -or -not $derived.IsDecoded) { throw "Could not validate the owned dedicated SSH private key: $($derived.ErrorText)" }
    $derivedKey = Get-WslAgentSshPublicKey -Text $derived.Text.Trim()
    if (-not (Test-Path -LiteralPath $public)) {
        if (-not $pendingKey) { throw 'Recorded public key is missing; it was not replaced.' }
        Write-WslAgentSshFile -Path $public -Text ($derivedKey + "`n")
    }
    if ((Get-Item -LiteralPath $public).Length -gt 8192) { throw 'SSH public-key file is unexpectedly large.' }
    $publicKey = Get-WslAgentSshPublicKey -Text ([IO.File]::ReadAllText($public).Trim())
    $checked = Invoke-WslCommand -FilePath 'ssh-keygen.exe' -Arguments @('-l', '-f', $public) -TimeoutMilliseconds 10000
    $privateSha = (Get-FileHash -LiteralPath $key -Algorithm SHA256).Hash.ToLowerInvariant()
    $publicSha = (Get-FileHash -LiteralPath $public -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($checked.ExitCode -ne 0 -or $derivedKey -cne $publicKey -or ($keyMetadata.public_key -and $keyMetadata.public_key -cne $publicKey) -or ($keyMetadata.private_sha256 -and $keyMetadata.private_sha256 -cne $privateSha) -or ($keyMetadata.public_sha256 -and $keyMetadata.public_sha256 -cne $publicSha)) { throw 'Dedicated private/public SSH key does not match its recorded identity; it was retained.' }
    Write-WslAgentSshFile -Path $keyRecord -Text (@{owner = $owner; state = 'READY'; public_key = $publicKey; private_sha256 = $privateSha; public_sha256 = $publicSha} | ConvertTo-Json -Compress)
    Write-Host '正在安装并验证 SSH / SSH setup；客机日志：/var/lib/onedebian-agent/ssh.log'
    $backend = Invoke-WslAgentCommand -Distro $Distro -Entry $Entry -Command ssh -Options @('--yes', '--ssh-public-key', $publicKey, '--ssh-port', [string]$SshPort, '--json') -Timeout 0 -AllowFailure
    try { $ready = $backend.Text | ConvertFrom-Json -ErrorAction Stop } catch { throw "SSH setup returned invalid data: $($backend.ErrorText)" }
    if ($backend.ExitCode -ne 0 -or $ready.state -cne 'SSH_READY' -or [int]$ready.port -ne $SshPort) { throw "SSH setup failed: $($ready.error) $($ready.reason) $($backend.ErrorText)" }
    $hostKey = Get-WslAgentSshPublicKey -Text ([string]$ready.host_public_key).Trim()
    $candidate = Join-Path $root ($alias + '.host-public-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        Write-WslAgentSshFile -Path $candidate -Text ($hostKey + "`n")
        $checkHost = Invoke-WslCommand -FilePath 'ssh-keygen.exe' -Arguments @('-l', '-f', $candidate) -TimeoutMilliseconds 10000
        if ($checkHost.ExitCode -ne 0) { throw 'The selected WSL returned an invalid SSH host key.' }
    } finally { if (Test-Path -LiteralPath $candidate) { Remove-Item -LiteralPath $candidate -Force } }
    $wsl = (Get-Command 'wsl.exe' -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $proxy = (@($wsl, '--distribution', $Distro, '--user', 'agent', '--exec', '/usr/bin/nc', '127.0.0.1', [string]$SshPort) | ForEach-Object { ConvertTo-WslCommandArgument $_ }) -join ' '
    $fragmentText = "# oneDebian-agent-ssh-v1`nHost $alias`n  HostName 127.0.0.1`n  User agent`n  Port $SshPort`n  IdentityFile `"$($key.Replace('\','/'))`"`n  IdentitiesOnly yes`n  BatchMode yes`n  StrictHostKeyChecking yes`n  CheckHostIP no`n  HostKeyAlias $alias`n  UserKnownHostsFile `"$($known.Replace('\','/'))`"`n  ProxyCommand $proxy`n"
    $knownText = "$alias,[$alias]:$SshPort $hostKey`n"
    $include = 'Include "' + (Join-Path $root '*.conf').Replace('\','/') + '"'
    $original = if (Test-Path -LiteralPath $config) { [IO.File]::ReadAllText($config, (New-Object Text.UTF8Encoding($false, $true))) } else { '' }
    if ($original.IndexOf([char]0) -ge 0) { throw 'SSH config is not plain UTF-8 text; review it manually.' }
    $hasInclude = $original -match ('(?m)^' + [regex]::Escape($include) + '\r?$')
    if ($hasInclude -and -not $original.StartsWith($include + "`n") -and -not $original.StartsWith($include + "`r`n")) { throw 'The oneDebian SSH Include was moved into another scope; review it manually.' }
    if (-not $hasInclude) {
        if (-not (Test-Path -LiteralPath (Join-Path $root 'config.before'))) { Write-WslAgentSshFile -Path (Join-Path $root 'config.before') -Text $original }
        Write-WslAgentSshFile -Path $config -Text ($include + "`n" + $original)
    }
    Write-WslAgentSshFile -Path $fragment -Text $fragmentText
    Write-WslAgentSshFile -Path $known -Text $knownText
    Write-WslAgentSshFile -Path $recordPath -Text (@{owner = $owner; distro = $Distro; alias = $alias; port = $SshPort;
        config_sha256 = (Get-FileHash -LiteralPath $fragment -Algorithm SHA256).Hash.ToLowerInvariant();
        known_sha256 = (Get-FileHash -LiteralPath $known -Algorithm SHA256).Hash.ToLowerInvariant()} | ConvertTo-Json -Compress)
    $connection = Invoke-WslCommand -FilePath 'ssh.exe' -Arguments @('-T', '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes', '-o', 'ConnectTimeout=15', $alias, 'id -un && hostname') -TimeoutMilliseconds 30000
    $lines = @($connection.Text.Trim() -split '\r?\n')
    if ($connection.ExitCode -ne 0 -or -not $connection.IsDecoded -or $lines.Count -ne 2 -or $lines[0] -cne 'agent' -or $lines[1] -notmatch '^[a-zA-Z0-9_.-]+$') { throw "SSH alias is configured but its login test failed: $($connection.ErrorText)" }
    Write-Host "SSH 已就绪 / Ready: ssh $alias；用户 agent；主机 $($lines[1])"
    Write-Host '通过实例名连接，不依赖 WSL IP；不监听 Windows 22 端口，也无需 Linux Codex 登录。'
    return [pscustomobject]@{state = 'SSH_READY'; alias = $alias; port = $SshPort; hostname = $lines[1]; config = $fragment}
}

function Remove-WslAgentSshRegistration {
    param([Parameter(Mandatory = $true)][string]$Distro)
    if ($Distro -notmatch '\A[A-Za-z0-9][A-Za-z0-9_. -]{0,63}\z' -or $Distro.EndsWith(' ')) { throw 'Invalid WSL name for SSH removal.' }
    $alias = 'oneDebian-' + ($Distro.ToLowerInvariant() -replace '[^a-z0-9_.-]', '-')
    $ssh = Join-Path $env:USERPROFILE '.ssh'
    $root = Join-Path $ssh 'onedebian-agent'
    $recordPath = Join-Path $root ($alias + '.json')
    $fragment = Join-Path $root ($alias + '.conf')
    $known = Join-Path $root ($alias + '.known_hosts')
    $marker = Join-Path $root '.owner'
    foreach ($path in @($root, $marker, $recordPath, $fragment, $known)) { Assert-WslAgentSshPath -Path $path }
    if (-not (Test-Path -LiteralPath $recordPath)) { return [pscustomobject]@{state='SSH_ABSENT';reason='No owned SSH alias registration; Windows keys retained'} }
    $owner = 'oneDebian-agent-ssh-v1|' + [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if (-not (Test-Path -LiteralPath $marker) -or [IO.File]::ReadAllText($marker) -cne $owner) { throw 'SSH ownership marker differs; registration was retained.' }
    $record = [IO.File]::ReadAllText($recordPath) | ConvertFrom-Json -ErrorAction Stop
    if ($record.owner -cne $owner -or $record.distro -cne $Distro -or $record.alias -cne $alias) { throw 'SSH registration belongs to another target; it was retained.' }
    foreach ($item in @(@($fragment, 'config_sha256'), @($known, 'known_sha256'))) {
        if ((Test-Path -LiteralPath $item[0]) -and (Get-FileHash -LiteralPath $item[0] -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$record.($item[1])) {
            return [pscustomobject]@{state='SSH_RETAINED';reason='SSH alias or host-key file was edited; all registration files and Windows keys retained'}
        }
    }
    foreach ($path in @($fragment, $known, $recordPath)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force } }
    $reason = 'Removed only this owned SSH alias and host-key entry; Windows keys retained'
    if (-not @(Get-ChildItem -LiteralPath $root -Filter '*.conf' -File).Count) {
        $config = Join-Path $ssh 'config'
        Assert-WslAgentSshPath -Path $config
        if (Test-Path -LiteralPath $config) {
            $text = [IO.File]::ReadAllText($config, (New-Object Text.UTF8Encoding($false, $true)))
            $prefix = 'Include "' + (Join-Path $root '*.conf').Replace('\','/') + '"' + "`n"
            if ($text.StartsWith($prefix) -and [regex]::Matches($text, [regex]::Escape($prefix.TrimEnd("`n"))).Count -eq 1) { Write-WslAgentSshFile -Path $config -Text $text.Substring($prefix.Length) }
            elseif ($text.Contains($root.Replace('\','/'))) { $reason += '; edited global Include retained' }
        }
    }
    return [pscustomobject]@{state='SSH_REMOVED';reason=$reason}
}
