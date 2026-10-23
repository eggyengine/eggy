"""Install the pinned export SDKs, reusing explicitly configured or cached installations."""

import argparse
import errno
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tarfile
import urllib.request
import urllib.parse
import zipfile

EMSCRIPTEN_VERSION = "4.0.14"
EMSDK_COMMIT = "4.0.14"
EMSDK_SHA256 = "24142f5506a99dab75b18ccecf2e3a23b4e243fa6fac1b6c20b2081bb4fbc8c5"
ANDROID_TOOLS = "13114758"
ANDROID_BUILD_TOOLS = "36.0.0"
JDK_RELEASE = "jdk-17.0.16+8"


def say(message):
    print(f"[Export SDK] {message}", file=sys.stderr, flush=True)


def run(argv, **kwargs):
    say(" ".join(map(str, argv)))
    subprocess.run(list(map(str, argv)), check=True, stdout=sys.stderr, **kwargs)


def download(url, destination, sha256=None):
    """Keep completed downloads; never trust a partial transfer as an archive."""
    destination.parent.mkdir(parents=True, exist_ok=True)
    if not destination.exists():
        say(f"Downloading {url}")
        partial = destination.with_suffix(destination.suffix + ".partial")
        try:
            with urllib.request.urlopen(url, timeout=120) as response, partial.open("wb") as output:
                total = int(response.headers.get("Content-Length", 0))
                size = 0
                reported = -1
                while chunk := response.read(1024 * 1024):
                    output.write(chunk)
                    size += len(chunk)
                    progress = size // (16 * 1024 * 1024)
                    if progress != reported:
                        say(f"Downloaded {size // (1024 * 1024)} MiB" +
                            (f" of {total // (1024 * 1024)} MiB" if total else ""))
                        reported = progress
            if total and size != total:
                raise RuntimeError(f"Incomplete download of {url}; retry the export")
            partial.replace(destination)
        finally:
            partial.unlink(missing_ok=True)
    if sha256:
        with destination.open("rb") as source:
            digest = hashlib.file_digest(source, "sha256").hexdigest()
        if digest != sha256:
            destination.unlink()
            raise RuntimeError(f"SHA-256 mismatch for {url}; download removed")
    return destination


def unpack(archive, destination):
    """Only extract trusted SDK archives, rejecting paths outside the staging directory."""
    shutil.rmtree(destination, ignore_errors=True)
    destination.mkdir(parents=True)
    if zipfile.is_zipfile(archive):
        with zipfile.ZipFile(archive) as source:
            for info in source.infolist():
                if not (destination / info.filename).resolve().is_relative_to(destination.resolve()):
                    raise RuntimeError("Archive contains an unsafe path")
            source.extractall(destination)
            for info in source.infolist():
                mode = info.external_attr >> 16
                if mode & 0o111:
                    (destination / info.filename).chmod(mode & 0o777)
    else:
        with tarfile.open(archive) as source:
            source.extractall(destination, filter="data")


def default_cache():
    if os.name == "nt":
        return Path(os.environ.get("LOCALAPPDATA", Path.home() / "AppData/Local")) / "Eggy/SDKs"
    if sys.platform == "darwin":
        return Path.home() / "Library/Caches/Eggy/SDKs"
    return Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "eggy/sdks"


