#!/bin/bash
# part_backup.sh - READ-ONLY backup of the partition tables of every UFS LUN (sda..sdf) of the phone.
# Works from Android or recovery with root adb. Output: $PART_DATA/backups/<date>/ (+ a second copy in $WIN_STAGE/partition_backup/<date>/)
#   per LUN: gpt_<lun>.sgdisk (restorable), print_<lun>.txt, head_<lun>.bin, tail_<lun>.bin;  plus SHA256.txt
set -u
HERE=$(cd "$(dirname "$0")" && pwd); . "$HERE/lib.sh"; start_log
need_cmds python3 timeout sha256sum; check_tool_exists "$ADB" adb
st=$(adb_state); case "$st" in recovery|device) ok "phone state: $st";; *) die "no phone in adb mode (state '${st:-none}'). Boot Android or recovery and check 'adb devices'.";; esac
adb_is_root || { explain_no_root; die "no root adb"; }
devtmp_init
setup_sgdisk
D=$PART_DATA/backups/$(date +%Y%m%d_%H%M); mkdir -p "$D" "$WIN_STAGE/partition_backup" || die "cannot create $D / $WIN_STAGE/partition_backup"; cd "$D" || exit 1
LUNS=$(adbq 'ls /dev/block' | grep -E '^sd[a-z]$' | tr '\n' ' '); [ -n "$LUNS" ] || die "no sd* disks found on the phone"
say "backing up: $LUNS"
for d in $LUNS; do
  bytes=$(adbq "blockdev --getsize64 /dev/block/$d" | tr -dc 0-9); [ -n "$bytes" ] || die "cannot read the size of $d"; sect=$(( bytes / 4096 ))   # computed here: the phone's shell has 32-bit arithmetic
  adbq "$SG --backup=$DEVTMP/gpt_$d.sgdisk /dev/block/$d" >/dev/null
  adbq "$SG --print /dev/block/$d" > print_$d.txt
  timeout 60 "$ADB" pull $DEVTMP/gpt_$d.sgdisk gpt_$d.sgdisk >/dev/null 2>&1
  timeout 200 "$ADB" exec-out "dd if=/dev/block/$d bs=4096 count=256 2>/dev/null" > head_$d.bin
  timeout 200 "$ADB" exec-out "dd if=/dev/block/$d bs=4096 skip=$((sect-256)) count=256 2>/dev/null" > tail_$d.bin
  # integrity: the saved table must be non-trivial and the dumps must be the size we asked for; the backup GPT header must be in the tail
  [ -f gpt_$d.sgdisk ] && [ "$(stat -c %s gpt_$d.sgdisk)" -gt 500 ] || die "backup of $d looks empty (gpt_$d.sgdisk)"
  [ "$(stat -c %s head_$d.bin)" -eq $((256*4096)) ] && [ "$(stat -c %s tail_$d.bin)" -eq $((256*4096)) ] || die "short dump for $d (cable/adb problem?)"
  python3 - "$d" <<'P' || die "the end-of-disk dump of $d has no GPT header: the backup is not trustworthy"
import sys; d=open(f'tail_{sys.argv[1]}.bin','rb').read(); sys.exit(0 if b'EFI PART' in d else 1)
P
  echo "  $d: $sect sectors, $(grep -cE '^ +[0-9]+ ' print_$d.txt) partitions  OK"
done
sha256sum $(ls | grep -v SHA256) > SHA256.txt
cp -r "$D" "$WIN_STAGE/partition_backup/" || die "could not make the second copy in $WIN_STAGE/partition_backup"
( cd "$WIN_STAGE/partition_backup/$(basename "$D")" && sha256sum -c SHA256.txt --quiet ) && ok "second copy verified (checksums match)" || die "the second copy is corrupt"
echo; echo "${C_G}Backup done:${C_0} $D"; echo "second copy : $WIN_STAGE/partition_backup/$(basename "$D")"
echo "${C_Y}Also copy this folder somewhere ELSE (another PC, cloud, USB stick): it is the only way back.${C_0}"
