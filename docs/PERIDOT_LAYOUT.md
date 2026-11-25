# Stock partition layout of peridot (`sda`)

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
