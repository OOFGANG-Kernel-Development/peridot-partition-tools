# What has been tested (and what has not)

Honesty table, so nobody has to guess. Phone: one POCO F6 (peridot), factory engineering ROM `FACTORY-PERIDOT-24.4.17_14.0`, 2026-11-25.

| Item | How | Result |
|---|---|---|
| Resize 8.5 -> 12 GiB with the **v1** scripts (`--execute`) | real phone | Android booted; `lpdump`/`sgdisk`/`df` show 12 GiB / 223.5 GiB. First run left the phone in recovery (flag in `misc`): fixed |
| Restore to the original table + factory `super` with the v1 scripts (`--execute --flash-factory`) | real phone | table back (equals backup), Android booted, original sizes |
| Resize again with the v1 final scripts (`--execute`) | real phone | OK, booted, 12 GiB |
| `lp_resize.py` metadata patch vs Android `lpdump` | factory and 12 GiB image heads | only the size/limit lines differ, all partitions identical |
| `lp_resize.py` v2: `info`, `check`, `suggest`, `resize`, `verify` | factory ROM and retail HyperOS `OS3.0.303.0.WNPINXM` ROM (files only) | correct on both; error cases (not a super, shrinking) refused |
| `rom_check.sh` | retail HyperOS ROM, no phone | OK, suggests 10 GiB |
| **v2** `part_backup.sh`, `part_resize.sh` (normal mode, dry run and `--execute`), `--reflash-only`, `part_restore.sh` | needs a phone | **not yet run as v2** (a first v2 backup attempt in Android found that Android has no `/tmp`: fixed with a per-phone scratch folder). Run the checklist below before trusting them |
| Retail ROM (`OS3.0.303.0.WNPINXM`) flashed with its `flash_all`, then `--reflash-only --super-gib 12` (dry run, then `--execute`) on the 12 GiB table | real phone, bootloader only | dry run OK (bootloader reported `partition-size:super` = 12 GiB); the 12 GiB HyperOS `super` was built (6/6 metadata copies valid) and flashed without errors. **HyperOS booted from it**: Android 16 (sdk 36), kernel 6.1.138-android14-11, `/data` 224 GiB, `system_a/vendor_a/product_a/odm_a/mi_ext_a/system_ext_a` and the dlkm partitions mapped and mounted. The script itself reported `Android is up` and exited 0 (this was the first real `--execute` of the v2 `--reflash-only` path) |
| **Custom recovery on the retail HyperOS ROM** (root `uid 0`, `ro.debuggable=1`, native `sgdisk` and `lpdump`, slot `_a`) | real phone | `lpdump` of the booted-from-`--reflash-only` HyperOS: block device **12884901888 bytes (12 GiB)**, groups 12874416128, partitions `odm_a product_a system_a system_ext_a vendor_a mi_ext_a`. `part_backup.sh` (6 LUNs, second copy verified) OK. `part_resize.sh --factory <HyperOS> --super-gib 14` **dry run**: all checks OK, ROM match = `same ROM`, plan `super` 14 GiB / `userdata` 221.5 GiB. Refusals verified: wrong ROM (engineering ROM against the installed HyperOS: `DIFFERENT`, refused), size not larger (`Only growing is supported`), missing backup. **Real `--execute` of the normal mode on HyperOS: not run** |
| **KernelSU root in Android** (`su` granted to Shell; `adb shell su -c id` = uid 0, context `u:r:ksu:s0`) | real phone, HyperOS | `su` wrapper verified: detection (`SU=1`), quoting incl. apostrophes/pipes/redirects, native `sgdisk`, binary-safe disk dump, pull of a root-made file; `part_backup.sh` (6 LUNs, second copy verified) and `part_resize.sh --allow-android` dry run (14 GiB) all OK, `same ROM` |
| Retail ROM stock recovery | real phone | `adb shell` works but uid 2000, `adb root` refused, disk root-only, no `su`: the script stops with a clear message and changes nothing (also found and fixed: `fastboot version` is not a command and hung the script when the phone was not in the bootloader) |
| Other storage variants (128 GB, 512 GB) | - | **never tested** (tested on a 256 GB-class phone only). The scripts read sizes from the phone and refuse layouts they do not understand; see PERIDOT_LAYOUT.md |
| Linux / macOS hosts | - | never tested |
| Other devices | - | never tested; refused by design |

## Checklist to test a change on a phone you can lose

1. `bash scripts/rom_check.sh <ROM>` - no phone.
2. Phone in Android with root adb: `part_backup.sh` (read only) - verify the second copy and `SHA256.txt`.
3. Recovery: `part_resize.sh --factory <ROM>` (dry run, all lines OK, `DRY RUN ONLY`).
4. Try the refusals: a wrong ROM (`ROM differs`), `--super-gib` smaller than today (`only growing`), no backup (rename the backup folder), phone in Android without `--allow-android`.
5. `part_resize.sh ... --execute`, answer `ERASE`; check the printed `lpdump`/`df`; reboot once more and check that Android still boots (not recovery).
6. `part_restore.sh` dry run, then `--execute --flash-factory`; check again.
7. Bootloader only: `part_resize.sh --factory <ROM> --super-gib <N> --reflash-only` (dry run, then `--execute`).
