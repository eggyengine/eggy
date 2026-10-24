#!/usr/bin/env bash
# Create a project from Eggy's template.
#
#   curl -fsSL https://raw.githubusercontent.com/eggyengine/eggy/main/scripts/get-started.sh | bash
#
# On Windows, from PowerShell:
#
#   irm https://raw.githubusercontent.com/eggyengine/eggy/main/scripts/get-started.ps1 | iex
#
# Prompts are read from the terminal, so this still works when the script arrives on stdin.
# EGGY_SOURCE overrides where the template is downloaded from (a raw checkout URL).
# EGGY_GIT overrides the Eggy package `zig fetch` saves.
# EGGY_GET_STARTED_TEST=1 loads the functions and returns, for the script's own check.
if [ -z "${BASH_VERSION:-}" ]; then
    echo "get-started needs bash." >&2
    exit 1
fi
set -euo pipefail

SOURCE="${EGGY_SOURCE:-https://raw.githubusercontent.com/eggyengine/eggy/main}"
EGGY_GIT="${EGGY_GIT:-git+https://github.com/eggyengine/eggy}"
ZIG_RELEASE="0.17.0"
TEMPLATE_FINGERPRINT="0x76cd980c5eed1e55"
files=(
    .gitignore
    build.zig
    build.zig.zon
    controls.zon
    eggy.zon
    src/main.zig
    src/root.zig
)

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
    for tool in curl mkdir cat rm mktemp dirname basename tr touch; do
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

