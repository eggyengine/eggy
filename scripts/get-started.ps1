# Create a project from Eggy's template on Windows.
#
#   irm https://raw.githubusercontent.com/eggyengine/eggy/main/scripts/get-started.ps1 | iex
#
# Asks in the current PowerShell session. If Zig 0.17 is missing, a yes installs
# zvm (when it is not already installed) and then Zig.
# EGGY_SOURCE overrides where the template is downloaded from.
# EGGY_GIT overrides the Eggy package `zig fetch` saves.
# EGGY_GET_STARTED_TEST=1 defines the functions and returns, for this script's own check.
# Do not call exit: this file is invoked inside the caller's session.

$EggySource = if ($env:EGGY_SOURCE) { $env:EGGY_SOURCE } else { 'https://raw.githubusercontent.com/eggyengine/eggy/main' }
$EggyGit = if ($env:EGGY_GIT) { $env:EGGY_GIT } else { 'git+https://github.com/eggyengine/eggy' }
$ZigRelease = '0.17.0'
$TemplateFingerprint = '0x76cd980c5eed1e55'
$TemplateFiles = @(
    '.gitignore'
    'build.zig'
    'build.zig.zon'
    'controls.zon'
    'eggy.zon'
    'src/main.zig'
    'src/root.zig'
)
$ZigKeywords = @(
    'addrspace', 'align', 'allowzero', 'and', 'anyframe', 'anytype', 'asm', 'break', 'callconv',
    'catch', 'comptime', 'const', 'continue', 'defer', 'else', 'enum', 'errdefer', 'error',
    'export', 'extern', 'fn', 'for', 'if', 'inline', 'noalias', 'noinline', 'nosuspend',
    'opaque', 'or', 'orelse', 'packed', 'pub', 'resume', 'return', 'linksection', 'struct',
    'suspend', 'switch', 'test', 'threadlocal', 'try', 'union', 'unreachable', 'var',
    'volatile', 'while'
)

function Test-Yes([string]$Reply) {
    return $Reply -match '^(?i)(y|yes)$'
}

function Read-Answer([string]$Prompt, [string]$Default) {
    if ($Default) {
        $reply = Read-Host "$Prompt [$Default]"
        if ([string]::IsNullOrWhiteSpace($reply)) { return $Default }
        return $reply.Trim()
    }
    while ($true) {
        $reply = Read-Host $Prompt
        if (-not [string]::IsNullOrWhiteSpace($reply)) { return $reply.Trim() }
        Write-Host 'Please enter a value.'
    }
}

