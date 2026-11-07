# Install Eggy on Windows: Zig 0.17 if it is missing, then the launcher, from GitHub Releases.
#
#   irm https://raw.githubusercontent.com/eggyengine/eggy/main/scripts/get-started.ps1 | iex
#
# Asks in the current PowerShell session. If Zig 0.17 is missing, a yes installs zvm (when it is
# not already installed) and then Zig. Then it asks for the latest release or the nightly, and
# whether to install just for you (%LOCALAPPDATA%\Programs\Eggy) or for everyone
# (%ProgramFiles%\Eggy, from an administrator PowerShell), adds its bin folder to PATH and the
# Start menu, and replaces the launcher installed there before.
# EGGY_REPO overrides the GitHub repository the launcher is downloaded from (owner/name).
# EGGY_GET_STARTED_TEST=1 defines the functions and returns, for this script's own check.
# Do not call exit: this file is invoked inside the caller's session.

$EggyRepo = if ($env:EGGY_REPO) { $env:EGGY_REPO } else { 'eggyengine/eggy' }
$ZigRelease = '0.17.1'
$Platform = 'windows-x86_64'

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


# Eggy's logo, darker toward the shell's shadow.
function Write-Egg {
    Write-Host @'

         :oooooooooo:
       :ooooooooooooo00
      :oo....:oooooooo00
     :oooo:::ooooooooo0#O
     ooooooooooooooooO0#0
    :oooooooooooooooOO00#O
    OoooooooooooooooO00##0
    0OooooooooooooOOO##@@#
    00OOoooooooOOOO0##@@@#
    0#00OOOOOOOOO####@@@##
    0##############@@@@@#
     0##@@@@###@@@@@@@@#0
      ####@@@@@@@@@@@##0
         ###########O

'@
}

# Where a channel's asset downloads from. `latest` skips prereleases, so it never serves the nightly;
# nightlies are tagged by day (`nightly-<yyyy-mm-dd>`), and GitHub lists the newest first.
function Get-AssetUrl([string]$Channel) {
    if ($Channel -eq 'nightly') {
        $releases = Invoke-RestMethod -UseBasicParsing -Uri "https://api.github.com/repos/$EggyRepo/releases?per_page=30"
        $tag = ($releases | Where-Object { $_.tag_name -like 'nightly-*' } | Select-Object -First 1).tag_name
        if (-not $tag) { throw 'No nightly release found.' }
        return "https://github.com/$EggyRepo/releases/download/$tag/eggy-$Platform.tar.gz"
    }
    return "https://github.com/$EggyRepo/releases/latest/download/eggy-$Platform.tar.gz"
}

# Download `Channel`'s launcher to `Archive`. $false when it is not there, so the caller can offer another.
function Get-Launcher([string]$Channel, [string]$Archive) {
    Write-Host "Downloading the $Channel launcher."
    try {
        Invoke-WebRequest -UseBasicParsing -Uri (Get-AssetUrl $Channel) -OutFile $Archive
        return $true
    }
    catch {
        return $false
    }
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Unpack `Archive` beside `Destination` and swap it in, so a failed unpack leaves the old launcher working.
function Install-Launcher([string]$Archive, [string]$Destination) {
    $fresh = "$Destination.new"
    $old = "$Destination.old"
    foreach ($path in @($fresh, $old)) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
    }
    New-Item -ItemType Directory -Force -Path $fresh | Out-Null
    # tar.exe ships with Windows 10 and later.
    & tar.exe -xzf $Archive -C $fresh
    if ($LASTEXITCODE -ne 0) { throw "tar failed ($LASTEXITCODE)." }
    if (-not (Test-Path -LiteralPath (Join-Path $fresh 'bin\eggy_editor.exe'))) {
        Remove-Item -LiteralPath $fresh -Recurse -Force
        throw 'The download has no bin\eggy_editor.exe.'
    }
    if (Test-Path -LiteralPath $Destination) { Move-Item -LiteralPath $Destination -Destination $old }
    Move-Item -LiteralPath $fresh -Destination $Destination
    if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Recurse -Force }
}

