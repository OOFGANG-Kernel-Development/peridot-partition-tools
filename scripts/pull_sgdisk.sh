#!/bin/bash
# pull_sgdisk.sh - copy Android's own sgdisk (and the 2 libraries it needs) from YOUR booted phone, so they can be used in recovery.
# Needs: phone booted in Android, USB debugging on, adb root (userdebug/eng ROM) or a ROM that lets 'adb shell' read /system.
set -eu
ADB=${ADB:-/mnt/c/platform-tools/adb.exe}
DATA=${PART_DATA:-$HOME/peridot-partition-data}; SGB=${SGB:-$DATA/sgdisk_bundle}; mkdir -p "$SGB"
for f in /system/bin/sgdisk /system/lib64/libext2_uuid.so /system/lib64/libc++.so; do
  timeout 60 "$ADB" exec-out "cat $f" > "$SGB/$(basename $f)"; echo "$(basename $f): $(stat -c %s "$SGB/$(basename $f)") bytes"
done
[ "$(stat -c %s "$SGB/sgdisk")" -gt 100000 ] || { echo "sgdisk looks wrong - is the phone booted and authorised?"; exit 1; }
echo "bundle ready in $SGB"
