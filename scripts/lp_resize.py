#!/usr/bin/env python3
"""
lp_resize.py - analyse, check and grow the Android "super" image (dynamic partitions) WITHOUT unpacking it.

Why growing works without moving data: both copies of the LP metadata (3 primary + 3 backup slots) live at the START of the device and every
partition extent is an absolute sector inside super. A bigger physical partition that starts at the same sector therefore only needs:
  * the LP block-device "size"          -> the new partition size in bytes
  * the LP group "maximum_size"         -> the new size minus the same overhead the ROM used (kept from the original)
  * the metadata checksums (tables sha256 + header sha256) of every metadata copy
  * the sparse image extended with a DONT_CARE chunk so it covers the new size
Nothing else changes: system/vendor/... are bit-identical.

commands
  info    <img>                       human readable dump of the metadata (partitions, extents, groups, block device)
  check   <img> [GiB]                 compatibility verdict + sizes: used by the ROM, minimum, suggested, and (with GiB) whether GiB works
  resize  <in.img> <out.img> <GiB>    write the grown image (sparse stays sparse, raw stays raw) and verify it
  verify  <img> <GiB>                 re-read an image and check sizes and all checksums
  match   <device_head.bin> <img>     does the super on the phone (first MiB dumped from it) belong to the same ROM as <img>?
  suggest <img>                       just print the suggested size in GiB (an integer) for scripts

exit codes: 0 ok / match, 1 not ok / different, 2 unsupported or bad input
Inputs may be Android sparse images (magic 3aff26ed) or raw images. Split images (super.img_sparsechunk.N / super_N.img) are NOT supported:
merge them first (for example with simg2img).
"""
import hashlib, math, os, struct, sys

SPARSE_MAGIC = 0xED26FF3A
CH_RAW, CH_FILL, CH_DONT_CARE, CH_CRC = 0xCAC1, 0xCAC2, 0xCAC3, 0xCAC4
GEOM_MAGIC = 0x616C4467
HDR_MAGIC = 0x414C5030
RESERVED = 4096
GEOM_SIZE = 4096
SCAN = 1 << 20
GIB = 1 << 30
MIB = 1 << 20


class Unsupported(Exception):
    pass


def is_sparse(path):
    with open(path, "rb") as f:
        b = f.read(4)
    return len(b) == 4 and struct.unpack("<I", b)[0] == SPARSE_MAGIC


def sparse_header(f):
    f.seek(0)
    (magic, major, minor, fhs, chs, blk, tblks, tchunks, crc) = struct.unpack("<IHHHHIIII", f.read(28))
    if magic != SPARSE_MAGIC or major != 1:
        raise Unsupported("not an Android sparse image")
    return dict(fhs=fhs, chs=chs, blk=blk, tblks=tblks, tchunks=tchunks, crc=crc)


def logical_size(path):
    if is_sparse(path):
        with open(path, "rb") as f:
            h = sparse_header(f)
        return h["tblks"] * h["blk"]
    return os.path.getsize(path)


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
            else:
                raise Unsupported(f"unknown sparse chunk type {ctype:#x}")
            if len(out) >= n:
                break
    return bytes(out[:n])


def cstr(b):
    return b.split(b"\0", 1)[0].decode("ascii", "replace")


def parse_geometry(head):
    off = RESERVED
    if len(head) < off + 52:
        raise Unsupported("image too small to hold LP geometry")
    magic, ssz = struct.unpack_from("<II", head, off)
    if magic != GEOM_MAGIC:
        raise Unsupported("no LP (dynamic partitions) geometry at offset 4096: this is not a super image")
    chk = head[off + 8: off + 40]
    calc = hashlib.sha256(head[off: off + 8] + b"\0" * 32 + head[off + 40: off + ssz]).digest()
    mmax, slots, lbs = struct.unpack_from("<III", head, off + 40)
    return dict(max=mmax, slots=slots, lbs=lbs, ok=(chk == calc))