function Test-PackageName([string]$Name) {
    if ($Name -eq '_' -or $Name.Length -lt 1 -or $Name.Length -gt 32) { return $false }
    if ($Name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { return $false }
    if ($ZigKeywords -ccontains $Name) { return $false }
    return $true
}

# The same derivation the editor uses: lower case, words joined by `_`, `game_` when needed.
function Get-PackageName([string]$Title) {
    $result = ''
    $gap = $false
    foreach ($char in $Title.ToCharArray()) {
        $text = [string]$char
        if ($text -match '[A-Za-z0-9]') {
            $lower = $text.ToLowerInvariant()
            if ($result.Length -eq 0 -and $lower -match '[0-9]') {
                $result = 'game_'
            }
            elseif ($gap -and $result.Length -gt 0 -and $result.Length -lt 32) {
                $result += '_'
            }
            $gap = $false
            if ($result.Length -eq 32) { break }
            $result += $lower
        }
        else {
            $gap = $true
        }
    }
    if ($result -and -not (Test-PackageName $result) -and ($result.Length + 5) -le 32) {
        $result = "game_$result"
    }
    return $result
}

function ConvertTo-ZonString([string]$Text) {
    return $Text.Replace('\', '\\').Replace('"', '\"').Replace("`r", '').Replace("`n", ' ')
}

# PowerShell remembers the first `zig` it found, so a zvm switch in this session
# has to call the shim in ~/.zvm/bin by path.
function Get-ZigExe {
    if ($script:ZigExe) { return $script:ZigExe }
    $cmd = Get-Command zig -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Get-ZigVersionText {
    $exe = Get-ZigExe
    if (-not $exe) { return '' }
    $text = (& $exe version 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { return '' }
    return ($text -replace "`r", '').Trim()
}

function Get-ZonField([string]$Text, [string]$Name) {
    $pattern = '(?m)^\s*\.' + [regex]::Escape($Name) + ' = "(.*)",\s*$'
    if ($Text -notmatch $pattern) { return $null }
    return $Matches[1].Replace('\\', '\').Replace('\"', '"')
}

function Add-ZvmPath {
    $root = Join-Path $HOME '.zvm'
    $self = if ($env:ZVM_INSTALL) { $env:ZVM_INSTALL } else { Join-Path $root 'self' }
    $bin = Join-Path $root 'bin'
    $env:ZVM_INSTALL = $self
    $env:PATH = "$bin$([IO.Path]::PathSeparator)$self$([IO.Path]::PathSeparator)$env:PATH"
}

function Get-ZvmPath {
    $cmd = Get-Command zvm -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $self = Join-Path (Join-Path $HOME '.zvm') 'self'
    foreach ($name in @('zvm.exe', 'zvm')) {
        $candidate = Join-Path $self $name
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return $null
}

function Install-ZvmIfNeeded {
    Add-ZvmPath
    if (Get-ZvmPath) { return }
    Write-Host 'Installing zvm from https://www.zvm.app.'
    $installer = (Invoke-WebRequest -UseBasicParsing -Uri 'https://www.zvm.app/install.ps1').Content
    Invoke-Expression $installer
    Add-ZvmPath
    if (-not (Get-ZvmPath)) {
        throw 'zvm was installed but is not at ~/.zvm/self.'
    }
}

# Ask before changing the machine. Yes installs zvm when it is missing, then Zig 0.17.
# Returns $false when the person declines.
function Install-ZigIfNeeded {
    $version = Get-ZigVersionText
    if ($version -match '^0\.17\.') {
        $script:ZigVersion = $version
        return $true
    }
    if ($version) {
        Write-Host "This zig is $version. Eggy needs Zig 0.17."
    }
    else {
        Write-Host 'Zig is not installed. Eggy needs Zig 0.17.'
    }
    $reply = Read-Answer "Install Zig $ZigRelease with zvm? This installs zvm if needed and switches your active Zig" 'Y'
    if (-not (Test-Yes $reply)) {
        Write-Host "Zig ${ZigRelease}: https://ziglang.org/download/"
        return $false
    }
    Install-ZvmIfNeeded
    $zvm = Get-ZvmPath
    Write-Host "Installing Zig $ZigRelease."
    & $zvm install $ZigRelease
    if ($LASTEXITCODE -ne 0) { throw "zvm install failed ($LASTEXITCODE)." }
    & $zvm use $ZigRelease
    if ($LASTEXITCODE -ne 0) { throw "zvm use failed ($LASTEXITCODE)." }
    Add-ZvmPath
    $bin = Join-Path (Join-Path $HOME '.zvm') 'bin'
    $script:ZigExe = $null
    foreach ($name in @('zig.exe', 'zig.cmd', 'zig')) {
        $candidate = Join-Path $bin $name
        if (Test-Path -LiteralPath $candidate) {
            $script:ZigExe = $candidate
            break
        }
    }
    $version = Get-ZigVersionText
    if ($version -notmatch '^0\.17\.') {
        throw 'Zig 0.17 is still not on PATH. Open a new terminal so ~/.zvm/bin is picked up.'
    }
    $script:ZigVersion = $version
    return $true
}

function Test-ZigInstall {
    $envText = (& (Get-ZigExe) env 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { throw 'zig env failed.' }
    $stdDir = Get-ZonField $envText 'std_dir'
    $cache = Get-ZonField $envText 'global_cache_dir'
    if (-not $stdDir -or -not (Test-Path -LiteralPath (Join-Path $stdDir 'std.zig'))) {
        throw "Zig's standard library is not beside this compiler ($stdDir)."
    }
    if (-not $cache) { throw "Zig's cache is not writable." }
    New-Item -ItemType Directory -Force -Path $cache | Out-Null
    $probe = Join-Path $cache 'eggy-get-started-probe'
    try {
        New-Item -ItemType File -Force -Path $probe | Out-Null
    }
    catch {
        throw "Zig's cache is not writable ($cache)."
    }
    Remove-Item -LiteralPath $probe -Force
}

# Every template file, before the project directory is created.
function Get-Template {
    $stage = Join-Path ([IO.Path]::GetTempPath()) ('eggy-template-' + [guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Path $stage | Out-Null
    $missing = @()
    foreach ($file in $TemplateFiles) {
        $dest = Join-Path $stage ($file -replace '/', [IO.Path]::DirectorySeparatorChar)
        $parent = Split-Path -Parent $dest
        if (-not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent | Out-Null
        }
        $url = "$EggySource/resources/template/$file"
        try {
            Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $dest
            if (-not (Test-Path -LiteralPath $dest) -or (Get-Item -LiteralPath $dest).Length -eq 0) {
                throw 'empty'
            }
        }
        catch {
            $missing += $url
        }
    }
    if ($missing.Count -gt 0) {
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host 'Could not download the template:'
        foreach ($url in $missing) { Write-Host "  $url" }
        return $null
    }
    return $stage
}

function Resolve-ProjectDirectory([string]$Path) {
    if (-not [IO.Path]::IsPathRooted($Path)) {
        $Path = Join-Path (Get-Location) $Path
    }
    $full = [IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $full
    if (-not $parent -or -not (Test-Path -LiteralPath $parent)) {
        throw "That folder's parent does not exist: $parent"
    }
    return $full
}

function Test-DirectoryEmpty([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $true }
    return @(Get-ChildItem -Force -LiteralPath $Path).Count -eq 0
}

function Get-Fingerprint([string]$Name) {
    $work = Join-Path ([IO.Path]::GetTempPath()) ('eggy-fingerprint-' + [guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Path $work | Out-Null
    $source = Join-Path $work 'fingerprint.zig'
    $utf8 = New-Object System.Text.UTF8Encoding $false
    $program = @'
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
    _ = args.next();
    const name = args.next() orelse return error.MissingName;
    var random: [4]u8 = undefined;
    init.io.random(&random);
    var id = std.mem.readInt(u32, &random, .little);
    if (id == 0 or id == 0xffffffff) id = 1;
    const fingerprint = @as(u64, std.hash.Crc32.hash(name)) << 32 | id;
    var buffer: [32]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    try stdout.interface.print("0x{x:0>16}\n", .{fingerprint});
    try stdout.interface.flush();
}
'@
    try {
        [IO.File]::WriteAllText($source, $program, $utf8)
        $printed = (& (Get-ZigExe) run $source -- $Name | Out-String)
        if ($LASTEXITCODE -ne 0) { throw "zig run failed ($LASTEXITCODE)." }
        return ($printed -replace "`r", '').Trim()
    }
    finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Write-FilledFile([string]$Path, [string]$Fingerprint, [string]$Name, [string]$Title) {
    $utf8 = New-Object System.Text.UTF8Encoding $false
    $data = [IO.File]::ReadAllText($Path)
    $data = $data.Replace($TemplateFingerprint, $Fingerprint)
    $data = $data.Replace('eggy_template_name', $Name)
    $data = $data.Replace('eggy_template_title', $Title)
    [IO.File]::WriteAllText($Path, $data, $utf8)
}

function Start-EggyProject {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    if (-not [Environment]::UserInteractive) {
        Write-Error 'get-started needs a terminal so it can ask a few questions.'
        return
    }
    if (-not (Install-ZigIfNeeded)) { return }
    Test-ZigInstall
    $stage = Get-Template
    if (-not $stage) { return }
    $directory = $null
    $wipe = $false
    try {
        Write-Host "Create an Eggy project. Zig $($script:ZigVersion)."
        $title = Read-Answer 'Project title'
        $suggested = Get-PackageName $title
        while ($true) {
            if ($suggested) {
                $name = Read-Answer 'Package name' $suggested
            }
            else {
                $name = Read-Answer 'Package name'
            }
            if (Test-PackageName $name) { break }
            Write-Host 'Package names are Zig identifiers of at most 32 characters, not keywords.'
            $suggested = ''
        }
        $directory = Resolve-ProjectDirectory (Read-Answer 'Directory' $name)
        if (-not (Test-DirectoryEmpty $directory)) {
            Write-Error "$directory exists and is not empty. Nothing was written."
            return
        }
        Write-Host "Title:     $title"
        Write-Host "Package:   $name"
        Write-Host "Directory: $directory"
        if (-not (Test-Yes (Read-Answer 'Create this project?' 'Y'))) {
            Write-Host 'Cancelled.'
            return
        }

        New-Item -ItemType Directory -Force -Path (Join-Path $directory 'src') | Out-Null
        $wipe = $true
        foreach ($file in $TemplateFiles) {
            $relative = $file -replace '/', [IO.Path]::DirectorySeparatorChar
            $from = Join-Path $stage $relative
            $to = Join-Path $directory $relative
            $parent = Split-Path -Parent $to
            if (-not (Test-Path -LiteralPath $parent)) {
                New-Item -ItemType Directory -Path $parent | Out-Null
            }
            Copy-Item -LiteralPath $from -Destination $to
        }
        $titleZon = ConvertTo-ZonString $title
        $fingerprint = Get-Fingerprint $name
        foreach ($file in $TemplateFiles) {
            $relative = $file -replace '/', [IO.Path]::DirectorySeparatorChar
            Write-FilledFile (Join-Path $directory $relative) $fingerprint $name $titleZon
        }

        # Drop the placeholder path: `zig fetch --save` would overwrite only its string and skip the hash.
        $zonPath = Join-Path $directory 'build.zig.zon'
        $utf8 = New-Object System.Text.UTF8Encoding $false
        $zon = [IO.File]::ReadAllText($zonPath)
        $needle = '.eggy = .{ .path = "eggy_template_engine" },'
        if ($zon.IndexOf($needle) -lt 0) {
            throw "The template no longer has the engine placeholder this script removes."
        }
        [IO.File]::WriteAllText($zonPath, $zon.Replace($needle, ''), $utf8)

        Write-Host 'Fetching Eggy and its required packages.'
        Push-Location $directory
        try {
            & (Get-ZigExe) fetch --save=eggy $EggyGit
            if ($LASTEXITCODE -ne 0) { throw "zig fetch failed ($LASTEXITCODE)." }
            & (Get-ZigExe) build --fetch
            if ($LASTEXITCODE -ne 0) { throw "zig build --fetch failed ($LASTEXITCODE)." }
        }
        finally {
            Pop-Location
        }
        $wipe = $false
        Write-Host ""
        Write-Host "Created $directory"
        Write-Host "  cd $directory"
        Write-Host '  zig build run'
    }
    catch {
        if ($wipe -and $directory -and (Test-Path -LiteralPath $directory)) {
            Remove-Item -LiteralPath $directory -Recurse -Force -ErrorAction SilentlyContinue
        }
        throw
    }
    finally {
        if ($stage -and (Test-Path -LiteralPath $stage)) {
            Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

if ($env:EGGY_GET_STARTED_TEST -eq '1') {
    return
}
Start-EggyProject
