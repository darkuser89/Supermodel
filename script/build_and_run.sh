#!/usr/bin/env bash
# Build and run the native macOS renderer; keep generated data outside the repo.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_root="${METAL4_BUILD_ROOT:-$HOME/Documents/Supermodel-metal-build}"
mode="run"
case "${1:-}" in
  --debug|--logs|--telemetry|--verify) mode="$1"; shift ;;
esac
case "$build_root" in
  /*) ;;
  *) echo "METAL4_BUILD_ROOT must be absolute" >&2; exit 2 ;;
esac
case "$build_root/" in
  "$repo_root/"*) echo "Build directory must be outside the repository" >&2; exit 2 ;;
esac
mkdir -p "$build_root"
if pgrep -x supermodel >/dev/null 2>&1; then
  pkill -TERM -x supermodel
  for ((attempt=0; attempt<50; ++attempt)); do
    if ! pgrep -x supermodel >/dev/null 2>&1; then break; fi
    sleep 0.1
  done
  if pgrep -x supermodel >/dev/null 2>&1; then
    echo "Existing Supermodel did not exit; refusing a second instance" >&2
    exit 1
  fi
fi
cd "$repo_root"
make -f Makefiles/Makefile.OSX "METAL4_BUILD_ROOT=$build_root" -j8 emulator check-native > "$build_root/build.log" 2>&1
runtime_root="$build_root/Runtime"
mkdir -p "$runtime_root/Config" "$runtime_root/NVRAM" "$runtime_root/Saves" "$runtime_root/ROMs"
for resource in Games.xml Music.xml; do
  if [[ ! -e "$runtime_root/Config/$resource" ]]; then
    ln -s "$repo_root/Config/$resource" "$runtime_root/Config/$resource"
  fi
done
if [[ ! -e "$runtime_root/Assets" ]]; then ln -s "$repo_root/Assets" "$runtime_root/Assets"; fi
# Give the SDL/Cocoa process bundle metadata and a discoverable Dock identity.
# The executable is a hard link to the current build, not a second binary copy.
app_root="$build_root/Supermodel.app"
mkdir -p "$app_root/Contents/MacOS"
ln -f "$build_root/supermodel" "$app_root/Contents/MacOS/supermodel"
for resource in Frameworks Supermodel.metallib; do
  if [[ ! -e "$app_root/Contents/MacOS/$resource" ]]; then
    ln -s "$build_root/$resource" "$app_root/Contents/MacOS/$resource"
  fi
done
cat > "$app_root/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>supermodel</string>
<key>CFBundleIdentifier</key><string>org.supermodel.metal4</string>
<key>CFBundleName</key><string>Supermodel</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>NSHighResolutionCapable</key><true/>
<!-- This emulator restores its own configuration, NVRAM and save states.
     AppKit's synchronous state archiver stalls the SDL event pump.
     NSDisablePersistence is an undocumented bundle opt-out; the public
     per-window opt-out alone still archives application-level state. -->
<key>NSDisablePersistence</key><true/>
</dict></plist>
PLIST
executable="$app_root/Contents/MacOS/supermodel"
cd "$runtime_root"
case "$mode" in
  --debug) exec lldb -- "$executable" "$@" ;;
  --logs|--telemetry) exec "$executable" "$@" ;;
  --verify)
    "$executable" "$@" &
    app_pid=$!
    sleep 2
    kill -0 "$app_pid"
    echo "Supermodel started: PID $app_pid"
    wait "$app_pid"
    ;;
  *) exec "$executable" "$@" ;;
esac
