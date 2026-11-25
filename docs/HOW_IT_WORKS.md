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

## 4. What `part_resize.sh --execute` does, step by step

1. Checks the preconditions: a backup exists (two copies), the factory `super.img` exists, the phone is in **recovery**, it is a peridot, the sector size is 4096.
2. Compares the **live** partition table with your backup. If anything differs, it stops.
3. Reads the real positions of `super` and `userdata` and their GUIDs from the live table (by name, nothing is hard-coded), checks that `userdata` starts right after `super`.
4. Builds the resized `super` image and **dry-runs** the new table with `sgdisk --pretend` (it never writes in this step).
5. Writes the new GPT with Android's `sgdisk` (in recovery, so nothing from `super`/`userdata` is mounted), reads the table back and checks it.
6. Reboots to the **bootloader** and flashes: `super` (new image), erases `metadata`, flashes `userdata` (the factory one, small, Android grows it on first boot).
7. Boots and prints `lpdump`, `sgdisk --print` and `df /data` so you can see the new sizes.

`userdata` is recreated because its start moved: whatever was on the old `userdata` no longer lines up with the new table, so the contents are lost. That is why a backup of **your files** is needed before anything else.
The earlier partition-table backup does **not** contain your files; it only contains the table.

## 5. Why recovery, why the real `sgdisk`

- In recovery nothing is mounted from `super` or `userdata`, so there is no running system that could be confused by a table change.
- Android's own `sgdisk` is a well-tested tool that writes both the main and the backup GPT with correct CRCs. The scripts only give it the numbers.
- Recovery images normally do not ship `sgdisk`, so `pull_sgdisk.sh` copies it (and `libext2_uuid.so`, `libc++.so`) from your phone's own system before the first run.

## 6. What is **not** touched

- Bootloader chain (`xbl`, `abl`, `tz`, `hyp`, `aop`, ...): different LUNs, never written by these scripts.
- All other partitions (`boot_a/b`, `vendor_boot_a/b`, `dtbo`, `vbmeta`, `persist`, `misc`, `metadata`, ...) keep their position and size: they all sit *before* `super`. Only `super` (grows) and `userdata` (starts later, becomes empty) change.
- Calibration data in `persist` etc. stays as it is.

## 7. Limits

See the README: growing only, stock neighbour layout only, 4096-byte sectors only, peridot only.
