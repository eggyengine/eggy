"""Build the pinned SDL Android patch in Zig's output directory, never in a global scratch dir."""
import os
from pathlib import Path
import shutil
import subprocess
import sys

source, output, patch, zig, target, optimize, libc = sys.argv[1:]
output = Path(output).resolve()
work = output / "source"
shutil.rmtree(work, ignore_errors=True)
shutil.copytree(source, work)
for root, dirs, files in os.walk(work):
    Path(root).chmod(0o755)
    for name in files:
        path = Path(root) / name
        if not path.is_symlink():
            path.chmod(path.stat().st_mode | 0o200)
with open(patch, "rb") as diff:
    subprocess.run(["patch", "-p1"], cwd=work, stdin=diff, check=True)
libc = Path(libc).resolve()
crt = next(line.removeprefix("crt_dir=") for line in libc.read_text().splitlines() if line.startswith("crt_dir="))
(work / ".ndk").mkdir()
(work / ".ndk/lib").symlink_to(crt, target_is_directory=True)
subprocess.run([zig, "build", f"-Dtarget={target}", f"-Doptimize={optimize}",
                "-Dpreferred_linkage=dynamic", "--prefix", str(output),
                "--libc", str(libc), "--search-prefix", ".ndk"], cwd=work, check=True)