def web(cache, explicit):
    configured = explicit or os.environ.get("EMSDK")
    root = Path(configured).expanduser().resolve() if configured else (
        Path.home() / "emsdk" if (Path.home() / "emsdk/upstream/emscripten").is_dir()
        else cache / f"emsdk-{EMSCRIPTEN_VERSION}"
    )
    emcc = root / "upstream/emscripten" / ("emcc.bat" if os.name == "nt" else "emcc")
    if not emcc.exists():
        if configured:
            raise RuntimeError(f"Configured emsdk has no emcc: {root}; fix EMSDK/-Demsdk or unset it")
        archive = download(
            f"https://github.com/emscripten-core/emsdk/archive/refs/tags/{EMSDK_COMMIT}.tar.gz",
            cache / f"emsdk-{EMSDK_COMMIT}.tar.gz",
            EMSDK_SHA256,
        )
        stage = cache / f"emsdk-{EMSCRIPTEN_VERSION}.extract"
        unpack(archive, stage)
        root.mkdir(parents=True, exist_ok=True)
        for item in next(stage.iterdir()).iterdir():
            target = root / item.name
            if not target.exists():
                shutil.move(str(item), target)
        shutil.rmtree(stage)
        emsdk = root / ("emsdk.bat" if os.name == "nt" else "emsdk")
        run([emsdk, "install", EMSCRIPTEN_VERSION])
        run([emsdk, "activate", EMSCRIPTEN_VERSION])
    elif not configured and not (root / ".emscripten").exists():
        # A cancelled activation must not leave an otherwise installed cached SDK unusable.
        run([root / ("emsdk.bat" if os.name == "nt" else "emsdk"), "activate", EMSCRIPTEN_VERSION])
    env = dict(os.environ, EMSDK=str(root), EM_CONFIG=str(root / ".emscripten"))
    # Vitellus translates Dawn's header during build configuration, before em++ runs.
    header = root / "upstream/emscripten/cache/ports/emdawnwebgpu/emdawnwebgpu_pkg/webgpu/include/webgpu/webgpu.h"
    if not header.exists():
        run([root / "upstream/emscripten" / ("embuilder.bat" if os.name == "nt" else "embuilder"),
             "build", "emdawnwebgpu"], env=env)
    if not header.exists():
        raise RuntimeError("Emscripten did not install the emdawnwebgpu headers")
    say(f"Using emsdk: {root}")
    return {"EMSDK": str(root), "EM_CONFIG": str(root / ".emscripten")}


def java_home(cache):
    configured = os.environ.get("JDK_HOME") or os.environ.get("JAVA_HOME")
    if configured:
        home = Path(configured).expanduser().resolve()
        if not (home / "bin" / ("javac.exe" if os.name == "nt" else "javac")).exists():
            raise RuntimeError(f"Configured JDK has no javac: {home}")
        return home
    # Apple's /usr/bin/javac is an installer stub, not the JDK it appears to be.
    if sys.platform == "darwin":
        discovered = subprocess.run(["/usr/libexec/java_home", "-v", "17+"], capture_output=True, text=True)
        if discovered.returncode == 0:
            return Path(discovered.stdout.strip())
        javac = None
    else:
        javac = shutil.which("javac")
    if javac:
        return Path(javac).resolve().parent.parent
    system = {"linux": "linux", "darwin": "mac", "win32": "windows"}.get(sys.platform)
    arch = {"x86_64": "x64", "AMD64": "x64", "arm64": "aarch64", "aarch64": "aarch64"}.get(platform.machine())
    if not system or not arch:
        raise RuntimeError("No automatic JDK distribution for this host; set JAVA_HOME to JDK 17+")
    name = f"OpenJDK17U-jdk_{arch}_{system}_hotspot_17.0.16_8." + ("zip" if os.name == "nt" else "tar.gz")
    url = f"https://github.com/adoptium/temurin17-binaries/releases/download/{urllib.parse.quote(JDK_RELEASE)}/{name}"
    root = cache / f"temurin-{JDK_RELEASE}-{system}-{arch}"
    if not root.exists():
        with urllib.request.urlopen(url + ".sha256.txt", timeout=60) as response:
            checksum = response.read().decode().split()[0]
        archive = download(url, cache / name, checksum)
        stage = Path(str(root) + ".extract")
        unpack(archive, stage)
        next(stage.iterdir()).rename(root)
        shutil.rmtree(stage)
    return root / "Contents/Home" if sys.platform == "darwin" else root