def parse_header(blob):
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
    flags = struct.unpack_from("<I", blob, 128)[0] if hsz >= 132 else 0
    tables = blob[hsz: hsz + tsz]
    calc_t = hashlib.sha256(tables).digest()
    calc_h = hashlib.sha256(blob[:12] + b"\0" * 32 + blob[44:hsz]).digest()
    return dict(major=major, minor=minor, hsz=hsz, tsz=tsz, desc=desc, flags=flags, tables_ok=(calc_t == tchk), header_ok=(calc_h == hchk))


def metadata_offsets(g):
    prim = RESERVED + GEOM_SIZE * 2
    back = prim + g["max"] * g["slots"]
    return [("primary", s, prim + g["max"] * s) for s in range(g["slots"])] + [("backup", s, back + g["max"] * s) for s in range(g["slots"])]


def parse_tables(blob, h):
    """full decode of one metadata copy -> dict"""
    base = h["hsz"]
    t = {"block_devices": [], "groups": [], "partitions": [], "extents": []}
    o, n, e = h["desc"]["block_devices"]
    if e != 64:
        raise Unsupported(f"unexpected block-device entry size {e}")
    for i in range(n):
        p = base + o + i * e
        fsl, al, alo, size = struct.unpack_from("<QIIQ", blob, p)
        t["block_devices"].append(dict(name=cstr(blob[p + 24: p + 60]), first_sector=fsl, alignment=al, size=size, flags=struct.unpack_from("<I", blob, p + 60)[0]))
    o, n, e = h["desc"]["groups"]
    if e != 48:
        raise Unsupported(f"unexpected group entry size {e}")
    for i in range(n):
        p = base + o + i * e
        t["groups"].append(dict(name=cstr(blob[p: p + 36]), flags=struct.unpack_from("<I", blob, p + 36)[0], max=struct.unpack_from("<Q", blob, p + 40)[0]))
    o, n, e = h["desc"]["extents"]
    if e != 24:
        raise Unsupported(f"unexpected extent entry size {e}")
    for i in range(n):
        p = base + o + i * e
        ns, tt, td, ts = struct.unpack_from("<QIQI", blob, p)
        t["extents"].append(dict(sectors=ns, type=tt, data=td, src=ts))
    o, n, e = h["desc"]["partitions"]
    if e != 52:
        raise Unsupported(f"unexpected partition entry size {e}")
    for i in range(n):
        p = base + o + i * e
        name = cstr(blob[p: p + 36]); attrs, fe, ne, gi = struct.unpack_from("<IIII", blob, p + 36)
        exts = t["extents"][fe: fe + ne]
        t["partitions"].append(dict(name=name, attrs=attrs, group=t["groups"][gi]["name"] if gi < len(t["groups"]) else f"#{gi}",
                                   size=sum(x["sectors"] for x in exts) * 512, extents=[(x["data"], x["sectors"], x["type"]) for x in exts]))
    return t


def load(path):
    head = read_head(path)
    g = parse_geometry(head)
    first = None
    for kind, slot, off in metadata_offsets(g):
        h = parse_header(head[off: off + g["max"]])
        if h:
            first = (kind, slot, off, h)
            break
    if not first:
        raise Unsupported("no valid LP metadata header found")
    kind, slot, off, h = first
    if h["major"] != 10:
        raise Unsupported(f"LP metadata major version {h['major']} (only 10.x is understood)")
    tables = parse_tables(head[off: off + g["max"]], h)
    return head, g, h, tables


def analysis(path):
    head, g, h, t = load(path)
    if len(t["block_devices"]) != 1:
        raise Unsupported(f"{len(t['block_devices'])} block devices (retrofit dynamic partitions): not supported")
    bd = t["block_devices"][0]
    if bd["name"] != "super":
        raise Unsupported(f"block device is called '{bd['name']}', expected 'super'")
    gsum = {}
    for p in t["partitions"]:
        gsum[p["group"]] = gsum.get(p["group"], 0) + p["size"]
    used_all = sum(gsum.values())
    biggest_slot = max([v for k, v in gsum.items() if k != "default"] or [0])
    overheads = [bd["size"] - x["max"] for x in t["groups"] if x["max"]]
    overhead = overheads[0] if overheads and all(o == overheads[0] for o in overheads) and 0 < overheads[0] < 64 * MIB else None
    reserved = bd["first_sector"] * 512
    return dict(geometry=g, version=f"{h['major']}.{h['minor']}", flags=h["flags"], block_device=bd, groups=t["groups"], group_sum=gsum,
                partitions=t["partitions"], used=used_all, used_largest_slot=biggest_slot, overhead=overhead, reserved=reserved,
                minimum=reserved + used_all, virtual_ab=bool(h["flags"] & 1))


