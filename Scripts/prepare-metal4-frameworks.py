#!/usr/bin/env python3
"""Prepare pinned SDL frameworks in the external native build tree only."""
import hashlib
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import urllib.request

DEPENDENCIES = (
    ("SDL2", "https://github.com/libsdl-org/SDL/releases/download/release-2.32.10/SDL2-2.32.10.dmg",
     "4a7ac31640d70214e848f994be8a12849c0f97918a7e6c2e27a40036166d1a7f"),
    ("SDL2_net", "https://github.com/libsdl-org/SDL_net/releases/download/release-2.4.0/SDL2_net-2.4.0.dmg",
     "e995b2ab5a03f96d1c38c4f9b83bb11889d592984436bd3229358b7ce3b08053"),
)


def main():
    root = Path(sys.argv[1]).expanduser().resolve()
    repository = Path(__file__).resolve().parents[1]
    if root == Path("/") or root == repository or repository in root.parents or any("audit" in p.lower() for p in root.parts):
        raise SystemExit("SDL dependencies require a dedicated external build directory")
    frameworks = root / "Frameworks"
    frameworks.mkdir(parents=True, exist_ok=True)
    for name, url, digest in DEPENDENCIES:
        destination = frameworks / (name + ".framework")
        if (destination / "Headers").is_dir() and (destination / name).is_file():
            continue
        with tempfile.TemporaryDirectory(prefix=".sdl-prepare-", dir=root) as temporary:
            work = Path(temporary)
            disk_image = work / "framework.dmg"
            request = urllib.request.Request(url, headers={"User-Agent": "Supermodel-Metal4-build"})
            with urllib.request.urlopen(request) as response, disk_image.open("wb") as output:
                shutil.copyfileobj(response, output)
            if hashlib.sha256(disk_image.read_bytes()).hexdigest() != digest:
                raise SystemExit(f"SHA-256 mismatch for {name}")
            mount = work / "mount"
            mount.mkdir()
            subprocess.run(["hdiutil", "attach", "-nobrowse", "-readonly", "-quiet", "-mountpoint", str(mount), str(disk_image)], check=True)
            try:
                source = mount / (name + ".framework")
                if not source.is_dir():
                    raise SystemExit(f"Framework missing from {name} disk image")
                if destination.exists():
                    raise SystemExit(f"Refusing to overwrite incomplete external framework: {destination}")
                shutil.copytree(source, destination, symlinks=True)
            finally:
                subprocess.run(["hdiutil", "detach", "-quiet", str(mount)], check=True)
        print(f"Prepared {name} (official asset SHA-256 verified)")


if __name__ == "__main__":
    main()
