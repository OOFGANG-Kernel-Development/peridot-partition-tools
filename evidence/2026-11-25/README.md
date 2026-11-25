# Evidence: the partition tools were run on a real phone (2026-11-25)

Raw logs of the real runs, so the claims in the [README](../../README.md) and [docs/TESTING.md](../../docs/TESTING.md) can be checked instead of trusted.
**One** POCO F6 (peridot, 256 GB-class), two ROMs (factory engineering ROM `FACTORY-PERIDOT-24.4.17_14.0`, retail HyperOS `OS3.0.303.0.WNPINXM`).

> The logs were **scrubbed** before publishing: your own folders became `$HOME` / `<download-folder>`, the phone's serial became `<device-serial>`, and disk/partition GUIDs were removed.
> Nothing else was edited: timestamps, command output, errors and refusals are as the scripts printed them.

## What the evidence shows

1. **A real resize works**: `super` was grown on the phone and the phone booted from it (steps 1 and 3 below), checked independently with Android's own `lpdump` and `sgdisk` read from a recovery (`raw_captures/`).
2. **The restore works**: the original table was written back from the backup and equalled it, then the ROM's own `super` was flashed and the phone booted (step 2).
3. **The safety checks refuse** wrong ROM, size not larger, missing backup, no root, no phone: each stopped with a clear message and **changed nothing**.
4. **Bugs were found by these runs and fixed** (listed in [docs/TESTING.md](../../docs/TESTING.md)); the logs of the failing runs are kept, not deleted.

## The round trip (in order)

| Step | Command (summarised) | Result | Log |
|---|---|---|---|
| start | table `super` 12 GiB / `userdata` 223.5 GiB, retail HyperOS installed | - | - |
| 1 | `part_resize.sh --super-gib 14 --execute` (custom recovery, root) | `super` 14 GiB; HyperOS booted; `lpdump` 15032385536 bytes | `script_logs/part_resize_20261125_061554.txt` |
| 2 | `part_restore.sh --execute --flash-factory` (from the backup taken before step 1) | table back to 12 GiB, equal to backup; ROM's own 8.5 GiB `super` flashed; HyperOS booted | `script_logs/part_restore_20261125_063148.txt` |
| 3 | `part_resize.sh --super-gib 12 --reflash-only --execute` | 12 GiB `super` flashed from the bootloader; HyperOS booted | `script_logs/part_resize_20261125_064538.txt` |
| end | final state read from the recovery | `super` 12884901888 bytes (12 GiB), groups 12874416128, table 12.0 / 223.5 GiB, `misc` empty | `raw_captures/final_state_recovery_root.txt`, `raw_captures/final_state_android.txt` |

An earlier round trip with the **first version** of the scripts (restore to the original layout, then resize to 12 GiB, factory engineering ROM) is in `first_round_trip_v1/`.

## Every script log, in time order