def suggest_gib(a):
    # headroom: +30 % over what the ROM uses, at least 1 GiB more than the ROM needs, never below the current size, whole GiB
    need = max(a["block_device"]["size"], int(a["minimum"] * 1.30), a["minimum"] + GIB)
    return int(math.ceil(need / GIB))


def fmt(n):
    return f"{n} ({n / GIB:.3f} GiB)"


def cmd_info(path):
    a = analysis(path)
    g = a["geometry"]
    print(f"LP metadata v{a['version']}  slots={g['slots']}  metadata_max_size={g['max']}  logical_block_size={g['lbs']}  geometry_checksum_ok={g['ok']}  virtual_ab_flag={a['virtual_ab']}")
    bd = a["block_device"]
    print(f"block device '{bd['name']}': first_sector={bd['first_sector']} ({bd['first_sector'] * 512 // MIB} MiB reserved)  size={fmt(bd['size'])}")
    for x in a["groups"]:
        print(f"group '{x['name']}': max={fmt(x['max']) if x['max'] else 'unlimited'}  used={fmt(a['group_sum'].get(x['name'], 0))}")
    print("partitions:")
    for p in a["partitions"]:
        print(f"  {p['name']:<18} group={p['group']:<26} size={fmt(p['size'])}  extents={len(p['extents'])}{'  (empty)' if not p['size'] else ''}")
    print(f"total used by partitions: {fmt(a['used'])}")


def cmd_check(path, want_gib=None):
    problems, notes = [], []
    try:
        a = analysis(path)
    except Unsupported as e:
        print(f"UNSUPPORTED: {e}")
        return 2
    except Exception as e:  # noqa
        print(f"UNREADABLE: {e}")
        return 2
    g = a["geometry"]
    if not g["ok"]:
        problems.append("geometry checksum is wrong")
    if g["lbs"] != 4096:
        notes.append(f"logical_block_size is {g['lbs']} (4096 expected on peridot)")
    head = read_head(path)
    good = bad = 0
    for kind, slot, off in metadata_offsets(g):
        h = parse_header(head[off: off + g["max"]])
        if not h:
            continue
        if h["tables_ok"] and h["header_ok"]:
            good += 1
        else:
            bad += 1
    if bad:
        problems.append(f"{bad} metadata copies have bad checksums")
    if a["overhead"] is None:
        notes.append("the groups' maximum sizes do not follow 'device size minus a small overhead'; group limits will be left unchanged")
    bd = a["block_device"]
    cur = bd["size"]
    sug = suggest_gib(a)
    print(f"image            : {os.path.basename(path)}  ({'sparse' if is_sparse(path) else 'raw'}, logical size {fmt(logical_size(path))})")
    print(f"LP metadata      : v{a['version']}, {g['slots']} slots, {good} valid copies, Virtual A/B flag: {a['virtual_ab']}")
    print(f"super device     : {fmt(cur)} in this ROM")
    for x in a["groups"]:
        used = a["group_sum"].get(x["name"], 0)
        if x["max"] or used:
            lim = f"{x['max'] / GIB:.3f} GiB" if x["max"] else "none"
            print(f"  group {x['name']:<26} used {used / GIB:6.3f} GiB   limit {lim}")
    print(f"used by partitions: {fmt(a['used'])}   (largest single slot: {a['used_largest_slot'] / GIB:.3f} GiB)")
    print(f"free in this ROM's super: {(cur - a['reserved'] - a['used']) / GIB:.3f} GiB")
    print(f"minimum possible : {fmt(a['minimum'])}")
    print(f"suggested size   : {sug} GiB  (ROM + 30 % headroom, whole GiB, not below today's size)")
    if want_gib is not None:
        want = int(want_gib * GIB)
        if want <= cur:
            problems.append(f"{want_gib} GiB is not larger than the ROM's own super ({cur / GIB:.3f} GiB): only growing is supported")
        if want < a["minimum"]:
            problems.append(f"{want_gib} GiB is smaller than what the partitions need ({a['minimum'] / GIB:.3f} GiB)")
        if want % MIB:
            problems.append("the size must be a whole number of MiB")
        if not problems:
            print(f"requested size   : {want_gib} GiB -> OK")
    for n_ in notes:
        print("NOTE:", n_)
    for p in problems:
        print("PROBLEM:", p)
    print("VERDICT          :", "OK, this image can be resized" if not problems else "NOT OK")
    return 0 if not problems else 1


