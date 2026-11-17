"""Convert V8 code cache (.jsc) produced by one Electron build so it loads in
another build of the *same* Electron/V8 version on a different platform.

Only read-only-heap references differ between builds (Node's embedded
snapshot orders its internalized strings differently).  We parse the code
cache bytecode stream, remap every ReadOnlyHeapRef to the equivalent object
in the target build, and rewrite header fields.
"""
import struct, sys, zlib, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from roimg import find_node_blob, ro_image

STR_MAPS = (0x155, 0x12d)  # internalized one-byte / two-byte string maps
HEADER = 32


def get_u30(d, p):
    a = int.from_bytes(d[p:p + 4].ljust(4, b'\0'), 'little')
    n = (a & 3) + 1
    return (a & ((1 << (8 * n)) - 1)) >> 2, p + n


def put_u30(v):
    assert 0 <= v < (1 << 30)
    if v < 1 << 6: n = 1
    elif v < 1 << 14: n = 2
    elif v < 1 << 22: n = 3
    else: n = 4
    return ((v << 2) | (n - 1)).to_bytes(n, 'little')


def str_key(img, off):
    m, h, L = struct.unpack_from('<III', img, off)
    if m not in STR_MAPS: return None
    nb = L if m == 0x155 else 2 * L
    if L > 1 << 20 or off + 12 + nb > len(img): return None
    return (m, bytes(img[off + 12:off + 12 + nb]))


def index_strings(img):
    """Map string key -> offset for every plausible string object in a page."""
    idx = {}
    for off in range(0x10, len(img) - 12, 4):
        m = struct.unpack_from('<I', img, off)[0]
        if m not in STR_MAPS: continue
        h = struct.unpack_from('<I', img, off + 4)[0]
        if (h & 3) not in (0, 2): continue  # integer-index or computed hash
        k = str_key(img, off)
        if k is not None: idx.setdefault(k, off)
    return idx


class RoMapper:
    def __init__(self, src_bin, src_ck, dst_bin, dst_ck):
        d, b = find_node_blob(src_bin, src_ck); self.src = ro_image(d, b)
        d, b = find_node_blob(dst_bin, dst_ck); self.dst = ro_image(d, b)
        self.same = {p for p in self.src if p in self.dst and self.src[p] == self.dst[p]}
        self.idx = {}
        self.cache = {}
        self.fail = []

    def map(self, page, off):
        if page in self.same: return page, off
        key = (page, off)
        if key in self.cache: return self.cache[key]
        sk = str_key(self.src[page], off)
        res = None
        if sk is not None:
            for p in [page] + [q for q in self.dst if q != page]:
                if p in self.same: continue
                if p not in self.idx: self.idx[p] = index_strings(self.dst[p])
                if sk in self.idx[p]:
                    res = (p, self.idx[p][sk]); break
        else:
            # Non-string object: accept identity if bytes match at the same spot.
            a = self.src[page][off:off + 32]; b = self.dst.get(page, b'')[off:off + 32]
            if a == b: res = (page, off)
        if res is None:
            self.fail.append((page, off, bytes(self.src[page][off:off + 24]).hex()))
            res = (page, off)
        self.cache[key] = res
        return res


