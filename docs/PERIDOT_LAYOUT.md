# Stock partition layout of peridot (`sda`)

> **Storage variants.** The phone is sold with different UFS sizes (128 / 256 / 512 GB class). The numbers below were measured on a **256 GB-class** phone (236.3 GiB `sda`).
> On the other variants `sda` has a different total size, so `userdata` is larger or smaller and the backup GPT sits elsewhere. Everything in front of `userdata` (including `super` at sector 208896) is laid out by the ROM package in the same way,
> because `userdata` is defined as "the rest of the disk" (`size 0` in `rawprogram0.xml`). The scripts never use these numbers: they read the real positions from the phone, check that `userdata` is the last partition and fills the disk,
> and refuse to restore a backup onto a disk of a different size. **A backup always belongs to the one phone it was taken from.**

Taken with `sgdisk --print /dev/block/sda` on a POCO F6 (peridot) running the factory eng ROM `FACTORY-PERIDOT-24.4.17_14.0`. The raw output is in
[`examples/print_sda_stock_layout.txt`](../examples/print_sda_stock_layout.txt) (the disk GUID line was removed because it identifies one specific device).

- Disk: 61 949 952 sectors of **4096 bytes** = 236.3 GiB, 31 partitions, no free space.
- First usable sector 6, last usable sector 61 949 946.

The two partitions that these tools resize:

| # | Name | First sector | Last sector | Size |
|---|---|---|---|---|
| 30 | `super` | 208 896 | 2 437 119 | 8.5 GiB |
| 31 | `userdata` | 2 437 120 | 61 949 946 | 227.0 GiB |

Sector arithmetic used by `part_resize.sh` (4096-byte sectors):

```
sectors of the new super  = GiB * 1024^3 / 4096          (12 GiB -> 3 145 728)
super last sector         = super first sector + sectors - 1     (12 GiB -> 3 354 623)
userdata first sector     = super last sector + 1                (-> 3 354 624)
userdata last sector      = unchanged (end of disk)
```

Dynamic partitions inside the stock `super` (metadata version 10.2, 3 slots, `metadata_max_size` 65 536 bytes, Virtual A/B):
`odm_a`, `product_a`, `system_a`, `system_dlkm_a`, `system_ext_a`, `vendor_a`, `vendor_dlkm_a` (and the empty `_b` counterparts) in the groups
`qti_dynamic_partitions_a` / `qti_dynamic_partitions_b`; both groups have a maximum size of 9 116 319 744 bytes = the 9 126 805 504-byte device size minus 10 MiB.

Other storage units: `sdb`, `sdc` (12 MiB each), `sdd` (8 MiB), `sde` (about 1.9 GiB, firmware such as `abl`, modem, ...), `sdf` (64 MiB). They are only backed up, never written.

Your phone's numbers may differ if it runs a different ROM/firmware build; the scripts read the real values from the live table and stop when the layout is not the one they understand.

## What the two tested ROMs put into `super`

Both packages define the same 33 partitions on `sda` (identical positions and sizes); only their `super.img` content differs. Sizes are the bytes of each logical partition in slot `_a`:

| partition | factory engineering ROM (Android 14) | retail HyperOS `OS3.0.303.0.WNPINXM` (Android 16) |
|---|---|---|
| `odm_a` | in 14 partitions, 3.862 GiB total | 1.784 GiB |
| `product_a` | | 3.185 GiB |
| `system_a` | | 0.668 GiB |
| `system_ext_a` | | 0.587 GiB |
| `vendor_a` | | 0.400 GiB |
| `mi_ext_a` | *(not present)* | 0.642 GiB |
| `system_dlkm_a`, `vendor_dlkm_a` | (small) | 0.014 / 0.028 GiB |
| **total used** | **3.862 GiB** | **7.309 GiB** |
| LP metadata | v10.2, 3 slots, 64 KiB each, device 8.5 GiB, groups `qti_dynamic_partitions_a/_b` limit 8.490 GiB | identical |
| anti-rollback (`anti_version.txt`) | 1 | 1 |

(The per-partition split of the engineering ROM is shown by `python3 scripts/lp_resize.py info <super.img>`.) The HyperOS image fits the stock 8.5 GiB with only 1.19 GiB to spare, which is the practical reason for enlarging `super`.
