#!/bin/bash
# Add the unofficial Vibe Desktop package repository (Debian 10+, Ubuntu 20.04+, Mint, Pop!_OS).
#   curl -fsSL @PAGES_URL@/install-deb.sh | sudo bash
set -euo pipefail
URL="@PAGES_URL@"
[ "$(id -u)" -eq 0 ] || { echo "Run as root (sudo)." >&2; exit 1; }
[ "$(dpkg --print-architecture)" = amd64 ] || { echo "Only amd64 is supported." >&2; exit 1; }
command -v gpg >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y -qq gnupg; }

KEYRING=/usr/share/keyrings/unofficial-vibe-desktop.gpg
curl -fsSL "$URL/gpg-key.asc" | gpg --batch --yes --dearmor -o "$KEYRING"
chmod 644 "$KEYRING"
echo "deb [arch=amd64 signed-by=$KEYRING] $URL/deb ./" > /etc/apt/sources.list.d/unofficial-vibe-desktop.list
apt-get update -qq
echo "Repository added."
echo
echo "Install:  sudo apt install unofficial-vibe-desktop"
echo "Updates arrive with:  sudo apt upgrade"