def convert(data, mapper, dst_ro_checksum):
    d = bytes(data)
    plen = struct.unpack_from('<I', d, 20)[0]
    pay = d[HEADER:HEADER + plen]
    out = bytearray(); p = 0; nref = 0
    def raw(n):
        nonlocal p
        out.extend(pay[p:p + n]); p += n
    def u30():
        nonlocal p
        v, q = get_u30(pay, p); out.extend(pay[p:q]); p = q; return v
    while p < len(pay):
        bc = pay[p]; out.append(bc); p += 1
        if bc <= 0x03: u30()                      # NewObject: size
        elif bc == 0x05:                          # ReadOnlyHeapRef
            pg, p = get_u30(pay, p); off, p = get_u30(pay, p)
            npg, noff = mapper.map(pg, off); nref += 1
            out.extend(put_u30(npg)); out.extend(put_u30(noff))
        elif bc in (0x04, 0x06, 0x07, 0x08, 0x09, 0x1a, 0x21): u30()
        elif bc in (0x0a, 0x17, 0x18, 0x19, 0x1e, 0x1f, 0x22): pass
        elif bc == 0x0b:                          # Synchronize: end of stream
            raw(len(pay) - p)
        elif bc == 0x0c: u30(); raw(1)            # VariableRepeatRoot
        elif bc in (0x0d, 0x0e):                  # OffHeapBackingStore
            n = struct.unpack_from('<I', pay, p)[0]; raw(4)
            if bc == 0x0e: raw(4)
            raw(n)
        elif bc == 0x11: n = u30(); raw(4 * n)    # VariableRawData
        elif bc in (0x12, 0x13): u30()            # Api/ExternalReference
        elif bc in (0x14, 0x15): u30(); u30()     # sandboxed variants + tag
        elif bc == 0x16: raw(8); u30()
        elif bc == 0x1b or bc == 0x1c: u30(); u30()  # NewMetaMap
        elif bc == 0x1d: raw(1)                   # ExtendedMapBitFieldEx
        elif bc == 0x20: u30()                    # AllocateJSDispatchEntry
        elif 0x40 <= bc <= 0x5f: pass             # RootArrayConstants
        elif 0x60 <= bc <= 0x7f: raw(4 * (bc - 0x60 + 1))  # FixedRawData
        elif 0x80 <= bc <= 0x8f: raw(1)           # FixedRepeatRoot
        elif 0x90 <= bc <= 0x97: pass             # HotObject
        else:
            raise ValueError('unknown bytecode %#x at payload offset %#x' % (bc, p - 1))
    while len(out) % 8: out.append(0x0a)  # pad with Nop to pointer alignment
    hdr = bytearray(d[:HEADER])
    struct.pack_into('<I', hdr, 16, dst_ro_checksum)
    struct.pack_into('<I', hdr, 20, len(out))
    struct.pack_into('<I', hdr, 24, zlib.adler32(bytes(out)) & 0xffffffff)
    return bytes(hdr) + bytes(out), nref


if __name__ == '__main__':
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument('--src-bin', required=True)
    ap.add_argument('--dst-bin', required=True)
    ap.add_argument('files', nargs='+')
    ap.add_argument('--check-roundtrip', action='store_true')
    a = ap.parse_args()
    first = open(a.files[0], 'rb').read()
    src_ck = struct.unpack_from('<I', first, 16)[0]
    # target checksum = the RO checksum stored in the target's node blob header
    dst_bytes = open(a.dst_bin, 'rb').read()
    ver = b'15.6.75.25-electron.0'; i = -1; dst_ck = None
    while True:
        i = dst_bytes.find(ver, i + 1)
        if i < 0: break
        if struct.unpack_from('<I', dst_bytes, i - 16)[0] == 4:  # 4 contexts = node blob
            dst_ck = struct.unpack_from('<I', dst_bytes, i - 4)[0]
    del dst_bytes
    m = RoMapper(a.src_bin, src_ck, a.dst_bin, dst_ck)
    print('identical RO pages:', sorted(m.same), file=sys.stderr)
    total_fail = 0
    for f in a.files:
        data = open(f, 'rb').read()
        if struct.unpack_from('<I', data, 16)[0] != src_ck:
            print('skip (foreign checksum):', f, file=sys.stderr); continue
        nf0 = len(m.fail)
        out, nref = convert(data, m, dst_ck)
        nf = len(m.fail) - nf0; total_fail += nf
        if not a.check_roundtrip:
            open(f, 'wb').write(out)
        print('%-45s refs=%d unmapped=%d' % (f.split('/')[-1], nref, nf), file=sys.stderr)
    for x in m.fail[:20]: print('  unmapped', x, file=sys.stderr)
    sys.exit(1 if total_fail else 0)