# Every template file, before the directory is created. One missing file is a failure.
fetch_template() {
    local file dest missing=()
    stage=$(mktemp -d)
    for file in "${files[@]}"; do
        mkdir -p -- "$stage/$(dirname "$file")"
        if ! curl -fsSL "${SOURCE}/resources/template/${file}" -o "$stage/$file" || [[ ! -s "$stage/$file" ]]; then
            missing+=("${SOURCE}/resources/template/${file}")
        fi
    done
    if [[ ${#missing[@]} -eq 0 ]]; then
        return 0
    fi
    echo "Could not download the template:" >&2
    printf '  %s\n' "${missing[@]}" >&2
    exit 1
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

is_keyword() {
    case "$1" in
        addrspace | align | allowzero | and | anyframe | anytype | asm | break | callconv | catch | comptime | const | continue | defer | else | enum | errdefer | error | export | extern | fn | for | if | inline | noalias | noinline | nosuspend | opaque | or | orelse | packed | pub | resume | return | linksection | struct | suspend | switch | test | threadlocal | try | union | unreachable | var | volatile | while)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# A Zig package name: a plain identifier, at most 32 bytes, not `_` and not a keyword.
valid_name() {
    local name=$1
    [[ "$name" != "_" && ${#name} -ge 1 && ${#name} -le 32 && "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
    is_keyword "$name" && return 1
    return 0
}

# The same derivation the editor uses: lower case, words joined by `_`, `game_` when needed.
derive_name() {
    local title=$1
    local result="" gap=0 char lower i
    for ((i = 0; i < ${#title}; i++)); do
        char=${title:i:1}
        if [[ "$char" =~ [A-Za-z0-9] ]]; then
            lower=$(printf '%s' "$char" | tr '[:upper:]' '[:lower:]')
            if [[ -z "$result" && "$lower" =~ [0-9] ]]; then
                result="game_"
            elif [[ $gap -eq 1 && -n "$result" && ${#result} -lt 32 ]]; then
                result="${result}_"
            fi
            gap=0
            [[ ${#result} -eq 32 ]] && break
            result="${result}${lower}"
        else
            gap=1
        fi
    done
    if [[ -n "$result" ]] && ! valid_name "$result" && [[ $((${#result} + 5)) -le 32 ]]; then
        result="game_${result}"
    fi
    printf '%s' "$result"
}

# Escape `text` so it can sit inside a Zig string literal.
escape_zon() {
    local text=$1
    text=${text//\\/\\\\}
    text=${text//\"/\\\"}
    text=${text//$'\n'/ }
    printf '%s' "$text"
}

# Swap placeholders without dropping a trailing newline (`$(cat)` would).
fill_file() {
    local file=$1 fingerprint=$2 name=$3 title=$4
    local data
    data=$(cat "$file"; printf x)
    data=${data%x}
    data=${data//${TEMPLATE_FINGERPRINT}/"${fingerprint}"}
    data=${data//eggy_template_name/"${name}"}
    data=${data//eggy_template_title/"${title}"}
    printf '%s' "$data" >"$file"
}

fingerprint_for() {
    local name=$1 work
    work=$(mktemp -d)
    cat >"$work/fingerprint.zig" <<'EOF'
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
EOF
    zig run "$work/fingerprint.zig" -- "$name"
    rm -rf -- "$work"
}

resolve_dir() {
    local path=$1 parent base
    if [[ "$path" != /* ]]; then
        path="${start_dir}/${path}"
    fi
    if [[ -d "$path" ]]; then
        (cd "$path" && pwd)
        return
    fi
    parent=$(dirname "$path")
    base=$(basename "$path")
    if [[ ! -d "$parent" ]]; then
        echo "That folder's parent does not exist: $parent" >&2
        return 1
    fi
    printf '%s/%s\n' "$(cd "$parent" && pwd)" "$base"
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

dir_is_empty() {
    local path=$1 entries
    [[ -d "$path" ]] || return 0
    shopt -s nullglob dotglob
    entries=("$path"/*)
    shopt -u nullglob dotglob
    [[ ${#entries[@]} -eq 0 ]]
}

main() {
    local title suggested name reply title_zon fingerprint file
    start_dir=$PWD
    stage=""
    directory=""
    wipe_on_fail=0
    trap '[[ -n "${stage}" ]] && rm -rf -- "$stage"' EXIT
    trap '[[ "$wipe_on_fail" == 1 ]] && rm -rf -- "$directory"' ERR

    require_tools
    ensure_zig
    check_zig
    fetch_template

    print_egg
    echo "Create an Eggy project. Zig ${zig_version}." >/dev/tty

    title=$(ask "Project title")
    suggested=$(derive_name "$title")
    while true; do
        if [[ -n "$suggested" ]]; then
            name=$(ask "Package name" "$suggested")
        else
            name=$(ask "Package name")
        fi
        if valid_name "$name"; then
            break
        fi
        echo "Package names are Zig identifiers of at most 32 characters, not keywords." >/dev/tty
        suggested=""
    done

    directory=$(ask "Directory" "$name")
    directory=$(resolve_dir "$directory")
    if ! dir_is_empty "$directory"; then
        echo "$directory exists and is not empty. Nothing was written." >&2
        exit 1
    fi

    printf 'Title:     %s\nPackage:   %s\nDirectory: %s\n' "$title" "$name" "$directory" >/dev/tty
    reply=$(ask "Create this project?" "Y")
    case "${reply,,}" in
        y | yes) ;;
        *)
            echo "Cancelled." >/dev/tty
            exit 0
            ;;
    esac

    mkdir -p -- "$directory/src"
    wipe_on_fail=1

    for file in "${files[@]}"; do
        mkdir -p -- "$directory/$(dirname "$file")"
        cat "$stage/$file" >"$directory/$file"
    done

    title_zon=$(escape_zon "$title")
    fingerprint=$(fingerprint_for "$name")
    fingerprint=${fingerprint//$'\r'/}
    fingerprint=${fingerprint//$'\n'/}
    for file in "${files[@]}"; do
        fill_file "$directory/$file" "$fingerprint" "$name" "$title_zon"
    done

    # Drop the placeholder path: `zig fetch --save` would overwrite only its string and skip the hash.
    local zon data needle
    zon="$directory/build.zig.zon"
    data=$(cat "$zon"; printf x)
    data=${data%x}
    needle='.eggy = .{ .path = "eggy_template_engine" },'
    if [[ "$data" != *"$needle"* ]]; then
        echo "The template no longer has the engine placeholder this script removes." >&2
        exit 1
    fi
    data=${data//"$needle"/}
    printf '%s' "$data" >"$zon"

    # Required packages only. Optional build tools stay lazy until a build asks for them.
    echo "Fetching Eggy and its required packages." >/dev/tty
    (
        trap - ERR
        cd "$directory"
        zig fetch --save=eggy "$EGGY_GIT"
        zig build --fetch
    )

    wipe_on_fail=0
    trap - ERR

    printf '\nCreated %s\n' "$directory" >/dev/tty
    reply=$(ask "Open the editor now? The project compiles first" "Y")
    case "${reply,,}" in
        y | yes) ;;
        *)
            printf 'Open it later with:\n  cd %s\n  zig build run\n' "$directory" >/dev/tty
            return
            ;;
    esac

    # Read input from the terminal: when piped from curl, stdin is the script.
    echo "Sit back and make yourself a coffee, as it'll take a while to compile." >/dev/tty
    cd "$directory"
    zig build run </dev/tty
}

if [[ "${EGGY_GET_STARTED_TEST:-}" == 1 ]]; then
    return 0 2>/dev/null || exit 0
fi
main
