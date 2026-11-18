#!/usr/bin/env bash
# Build a Linux AppImage of Mistral Vibe Desktop from the official Windows installer.
#
#   ./build.sh /path/to/vibe-X.Y.Z-setup.exe     # -> dist/Vibe-X.Y.Z-x86_64.AppImage
#
# How it works (see README.md for details):
#   * Older releases ship the app's main process as V8 bytecode (.jsc). Windows
#     bytecode only differs from what Linux Electron expects in its references into
#     V8's read-only heap (Node's embedded snapshot orders its strings per build).
#     tools/jscconv.py remaps those references, so the original code runs unchanged.
#   * Native Node modules are rebuilt for Linux, the Python backend (mistral-vibe)
#     is installed into a portable Python, Windows-only helpers are replaced.
#
# Requirements: 7z, node/npm/npx, python3, uv, gcc/g++/make, curl, pkg-config.
# Header packages (libxkbfile, libXi, libXfixes devel) are fetched with
# `dnf download` / `apt-get download` if not installed system-wide.
set -euo pipefail

EXE="$(readlink -f "${1:?usage: $0 vibe-X.Y.Z-setup.exe}")"
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${WORK:-$HERE/work}"
OUT="${OUT:-$HERE/dist}"
# Optional AppImage update information, e.g. "gh-releases-zsync|owner|repo|latest|Vibe-*x86_64.AppImage.zsync"
UPDATE_INFO="${UPDATE_INFO:-}"
TOOLS="$HERE/tools"
mkdir -p "$WORK"
log() { printf '\n==> %s\n' "$*"; }

# ---------------------------------------------------------------- extract
log "Extracting Windows installer"
rm -rf "$WORK/nsis" "$WORK/win" "$WORK/wasar"
mkdir -p "$WORK/nsis" "$WORK/win"
7z x -y -o"$WORK/nsis" "$EXE" '$PLUGINSDIR/app-64.7z' >/dev/null
7z x -y -o"$WORK/win" "$WORK/nsis/\$PLUGINSDIR/app-64.7z" >/dev/null
rm -rf "$WORK/nsis"
# asar extracts the app even when optional native files for other platforms are missing.
npx -y @electron/asar@3.2.17 extract "$WORK/win/resources/app.asar" "$WORK/wasar" >"$WORK/asar.log" 2>&1 || true
MAIN="$WORK/wasar/out/main"
if [ ! -f "$MAIN/index.js" ] || { [ ! -f "$MAIN/desktop-main.js" ] && [ ! -f "$MAIN/desktop-main.jsc" ]; }; then
  sed -n '1,12p' "$WORK/asar.log" >&2
  echo "app.asar extraction failed: main process files are missing" >&2
  exit 1
fi
VERSION="$(python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' "$WORK/wasar/package.json")"
ELECTRON_VERSION="$(grep -aoE 'Electron/[0-9]+\.[0-9]+\.[0-9]+' "$WORK/win/Vibe.exe" | head -1 | cut -d/ -f2)"
echo "Vibe $VERSION, Electron $ELECTRON_VERSION"

# ---------------------------------------------------------------- electron
log "Fetching Electron $ELECTRON_VERSION for linux-x64"
EZIP="$WORK/electron-v$ELECTRON_VERSION-linux-x64.zip"
[ -f "$EZIP" ] || curl -fL -o "$EZIP" "https://github.com/electron/electron/releases/download/v$ELECTRON_VERSION/electron-v$ELECTRON_VERSION-linux-x64.zip"
rm -rf "$WORK/electron" && mkdir -p "$WORK/electron" && (cd "$WORK/electron" && unzip -q "$EZIP")

# ---------------------------------------------------------------- bytecode
mapfile -t JSC < <(find "$MAIN" -type f -name '*.jsc')
if [ "${#JSC[@]}" -gt 0 ]; then
  log "Converting V8 bytecode (Windows -> Linux)"
  python3 -I "$TOOLS/jscconv.py" --src-bin "$WORK/win/Vibe.exe" --dst-bin "$WORK/electron/electron" "${JSC[@]}"
  log "Verifying every bytecode file deserializes"
  cat > "$WORK/verify-jsc.js" <<'EOF'
