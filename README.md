# Vibe Desktop for Linux (unofficial)

Unofficial Linux AppImage of **[Mistral Vibe Desktop](https://mistral.ai)**, repackaged from Mistral's official
Windows installer until there is an official Linux build.

> **Not affiliated with or endorsed by Mistral AI.** All app code belongs to Mistral AI; this repository only
> contains the scripts that repackage it. If Mistral asks for this to be taken down, it will be.

## Quick install

| Distro | Command |
|--------|---------|
| Fedora / RHEL / Alma / Rocky 8+ | `curl -fsSL https://pangramm.github.io/unofficial-vibe-desktop-linux/install-rpm.sh \| sudo bash && sudo dnf install unofficial-vibe-desktop` |
| openSUSE | `curl -fsSL https://pangramm.github.io/unofficial-vibe-desktop-linux/install-rpm.sh \| sudo bash && sudo zypper install unofficial-vibe-desktop` |
| Arch / Manjaro / EndeavourOS | `curl -fsSL https://pangramm.github.io/unofficial-vibe-desktop-linux/install-arch.sh \| sudo bash && sudo pacman -Syu unofficial-vibe-desktop` |
| Debian 10+ / Ubuntu 20.04+ / Mint / Pop!_OS | `curl -fsSL https://pangramm.github.io/unofficial-vibe-desktop-linux/install-deb.sh \| sudo bash && sudo apt install unofficial-vibe-desktop` |
| Any distro (AppImage, no root) | `curl -fsSL https://raw.githubusercontent.com/pangramm/unofficial-vibe-desktop-linux/main/install.sh \| sh` |
| Any distro (manual) | [AppImage from the latest release](../../releases/latest), optionally managed by [Gear Lever](https://flathub.org/apps/it.mijorus.gearlever) |

x86_64 only, glibc 2.28 or newer (any distro from about 2019 on).

**Packages (dnf / zypper / pacman / apt):** the setup script adds a GPG-signed repository
([key](https://pangramm.github.io/unofficial-vibe-desktop-linux/gpg-key.asc)), so new versions arrive with your
normal `sudo dnf upgrade` / `sudo zypper update` / `sudo pacman -Syu` / `sudo apt upgrade`. The app is installed to
`/opt/unofficial-vibe-desktop` with a `vibe-desktop` command and a menu entry. Uninstall with
`sudo dnf remove unofficial-vibe-desktop` (or `apt remove`, `pacman -R`); remove the repository via
`/etc/yum.repos.d/unofficial-vibe-desktop.repo`, `/etc/zypp/repos.d/…`, `/etc/apt/sources.list.d/unofficial-vibe-desktop.list`
or the `[unofficial-vibe-desktop]` section in `/etc/pacman.conf`.

**AppImage one-liner:** downloads the latest AppImage, verifies its SHA-256, installs it to
`~/.local/share/unofficial-vibe-desktop/`, adds a `vibe-desktop` command and a menu entry, and registers the
`lechat://` link handler. Run it again to update. To remove it, run the same command with `| sh -s -- --uninstall`
(your settings in `~/.config/le-chat-desktop` are kept).

<details>
<summary>Manual AppImage install</summary>

```bash
chmod +x Vibe-*-x86_64.AppImage
./Vibe-*-x86_64.AppImage
./Vibe-*-x86_64.AppImage --install-desktop-entry   # optional: menu entry + lechat:// handler
```

**Updates:** the AppImage carries update information, so Gear Lever, AppImageLauncher or `appimageupdatetool`
can update it in place. The app's built-in updater has no Linux feed and does nothing.

Needs FUSE (`fuse3`/`libfuse2`, standard on most desktops). Without FUSE:
`APPIMAGE_EXTRACT_AND_RUN=1 ./Vibe-*.AppImage`.

</details>

## How it works

A GitHub Action checks Mistral's update feed every three hours. When a new version appears it downloads the
Windows installer, verifies its SHA-512 against the feed, runs [`build.sh`](build.sh) and publishes a release with the
AppImage, a `.deb` and a signed `.rpm`. The signed apt, dnf and pacman repositories are rebuilt and deployed to GitHub Pages
([`packaging/build-repos.sh`](packaging/build-repos.sh)).

Vibe 1.3.0 ships its Electron main process as JavaScript, which the build copies directly. Older releases ship
**V8 bytecode** (`.jsc`), which only loads in the exact V8 build that produced it. Comparing the Windows build with
the official Linux build of the same Electron version shows that the bytecode differs in its references into
V8's **read-only heap**. Node's embedded startup snapshot orders its internalized strings differently per
platform build (pages 7, 9 and 10). [`tools/jscconv.py`](tools/jscconv.py) parses the code-cache stream (V8 15.6
serializer format), remaps every `ReadOnlyHeapRef` to the same object in the Linux snapshot by matching string
contents, and rewrites the header (read-only checksum, payload length, checksum). The original code then runs
unmodified on Linux Electron.

Everything else is swapped for Linux equivalents:

| Windows                                         | Linux                                                          |
|-------------------------------------------------|----------------------------------------------------------------|
| `vibe-app-server.exe` (PyInstaller)             | [`mistral-vibe`](https://pypi.org/project/mistral-vibe/) from PyPI in a portable Python 3.12 |
| `node-pty`, `native-keymap` (win32)             | rebuilt against the Electron headers                            |
| `koffi` (win32)                                 | `@koromix/koffi-linux-x64`                                      |
| `key-server.exe`                                | keyspy's `X11KeyServer`, built from the bundled source          |
| `rg.exe`, `agent-browser.exe`                   | Linux releases of the same versions                             |
| computer-use, mic-monitor, send-paste, audio helpers | dropped (Windows-only)                                     |
| `systemPreferences.getMediaAccessStatus` & co. (macOS/Windows-only Electron APIs) | polyfilled by [`tools/linux-shim.cjs`](tools/linux-shim.cjs) |

Release builds normally pin the version bundled in the Windows build. Desktop 1.3.0 and later also require the
Linux app server to pass a JSON-RPC contract check for `agents/list` and `runtime/read`, including the approval
policy fields. The PyPI wheel for `mistral-vibe==3.1.3` lacks those fields despite matching the Windows version.

## Limitations

- Global shortcuts use X11 (XInput2); on Wayland they only see XWayland windows.
- No Computer Use plugin, meeting detection or system-audio capture.
- Runs with `--no-sandbox` (Chromium's setuid sandbox cannot work inside an AppImage mount).

## Build it yourself

```bash
./build.sh vibe-X.Y.Z-setup.exe          # -> dist/Vibe-X.Y.Z-x86_64.AppImage
```

The installer is at `https://storage.googleapis.com/mistralai-ci-desktop-app/vibe-X.Y.Z-setup.exe`
(current version in [`latest.yml`](https://storage.googleapis.com/mistralai-ci-desktop-app/latest.yml)).

Requires `7z`, `node`/`npm`, `python3`, [`uv`](https://docs.astral.sh/uv/), `gcc`/`g++`/`make`, `curl`, `pkg-config`
and the X11 headers for libxkbfile, libXi and libXfixes. If those headers are not installed, the script fetches them
without root via `dnf download` / `apt-get download`. `STRICT_BACKEND=1` aborts instead of falling back to the newest
`mistral-vibe` on PyPI when the bundled version is not published yet. The RPC check also applies to fallback builds.
To test a wheel built from compatible upstream source, pass `BACKEND_WHEEL=/path/to/mistral_vibe-….whl`. The
release workflow supports the same path through its `backend_source_commit` input.

## License

The scripts in this repository are MIT-licensed (see [LICENSE](LICENSE)). Vibe Desktop itself is proprietary software
by Mistral AI; Electron, Node.js and the other bundled components keep their own licenses.
