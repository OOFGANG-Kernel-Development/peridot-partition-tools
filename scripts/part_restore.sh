#!/bin/bash
# part_restore.sh - put the ORIGINAL partition table of sda back (from a part_backup.sh backup) and optionally reflash the factory super/userdata.
#
# The phone must be in STOCK RECOVERY with adb root (adb reboot recovery, or Power+Vol-Up from the bootloader menu).
# usage: part_restore.sh [--backup DIR] [--factory DIR] [--flash-factory] [--execute]
#   default: dry run (shows what would be restored).  --execute writes the GPT.  --flash-factory additionally boots the bootloader and flashes
#   factory super.img + erase metadata + factory userdata.img + reboot (this is what makes the phone boot again after the table is back,
#   because the data inside the partitions was recreated by part_resize.sh).
set -u
ADB=${ADB:-/mnt/c/platform-tools/adb.exe}; FB=${FB:-/mnt/c/platform-tools/fastboot.exe}
DATA=${PART_DATA:-$HOME/peridot-partition-data}      # backups, sgdisk bundle and generated images live here
WIN_STAGE=${WIN_STAGE:-/mnt/c/peridot_flash}             # a Windows folder (seen from WSL) where Windows fastboot can read files
FACTORY=${FACTORY:-}
BACKUP=${BACKUP:-$(ls -dt "$DATA"/backups/2*/ 2>/dev/null | head -1)}
SGB=${SGB:-$DATA/sgdisk_bundle}
EXEC=0; FLASH=0
while [ $# -gt 0 ]; do case $1 in
  --backup) BACKUP=$2; shift 2;; --factory) FACTORY=$2; shift 2;; --flash-factory) FLASH=1; shift;; --execute) EXEC=1; shift;;
  *) echo "unknown arg $1"; exit 2;; esac; done
die(){ echo "ERROR: $*" >&2; exit 1; }
say(){ echo; echo "== $*"; }
adbq(){ timeout 120 "$ADB" shell "$@" 2>&1 | tr -d '\r'; }

[ -f "$BACKUP/gpt_sda.sgdisk" ] && [ -f "$BACKUP/print_sda.txt" ] || die "backup not found: $BACKUP"
for f in sgdisk libext2_uuid.so libc++.so; do [ -f "$SGB/$f" ] || die "missing $SGB/$f"; done
st=$(timeout 10 "$ADB" get-state 2>/dev/null | tr -d '\r'); [ "$st" = recovery ] || die "phone must be in recovery (state='$st')"
say "restore from $BACKUP"
adbq 'mkdir -p /tmp/sgb' >/dev/null
for f in sgdisk libext2_uuid.so libc++.so; do timeout 60 "$ADB" push "$(wslpath -w "$SGB/$f")" /tmp/sgb/$f >/dev/null 2>&1 || die "adb push of $f failed (is the phone reachable? is $SGB a real folder, not a symlink?)"; done
timeout 60 "$ADB" push "$(wslpath -w "$BACKUP/gpt_sda.sgdisk")" /tmp/gpt_sda.sgdisk >/dev/null 2>&1 || die "adb push of the backup table failed"
adbq 'chmod 755 /tmp/sgb/sgdisk'
SG='LD_LIBRARY_PATH=/tmp/sgb:/system/lib64 /tmp/sgb/sgdisk'
echo "-- current table:"; adbq "$SG --print /dev/block/sda" | grep -E " super| userdata"
echo "-- table that will be restored (dry run, nothing written):"; adbq "$SG --pretend --load-backup=/tmp/gpt_sda.sgdisk --print /dev/block/sda" | grep -E " super| userdata|Warning|Error|problem"
[ $EXEC = 1 ] || { echo; echo "DRY RUN ONLY. Re-run with --execute (and --flash-factory)."; exit 0; }

say "writing the original table back"
adbq "$SG --load-backup=/tmp/gpt_sda.sgdisk /dev/block/sda" | tail -3; adbq sync
want=$(grep -E "^ +[0-9]+ " "$BACKUP/print_sda.txt" | awk '{print $1,$2,$3,$7}')
live=$(adbq "$SG --print /dev/block/sda" | grep -E "^ +[0-9]+ " | awk '{print $1,$2,$3,$7}')
[ "$live" = "$want" ] || { diff <(echo "$want") <(echo "$live"); die "table after restore differs from the backup"; }
echo "restored: live table == backup"
[ $FLASH = 1 ] || { echo "Table restored. Run again with --flash-factory (or flash_all.sh) to put super/userdata back."; exit 0; }

[ -n "$FACTORY" ] && [ -f "$FACTORY/super.img" ] || die "--flash-factory needs --factory DIR (factory ROM images folder with super.img/userdata.img)"
say "clear the recovery flag, then bootloader + factory super/userdata"
adbq 'dd if=/dev/zero of=/dev/block/by-name/misc bs=2048 count=1 2>&1 | tail -1; sync' >/dev/null
timeout 20 "$ADB" reboot bootloader
for i in $(seq 1 40); do timeout 6 "$FB" devices 2>/dev/null | grep -q fastboot && break; sleep 3; done
timeout 6 "$FB" devices 2>/dev/null | grep -q fastboot || die "no bootloader (hold Power + Volume-Down) - then flash manually: fastboot flash super super.img; fastboot erase metadata; fastboot flash userdata userdata.img"
"$FB" flash super "$(wslpath -w "$FACTORY/super.img")" || die "flash super failed"
"$FB" erase metadata && "$FB" flash userdata "$(wslpath -w "$FACTORY/userdata.img")" || die "userdata step failed"
"$FB" reboot
for i in $(seq 1 120); do st=$(timeout 8 "$ADB" get-state 2>/dev/null | tr -d '\r'); r=$(timeout 8 "$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r'); [ "$st" = device ] && [ "$r" = 1 ] && break; sleep 6; done
echo "adb state=$st boot_completed=$r"