def patch_metadata(head, new_bytes):
    g = parse_geometry(head)
    if not g["ok"]:
        raise Unsupported("geometry checksum invalid in the input image")
    head = bytearray(head)
    old = None; overhead = None; patched = 0
    for kind, slot, off in metadata_offsets(g):
        blob = bytes(head[off: off + g["max"]])
        h = parse_header(blob)
        if not h:
            continue
        if not (h["tables_ok"] and h["header_ok"]):
            raise Unsupported(f"{kind} slot {slot}: checksum bad before patching")
        tb = bytearray(blob[h["hsz"]: h["hsz"] + h["tsz"]])
        o, n, e = h["desc"]["block_devices"]
        if e != 64 or n != 1:
            raise Unsupported("expected exactly one 64-byte block device entry")
        if cstr(bytes(tb[o + 24: o + 60])) != "super":
            raise Unsupported("block device 'super' not found")
        cur = struct.unpack_from("<Q", tb, o + 16)[0]
        if old is None:
            old = cur
        if cur != old:
            raise Unsupported("metadata copies disagree about the super size")
        struct.pack_into("<Q", tb, o + 16, new_bytes)
        go, gn, ge = h["desc"]["groups"]
        for i in range(gn):
            p = go + i * ge
            mx = struct.unpack_from("<Q", tb, p + 40)[0]
            if mx == 0:
                continue
            ov = old - mx
            if 0 < ov < 64 * MIB:
                overhead = ov if overhead is None else overhead
                struct.pack_into("<Q", tb, p + 40, new_bytes - ov)
            # an unusual group limit is left alone: still valid, just not enlarged
        nb = bytearray(blob[: h["hsz"]])
        nb[48:80] = hashlib.sha256(bytes(tb)).digest()
        nb[12:44] = b"\0" * 32
        nb[12:44] = hashlib.sha256(bytes(nb)).digest()
        head[off: off + h["hsz"]] = nb
        head[off + h["hsz"]: off + h["hsz"] + h["tsz"]] = tb
        patched += 1
    if patched < 2 or old is None:
        raise Unsupported("fewer than two metadata copies could be patched")
    return bytes(head), dict(old=old, overhead=overhead, copies=patched)


