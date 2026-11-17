#!/bin/bash
# Add the unofficial Vibe Desktop pacman repository (Arch, Manjaro, EndeavourOS, ...).
#   curl -fsSL @PAGES_URL@/install-arch.sh | sudo bash
set -euo pipefail
URL="@PAGES_URL@"
FPR="@KEY_FPR@"
[ "$(id -u)" -eq 0 ] || { echo "Run as root (sudo)." >&2; exit 1; }
[ "$(uname -m)" = x86_64 ] || { echo "Only x86_64 is supported." >&2; exit 1; }

KEY="$(mktemp)"; trap 'rm -f "$KEY"' EXIT
curl -fsSL "$URL/gpg-key.asc" -o "$KEY"
pacman-key --add "$KEY" >/dev/null
pacman-key --lsign-key "$FPR" >/dev/null

if ! grep -q '^\[unofficial-vibe-desktop\]' /etc/pacman.conf; then
  cat >> /etc/pacman.conf <<CONF

[unofficial-vibe-desktop]
SigLevel = Required DatabaseRequired
Server = $URL/arch/\$arch
CONF
fi
echo "Repository added to /etc/pacman.conf"
echo
echo "Install:  sudo pacman -Syu unofficial-vibe-desktop"
echo "Updates arrive with:  sudo pacman -Syu"
