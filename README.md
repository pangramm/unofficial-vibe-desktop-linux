# Vibe Desktop for Linux (unofficial)

Unofficial Linux AppImage of **[Mistral Vibe Desktop](https://mistral.ai)**, repackaged from Mistral's official
Windows installer until there is an official Linux build.

> **Not affiliated with or endorsed by Mistral AI.** All app code belongs to Mistral AI; this repository only
> contains the scripts that repackage it. If Mistral asks for this to be taken down, it will be.

## Install

Download `Vibe-X.Y.Z-x86_64.AppImage` from the [latest release](../../releases/latest), then:

```bash
chmod +x Vibe-*-x86_64.AppImage
./Vibe-*-x86_64.AppImage
```

Optional: add a menu entry and register the `lechat://` link handler:

```bash
./Vibe-*-x86_64.AppImage --install-desktop-entry
```

**Updates:** the AppImage carries update information, so [Gear Lever](https://flathub.org/apps/it.mijorus.gearlever),
AppImageLauncher or `appimageupdatetool` can update it in place. The app's built-in updater has no Linux feed and does nothing.

Needs x86_64 and FUSE (`libfuse2`/`fuse3`, standard on most desktops). Without FUSE:
`APPIMAGE_EXTRACT_AND_RUN=1 ./Vibe-*.AppImage`.

## How it works

A GitHub Action checks Mistral's update feed every three hours. When a new version appears it downloads the
Windows installer, verifies its SHA-512 against the feed, runs [`build.sh`](build.sh) and publishes a release.

The interesting part: Vibe's Electron main process ships as **V8 bytecode** (`.jsc`), not JavaScript, and V8
bytecode only loads in the exact V8 build that produced it. Comparing the Windows build with the official
Linux build of the same Electron version shows that the bytecode differs in only one way: its references into
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

The backend version always matches the one bundled in the Windows build. Mistral publishes it on PyPI a few days
after the desktop release, so a new version can appear here with that delay.

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
`mistral-vibe` on PyPI when the bundled version is not published yet.

## License

The scripts in this repository are MIT-licensed (see [LICENSE](LICENSE)). Vibe Desktop itself is proprietary software
by Mistral AI; Electron, Node.js and the other bundled components keep their own licenses.