def resize(src, dst, gib):
    new_bytes = int(gib * GIB)
    if new_bytes % 4096:
        raise Unsupported("size must be a multiple of 4096 bytes")
    a = analysis(src)
    if new_bytes <= a["block_device"]["size"]:
        raise Unsupported("new size must be larger than the current one (shrinking is not supported)")
    if new_bytes < a["minimum"]:
        raise Unsupported("new size is smaller than what the partitions need")
    head = read_head(src)
    new_head, info = patch_metadata(head, new_bytes)
    if not is_sparse(src):
        with open(src, "rb") as fi, open(dst, "wb") as fo:
            fo.write(new_head)
            fi.seek(len(new_head))
            while True:
                b = fi.read(8 * MIB)
                if not b:
                    break
                fo.write(b)
            fo.truncate(new_bytes)
        return info
    with open(src, "rb") as fi:
        h = sparse_header(fi)
        blk = h["blk"]
        add = new_bytes // blk - h["tblks"]
        if add <= 0:
            raise Unsupported("sparse image already covers the new size")
        with open(dst, "wb") as fo:
            fo.write(struct.pack("<IHHHHIIII", SPARSE_MAGIC, 1, 0, h["fhs"], h["chs"], blk, new_bytes // blk, h["tchunks"] + 1, 0))
            fi.seek(h["fhs"])
            pos_blk = 0
            for _ in range(h["tchunks"]):
                ch = fi.read(12)
                ctype, rsv, csz, tsz = struct.unpack("<HHII", ch)
                fo.write(ch)
                body = tsz - 12
                if ctype == CH_RAW:
                    data = bytearray(fi.read(body))
                    s = pos_blk * blk
                    if s < SCAN:
                        n = min(len(data), SCAN - s)
                        data[:n] = new_head[s: s + n]
                    fo.write(data)
                else:
                    fo.write(fi.read(body))
                pos_blk += csz
            if pos_blk != h["tblks"]:
                raise Unsupported("sparse chunk sizes do not add up")
            fo.write(struct.pack("<HHII", CH_DONT_CARE, 0, add, 12))
    return info


def verify(path, gib, original=None):
    new_bytes = int(gib * GIB)
    head = read_head(path)
    g = parse_geometry(head)
    if not g["ok"]:
        raise AssertionError("geometry checksum bad")
    good = 0
    for kind, slot, off in metadata_offsets(g):
        blob = head[off: off + g["max"]]
        h = parse_header(blob)
        if not h:
            continue
        assert h["tables_ok"] and h["header_ok"], f"{kind} {slot}: checksum bad"
        o, n, e = h["desc"]["block_devices"]
        for i in range(n):
            size = struct.unpack_from("<Q", blob, h["hsz"] + o + i * e + 16)[0]
            assert size == new_bytes, f"{kind} {slot}: block device size {size} != {new_bytes}"
        good += 1
    assert good >= 2, "fewer than two valid metadata copies"
    assert logical_size(path) == new_bytes, "image logical size mismatch"
    if original:
        a0 = analysis(original); a1 = analysis(path)
        assert [(p["name"], p["group"], p["size"], p["extents"]) for p in a0["partitions"]] == [(p["name"], p["group"], p["size"], p["extents"]) for p in a1["partitions"]], "partition table changed"
    print(f"verify OK: {good} metadata copies valid, super size = {new_bytes} bytes ({gib} GiB){', partition table identical to the original' if original else ''}")


def cmd_match(device_head, img):
    """Same ROM? Compare the big system-like partitions (names + sizes); *_dlkm are ignored because custom kernels change them."""
    def key(path):
        a = analysis(path)
        return {p["name"]: p["size"] for p in a["partitions"] if p["size"] and "dlkm" not in p["name"]}
    try:
        d = key(device_head); r = key(img)
    except Unsupported as e:
        print(f"UNKNOWN: {e}")
        return 2
    diff = [(k, d.get(k), r.get(k)) for k in sorted(set(d) | set(r)) if d.get(k) != r.get(k)]
    if not diff:
        print(f"MATCH: the phone's super and the ROM have the same {len(r)} partitions with identical sizes")
        return 0
    print("DIFFERENT: the ROM does not look like the one installed on the phone")
    for k, a, b in diff[:12]:
        print(f"  {k}: phone={a} rom={b}")
    return 1


if __name__ == "__main__":
    a = sys.argv[1:]
    try:
        if len(a) == 2 and a[0] == "info":
            cmd_info(a[1])
        elif len(a) in (2, 3) and a[0] == "check":
            sys.exit(cmd_check(a[1], float(a[2]) if len(a) == 3 else None))
        elif len(a) == 2 and a[0] == "suggest":
            print(suggest_gib(analysis(a[1])))
        elif len(a) == 4 and a[0] == "resize":
            info = resize(a[1], a[2], float(a[3]))
            print(f"resized: {info['old']} -> {int(float(a[3]) * GIB)} bytes; patched {info['copies']} metadata copies; group overhead kept at {info['overhead']}")
            verify(a[2], float(a[3]), original=a[1])
        elif len(a) == 3 and a[0] == "verify":
            verify(a[1], float(a[2]))
        elif len(a) == 3 and a[0] == "match":
            sys.exit(cmd_match(a[1], a[2]))
        else:
            print(__doc__)
            sys.exit(2)
    except Unsupported as e:
        print(f"UNSUPPORTED: {e}", file=sys.stderr)
        sys.exit(2)
    except AssertionError as e:
        print(f"VERIFY FAILED: {e}", file=sys.stderr)
        sys.exit(1)
