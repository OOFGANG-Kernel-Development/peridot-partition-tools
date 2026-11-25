# How it works

A short, beginner-friendly explanation of what the scripts really do, so you can judge the risks yourself.

## 1. The phone's storage

The phone uses **UFS** storage. Android sees it as six separate disks called **LUNs**: `sda` ... `sdf`.
Most of the user-visible partitions (`super`, `userdata`, `metadata`, `boot_a`, `vendor_boot_a`, ...) live on `sda` (about 236 GiB, **4096-byte sectors**).
The bootloader chain (`xbl`, `abl`, `tz`, ...) lives on the other LUNs. The scripts only ever change `sda`; the other LUNs are only backed up.

Each disk starts with a **GPT** (GUID Partition Table): a small table (a few sectors at the beginning, and a second copy at the very end) that says
"partition number N is called X, starts at sector A and ends at sector B". The partitions themselves are just ranges of sectors, so
**changing the GPT does not move or copy any data**. It only changes where each partition is considered to start and end.

Stock layout of the two partitions that matter (see [PERIDOT_LAYOUT.md](PERIDOT_LAYOUT.md)):

```
 ... | rescue | super (8.5 GiB)             | userdata (227 GiB) |   <- end of disk
              ^ sector 208896                ^ sector 2437120
```

## 2. What `super` is

`super` is one big partition that holds the *dynamic partitions*: `system`, `system_ext`, `product`, `vendor`, `odm`, `vendor_dlkm`, `system_dlkm` (each for slots `_a` and `_b`).
Inside `super`, Android keeps its own small table called the **LP metadata** (logical partition metadata):

- the **geometry** (where the metadata sits, how many slots),
- six copies of the metadata (3 "primary" + 3 "backup" slots, all at the **start** of `super`),
- for each logical partition a list of **extents** ("sectors X..Y of super"),
- the **size of the block device** (the physical `super` partition) and the **maximum size of each group** (`qti_dynamic_partitions_a/_b`).

This phone is **Virtual A/B**: the slot `_a` partitions hold the system, the `_b` ones are empty.

## 3. Why growing `super` is mostly a metadata job

If `super` just gets a bigger partition range **starting at the same sector**, every extent inside it is still valid (extents are offsets from the start of `super`).
Only three things must change inside the LP metadata so that Android understands the new size:

1. the block-device `size` of `super`,
2. the `maximum_size` of the two groups (the stock value is the device size minus 10 MiB; the same 10 MiB is kept),
3. the checksums (a SHA-256 over the tables and one over the header) of **all six** metadata copies.

`scripts/lp_resize.py` does exactly this on the factory `super.img` (an Android *sparse* image), and then appends an empty "don't care" chunk so the image covers the new, bigger size.
The system/vendor/... data inside the image is not touched, byte for byte. The script verifies every checksum again after writing, and you can cross-check with Android's own
`lpdump`: in our test the output for the original and the resized image differed **only** in the three size lines.

## 4. How the tool decides what to do (it reads, then acts)

`scripts/lp_resize.py check` opens the ROM's `super.img` (sparse or raw) and decodes the LP metadata completely: the block device, the groups and **every partition with its extents**. From that it knows
what the ROM really needs and prints it, for example for the two tested ROMs:

| ROM | partitions in `super` | used by slot `_a` | free in its own 8.5 GiB | suggested size |
|---|---|---|---|---|
| factory engineering ROM (Android 14) | 14 | 3.9 GiB | 4.6 GiB | 9 GiB |
| retail HyperOS `OS3.0.303.0.WNPINXM` (Android 16) (package label 16.0) | 16 (adds `mi_ext_a`) | 7.3 GiB | 1.2 GiB | 10 GiB |

The suggestion is `used + 30 %`, at least 1 GiB above what the partitions need, never below today's size, rounded up to a whole GiB. On a **Virtual A/B** phone like peridot only slot `_a` holds data (the `_b` partitions are 0 bytes);
OTA updates keep their snapshot data in `userdata`, so `super` does not have to be twice the ROM.

## 5. What `part_resize.sh --execute` does, step by step

1. **ROM package**: `super.img` and `userdata.img` present, not a split image, `lp_resize.py check` says OK for the chosen size, enough disk space on the PC and in the Windows staging folder.
2. **Phone**: in recovery, root adb works, it is a peridot, battery at least 50 %, `super` found on its disk, sector size 4096.
3. **Live table**: `super` and `userdata` are read by *name* (positions, GUIDs, type codes); `userdata` must start directly after `super`; the new size must be larger and leave at least 1 GiB for `userdata`.
4. **Backup**: a backup exists in two places and equals the live table (otherwise: stop).
5. **ROM match**: the first MiB of the phone's real `super` is read and compared with the ROM image (names and sizes of the non-`*_dlkm` partitions). A different ROM is refused, because only `super`/`userdata` are replaced and the firmware/boot images would not fit.
6. **Plan**: `sgdisk --pretend` computes the new table; nothing is written. Without `--execute` the script ends here.
7. You must **type `ERASE`**. Then the resized `super` image is built and verified (all 6 metadata copies, partition table unchanged), the new GPT is written and read back.
8. The recovery flag in `misc` is cleared, the phone reboots to the bootloader. There: product must be peridot, anti-rollback must not be higher than the ROM's, then `super` is flashed, `metadata` erased, `userdata` flashed, the phone reboots.
9. It waits for a **real Android boot** (adb state `device` and `sys.boot_completed=1`; recovery does not count) and prints `lpdump`, `df`.

`userdata` is recreated because its start moved: the old contents no longer line up with the new table. The partition-table backup contains **no personal files**.

### `--reflash-only` (bootloader only)

When the table already has the size you want (for example after you changed ROM with its own `flash_all`), the tool skips the table: it asks the bootloader for `partition-size:super`, requires it to equal the requested size, builds the matching `super` for the new ROM and flashes it.
It needs no adb and no recovery, which is why it works with retail ROMs.

## 6. Why recovery, why the real `sgdisk`

- In recovery nothing is mounted from `super` or `userdata`, so there is no running system that could be confused by a table change.
- Android's own `sgdisk` is a well-tested tool that writes both the main and the backup GPT with correct CRCs. The scripts only give it the numbers.
- Recovery images normally do not ship `sgdisk`, so `pull_sgdisk.sh` copies it (and `libext2_uuid.so`, `libc++.so`) from your phone's own system before the first run.

## 7. What is **not** touched

- Bootloader chain (`xbl`, `abl`, `tz`, `hyp`, `aop`, ...): different LUNs, never written by these scripts.
- All other partitions (`boot_a/b`, `vendor_boot_a/b`, `dtbo`, `vbmeta`, `persist`, `misc`, `metadata`, ...) keep their position and size: they all sit *before* `super`. Only `super` (grows) and `userdata` (starts later, becomes empty) change.
- Calibration data in `persist` etc. stays as it is.

## 8. Limits

See the README: growing only, stock neighbour layout only, 4096-byte sectors only, peridot only.
