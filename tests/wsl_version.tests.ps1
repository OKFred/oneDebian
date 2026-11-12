# Offline version checks; load functions without entering the real menu or WSL.
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'menu.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'Menu source contains parser errors.' }
foreach ($name in @('Get-OneDebianVersion', 'Main', 'Show-About')) {
    $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    if ($null -eq $definition) { throw "Menu function is missing: $name" }
    . ([scriptblock]::Create($definition.Extent.Text))
}
$script:versionCases = 0
$script:versionFailures = New-Object 'System.Collections.Generic.List[string]'
function Assert-Version { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }
function Test-Version { param([string]$Name, [scriptblock]$Body)
    $script:versionCases++
    try { & $Body; Write-Host "PASS $Name" }
    catch { $script:versionFailures.Add("${Name}: $($_.Exception.Message)"); Write-Host "FAIL ${Name}: $($_.Exception.Message)" }
}
function Use-VersionFixture { param([scriptblock]$Body)
    $path = Join-Path ([IO.Path]::GetTempPath()) ('onedebian-version-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $path
    try { & $Body $path }
    finally {
        $resolved = [IO.Path]::GetFullPath($path)
        $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
        if ((Split-Path -Parent $resolved).TrimEnd('\', '/') -ine $temp -or [IO.Path]::GetFileName($resolved) -notmatch '^onedebian-version-[a-f0-9]{32}$') { throw 'Unsafe version fixture cleanup path.' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
function Initialize-VersionFixture { param([string]$Path)
    $git = (Get-Command git.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    & $git -c init.defaultBranch=version-fixture init --quiet --template= $Path
    if ($LASTEXITCODE -ne 0) { throw 'Fixture git init failed.' }
    $emptyHooks = Join-Path $Path '.git\empty-hooks'
    $null = New-Item -ItemType Directory -Path $emptyHooks
    [IO.File]::WriteAllText((Join-Path $Path 'tracked.txt'), "fixture`n")
    & $git -C $Path add -- tracked.txt
    if ($LASTEXITCODE -ne 0) { throw 'Fixture git add failed.' }
    & $git -C $Path -c user.name=oneDebian-fixture -c user.email=fixture@example.invalid -c commit.gpgSign=false -c "core.hooksPath=$emptyHooks" commit --no-gpg-sign -qm fixture
    if ($LASTEXITCODE -ne 0) { throw 'Fixture git commit failed.' }
    return $git
}

Test-Version 'clean checkout reports its short commit and version reading leaves the index unchanged' {
    Use-VersionFixture { param($fixture)
        $git = Initialize-VersionFixture -Path $fixture
        $expected = [string](& $git -C $fixture rev-parse --short=8 HEAD)
        $index = Join-Path $fixture '.git\index'
        $before = (Get-FileHash -LiteralPath $index).Hash
        $mtime = (Get-Item -LiteralPath $index).LastWriteTimeUtc
        $actual = Get-OneDebianVersion -RepoRoot $fixture
        Assert-Version ($actual -ceq $expected) 'clean version does not identify its commit'
        Assert-Version ((Get-FileHash -LiteralPath $index).Hash -ceq $before -and (Get-Item -LiteralPath $index).LastWriteTimeUtc -eq $mtime) 'version reading changed the Git index'
    }
}
Test-Version 'modified and untracked files both add the dirty suffix' {
    Use-VersionFixture { param($fixture)
        $null = Initialize-VersionFixture -Path $fixture
        $tracked = Join-Path $fixture 'tracked.txt'
        [IO.File]::AppendAllText($tracked, 'changed')
        Assert-Version ((Get-OneDebianVersion -RepoRoot $fixture) -cmatch '^[a-f0-9]{8,64}\+dirty$') 'tracked changes are not visible'
        [IO.File]::WriteAllText($tracked, "fixture`n")
        [IO.File]::WriteAllText((Join-Path $fixture 'untracked.txt'), 'new')
        Assert-Version ((Get-OneDebianVersion -RepoRoot $fixture) -cmatch '^[a-f0-9]{8,64}\+dirty$') 'untracked changes are not visible'
    }
}
Test-Version 'an archive does not borrow an enclosing repository version' {
    Use-VersionFixture { param($fixture)
        $null = Initialize-VersionFixture -Path $fixture
        $archive = Join-Path $fixture 'archive'
        $null = New-Item -ItemType Directory -Path $archive
        function Get-Command { throw 'Git should not be queried for an archive.' }
        Assert-Version ((Get-OneDebianVersion -RepoRoot $archive) -like 'unknown*') 'archive incorrectly reported its parent repository commit'
    }
}
Test-Version 'missing Git and invalid metadata fall back without throwing' {
    Use-VersionFixture { param($fixture)
        $null = New-Item -ItemType Directory -Path (Join-Path $fixture '.git')
        Assert-Version ((Get-OneDebianVersion -RepoRoot $fixture) -like 'unknown*') 'invalid Git metadata did not fall back'
        function Get-Command { throw 'fixture missing git.exe' }
        Assert-Version ((Get-OneDebianVersion -RepoRoot $fixture) -like 'unknown*') 'missing Git did not fall back'
    }
}
Test-Version 'version survives every menu clear and About uses the same startup value' {
    $script:oneDebianVersion = 'cafebabe+dirty'
    $state = [pscustomobject]@{ Events = (New-Object 'System.Collections.Generic.List[string]'); Reads = 0 }
    function Write-Host { param($Object, $ForegroundColor) $state.Events.Add([string]$Object) }
    function Clear-Host { $state.Events.Add('fixture-clear') }
    function Get-I18nStr { param($Key) $Key }
    function Start-Sleep { param($Seconds) }
    function Read-Host { param($Prompt)
        $state.Reads++
        $state.Events.Add('fixture-read')
        if ($state.Reads -eq 1) { return 'invalid-fixture-choice' }
        throw 'end private version fixture'
    }
    try { Main } catch { if ($_.Exception.Message -cne 'end private version fixture') { throw } }
    $joined = $state.Events -join "`n"
    Assert-Version (([regex]::Matches($joined, 'Version: cafebabe\+dirty')).Count -eq 2) 'menu clearing hid or changed the startup version'
    foreach ($segment in ($joined -split 'fixture-clear' | Select-Object -Skip 1)) {
        Assert-Version ($segment.IndexOf('Version: cafebabe+dirty') -ge 0 -and $segment.IndexOf('Version: cafebabe+dirty') -lt $segment.IndexOf('fixture-read')) 'version was not visible before input'
    }
    $state.Events.Clear()
    Show-About
    Assert-Version (($state.Events -join "`n").Contains('cafebabe+dirty')) 'About did not reuse the startup version'
}
Write-Host "WSL version regressions: $script:versionCases tests, $($script:versionFailures.Count) failures."
if ($script:versionFailures.Count) { throw ($script:versionFailures -join "`n") }