def android(cache, explicit, api=35, ndk="27.1.12297006"):
    """Install the Android platform for API level `api` and NDK `ndk` (the build picks both)."""
    if sys.platform not in ("linux", "darwin"):
        raise RuntimeError("Android export currently needs a Linux or macOS host (SDL's Android build uses sh and patch)")
    if platform.machine() not in ("x86_64", "AMD64", "arm64", "aarch64") or (
        sys.platform == "linux" and platform.machine() not in ("x86_64", "AMD64")
    ):
        raise RuntimeError("Google's Android NDK has no distribution for this host")
    configured = explicit or os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT")
    root = Path(configured).expanduser().resolve() if configured else cache / "android"
    jdk = java_home(cache)
    manager = root / "cmdline-tools/latest/bin/sdkmanager"
    if not manager.exists() and not manager.parent.parent.exists():
        installed = sorted(root.glob("cmdline-tools/*/bin/sdkmanager"))
        if installed:
            manager.parent.parent.symlink_to(installed[-1].parent.parent, target_is_directory=True)
    if not manager.exists() and (root / "tools/bin/sdkmanager").exists():
        manager = root / "tools/bin/sdkmanager"
    if not manager.exists():
        system = "mac" if sys.platform == "darwin" else "linux"
        archive = download(
            f"https://dl.google.com/android/repository/commandlinetools-{system}-{ANDROID_TOOLS}_latest.zip",
            cache / f"android-tools-{system}-{ANDROID_TOOLS}.zip",
            "7ec965280a073311c339e571cd5de778b9975026cfcbe79f2b1cdcb1e15317ee" if system == "linux" else None,
        )
        stage = cache / f"android-tools-{system}.extract"
        unpack(archive, stage)
        manager.parent.parent.parent.mkdir(parents=True, exist_ok=True)
        (stage / "cmdline-tools").rename(manager.parent.parent)
        shutil.rmtree(stage)
    env = dict(os.environ, ANDROID_HOME=str(root), ANDROID_SDK_ROOT=str(root), JAVA_HOME=str(jdk), JDK_HOME=str(jdk))
    required = (
        root / f"platforms/android-{api}/android.jar",
        root / f"build-tools/{ANDROID_BUILD_TOOLS}/apksigner",
        root / f"ndk/{ndk}/source.properties",
    )
    if not all(item.exists() for item in required):
        say("Installing Android SDK packages; exporting accepts Google's Android SDK licenses.")
        # Keep the license texts available without flooding the export progress view.
        license_log = cache / "android-licenses.log"
        say(f"Android license acceptance log: {license_log}")
        with license_log.open("w") as output:
            subprocess.run([str(manager), f"--sdk_root={root}", "--licenses"], env=env,
                           input=b"y\n" * 100, stdout=output, stderr=subprocess.STDOUT, check=True)
        packages = (f"platforms;android-{api}", f"build-tools;{ANDROID_BUILD_TOOLS}", f"ndk;{ndk}")
        run([manager, f"--sdk_root={root}", *packages], env=env, input=b"y\n" * 100)
    if not all(item.exists() for item in required):
        raise RuntimeError("Android SDK installation is incomplete")
    say(f"Using Android SDK: {root}; JDK: {jdk}")
    return {key: env[key] for key in ("ANDROID_HOME", "ANDROID_SDK_ROOT", "JAVA_HOME", "JDK_HOME")}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("platform", choices=("web", "android"))
    parser.add_argument("--root")
    parser.add_argument("--result", required=True)
    parser.add_argument("--android-api", type=int, default=35)
    parser.add_argument("--ndk", default="27.1.12297006")
    args = parser.parse_args()
    cache = default_cache().resolve()
    cache.mkdir(parents=True, exist_ok=True)
    # Share installations across projects without simultaneous mutation of the same SDK.
    lock = cache / f"{args.platform}.lock"
    with lock.open("a+") as handle:
        if os.name != "nt":
            import fcntl
            say(f"Preparing {args.platform} SDK (waiting for another setup, if any)")
            fcntl.flock(handle, fcntl.LOCK_EX)
        else:
            import msvcrt
            import time
            handle.write(" ")
            handle.flush()
            handle.seek(0)
            while True:
                try:
                    msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
                    break
                except OSError as error:
                    if error.errno not in (errno.EACCES, errno.EAGAIN, errno.EDEADLK):
                        raise
                    time.sleep(1)
        result = web(cache, args.root) if args.platform == "web" else android(cache, args.root, args.android_api, args.ndk)
        Path(args.result).write_text(json.dumps(result), encoding="utf-8")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.CalledProcessError, tarfile.TarError, zipfile.BadZipFile) as error:
        say(f"Setup failed: {error}")
        sys.exit(1)
