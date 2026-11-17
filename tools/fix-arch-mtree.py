#!/usr/bin/env python3
"""Make .MTREE agree with the archive in an nfpm-built Arch package.

nfpm 2.49 gets two things wrong in .MTREE, so `pacman -Qkk` flags thousands of files:
  - directory modes include Go's os.ModeDir flag (mode=20000000755 instead of 755);
  - times are taken separately from the tar headers and can be off by a second;
  - symlinks get mode 0 (Linux reports 777).
This rewrites .MTREE from the tar headers themselves (mode and time) and re-packs the
archive through zstd without unpacking it to disk. File contents and digests are untouched.

    tools/fix-arch-mtree.py <package.pkg.tar.zst>
"""
import gzip, io, os, re, subprocess, sys, tarfile

pkg = sys.argv[1]
tmp = pkg + ".tmp"
norm = lambda p: p.removeprefix("./").rstrip("/")


def stream(path):
    return subprocess.Popen(["zstd", "-dcq", path], stdout=subprocess.PIPE)


def fix_member(m):
    m.mode = 0o777 if m.issym() else m.mode & 0o7777  # nfpm writes symlinks with mode 0
    m.mtime = int(m.mtime)
    for k in ("mtime", "atime", "ctime"):  # whole seconds only, like .MTREE
        m.pax_headers.pop(k, None)
    return m


# pass 1: what the archive will actually install
headers = {}
dec = stream(pkg)
with tarfile.open(fileobj=dec.stdout, mode="r|") as src:
    for m in src:
        fix_member(m)
        headers[norm(m.name)] = (m.mtime, m.mode)
if dec.wait():
    sys.exit("zstd -d failed")


def fix_line(line):
    if not line.startswith("./") or " " not in line:
        return line
    path, rest = line.split(" ", 1)
    h = headers.get(norm(path))
    if not h:
        return line
    rest = re.sub(r"\btime=\S+", "time=%d.0" % h[0], rest)
    rest = re.sub(r"\bmode=\d+", "mode=%o" % h[1], rest)
    return path + " " + rest


# pass 2: rewrite
changed = 0
dec = stream(pkg)
with open(tmp, "wb") as out:
    enc = subprocess.Popen(["zstd", "-q", "-19", "-T0", "-c"], stdin=subprocess.PIPE, stdout=out)
    with tarfile.open(fileobj=dec.stdout, mode="r|") as src, \
         tarfile.open(fileobj=enc.stdin, mode="w|", format=tarfile.PAX_FORMAT) as dst:
        for m in src:
            fix_member(m)
            if norm(m.name) == ".MTREE":
                old = gzip.decompress(src.extractfile(m).read()).decode().splitlines()
                new = [fix_line(l) for l in old]
                changed = sum(a != b for a, b in zip(old, new))
                data = gzip.compress(("\n".join(new) + "\n").encode(), mtime=0)
                m.size = len(data)
                dst.addfile(m, io.BytesIO(data))
            elif m.isfile():
                dst.addfile(m, src.extractfile(m))
            else:
                dst.addfile(m)
    enc.stdin.close()
    if enc.wait() or dec.wait():
        os.unlink(tmp)
        sys.exit("zstd failed")
os.replace(tmp, pkg)
print(f"fixed {changed} .MTREE entries in {os.path.basename(pkg)}")