| Time (clock of the PC the scripts ran on, 2026-11-25) | What it is | Outcome | File | What it shows |
|---|---|---|---|---|
| 2026-11-25 05:38:47 | backup (read-only) | refused: backup of sda looks empty (gpt_sda.sgdisk) | `script_logs/part_backup_20261125_053847.txt` | First v2 backup in **Android**: refused because the table dump could not be saved (Android has no `/tmp`). The backup script refused to produce an empty backup. Bug fixed afterwards. |
| 2026-11-25 05:39:09 | backup (read-only) | refused: no phone in adb mode (state 'none'). Boot Android or recovery and check 'adb devices'. | `script_logs/part_backup_20261125_053909.txt` | Run while the phone was being re-flashed by hand (no adb): clean refusal. |
| 2026-11-25 06:09:06 | backup (read-only) | Backup done, second copy verified | `script_logs/part_backup_20261125_060906.txt` | Backup in the custom recovery (root): 6 storage units, second copy verified. |
| 2026-11-25 06:12:38 | backup (read-only) | Backup done, second copy verified | `script_logs/part_backup_20261125_061238.txt` | Backup in Android through KernelSU `su` (root granted to the Shell app): 6 units, second copy verified. |
| 2026-11-25 05:46:14 | reflash-only: dry run | all checks passed, nothing changed | `script_logs/part_resize_20261125_054614.txt` | `--reflash-only` dry run, phone in the bootloader: bootloader reported `partition-size:super` = 12 GiB. |
| 2026-11-25 05:46:26 | reflash-only: EXECUTED | 'super' partition exactly the requested size; flashed; Android is up | `script_logs/part_resize_20261125_054626.txt` | **Real run**: 12 GiB build of the retail HyperOS `super` flashed from the bootloader; HyperOS booted. |
| 2026-11-25 05:56:26 | resize: aborted/killed by me | no result (run was stopped; see TESTING.md) | `script_logs/part_resize_20261125_055626.txt` | A dry run I started while the phone was in recovery; it hung on a bad tool check (`fastboot version`), I killed it and fixed the check. |
| 2026-11-25 05:57:57 | resize: REFUSED (safety check) | no root adb | `script_logs/part_resize_20261125_055757.txt` | Dry run against the **stock retail recovery**: `adb shell` is not root, so the script stopped and **changed nothing** ("Nothing was changed on the phone"). |
| 2026-11-25 06:09:16 | resize: dry run | all checks passed, nothing changed | `script_logs/part_resize_20261125_060916.txt` | Resize dry run (14 GiB, HyperOS ROM) in the custom recovery: all checks OK, `same ROM`. |
| 2026-11-25 06:09:26 | resize: REFUSED (safety check) | this ROM differs from the one installed. Only super/userdata would be replaced; the firmware and boot images w | `script_logs/part_resize_20261125_060926.txt` | **Refusal test**: the old engineering ROM given for the installed HyperOS: `DIFFERENT`, refused. |
| 2026-11-25 06:09:28 | resize: REFUSED (safety check) | the new super (12 GiB) is not larger than the current one (12 GiB). Only growing is supported. (If the table i | `script_logs/part_resize_20261125_060928.txt` | **Refusal test**: 12 GiB requested on a 12 GiB table: "Only growing is supported". |
| 2026-11-25 06:09:30 | resize: REFUSED (safety check) | no partition backup found. Run part_backup.sh first (it is read-only). | `script_logs/part_resize_20261125_060930.txt` | **Refusal test**: no backup available: refused. |
| 2026-11-25 06:12:49 | resize: dry run | all checks passed, nothing changed | `script_logs/part_resize_20261125_061249.txt` | Resize dry run in Android through `su` with `--allow-android`: all checks OK. |
| 2026-11-25 06:13:50 | resize: REFUSED (safety check) | adb push of sgdisk failed (is $HOME/peridot-partition-data/sgdisk_bundle a real folder, not a symlink / synced | `script_logs/part_resize_20261125_061350.txt` | Right after the custom recovery booted, `/system` and `/tmp` were not ready and the `sgdisk` push failed: the script stopped, **nothing changed**. Fixed (waits for the recovery, retries). |
| 2026-11-25 06:15:45 | resize: dry run | all checks passed, nothing changed | `script_logs/part_resize_20261125_061545.txt` | Dry run of the 14 GiB resize (recovery). |
| 2026-11-25 06:15:54 | resize: EXECUTED | table written and read back; flashed; Android is up | `script_logs/part_resize_20261125_061554.txt` | **Real run, step 1 of the round trip**: table written (`super` 14 GiB / `userdata` 221.5 GiB), 14 GiB image flashed, HyperOS booted. |
| 2026-11-25 06:45:28 | reflash-only: dry run | all checks passed, nothing changed | `script_logs/part_resize_20261125_064528.txt` | `--reflash-only` dry run from the custom recovery. |
| 2026-11-25 06:45:38 | reflash-only: EXECUTED | 'super' partition exactly the requested size; flashed; Android is up | `script_logs/part_resize_20261125_064538.txt` | **Real run, step 3**: recovery flag cleared, bootloader confirmed `super` is exactly 12 GiB, 12 GiB image flashed, HyperOS booted. Final state. |
| 2026-11-25 06:31:39 | restore: dry run | plan shown, nothing changed | `script_logs/part_restore_20261125_063139.txt` | Restore dry run: shows 14 GiB -> 12 GiB and the disk-size safety check. |
| 2026-11-25 06:31:48 | restore: EXECUTED (+ factory flash) | table restored and equal to backup; Android is up | `script_logs/part_restore_20261125_063148.txt` | **Real run, step 2**: original table restored (equal to the backup), the ROM's own `super` flashed, HyperOS booted. |

## Other files

- `raw_captures/final_state_recovery_root.txt` - raw `lpdump` and `sgdisk --print` of the final state, read as root from the custom recovery.
- `raw_captures/final_state_android.txt` - the same moment seen from Android: build, `/data` size, the logical partitions mapped and mounted.
- `raw_captures/rom_analysis_*.txt`, `rom_super_contents_retail_hyperos_rom.txt` - what `lp_resize.py check/info` reports for both ROMs.
- `first_round_trip_v1/` - the earlier round trip run with the first version of the scripts.

## What this does NOT prove

- It is **one phone** and **two ROMs**. Other storage sizes (128 / 512 GB), other ROM versions, other hosts are untested.
- Only **successful** runs and **refusals** were exercised. **No failure in the middle of a write** (cable pulled, power loss) and no invalid partition table was ever produced or tested.
- A real `--allow-android --execute` through `su` was not run (only the backup and the dry run).
- Logs show what the scripts did and printed; the independent checks are the `lpdump`/`sgdisk` captures taken from the recovery.
