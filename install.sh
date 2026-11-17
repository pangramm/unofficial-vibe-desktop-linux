#!/bin/sh
# Install (or update) the unofficial Vibe Desktop AppImage for the current user. No root needed.
#
#   curl -fsSL https://raw.githubusercontent.com/pangramm/unofficial-vibe-desktop-linux/main/install.sh | sh
#   curl -fsSL https://raw.githubusercontent.com/pangramm/unofficial-vibe-desktop-linux/main/install.sh | sh -s -- --uninstall
set -eu

REPO="pangramm/unofficial-vibe-desktop-linux"
DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
DEST_DIR="$DATA/unofficial-vibe-desktop"
APPIMAGE="$DEST_DIR/Vibe-x86_64.AppImage"
BIN_DIR="$HOME/.local/bin"
LINK="$BIN_DIR/vibe-desktop"

say() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

if [ "${1:-}" = "--uninstall" ]; then
  rm -f "$LINK" "$DATA/applications/vibe-linux.desktop" "$DATA/icons/hicolor/512x512/apps/vibe-linux.png"
  rm -rf "$DEST_DIR"
  command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$DATA/applications" >/dev/null 2>&1 || true
  say "Vibe Desktop removed. Your settings in ~/.config/le-chat-desktop were kept."
  exit 0
fi

[ "$(uname -s)" = Linux ] || die "Linux only."
[ "$(uname -m)" = x86_64 ] || die "Only x86_64 is supported for now."
command -v curl >/dev/null 2>&1 || die "curl is required."
command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required."

say "Looking up the latest release..."
API="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest")" || die "No release published yet."
URL="$(printf '%s' "$API" | grep -o '"browser_download_url": *"[^"]*x86_64\.AppImage"' | head -1 | sed 's/.*"\(https[^"]*\)"/\1/')"
TAG="$(printf '%s' "$API" | grep -o '"tag_name": *"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
[ -n "$URL" ] || die "No AppImage found in the latest release."

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
NAME="$(basename "$URL")"
say "Downloading $NAME ($TAG)..."
curl -fL --progress-bar -o "$TMP/$NAME" "$URL"
curl -fsSL -o "$TMP/$NAME.sha256" "$URL.sha256"
(cd "$TMP" && sha256sum -c "$NAME.sha256" >/dev/null) || die "Checksum verification failed."

mkdir -p "$DEST_DIR" "$BIN_DIR"
mv "$TMP/$NAME" "$APPIMAGE"
chmod +x "$APPIMAGE"
ln -sf "$APPIMAGE" "$LINK"

# Menu entry + lechat:// handler (works without FUSE too).
APPIMAGE_EXTRACT_AND_RUN=1 APPIMAGE="$APPIMAGE" "$APPIMAGE" --install-desktop-entry >/dev/null

say "Installed Vibe $TAG."
say "Start it from your app menu or with: vibe-desktop"
case ":$PATH:" in *":$BIN_DIR:"*) ;; *) say "(Add $BIN_DIR to your PATH to use the vibe-desktop command.)";; esac
if ! command -v fusermount3 >/dev/null 2>&1 && ! command -v fusermount >/dev/null 2>&1; then
  say "Note: FUSE was not found. Install fuse3, or start with APPIMAGE_EXTRACT_AND_RUN=1 vibe-desktop"
fi
