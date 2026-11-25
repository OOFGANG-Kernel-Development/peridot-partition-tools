# What has been tested (and what has not)

Honesty table, so nobody has to guess. Phone: one POCO F6 (peridot), factory engineering ROM `FACTORY-PERIDOT-24.4.17_14.0`, 2026-11-25.

| Item | How | Result |
|---|---|---|
| Resize 8.5 -> 12 GiB with the **v1** scripts (`--execute`) | real phone | Android booted; `lpdump`/`sgdisk`/`df` show 12 GiB / 223.5 GiB. First run left the phone in recovery (flag in `misc`): fixed |
| Restore to the original table + factory `super` with the v1 scripts (`--execute --flash-factory`) | real phone | table back (equals backup), Android booted, original sizes |
| Resize again with the v1 final scripts (`--execute`) | real phone | OK, booted, 12 GiB |
| `lp_resize.py` metadata patch vs Android `lpdump` | factory and 12 GiB image heads | only the size/limit lines differ, all partitions identical |
| `lp_resize.py` v2: `info`, `check`, `suggest`, `resize`, `verify` | factory ROM and retail HyperOS 3.0 ROM (files only) | correct on both; error cases (not a super, shrinking) refused |
| `rom_check.sh` | retail HyperOS ROM, no phone | OK, suggests 10 GiB |
| **v2** `part_backup.sh`, `part_resize.sh` (normal mode, dry run and `--execute`), `--reflash-only`, `part_restore.sh` | needs a phone | **not yet run as v2** (a first v2 backup attempt in Android found that Android has no `/tmp`: fixed with a per-phone scratch folder). Run the checklist below before trusting them |
| Retail ROM installed on the phone, then `--reflash-only` | needs a phone with that ROM | **never tested** |
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