# Add `Folder` to the user's or the machine's PATH, once, and to this session's.
function Add-ToPath([string]$Folder, [EnvironmentVariableTarget]$Target) {
    $current = [Environment]::GetEnvironmentVariable('Path', $Target)
    $entries = @($current -split ';' | Where-Object { $_ })
    if ($entries -notcontains $Folder) {
        [Environment]::SetEnvironmentVariable('Path', (@($entries) + $Folder) -join ';', $Target)
    }
    if (@($env:PATH -split ';') -notcontains $Folder) { $env:PATH = "$env:PATH;$Folder" }
}

function New-StartMenuShortcut([string]$Programs, [string]$Exe) {
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut((Join-Path $Programs 'Eggy.lnk'))
    $shortcut.TargetPath = $Exe
    $shortcut.WorkingDirectory = Split-Path -Parent $Exe
    $shortcut.Description = 'Make games with Eggy'
    $shortcut.Save()
}

function Install-Eggy {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    if (-not [Environment]::UserInteractive) {
        Write-Error 'get-started needs a terminal so it can ask a few questions.'
        return
    }
    if ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64') {
        Write-Error "Eggy has no launcher build for $env:PROCESSOR_ARCHITECTURE Windows yet. Build it from source: https://github.com/$EggyRepo"
        return
    }
    if (-not (Install-ZigIfNeeded)) { return }
    Test-ZigInstall

    Write-Egg
    Write-Host "Install Eggy. Zig $($script:ZigVersion)."
    while ($true) {
        $channel = (Read-Answer 'Which build: release or nightly' 'release').ToLowerInvariant()
        if ($channel -in @('release', 'r')) { $channel = 'release'; break }
        if ($channel -in @('nightly', 'n')) { $channel = 'nightly'; break }
        Write-Host 'Type release or nightly.'
    }
    while ($true) {
        $scope = (Read-Answer 'Install for: me or everyone (admin)' 'me').ToLowerInvariant()
        if ($scope -in @('me', 'm', 'user')) { $everyone = $false; break }
        if ($scope -in @('everyone', 'e', 'admin', 'all')) { $everyone = $true; break }
        Write-Host 'Type me or everyone.'
    }
    if ($everyone) {
        if (-not (Test-Administrator)) {
            Write-Error 'Installing for everyone needs an administrator PowerShell. Open one and run this again.'
            return
        }
        $destination = Join-Path $env:ProgramFiles 'Eggy'
        $programs = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'
        $target = [EnvironmentVariableTarget]::Machine
    }
    else {
        $destination = Join-Path $env:LOCALAPPDATA 'Programs\Eggy'
        $programs = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
        $target = [EnvironmentVariableTarget]::User
    }

    $stage = Join-Path ([IO.Path]::GetTempPath()) ('eggy-launcher-' + [guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    try {
        $archive = Join-Path $stage "eggy-$Platform.tar.gz"
        if (-not (Get-Launcher $channel $archive)) {
            if ($channel -eq 'nightly') {
                Write-Error "Could not download the nightly from https://github.com/$EggyRepo/releases."
                return
            }
            $reply = Read-Answer "There is no release for $Platform yet. Install the nightly instead?" 'Y'
            if (-not (Test-Yes $reply)) { return }
            $channel = 'nightly'
            if (-not (Get-Launcher $channel $archive)) {
                Write-Error "Could not download the nightly from https://github.com/$EggyRepo/releases."
                return
            }
        }
        Install-Launcher $archive $destination
    }
    finally {
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    }

    $bin = Join-Path $destination 'bin'
    $exe = Join-Path $bin 'eggy_editor.exe'
    Add-ToPath $bin $target
    New-StartMenuShortcut $programs $exe
    Write-Host ''
    Write-Host "Installed the $channel launcher in $destination"
    Write-Host 'Open it from the Start menu, or with eggy_editor in a new terminal.'

    $reply = Read-Answer 'Open Eggy now?' 'Y'
    if (Test-Yes $reply) { Start-Process -FilePath $exe -WorkingDirectory $bin }
}

if ($env:EGGY_GET_STARTED_TEST -eq '1') {
    return
}
Install-Eggy
