#!/bin/bash
#
# sd-android-toggle.sh — dual-boot toggle for the Vontar DQ08 (RK3528) WITHOUT
# removing the SD card.
#
# The BootROM prefers the SD: if the SD has a valid idbloader (at LBA 64) it
# boots Armbian from the card; otherwise it falls through to the internal
# Android on eMMC. This script lets you invalidate the SD idbloader (-> next
# boot = Android) and later restore it (-> back to Armbian), so you can switch
# without physically pulling the card through the flaky slot.
#
# It NEVER touches the GPT (LBA 0..33) or the partitions (from LBA 32768), only
# the idbloader/U-Boot gap in between, and it always backs that gap up first.
#
# Subcommands:
#   backup                 Back up the boot gap only (safe, non-destructive).
#   to-android             Back up, then zero the idbloader, then reboot -> Android.
#   restore <backup.bin>   Write a backup back to the boot gap (run from Armbian,
#                          or from any Linux / rooted Android that sees the SD).
#
# Run as root. Auto-detects the SD as the disk that holds "/" when run on the
# booted Armbian; for `restore` from another OS, pass SD_DISK=/dev/... env var.
#
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

detect_sd_disk() {
    if [ -n "${SD_DISK:-}" ]; then echo "$SD_DISK"; return; fi
    local root_src pk
    root_src=$(findmnt -no SOURCE / 2>/dev/null) || die "cannot find root mount"
    pk=$(lsblk -no PKNAME "$root_src" 2>/dev/null | head -1)
    [ -n "$pk" ] || die "cannot resolve parent disk of $root_src (are you on the SD-booted Armbian? else set SD_DISK=)"
    echo "/dev/$pk"
}

# Safety gauntlet: refuse anything that doesn't look exactly like our SD card.
validate_sd() {
    local disk="$1" name p1start nparts sizeg
    [ -b "$disk" ] || die "$disk is not a block device"
    name=$(basename "$disk")
    sizeg=$(( $(blockdev --getsize64 "$disk") / 1000 / 1000 / 1000 ))
    nparts=$(lsblk -rno NAME "$disk" | grep -c "^${name}p") || true
    [ -f "/sys/block/$name/${name}p1/start" ] || die "$disk has no p1"
    p1start=$(cat "/sys/block/$name/${name}p1/start")
    echo "  disk=$disk size=${sizeg}GB partitions=$nparts p1_start=$p1start"
    # Android eMMC has ~14 partitions; our Armbian SD has exactly 2 (boot+root).
    [ "$nparts" -le 3 ] || die "$disk has $nparts partitions — looks like the eMMC/Android, REFUSING"
    # p1 must start well past the boot gap so we never clobber a partition.
    [ "$p1start" -ge 2048 ] || die "$disk p1 starts at $p1start (<2048) — REFUSING"
    echo "$p1start"
}

do_backup() {
    local disk p1start out
    disk=$(detect_sd_disk)
    p1start=$(validate_sd "$disk" | tail -1)
    out=${1:-/root/sd-uboot-region.bin}
    echo "Backing up boot gap: LBA 0..$((p1start-1)) of $disk -> $out"
    dd if="$disk" of="$out" bs=512 count="$p1start" conv=fsync status=none
    sync
    echo "OK: $(du -h "$out" | cut -f1)  $(sha256sum "$out")"
}

do_to_android() {
    local disk p1start bk
    disk=$(detect_sd_disk)
    p1start=$(validate_sd "$disk" | tail -1)
    bk=/root/sd-uboot-region.bin
    do_backup "$bk"
    echo
    echo ">>> Zeroing idbloader on $disk: LBA 64..$((p1start-1)) (GPT & partitions untouched)."
    dd if=/dev/zero of="$disk" bs=512 seek=64 count="$((p1start-64))" conv=fsync status=none
    sync
    echo ">>> idbloader invalidated. Backup kept at $bk (copy it off the box!)."
    echo ">>> Rebooting into internal Android in 5s (Ctrl-C to cancel)..."
    sleep 5
    reboot
}

do_restore() {
    local disk p1start bk="${1:-}"
    [ -n "$bk" ] && [ -f "$bk" ] || die "usage: $0 restore <backup.bin>"
    disk=$(detect_sd_disk)
    p1start=$(validate_sd "$disk" | tail -1)
    local bksectors=$(( $(stat -c%s "$bk") / 512 ))
    [ "$bksectors" -le "$p1start" ] || die "backup ($bksectors sectors) is larger than the boot gap ($p1start) — wrong file?"
    echo ">>> Restoring $bk -> $disk (from LBA 64, $((bksectors-64)) sectors, GPT preserved)."
    # Skip LBA 0..63 in the backup so we never rewrite the GPT/protective-MBR.
    dd if="$bk" of="$disk" bs=512 skip=64 seek=64 count="$((bksectors-64))" conv=fsync status=none
    sync
    echo ">>> Restored. Reboot to boot Armbian again."
}

case "${1:-}" in
    backup)   do_backup "${2:-}";;
    to-android) do_to_android;;
    restore)  do_restore "${2:-}";;
    *) echo "usage: $0 {backup|to-android|restore <backup.bin>}"; exit 2;;
esac
