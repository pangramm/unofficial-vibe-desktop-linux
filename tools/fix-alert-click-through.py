"""Keep Linux alert controls clickable while an alert is open."""

from pathlib import Path
import re
import sys


renderer = Path(sys.argv[1])
html = (renderer / "alert.html").read_text()
entry = re.search(r'<script\b[^>]*\bsrc="(\./assets/alert-[\w-]+\.js)"', html)
if entry is None:
    print("WARNING: Linux alert fix skipped: alert renderer entry point changed.", file=sys.stderr)
    sys.exit(0)

asset = renderer / entry[1]
source = asset.read_text()
# The upstream hook depends on mousemove events forwarded by an ignored window.
# Electron's forwarding is unavailable on Linux. Keep the idle window transparent
# to clicks and let the visible alert receive clicks directly.
old_call = re.compile(r"^  useAlertClickThrough\(\w+\);$", re.MULTILINE)
new_call = """  reactExports.useEffect(() => {
    window.alertAPI.setIgnoreMouseEvents(alertId === null);
  }, [alertId]);"""
patched, replacements = old_call.subn(new_call, source)
if replacements != 1:
    print("WARNING: Linux alert fix skipped: alert click-through call changed.", file=sys.stderr)
    sys.exit(0)

asset.write_text(patched)
