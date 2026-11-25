#!/bin/bash
# pull_sgdisk.sh - copy Android's own sgdisk (and the 2 libraries it needs) from YOUR booted phone so it can be used in recovery.
# Needs: phone booted in Android, USB debugging on, adb authorised, and a ROM where 'adb shell' can read /system (any ROM can; root not needed).
set -u
HERE=$(cd "$(dirname "$0")" && pwd); . "$HERE/lib.sh"
check_tool_exists "$ADB" adb; [ "$(adb_state)" = device ] || die "boot the phone into Android, enable USB debugging and authorise this PC ('adb devices' must say 'device')"
mkdir -p "$SGB"
for f in /system/bin/sgdisk /system/lib64/libext2_uuid.so /system/lib64/libc++.so; do
  timeout 60 "$ADB" exec-out "cat $f" > "$SGB/$(basename $f)"; echo "$(basename $f): $(stat -c %s "$SGB/$(basename $f)") bytes"
done
[ "$(stat -c %s "$SGB/sgdisk")" -gt 100000 ] || die "sgdisk looks wrong (too small): is /system/bin/sgdisk present on this ROM?"
file "$SGB/sgdisk" 2>/dev/null | grep -q "aarch64" || warn "the file does not look like an arm64 binary"
adbq "sgdisk --version" | grep -qi sgdisk && ok "sgdisk runs on the phone" || warn "sgdisk could not be run in Android (it may still work in recovery)"
echo "bundle ready in $SGB  (keep it for this ROM; pull again after switching to a different ROM version)"