const v8=require('v8');v8.setFlagsFromString("--no-lazy");v8.setFlagsFromString("--no-flush-bytecode");
const vm=require('vm'),fs=require('fs');
const d=new vm.Script("",{produceCachedData:true}).createCachedData();
const f=fs.readFileSync(process.argv[2]); d.copy(f,12,12,16);
const len=f.readUInt32LE(8);
const s=new vm.Script(len>1?'"'+"​".repeat(len-2)+'"':"",{cachedData:f});
if(s.cachedDataRejected){console.error("REJECTED",process.argv[2]);process.exit(2)}
EOF
  for f in "${JSC[@]}"; do
    ELECTRON_RUN_AS_NODE=1 "$WORK/electron/electron" "$WORK/verify-jsc.js" "$f" || { echo "bytecode check failed: $f"; exit 1; }
  done
  echo "all ${#JSC[@]} bytecode files OK"
fi

# ---------------------------------------------------------------- headers
HDR="$WORK/hdr"
fetch_dev_headers() {
  mkdir -p "$HDR/lib" && cd "$HDR"
  if command -v dnf >/dev/null; then
    dnf download --skip-unavailable --arch x86_64 --arch noarch \
      libxkbfile-devel libXi-devel libXfixes-devel xorg-x11-proto-devel >/dev/null 2>&1
    for r in *.rpm; do rpm2cpio "$r" | cpio -idm 2>/dev/null; done
  elif command -v apt-get >/dev/null; then
    apt-get download libxkbfile-dev libxi-dev libxfixes-dev x11proto-dev >/dev/null
    for r in *.deb; do dpkg-deb -x "$r" .; done
  else
    echo "Install libxkbfile, libXi and libXfixes development headers" >&2; exit 1
  fi
  for l in xkbfile Xi; do
    so="$( (ls /usr/lib64/lib$l.so.* /usr/lib/x86_64-linux-gnu/lib$l.so.* 2>/dev/null || true) | head -1)"
    [ -n "$so" ] || { echo "lib$l runtime library not found" >&2; exit 1; }
    ln -sf "$so" "lib/lib$l.so"
  done
  mkdir -p pc
  cat > pc/xkbfile.pc <<EOF
Name: xkbfile
Description: xkbfile (local headers)
Version: 1.1
Cflags: -I$HDR/usr/include
Libs: -L$HDR/lib -lxkbfile
EOF
  cd - >/dev/null
}
if ! pkg-config --exists xkbfile xi 2>/dev/null; then
  log "Fetching X11 development headers (no root needed)"
  rm -rf "$HDR"; fetch_dev_headers
  export PKG_CONFIG_PATH="$HDR/pc:${PKG_CONFIG_PATH:-}:/usr/lib64/pkgconfig:/usr/share/pkgconfig"
  export CPATH="$HDR/usr/include" LIBRARY_PATH="$HDR/lib"
fi

