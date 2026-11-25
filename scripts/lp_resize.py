#!/usr/bin/env python3
"""
lp_resize.py - grow (or inspect) the Android "super" image for a bigger super partition, without unpacking it.

Why this works: in a dynamic-partitions super image, both copies of the LP metadata (3 primary + 3 backup slots) live at the START of the
device and every partition extent is an absolute sector inside super. Growing the physical partition therefore needs only:
  * LP block-device "size"            -> new partition size in bytes
  * LP group "maximum_size"           -> new size minus the same overhead as before (qti_dynamic_partitions_a/_b)
  * the metadata checksums (tables sha256 + header sha256) of every metadata copy
  * the sparse image itself extended with a DONT_CARE chunk so it covers the new size.
No data moves, so system/vendor/... stay bit-identical.

usage:
  lp_resize.py info   <super.img|super.raw>                     # print geometry, block devices, groups, partitions
  lp_resize.py resize <in_sparse_super.img> <out.img> <GiB>     # write the grown sparse image
  lp_resize.py verify <out.img> <GiB>                           # re-read and check sizes + all checksums
Only Android sparse images (magic 3aff26ed) and raw images are supported as input.
"""
import hashlib, struct, sys, os

SPARSE_MAGIC = 0xED26FF3A
CH_RAW, CH_FILL, CH_DONT_CARE, CH_CRC = 0xCAC1, 0xCAC2, 0xCAC3, 0xCAC4
GEOM_MAGIC = 0x616C4467
HDR_MAGIC = 0x414C5030
RESERVED = 4096
GEOM_SIZE = 4096
SCAN = 1 << 20  # metadata always lies inside the first MiB with alignment 1 MiB


def is_sparse(path):
    with open(path, "rb") as f:
        return struct.unpack("<I", f.read(4))[0] == SPARSE_MAGIC


def sparse_header(f):
    f.seek(0)
    (magic, major, minor, fhs, chs, blk, tblks, tchunks, crc) = struct.unpack("<IHHHHIIII", f.read(28))
    assert magic == SPARSE_MAGIC and major == 1, "not an Android sparse image"
    return dict(fhs=fhs, chs=chs, blk=blk, tblks=tblks, tchunks=tchunks, crc=crc)


