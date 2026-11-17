#!/bin/bash
# Add the unofficial Vibe Desktop package repository (Fedora, RHEL/Alma/Rocky 8+, openSUSE).
#   curl -fsSL @PAGES_URL@/install-rpm.sh | sudo bash
set -euo pipefail
URL="@PAGES_URL@"
[ "$(id -u)" -eq 0 ] || { echo "Run as root (sudo)." >&2; exit 1; }
[ "$(uname -m)" = x86_64 ] || { echo "Only x86_64 is supported." >&2; exit 1; }

rpm --import "$URL/gpg-key.asc"
if command -v zypper >/dev/null 2>&1; then
  REPO_FILE=/etc/zypp/repos.d/unofficial-vibe-desktop.repo
  INSTALL="zypper install unofficial-vibe-desktop"; UPDATE="zypper update"
else
  REPO_FILE=/etc/yum.repos.d/unofficial-vibe-desktop.repo
  INSTALL="dnf install unofficial-vibe-desktop"; UPDATE="dnf upgrade"
fi
cat > "$REPO_FILE" <<REPO
[unofficial-vibe-desktop]
name=Vibe Desktop for Linux (unofficial)
baseurl=$URL/rpm/
type=rpm-md
enabled=1
autorefresh=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=$URL/gpg-key.asc
metadata_expire=3h
REPO
echo "Repository added: $REPO_FILE"
echo
echo "Install:  sudo $INSTALL"
echo "Updates arrive with:  sudo $UPDATE"