# ---------------------------------------------------------------- native modules
log "Building native Node modules for Electron $ELECTRON_VERSION"
NAT="$WORK/native"; rm -rf "$NAT"; mkdir -p "$NAT"
ver() { python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' "$WORK/wasar/node_modules/$1/package.json"; }
(cd "$NAT" && echo '{"name":"native","private":true}' > package.json &&
  npm install --ignore-scripts --no-audit --no-fund "node-pty@$(ver node-pty)" "native-keymap@$(ver native-keymap)" "@koromix/koffi-linux-x64@$(ver koffi)" >/dev/null)
for m in node-pty native-keymap; do
  (cd "$NAT/node_modules/$m" && npx -y node-gyp@11.4.2 rebuild --target="$ELECTRON_VERSION" --arch=x64 \
     --dist-url=https://electronjs.org/headers >"$NAT/gyp-$m.log" 2>&1) || { tail -20 "$NAT/gyp-$m.log"; exit 1; }
done
g++ -O2 ${CPATH:+-I$CPATH} ${LIBRARY_PATH:+-L$LIBRARY_PATH} -o "$NAT/key-server" \
  "$WORK/wasar/node_modules/keyspy/native/X11KeyServer/main.cpp" -lX11 -lXi

# ---------------------------------------------------------------- python backend
log "Installing mistral-vibe backend into a portable Python"
VIBE_PY_VERSION="$(ls "$WORK/win/resources/bin/vibe-app-server/_internal" | sed -n 's/^mistral_vibe-\(.*\)\.dist-info$/\1/p')"
uv python install 3.12 >/dev/null
PYROOT="$(dirname "$(dirname "$(readlink -f "$(uv python find 3.12 --managed-python)")")")"
rm -rf "$WORK/python" && cp -a "$PYROOT" "$WORK/python"
rm -f "$WORK/python/lib/python3.12/EXTERNALLY-MANAGED"
# PyPI sometimes lags behind the desktop release. STRICT_BACKEND=1 (e.g. in CI) fails instead
# of falling back to the newest published mistral-vibe.
if ! uv pip install --python "$WORK/python/bin/python3" --break-system-packages --no-cache "mistral-vibe==$VIBE_PY_VERSION" >/dev/null 2>&1; then
  [ "${STRICT_BACKEND:-0}" = 1 ] && { echo "mistral-vibe==$VIBE_PY_VERSION not on PyPI yet" >&2; exit 3; }
  echo "WARNING: mistral-vibe $VIBE_PY_VERSION (bundled in the Windows build) is not on PyPI yet; using the newest published version."
  uv pip install --python "$WORK/python/bin/python3" --break-system-packages --no-cache mistral-vibe >/dev/null
fi
echo "backend: $("$WORK/python/bin/python3" -I -c 'import importlib.metadata as m;print(m.version("mistral-vibe"))')"
echo "bundled_backend: $VIBE_PY_VERSION"
rm -rf "$WORK/python/lib/python3.12/test" "$WORK/python/lib/python3.12/idlelib" "$WORK/python/lib/python3.12/tkinter" \
       "$WORK/python/lib/python3.12/ensurepip" "$WORK/python/include" "$WORK/python/share"
"$WORK/python/bin/python3" -I -c 'from vibe.app_server.stdio import main'

# ---------------------------------------------------------------- helper binaries
log "Fetching ripgrep and agent-browser for Linux"
DL="$WORK/dl"; mkdir -p "$DL"
AB_VERSION="$(grep -aoE 'agent-browser/[0-9]+\.[0-9]+\.[0-9]+' "$WORK/win/resources/bin/agent-browser.exe" | head -1 | cut -d/ -f2)"
(cd "$DL" && rm -rf package && npm pack "agent-browser@$AB_VERSION" --silent >/dev/null &&
  tar xzf "agent-browser-$AB_VERSION.tgz" package/bin/agent-browser-linux-x64 &&
  mv package/bin/agent-browser-linux-x64 agent-browser && chmod +x agent-browser && rm -rf package)
RG_VERSION=15.2.0
(cd "$DL" && curl -fsSL "https://github.com/BurntSushi/ripgrep/releases/download/$RG_VERSION/ripgrep-$RG_VERSION-x86_64-unknown-linux-musl.tar.gz" | tar xz &&
  cp "ripgrep-$RG_VERSION-x86_64-unknown-linux-musl/rg" rg)

# ---------------------------------------------------------------- assemble AppDir
log "Assembling AppDir"
APPDIR="$WORK/Vibe.AppDir"; rm -rf "$APPDIR"; mkdir -p "$APPDIR/usr/lib"
APP="$APPDIR/usr/lib/vibe"
cp -a "$WORK/electron" "$APP"; mv "$APP/electron" "$APP/vibe"
R="$APP/resources"; rm -f "$R/default_app.asar"
cp -a "$WORK/wasar" "$R/app"
# Polyfill macOS/Windows-only Electron APIs before the main process code runs.
cp "$TOOLS/linux-shim.cjs" "$R/app/out/main/"
grep -q 'linux-shim' "$R/app/out/main/index.js" || sed -i '1a require("./linux-shim.cjs");' "$R/app/out/main/index.js"
# Keep actionable alerts clickable on Linux, where mouse-event forwarding is unavailable.
if [ -f "$R/app/out/renderer/alert.html" ]; then
  python3 -I "$TOOLS/fix-alert-click-through.py" "$R/app/out/renderer"
fi
N="$NAT/node_modules"
mkdir -p "$R/app/node_modules/node-pty/build/Release" "$R/app/node_modules/native-keymap/build/Release" "$R/app/node_modules/keyspy/build"
cp "$N/node-pty/build/Release/pty.node" "$R/app/node_modules/node-pty/build/Release/"
cp "$N/native-keymap/build/Release/keymapping.node" "$R/app/node_modules/native-keymap/build/Release/"
rm -rf "$R/app/node_modules/@koromix/koffi-linux-x64" && cp -a "$N/@koromix/koffi-linux-x64" "$R/app/node_modules/@koromix/"
cp "$NAT/key-server" "$R/app/node_modules/keyspy/build/X11KeyServer"
cp -a "$WORK/win/resources/app.asar.unpacked" "$R/"; rm -rf "$R/app.asar.unpacked/node_modules"
mkdir -p "$R/plugins"
cp -a "$WORK/win/resources/plugins/vibe-security" "$WORK/win/resources/plugins/modules" "$R/plugins/"  # computer-use is Windows-only
mkdir -p "$R/bin/vibe-app-server"
cp "$DL/rg" "$DL/agent-browser" "$NAT/key-server" "$R/bin/"
cp -a "$WORK/win/resources/bin/rg-licenses" "$WORK/win/resources/bin/agent-browser-LICENSE" "$R/bin/"
cp -a "$WORK/python" "$R/bin/vibe-app-server/python"
cat > "$R/bin/vibe-app-server/vibe-app-server" <<'EOF'
#!/bin/sh
# Linux port: run the mistral-vibe app server from the bundled Python.
HERE="$(dirname "$(readlink -f "$0")")"
exec "$HERE/python/bin/python3" -I -c 'import sys; from vibe.app_server.stdio import main; sys.argv[0] = "vibe-app-server"; sys.exit(main())' "$@"
EOF
chmod +x "$R/bin/vibe-app-server/vibe-app-server"
for f in app-update.yml RELEASE_NOTES.md; do cp "$WORK/win/resources/$f" "$R/"; done
cp "$WORK/win/resources/"*.png "$WORK/win/resources/"*.ico "$R/"

cp "$WORK/wasar/out/renderer/favicons/pwa-icon-512x512.png" "$APPDIR/vibe.png"
cp "$APPDIR/vibe.png" "$APPDIR/.DirIcon"
cat > "$APPDIR/vibe.desktop" <<EOF
[Desktop Entry]
Name=Vibe
Comment=Mistral Vibe Desktop (unofficial Linux port)
Exec=vibe %U
Icon=vibe
Type=Application
Categories=Development;
MimeType=x-scheme-handler/lechat;
StartupWMClass=le-chat-desktop
X-AppImage-Version=$VERSION
EOF
cat > "$APPDIR/AppRun" <<'EOF'
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"
if [ "$1" = "--install-desktop-entry" ]; then
  # Register a menu entry and the lechat:// handler for this AppImage.
  D="${XDG_DATA_HOME:-$HOME/.local/share}"
  mkdir -p "$D/applications" "$D/icons/hicolor/512x512/apps"
  cp "$HERE/vibe.png" "$D/icons/hicolor/512x512/apps/vibe-linux.png"
  sed -e "s|^Exec=.*|Exec=\"${APPIMAGE:-$HERE/AppRun}\" %U|" -e 's|^Icon=.*|Icon=vibe-linux|' \
    "$HERE/vibe.desktop" > "$D/applications/vibe-linux.desktop"
  command -v update-desktop-database >/dev/null && update-desktop-database "$D/applications" >/dev/null 2>&1
  mkdir -p "${XDG_CONFIG_HOME:-$HOME/.config}"
  command -v xdg-mime >/dev/null && xdg-mime default vibe-linux.desktop x-scheme-handler/lechat 2>/dev/null
  echo "Installed $D/applications/vibe-linux.desktop"
  exit 0
fi
export CHROME_DESKTOP=vibe-linux.desktop
# chrome-sandbox cannot be setuid inside an AppImage mount.
exec "$HERE/usr/lib/vibe/vibe" --no-sandbox --ozone-platform-hint=auto "$@"
EOF
chmod +x "$APPDIR/AppRun"

# ---------------------------------------------------------------- AppImage
log "Packing AppImage"
AIT="$WORK/appimagetool-x86_64.AppImage"
[ -x "$AIT" ] || { curl -fL -o "$AIT" https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage && chmod +x "$AIT"; }
mkdir -p "$OUT"
TARGET="$OUT/Vibe-$VERSION-x86_64.AppImage"
(cd "$OUT" && ARCH=x86_64 "$AIT" --appimage-extract-and-run --no-appstream ${UPDATE_INFO:+-u "$UPDATE_INFO"} "$APPDIR" "$TARGET" >/dev/null 2>&1)
(cd "$OUT" && sha256sum "$(basename "$TARGET")" > "$(basename "$TARGET").sha256")
log "Done: $TARGET"

# ---------------------------------------------------------------- deb / rpm (optional)
if [ "${PACKAGES:-0}" = 1 ]; then
  log "Building .deb, .rpm and Arch package"
  NFPM_VERSION=2.49.0
  NFPM="$WORK/nfpm"
  [ -x "$NFPM" ] || curl -fsSL "https://github.com/goreleaser/nfpm/releases/download/v$NFPM_VERSION/nfpm_${NFPM_VERSION}_Linux_x86_64.tar.gz" | tar xz -C "$WORK" nfpm
  STAGE="$WORK/pkgroot"; rm -rf "$STAGE"
  cp -al "$APP" "$STAGE" 2>/dev/null || cp -a "$APP" "$STAGE"
  rm -f "$STAGE/chrome-sandbox"
  chmod -R go-w "$STAGE"
  # Release 0 = built with a fallback backend, 1 = matching backend; so a later proper build upgrades.
  if [ "$("$WORK/python/bin/python3" -I -c 'import importlib.metadata as m;print(m.version("mistral-vibe"))')" = "$VIBE_PY_VERSION" ]; then
    PKG_RELEASE="${PKG_RELEASE:-1}"
  else
    PKG_RELEASE="${PKG_RELEASE:-0}"
  fi
  export PKG_VERSION="$VERSION" PKG_RELEASE APP_DIR="$STAGE" SANDBOX="$APP/chrome-sandbox" ICON="$APPDIR/vibe.png"
  # nfpm does not expand variables in file paths, so render the config first.
  render() { python3 -I -c 'import os,re,sys; t=open(sys.argv[1]).read(); print(re.sub(r"\$\{(\w+)\}", lambda m: os.environ[m.group(1)], t))' \
    "$HERE/packaging/nfpm.yaml" > "$1"; }
  render "$WORK/nfpm.yaml"
  (cd "$HERE" && for fmt in deb rpm; do "$NFPM" package -f "$WORK/nfpm.yaml" -p "$fmt" -t "$OUT/" >/dev/null; done)
  # pacman wants pkgrel >= 1, so Arch gets release + 1 (fallback 1, proper build 2).
  PKG_RELEASE=$((PKG_RELEASE + 1)) render "$WORK/nfpm-arch.yaml"
  (cd "$HERE" && "$NFPM" package -f "$WORK/nfpm-arch.yaml" -p archlinux -t "$OUT/" >/dev/null)
  # nfpm writes wrong modes/times into .MTREE, which `pacman -Qkk` reports; rewrite it from the tar headers.
  python3 -I "$HERE/tools/fix-arch-mtree.py" "$OUT"/*.pkg.tar.zst
  rm -rf "$STAGE"
  ls -la "$OUT"/*.deb "$OUT"/*.rpm "$OUT"/*.pkg.tar.zst
fi
