#!/usr/bin/env bash
# Install Eggy: Zig 0.17 if it is missing, then the launcher, from GitHub Releases.
#
#   curl -fsSL https://raw.githubusercontent.com/eggyengine/eggy/main/scripts/get-started.sh | bash
#
# On Windows, from PowerShell:
#
#   irm https://raw.githubusercontent.com/eggyengine/eggy/main/scripts/get-started.ps1 | iex
#
# It asks for the latest release or the nightly, and whether to install just for you
# (~/.local/share/eggy/launcher, linked as ~/.local/bin/eggy) or for everyone (/opt/eggy, linked
# as /usr/local/bin/eggy, through sudo). Running it again replaces the installed launcher.
# Prompts are read from the terminal, so this still works when the script arrives on stdin.
# EGGY_REPO overrides the GitHub repository the launcher is downloaded from (owner/name).
# EGGY_GET_STARTED_TEST=1 loads the functions and returns, for the script's own check.
if [ -z "${BASH_VERSION:-}" ]; then
    echo "get-started needs bash." >&2
    exit 1
fi
set -euo pipefail

EGGY_REPO="${EGGY_REPO:-eggyengine/eggy}"
ZIG_RELEASE="0.17.1"

case "$(uname -s 2>/dev/null || true)" in
    MINGW* | MSYS* | CYGWIN*)
        echo "On Windows, run this from PowerShell:" >&2
        echo "  irm https://raw.githubusercontent.com/eggyengine/eggy/main/scripts/get-started.ps1 | iex" >&2
        exit 1
        ;;
esac