def read_head(path, n=SCAN):
    """First n bytes of the logical image (sparse or raw)."""
    if not is_sparse(path):
        with open(path, "rb") as f:
            return f.read(n)
    out = bytearray()
    with open(path, "rb") as f:
        h = sparse_header(f)
        f.seek(h["fhs"])
        for _ in range(h["tchunks"]):
            ctype, _r, csz, tsz = struct.unpack("<HHII", f.read(12))
            nbytes = csz * h["blk"]
            if ctype == CH_RAW:
                need = max(0, min(nbytes, n - len(out)))
                out += f.read(need)
                f.seek(nbytes - need, 1)
            elif ctype == CH_FILL:
                v = f.read(4)
                out += (v * (nbytes // 4))[: max(0, n - len(out))]
            elif ctype == CH_DONT_CARE:
                out += b"\0" * min(nbytes, max(0, n - len(out)))
            elif ctype == CH_CRC:
                f.read(4)
            if len(out) >= n:
                break
    return bytes(out[:n])


def parse_geometry(head):
    off = RESERVED
    magic, ssz = struct.unpack_from("<II", head, off)
    assert magic == GEOM_MAGIC, "no LP geometry at 4096"
    chk = head[off + 8: off + 40]
    calc = hashlib.sha256(head[off: off + 8] + b"\0" * 32 + head[off + 40: off + ssz]).digest()
    mmax, slots, lbs = struct.unpack_from("<III", head, off + 40)
    return dict(max=mmax, slots=slots, lbs=lbs, ok=(chk == calc))


def parse_header(blob):
    """blob starts at a LpMetadataHeader. returns dict or None."""
    if len(blob) < 256 or struct.unpack_from("<I", blob, 0)[0] != HDR_MAGIC:
        return None
    major, minor, hsz = struct.unpack_from("<HHI", blob, 4)
    hchk = blob[12:44]
    tsz = struct.unpack_from("<I", blob, 44)[0]
    tchk = blob[48:80]
    desc = {}
    for i, name in enumerate(("partitions", "extents", "groups", "block_devices")):
        o, n, e = struct.unpack_from("<III", blob, 80 + 12 * i)
        desc[name] = (o, n, e)
    tables = blob[hsz: hsz + tsz]
    calc_t = hashlib.sha256(tables).digest()
    calc_h = hashlib.sha256(blob[:12] + b"\0" * 32 + blob[44:hsz]).digest()
    return dict(major=major, minor=minor, hsz=hsz, tsz=tsz, desc=desc, tables_ok=(calc_t == tchk), header_ok=(calc_h == hchk))


def cstr(b):
    return b.split(b"\0", 1)[0].decode("ascii", "replace")


def read_entries(blob, h, kind, fmt):
    o, n, e = h["desc"][kind]
    base = h["hsz"] + o
    for i in range(n):
        yield i, base + i * e


def metadata_offsets(g):
    prim = RESERVED + GEOM_SIZE * 2
    back = prim + g["max"] * g["slots"]
    return [("primary", s, prim + g["max"] * s) for s in range(g["slots"])] + [("backup", s, back + g["max"] * s) for s in range(g["slots"])]


def dump(path):
    head = read_head(path)
    g = parse_geometry(head)
    print(f"geometry: max_size={g['max']} slots={g['slots']} logical_block={g['lbs']} checksum_ok={g['ok']}")
    shown = False
    for kind, slot, off in metadata_offsets(g):
        h = parse_header(head[off:])
        if not h:
            print(f"  {kind} slot {slot}: no valid header")
            continue
        print(f"  {kind} slot {slot}: v{h['major']}.{h['minor']} tables={h['tsz']}B tables_ok={h['tables_ok']} header_ok={h['header_ok']}")
        if shown:
            continue
        shown = True
        blob = head[off:]
        for i, p in read_entries(blob, h, "block_devices", None):
            fsl, al, alo, size = struct.unpack_from("<QIIQ", blob, p)
            print(f"     block device '{cstr(blob[p + 24: p + 60])}': first_sector={fsl} size={size} ({size / 2**30:.3f} GiB)")
        for i, p in read_entries(blob, h, "groups", None):
            name = cstr(blob[p: p + 36]); fl, mx = struct.unpack_from("<IQ", blob, p + 36)
            print(f"     group '{name}': max_size={mx}")
        o, n, e = h["desc"]["partitions"]
        print(f"     partitions: {n}")
    return g


def patch_metadata(head, new_bytes):
    """returns (patched_head, info) - raises on any inconsistency."""
    g = parse_geometry(head)
    assert g["ok"], "geometry checksum invalid in the input image"
    head = bytearray(head)
    old = None; overhead = None; patched = 0
    for kind, slot, off in metadata_offsets(g):
        blob = bytes(head[off: off + g["max"]])
        h = parse_header(blob)
        if not h:
            continue
        assert h["tables_ok"] and h["header_ok"], f"{kind} slot {slot}: checksum bad before patching"
        tb = bytearray(blob[h["hsz"]: h["hsz"] + h["tsz"]])
        # block device 'super'
        o, n, e = h["desc"]["block_devices"]
        assert e == 64, "unexpected block-device entry size"
        dev_idx = None
        for i in range(n):
            p = o + i * e
            if cstr(bytes(tb[p + 24: p + 60])) == "super":
                dev_idx = p
        assert dev_idx is not None, "block device 'super' not found"
        cur = struct.unpack_from("<Q", tb, dev_idx + 16)[0]
        if old is None:
            old = cur
            overhead = None
        assert cur == old, "copies disagree about the super size"
        struct.pack_into("<Q", tb, dev_idx + 16, new_bytes)
        # groups
        o, n, e = h["desc"]["groups"]
        assert e == 48, "unexpected group entry size"
        for i in range(n):
            p = o + i * e
            name = cstr(bytes(tb[p: p + 36])); mx = struct.unpack_from("<Q", tb, p + 40)[0]  # name[36], flags u32, then maximum_size u64
            if mx == 0:  # 'default' group stays unlimited
                continue
            ov = old - mx
            assert 0 < ov < (64 << 20), f"group {name}: odd overhead {ov}"
            overhead = ov if overhead is None else overhead
            assert ov == overhead, "groups have different overheads"
            struct.pack_into("<Q", tb, p + 40, new_bytes - ov)
        # rebuild header
        nb = bytearray(blob[: h["hsz"]])
        nb[48:80] = hashlib.sha256(bytes(tb)).digest()
        nb[12:44] = b"\0" * 32
        nb[12:44] = hashlib.sha256(bytes(nb)).digest()
        head[off: off + h["hsz"]] = nb
        head[off + h["hsz"]: off + h["hsz"] + h["tsz"]] = tb
        patched += 1
    assert patched >= 2 and old is not None, "no metadata copies patched"
    return bytes(head), dict(old=old, overhead=overhead, copies=patched)


def resize(src, dst, gib):
    new_bytes = int(gib * (1 << 30))
    assert new_bytes % 4096 == 0
    head = read_head(src)
    new_head, info = patch_metadata(head, new_bytes)
    assert new_bytes > info["old"], "new size must be larger than the current one (shrinking is not supported)"
    with open(src, "rb") as fi:
        h = sparse_header(fi)
        blk = h["blk"]
        new_blks = new_bytes // blk
        add = new_blks - h["tblks"]
        assert add > 0
        with open(dst, "wb") as fo:
            fo.write(struct.pack("<IHHHHIIII", SPARSE_MAGIC, 1, 0, h["fhs"], h["chs"], blk, new_blks, h["tchunks"] + 1, 0))
            fi.seek(h["fhs"])
            pos_blk = 0
            for _ in range(h["tchunks"]):
                ch = fi.read(12)
                ctype, rsv, csz, tsz = struct.unpack("<HHII", ch)
                fo.write(ch)
                body = tsz - 12
                if ctype == CH_RAW:
                    data = bytearray(fi.read(body))
                    # overlay patched metadata where this chunk covers the first MiB
                    s = pos_blk * blk
                    if s < SCAN:
                        n = min(len(data), SCAN - s)
                        data[:n] = new_head[s: s + n]
                    fo.write(data)
                else:
                    fo.write(fi.read(body))
                pos_blk += csz
            assert pos_blk == h["tblks"], "sparse chunk sizes do not add up"
            fo.write(struct.pack("<HHII", CH_DONT_CARE, 0, add, 12))
    return info


def verify(path, gib):
    new_bytes = int(gib * (1 << 30))
    head = read_head(path)
    g = parse_geometry(head)
    assert g["ok"], "geometry checksum bad"
    good = 0
    for kind, slot, off in metadata_offsets(g):
        blob = head[off: off + g["max"]]
        h = parse_header(blob)
        if not h:
            continue
        assert h["tables_ok"] and h["header_ok"], f"{kind} {slot}: checksum bad"
        o, n, e = h["desc"]["block_devices"]
        base = h["hsz"] + o
        for i in range(n):
            size = struct.unpack_from("<Q", blob, base + i * e + 16)[0]
            assert size == new_bytes, f"{kind} {slot}: block device size {size} != {new_bytes}"
        good += 1
    if is_sparse(path):
        with open(path, "rb") as f:
            h = sparse_header(f)
            assert h["tblks"] * h["blk"] == new_bytes, "sparse total size mismatch"
    print(f"verify OK: {good} metadata copies valid, super size = {new_bytes} bytes ({gib} GiB)")


if __name__ == "__main__":
    a = sys.argv[1:]
    if len(a) == 2 and a[0] == "info":
        dump(a[1])
    elif len(a) == 4 and a[0] == "resize":
        info = resize(a[1], a[2], float(a[3]))
        print(f"resized: {info['old']} -> {int(float(a[3]) * (1 << 30))} bytes; patched {info['copies']} metadata copies; group overhead kept at {info['overhead']}")
        verify(a[2], float(a[3]))
    elif len(a) == 3 and a[0] == "verify":
        verify(a[1], float(a[2]))
    else:
        print(__doc__); sys.exit(2)
