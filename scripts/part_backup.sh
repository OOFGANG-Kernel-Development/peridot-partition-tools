#!/bin/bash
# part_backup.sh - read-only backup of the partition tables of all six UFS LUNs (sda..sdf) of the phone, to the host and to C:\peridot_flash\partition_backup.
# Works from Android (adb root) or stock recovery (needs sgdisk; pushes the sgdisk bundle from $DATA/sgdisk_bundle when missing).
# Output dir: $DATA/backups/<date>/  containing per LUN: gpt_<lun>.sgdisk (sgdisk --backup, restorable with --load-backup), print_<lun>.txt,
#   head_<lun>.bin (first 256 sectors), tail_<lun>.bin (last 256 sectors), plus SHA256.txt.
set -u
ADB=${ADB:-/mnt/c/platform-tools/adb.exe}
DATA=${PART_DATA:-$HOME/peridot-partition-data}      # backups, sgdisk bundle and generated images live here
WIN_STAGE=${WIN_STAGE:-/mnt/c/peridot_flash}             # a Windows folder (seen from WSL) where Windows fastboot can read files
SGB=${SGB:-$DATA/sgdisk_bundle}
D=$DATA/backups/$(date +%Y%m%d_%H%M); mkdir -p "$D" "$WIN_STAGE/partition_backup"; cd "$D" || exit 1
adbq(){ timeout 200 "$ADB" shell "$@" 2>&1 | tr -d '\r'; }
if adbq 'which sgdisk' | grep -q sgdisk; then SG=sgdisk; else
  adbq 'mkdir -p /tmp/sgb' >/dev/null; for f in sgdisk libext2_uuid.so libc++.so; do timeout 60 "$ADB" push "$(wslpath -w "$SGB/$f")" /tmp/sgb/$f >/dev/null 2>&1 || { echo "adb push of $f failed"; exit 1; }; done
  adbq 'chmod 755 /tmp/sgb/sgdisk'; SG='LD_LIBRARY_PATH=/tmp/sgb:/system/lib64 /tmp/sgb/sgdisk'; fi
for d in sda sdb sdc sdd sde sdf; do
  bytes=$(adbq "blockdev --getsize64 /dev/block/$d" | tr -dc 0-9); sect=$(( bytes / 4096 ))   # computed here: the phone's shell has 32-bit arithmetic
  adbq "$SG --backup=/tmp/gpt_$d.sgdisk /dev/block/$d" >/dev/null
  adbq "$SG --print /dev/block/$d" > print_$d.txt
  timeout 60 "$ADB" pull /tmp/gpt_$d.sgdisk gpt_$d.sgdisk >/dev/null 2>&1
  timeout 200 "$ADB" exec-out "dd if=/dev/block/$d bs=4096 count=256 2>/dev/null" > head_$d.bin
  timeout 200 "$ADB" exec-out "dd if=/dev/block/$d bs=4096 skip=$((sect-256)) count=256 2>/dev/null" > tail_$d.bin
  echo "$d: $sect sectors, $(grep -cE '^ +[0-9]+ ' print_$d.txt) partitions"
done
sha256sum $(ls | grep -v SHA256) > SHA256.txt
cp -r "$D" "$WIN_STAGE/partition_backup/" && echo "backup: $D  (second copy: $WIN_STAGE/partition_backup/$(basename "$D"))"
