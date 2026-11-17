#!/usr/bin/env bash
# Build the signed apt and dnf repositories for GitHub Pages.
#
#   packaging/build-repos.sh <dist-dir> <site-dir> <pages-url> <rpm-download-base>
#
# Expects the signing key in the current GnuPG keyring (default key). Signs the .rpm in
# <dist-dir> in place, so sign before uploading it to the release.
#   arch: <site>/arch/x86_64/  signed .pkg.tar.zst + signed pacman database
#   apt: <site>/deb/   flat repo: Packages, Release, InRelease, Release.gpg + the .deb
#   dnf: <site>/rpm/   repodata only; packages are fetched from <rpm-download-base>
#                      (the GitHub release) via xml:base, keeping the Pages site small.
set -euo pipefail
DIST="$(readlink -f "$1")"; SITE="$2"; PAGES_URL="$3"; RPM_BASE="$4"
HERE="$(cd "$(dirname "$0")" && pwd)"
KEY_ID="$(gpg --batch --list-secret-keys --with-colons | awk -F: '/^fpr/{print $10; exit}')"
[ -n "$KEY_ID" ] || { echo "no signing key in keyring" >&2; exit 1; }

DEB="$(ls "$DIST"/*.deb | head -1)"
RPM="$(ls "$DIST"/*.rpm | head -1)"
mkdir -p "$SITE/deb/amd64" "$SITE/rpm"

# ---- rpm: sign the package itself, then build signed metadata pointing at the release
cat > ~/.rpmmacros <<EOF
%__gpg $(command -v gpg)
%_gpg_name $KEY_ID
%__gpg_sign_cmd %{__gpg} --batch --no-armor --no-secmem-warning -u "%{_gpg_name}" -sbo %{__signature_filename} --digest-algo sha256 %{__plaintext_filename}
EOF
rpmsign --addsign "$RPM" >/dev/null
TMPK="$(mktemp)"; gpg --batch --armor --export "$KEY_ID" > "$TMPK"
TMPDB="$(mktemp -d)"; rpm --dbpath "$TMPDB" --import "$TMPK"
rpm --dbpath "$TMPDB" -K "$RPM" | grep -qiE 'signatures ok|digests signatures OK' || { rpm --dbpath "$TMPDB" -K "$RPM"; exit 1; }
rm -rf "$TMPDB" "$TMPK"
RPMDIR="$(mktemp -d)"; cp "$RPM" "$RPMDIR/"
createrepo_c --quiet --baseurl "$RPM_BASE" "$RPMDIR"
rm -rf "$SITE/rpm/repodata"; mv "$RPMDIR/repodata" "$SITE/rpm/"
rm -rf "$RPMDIR"
gpg --batch --yes --armor --detach-sign -o "$SITE/rpm/repodata/repomd.xml.asc" "$SITE/rpm/repodata/repomd.xml"

# ---- apt: flat repository with the .deb on Pages (apt cannot follow per-package absolute URLs)
rm -f "$SITE"/deb/amd64/*.deb; cp "$DEB" "$SITE/deb/amd64/"
(cd "$SITE/deb" &&
  dpkg-scanpackages --multiversion amd64 /dev/null > Packages 2>/dev/null &&
  gzip -9c Packages > Packages.gz &&
  apt-ftparchive -o APT::FTPArchive::Release::Origin=unofficial-vibe-desktop-linux \
                 -o APT::FTPArchive::Release::Label=unofficial-vibe-desktop-linux release . > Release &&
  gpg --batch --yes --armor --detach-sign -o Release.gpg Release &&
  gpg --batch --yes --clearsign -o InRelease Release)

# ---- pacman: signed package + signed database on Pages (pacman needs both under one Server URL)
PKG="$(ls "$DIST"/*.pkg.tar.zst 2>/dev/null | head -1 || true)"
if [ -n "$PKG" ]; then
  A="$SITE/arch/x86_64"; rm -rf "$A"; mkdir -p "$A"
  cp "$PKG" "$A/"; P="$A/$(basename "$PKG")"
  gpg --batch --yes --no-armor --detach-sign -o "$P.sig" "$P"
  (cd "$A" && repo-add -q unofficial-vibe-desktop.db.tar.gz "$(basename "$P")" >/dev/null)
  for f in db files; do
    gpg --batch --yes --no-armor --detach-sign -o "$A/unofficial-vibe-desktop.$f.tar.gz.sig" "$A/unofficial-vibe-desktop.$f.tar.gz"
    # Pages does not serve symlinks; ship real copies under the names pacman requests.
    rm -f "$A/unofficial-vibe-desktop.$f" "$A/unofficial-vibe-desktop.$f.sig"
    cp "$A/unofficial-vibe-desktop.$f.tar.gz" "$A/unofficial-vibe-desktop.$f"
    cp "$A/unofficial-vibe-desktop.$f.tar.gz.sig" "$A/unofficial-vibe-desktop.$f.sig"
  done
  rm -f "$A"/*.old "$A"/*.old.sig
fi

# ---- key, install scripts, landing page
gpg --batch --armor --export "$KEY_ID" > "$SITE/gpg-key.asc"
for s in install-deb.sh install-rpm.sh install-arch.sh; do
  sed -e "s|@PAGES_URL@|$PAGES_URL|g" -e "s|@KEY_FPR@|$KEY_ID|g" "$HERE/$s" > "$SITE/$s"
done
cat > "$SITE/index.html" <<EOF
<!doctype html><meta charset="utf-8"><title>Vibe Desktop for Linux (unofficial) - package repositories</title>
<h1>Vibe Desktop for Linux (unofficial)</h1>
<p>Not affiliated with Mistral AI. See <a href="https://github.com/${GITHUB_REPOSITORY:-pangramm/unofficial-vibe-desktop-linux}">the repository</a>.</p>
<pre>
# Fedora / RHEL / openSUSE
curl -fsSL $PAGES_URL/install-rpm.sh | sudo bash &amp;&amp; sudo dnf install unofficial-vibe-desktop

# Arch / Manjaro / EndeavourOS
curl -fsSL $PAGES_URL/install-arch.sh | sudo bash &amp;&amp; sudo pacman -Syu unofficial-vibe-desktop

# Debian / Ubuntu / Mint
curl -fsSL $PAGES_URL/install-deb.sh | sudo bash &amp;&amp; sudo apt install unofficial-vibe-desktop
</pre>
EOF
echo "repos built in $SITE (key $KEY_ID)"
