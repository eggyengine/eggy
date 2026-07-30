#!/usr/bin/env python3
"""
Compile annotated Slang shader entry points to HLSL, DXIL, or SPIR-V.

Examples:
    python compile_shader.py -hlsl triangle.slang
    python compile_shader.py -dxil triangle.slang
    python compile_shader.py -spirv triangle.slang
    python compile_shader.py -spirv --out-dir build/shaders triangle.slang
    python compile_shader.py -spirv --slangc C:/SDK/slang/bin/slangc.exe triangle.slang
    python compile_shader.py -spirv triangle.slang -- -O3

Expected entry-point syntax:
    [shader("vertex")]
    VertexOutput vsMain(...)

    [shader("fragment")]
    float4 psMain(...) : SV_Target0
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


@dataclass(frozen=True)
class EntryPoint:
    name: str
    stage: str


def executable_name() -> str:
    return "slangc.exe" if os.name == "nt" else "slangc"


def is_executable(path: Path) -> bool:
    if not path.is_file():
        return False
    # Windows executable permission bits are not consistently meaningful.
    return os.name == "nt" or os.access(path, os.X_OK)


def candidate_project_roots() -> Iterable[Path]:
    """Yield the working directory, script directory, and a few ancestors."""
    seen: set[Path] = set()

    for initial in (Path.cwd(), Path(__file__).resolve().parent):
        current = initial.resolve()
        for _ in range(5):
            if current not in seen:
                seen.add(current)
                yield current
            if current.parent == current:
                break
            current = current.parent


def find_slangc(explicit_path: str | None) -> Path:
    """
    Locate slangc using:
      1. --slangc
      2. SLANGC / SLANGC_PATH environment variables
      3. PATH
      4. common project-local and system locations
    """
    exe = executable_name()
    checked: list[Path] = []

    direct_values = [
        explicit_path,
        os.environ.get("SLANGC"),
        os.environ.get("SLANGC_PATH"),
    ]

    for value in direct_values:
        if not value:
            continue

        candidate = Path(value).expanduser()
        if candidate.is_dir():
            candidate /= exe

        candidate = candidate.resolve()
        checked.append(candidate)

        if is_executable(candidate):
            return candidate

        resolved_from_path = shutil.which(value)
        if resolved_from_path:
            return Path(resolved_from_path).resolve()

    from_path = shutil.which("slangc")
    if from_path:
        return Path(from_path).resolve()

    relative_locations = (
        Path(exe),
        Path("bin") / exe,
        Path("slang") / "bin" / exe,
        Path("tools") / "slang" / "bin" / exe,
        Path("third_party") / "slang" / "bin" / exe,
        Path("third-party") / "slang" / "bin" / exe,
        Path("vendor") / "slang" / "bin" / exe,
        Path("deps") / "slang" / "bin" / exe,
        Path("external") / "slang" / "bin" / exe,
    )

    for root in candidate_project_roots():
        for relative in relative_locations:
            candidate = (root / relative).resolve()
            checked.append(candidate)
            if is_executable(candidate):
                return candidate

    home = Path.home()
    system_candidates: list[Path] = [
        home / ".local" / "bin" / exe,
        Path("/usr/local/bin") / exe,
        Path("/usr/bin") / exe,
        Path("/opt/homebrew/bin") / exe,
    ]

    if os.name == "nt":
        local_app_data = os.environ.get("LOCALAPPDATA")
        program_files = os.environ.get("ProgramFiles")
        user_profile = os.environ.get("USERPROFILE")

        if local_app_data:
            system_candidates.extend(
                [
                    Path(local_app_data) / "slang" / "bin" / exe,
                    Path(local_app_data) / "Programs" / "Slang" / "bin" / exe,
                ]
            )
        if program_files:
            system_candidates.append(Path(program_files) / "Slang" / "bin" / exe)
        if user_profile:
            system_candidates.extend(
                [
                    Path(user_profile) / "scoop" / "shims" / exe,
                    Path(user_profile) / "slang" / "bin" / exe,
                ]
            )

    for candidate in system_candidates:
        candidate = candidate.expanduser().resolve()
        checked.append(candidate)
        if is_executable(candidate):
            return candidate

    searched = "\n".join(f"  - {path}" for path in checked[:30])
    raise FileNotFoundError(
        "Could not locate slangc.\n"
        "Install Slang and add slangc to PATH, set SLANGC_PATH, "
        "or pass --slangc <path>.\n"
        f"Checked locations included:\n{searched}"
    )


def strip_comments(source: str) -> str:
    """Remove comments so commented-out shader attributes are ignored."""
    return re.sub(
        r"//[^\n]*|/\*.*?\*/",
        "",
        source,
        flags=re.MULTILINE | re.DOTALL,
    )


def skip_attribute_block(text: str, start: int) -> int:
    """Skip one balanced [...] attribute block."""
    if start >= len(text) or text[start] != "[":
        return start

    depth = 0
    in_string = False
    escaped = False

    for index in range(start, len(text)):
        char = text[index]

        if in_string:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
            continue

        if char == '"':
            in_string = True
        elif char == "[":
            depth += 1
        elif char == "]":
            depth -= 1
            if depth == 0:
                return index + 1

    raise ValueError("Unterminated shader attribute block.")


def discover_entry_points(shader_path: Path) -> list[EntryPoint]:
    source = strip_comments(shader_path.read_text(encoding="utf-8"))

    shader_attribute = re.compile(
        r'\[\s*shader\s*\(\s*"(?P<stage>[A-Za-z0-9_-]+)"\s*\)\s*\]',
        flags=re.IGNORECASE,
    )

    entries: list[EntryPoint] = []

    for match in shader_attribute.finditer(source):
        cursor = match.end()

        # Skip whitespace and any additional attributes, such as [numthreads(...)].
        while True:
            whitespace = re.match(r"\s*", source[cursor:])
            assert whitespace is not None
            cursor += whitespace.end()

            if cursor < len(source) and source[cursor] == "[":
                cursor = skip_attribute_block(source, cursor)
                continue
            break

        open_paren = source.find("(", cursor)
        if open_paren == -1:
            raise ValueError(
                f'Could not find the function after [shader("{match.group("stage")}")]'
            )

        declaration_prefix = source[cursor:open_paren]
        identifiers = re.findall(r"[A-Za-z_][A-Za-z0-9_]*", declaration_prefix)
        if not identifiers:
            raise ValueError(
                f'Could not determine the function name after '
                f'[shader("{match.group("stage")}")]'
            )

        entries.append(
            EntryPoint(
                name=identifiers[-1],
                stage=match.group("stage").lower(),
            )
        )

    # Preserve source order while removing accidental duplicates.
    unique: list[EntryPoint] = []
    seen: set[tuple[str, str]] = set()
    for entry in entries:
        key = (entry.name, entry.stage)
        if key not in seen:
            seen.add(key)
            unique.append(entry)

    if not unique:
        raise ValueError(
            f"No annotated entry points found in {shader_path}.\n"
            'Add attributes such as [shader("vertex")] or [shader("fragment")].'
        )

    return unique


def output_extension(target: str) -> str:
    return {"hlsl": ".hlsl", "dxil": ".dxil", "spirv": ".spv"}[target]


def compile_entry_point(
    slangc: Path,
    shader_path: Path,
    entry: EntryPoint,
    target: str,
    profile: str,
    output_path: Path,
    extra_args: list[str],
) -> None:
    command = [
        str(slangc),
        str(shader_path),
        "-entry",
        entry.name,
        "-target",
        target,
        "-profile",
        profile,
    ]

    # Slang otherwise commonly emits "main" as the SPIR-V entry-point name.
    if target == "spirv":
        command.append("-fvk-use-entrypoint-name")

    command.extend(["-o", str(output_path)])
    command.extend(extra_args)

    print(f"[{entry.stage}] {entry.name} -> {output_path}")
    subprocess.run(command, check=True)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Compile annotated Slang shader entry points."
    )
    parser.add_argument("shader", type=Path, help="Input .slang shader file")

    target_group = parser.add_mutually_exclusive_group(required=True)
    target_group.add_argument(
        "-hlsl",
        action="store_const",
        const="hlsl",
        dest="target",
        help="Generate HLSL source files",
    )
    target_group.add_argument(
        "-dxil",
        action="store_const",
        const="dxil",
        dest="target",
        help="Generate DirectX 12 DXIL binaries",
    )
    target_group.add_argument(
        "-spirv",
        action="store_const",
        const="spirv",
        dest="target",
        help="Generate Vulkan SPIR-V binaries",
    )

    parser.add_argument(
        "--slangc",
        help="Explicit path to slangc or its containing directory",
    )
    parser.add_argument(
        "--out-dir",
        type=Path,
        help="Output directory (default: <shader directory>/compiled)",
    )
    parser.add_argument(
        "--profile",
        help="Override the default profile (HLSL/DXIL: sm_6_6, SPIR-V: glsl_450)",
    )
    parser.add_argument(
        "extra",
        nargs=argparse.REMAINDER,
        help="Extra slangc arguments after --, for example: -- -O3",
    )

    return parser.parse_args()


def main() -> int:
    args = parse_args()

    shader_path = args.shader.expanduser().resolve()
    if not shader_path.is_file():
        print(f"error: shader file does not exist: {shader_path}", file=sys.stderr)
        return 2

    target: str = args.target
    profile = args.profile or ("glsl_450" if target == "spirv" else "sm_6_6")
    output_dir = (
        args.out_dir.expanduser().resolve()
        if args.out_dir
        else shader_path.parent / "compiled"
    )
    output_dir.mkdir(parents=True, exist_ok=True)

    extra_args: list[str] = args.extra
    if extra_args and extra_args[0] == "--":
        extra_args = extra_args[1:]

    try:
        slangc = find_slangc(args.slangc)
        entries = discover_entry_points(shader_path)

        print(f"Using compiler: {slangc}")
        print(f"Target: {target}, profile: {profile}")

        version_text = subprocess.check_output(
            [str(slangc), "-version"], text=True, stderr=subprocess.STDOUT
        )
        version_match = re.search(r"(\d{4})\.(\d+)", version_text)
        fix_hlsl_semantics = target == "hlsl" and version_match is not None and (
            int(version_match.group(1)), int(version_match.group(2))
        ) < (2026, 4)

        extension = output_extension(target)
        for entry in entries:
            output_path = output_dir / (
                f"{shader_path.stem}.{entry.name}{extension}"
            )
            compile_entry_point(
                slangc=slangc,
                shader_path=shader_path,
                entry=entry,
                target=target,
                profile=profile,
                output_path=output_path,
                extra_args=extra_args,
            )
            if fix_hlsl_semantics:
                source = output_path.read_text(encoding="utf-8")
                output_path.write_text(
                    re.sub(r"(\s:\s*[A-Za-z_][A-Za-z_0-9]*?\d+)0\b", r"\1", source),
                    encoding="utf-8",
                )

    except FileNotFoundError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    except ValueError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    except subprocess.CalledProcessError as error:
        print(
            f"error: slangc failed with exit code {error.returncode}",
            file=sys.stderr,
        )
        return error.returncode or 1
    except OSError as error:
        print(f"error: failed to run slangc: {error}", file=sys.stderr)
        return 2

    print(f"Compiled {len(entries)} entry point(s) successfully.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