# Stop before any prompt when a tool or the terminal is missing. Zig is offered next.
require_tools() {
    local missing=() tool
    for tool in curl grep tar mkdir rm mv ln tee id mktemp uname touch; do
        command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
    done
    # Permission bits are not enough: with no controlling terminal, open fails.
    # Redirect stderr first so the shell's open error is not shown.
    if ! : 2>/dev/null </dev/tty >/dev/tty; then
        missing+=("a terminal")
    fi
    if [[ ${#missing[@]} -eq 0 ]]; then
        return 0
    fi
    echo "get-started is missing:" >&2
    printf '  %s\n' "${missing[@]}" >&2
    exit 1
}

unescape_zon() {
    local text=$1
    text=${text//\\\\/$'\1'}
    text=${text//\\\"/\"}
    text=${text//$'\1'/\\}
    printf '%s' "$text"
}

# Zig 0.17, its standard library, and a writable package cache.
check_zig() {
    local version env line std_dir cache
    version=$(zig version 2>/dev/null || true)
    version=${version//$'\r'/}
    version=${version//$'\n'/}
    case "$version" in
        0.17.*) ;;
        "")
            echo "zig version failed." >&2
            exit 1
            ;;
        *)
            echo "Eggy needs Zig 0.17 (this zig is ${version}). https://ziglang.org/download/" >&2
            exit 1
            ;;
    esac
    zig_version=$version

    env=$(zig env 2>/dev/null || true)
    if [[ -z "$env" ]]; then
        echo "zig env failed." >&2
        exit 1
    fi
    std_dir=""
    cache=""
    while IFS= read -r line; do
        case "$line" in
            *.std_dir\ =\ \"*)
                std_dir=${line#*.std_dir = \"}
                std_dir=${std_dir%\",}
                std_dir=$(unescape_zon "$std_dir")
                ;;
            *.global_cache_dir\ =\ \"*)
                cache=${line#*.global_cache_dir = \"}
                cache=${cache%\",}
                cache=$(unescape_zon "$cache")
                ;;
        esac
    done <<<"$env"
    if [[ -z "$std_dir" || ! -f "$std_dir/std.zig" ]]; then
        echo "Zig's standard library is not beside this compiler (${std_dir:-unknown})." >&2
        exit 1
    fi
    if [[ -z "$cache" ]] || ! mkdir -p -- "$cache" || ! touch "$cache/eggy-get-started-probe"; then
        echo "Zig's cache is not writable (${cache:-unknown})." >&2
        exit 1
    fi
    rm -f -- "$cache/eggy-get-started-probe"
}

add_zvm_path() {
    export ZVM_INSTALL="${ZVM_INSTALL:-$HOME/.zvm/self}"
    export PATH="$HOME/.zvm/bin:$ZVM_INSTALL:$PATH"
    hash -r
}

# zvm's own binary, from PATH or the directory its installer uses.
zvm_bin() {
    if command -v zvm >/dev/null 2>&1; then
        command -v zvm
        return 0
    fi
    local candidate
    for candidate in "$HOME/.zvm/self/zvm" "$HOME/.zvm/self/zvm.exe"; do
        if [[ -x "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

install_zvm_if_needed() {
    add_zvm_path
    if zvm_bin >/dev/null; then
        return 0
    fi
    echo "Installing zvm from https://www.zvm.app." >/dev/tty
    # The installer also adds ~/.zvm to the shell startup file.
    curl -fsSL https://www.zvm.app/install.sh | bash
    add_zvm_path
    if ! zvm_bin >/dev/null; then
        echo "zvm was installed but is not at ~/.zvm/self." >&2
        exit 1
    fi
}

# Ask before changing the machine. Yes installs zvm when it is missing, then Zig 0.17.
ensure_zig() {
    local version reply zvm
    version=$(zig version 2>/dev/null || true)
    version=${version//$'\r'/}
    version=${version//$'\n'/}
    case "$version" in
        0.17.*)
            zig_version=$version
            return 0
            ;;
    esac
    if [[ -n "$version" ]]; then
        echo "This zig is ${version}. Eggy needs Zig 0.17." >/dev/tty
    else
        echo "Zig is not installed. Eggy needs Zig 0.17." >/dev/tty
    fi
    reply=$(ask "Install Zig ${ZIG_RELEASE} with zvm? This installs zvm if needed and switches your active Zig" "Y")
    case "${reply,,}" in
        y | yes) ;;
        *)
            echo "Zig ${ZIG_RELEASE}: https://ziglang.org/download/" >/dev/tty
            exit 1
            ;;
    esac
    install_zvm_if_needed
    zvm=$(zvm_bin)
    echo "Installing Zig ${ZIG_RELEASE}." >/dev/tty
    "$zvm" install "$ZIG_RELEASE"
    "$zvm" use "$ZIG_RELEASE"
    add_zvm_path
    version=$(zig version 2>/dev/null || true)
    version=${version//$'\r'/}
    version=${version//$'\n'/}
    case "$version" in
        0.17.*) zig_version=$version ;;
        *)
            echo "Zig 0.17 is still not on PATH. Open a new terminal so ~/.zvm/bin is picked up." >&2
            exit 1
            ;;
    esac
}


ask() {
    local prompt=$1
    local default=${2:-}
    local reply
    if [[ -n "$default" ]]; then
        read -r -p "$prompt [$default]: " reply </dev/tty
        printf '%s' "${reply:-$default}"
    else
        while true; do
            read -r -p "$prompt: " reply </dev/tty
            if [[ -n "$reply" ]]; then
                printf '%s' "$reply"
                return
            fi
            echo "Please enter a value." >/dev/tty
        done
    fi
}

# Eggy's logo, darker toward the shell's shadow.
print_egg() {
    cat >/dev/tty <<'EOF'

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

EOF
}

# The release asset built for this computer, as the nightly workflow names it.
platform_name() {
    local os arch
    os=$(uname -s)
    arch=$(uname -m)
    case "$os/$arch" in
        Linux/x86_64 | Linux/amd64) echo linux-x86_64 ;;
        Darwin/arm64 | Darwin/aarch64) echo macos-aarch64 ;;
        *)
            echo "Eggy has no launcher build for $os on $arch yet. Build it from source: https://github.com/${EGGY_REPO}" >&2
            return 1
            ;;
    esac
}

# Where a channel's asset downloads from. `latest` skips prereleases, so it never serves the nightly;
# nightlies are tagged by day (`nightly-<yyyy-mm-dd>`), and GitHub lists the newest first.
asset_url() {
    local channel=$1 platform=$2 tag
    case "$channel" in
        release) echo "https://github.com/${EGGY_REPO}/releases/latest/download/eggy-${platform}.tar.gz" ;;
        nightly)
            local releases
            releases=$(curl -fsSL "https://api.github.com/repos/${EGGY_REPO}/releases?per_page=30") || return 1
            tag=$(grep -o -m1 '"tag_name": *"nightly-[0-9-]*"' <<<"$releases" | grep -o 'nightly-[0-9-]*') || return 1
            echo "https://github.com/${EGGY_REPO}/releases/download/${tag}/eggy-${platform}.tar.gz"
            ;;
    esac
}

# Download `channel`'s launcher into `archive`; a failure returns, so the caller can offer another channel.
download() {
    local channel=$1 platform=$2 archive=$3
    local url
    echo "Downloading the ${channel} launcher." >/dev/tty
    url=$(asset_url "$channel" "$platform") || return 1
    curl -fL --progress-bar "$url" -o "$archive" 2>/dev/tty
}

# Unpack `archive` beside `dest` and swap it in, so a failed download or unpack leaves the old
# launcher working. `run` is empty, or `sudo` for a system-wide install.
install_launcher() {
    local archive=$1 dest=$2 run=$3
    local fresh="${dest}.new" old="${dest}.old"
    $run rm -rf -- "$fresh" "$old"
    $run mkdir -p -- "$fresh"
    $run tar -xzf "$archive" -C "$fresh" --no-same-owner
    if [[ ! -x "$fresh/bin/eggy_editor" ]]; then
        $run rm -rf -- "$fresh"
        echo "The download has no bin/eggy_editor." >&2
        return 1
    fi
    if [[ -e "$dest" ]]; then
        $run mv -- "$dest" "$old"
    fi
    $run mv -- "$fresh" "$dest"
    $run rm -rf -- "$old"
}

# A menu entry for desktops that read freedesktop.org entries (Linux).
write_desktop_entry() {
    local file=$1 exe=$2 run=$3
    [[ "$(uname -s)" == Linux ]] || return 0
    $run mkdir -p -- "$(dirname "$file")"
    printf '[Desktop Entry]\nType=Application\nName=Eggy\nComment=Make games with Eggy\nExec=%s\nTerminal=false\nCategories=Development;Game;\n' "$exe" | $run tee "$file" >/dev/null
}

main() {
    local platform reply channel scope dest bin_dir desktop run archive exe
    stage=""
    trap '[[ -n "${stage}" ]] && rm -rf -- "$stage"' EXIT

    require_tools
    platform=$(platform_name)
    ensure_zig
    check_zig

    print_egg
    echo "Install Eggy. Zig ${zig_version}." >/dev/tty

    while true; do
        channel=$(ask "Which build: release or nightly" "release")
        case "${channel,,}" in
            release | r) channel=release; break ;;
            nightly | n) channel=nightly; break ;;
        esac
        echo "Type release or nightly." >/dev/tty
    done
    while true; do
        scope=$(ask "Install for: me or everyone (admin)" "me")
        case "${scope,,}" in
            me | m | user) scope=user; break ;;
            everyone | e | admin | all) scope=system; break ;;
        esac
        echo "Type me or everyone." >/dev/tty
    done

    if [[ "$scope" == user ]]; then
        dest="${XDG_DATA_HOME:-$HOME/.local/share}/eggy/launcher"
        bin_dir="$HOME/.local/bin"
        desktop="${XDG_DATA_HOME:-$HOME/.local/share}/applications/eggy.desktop"
        run=""
    else
        dest="/opt/eggy"
        bin_dir="/usr/local/bin"
        desktop="/usr/share/applications/eggy.desktop"
        run=""
        if [[ $(id -u) -ne 0 ]]; then
            if ! command -v sudo >/dev/null 2>&1; then
                echo "Installing for everyone needs root or sudo." >&2
                exit 1
            fi
            run="sudo"
        fi
    fi

    stage=$(mktemp -d)
    archive="$stage/eggy-${platform}.tar.gz"
    if ! download "$channel" "$platform" "$archive"; then
        if [[ "$channel" == nightly ]]; then
            echo "Could not download the nightly from https://github.com/${EGGY_REPO}/releases." >&2
            exit 1
        fi
        reply=$(ask "There is no release for ${platform} yet. Install the nightly instead?" "Y")
        case "${reply,,}" in
            y | yes) ;;
            *) exit 1 ;;
        esac
        channel=nightly
        download "$channel" "$platform" "$archive"
    fi

    install_launcher "$archive" "$dest" "$run"
    exe="$dest/bin/eggy_editor"
    $run mkdir -p -- "$bin_dir"
    $run ln -sfn -- "$exe" "$bin_dir/eggy"
    write_desktop_entry "$desktop" "$exe" "$run"

    printf '\nInstalled the %s launcher in %s\n' "$channel" "$dest" >/dev/tty
    case ":$PATH:" in
        *":$bin_dir:"*) echo "Open it any time with: eggy" >/dev/tty ;;
        *) echo "Add $bin_dir to PATH to open it with: eggy" >/dev/tty ;;
    esac

    reply=$(ask "Open Eggy now?" "Y")
    case "${reply,,}" in
        y | yes) ;;
        *) return ;;
    esac
    # Detached, so closing this terminal leaves Eggy open.
    nohup "$exe" </dev/null >/dev/null 2>&1 &
    disown
}

if [[ "${EGGY_GET_STARTED_TEST:-}" == 1 ]]; then
    return 0 2>/dev/null || exit 0
fi
main
