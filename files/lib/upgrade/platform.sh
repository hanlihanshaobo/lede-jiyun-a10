#!/bin/sh
#
# Jiyun A10 in-system upgrade (podkop profile).
#
# The upgrade package is an uncompressed tar with a fwtool metadata footer:
#
#   sysupgrade-jiyun_a10/CONTROL
#   sysupgrade-jiyun_a10/kernel   kernel + DTB + first-boot initramfs (FIT)
#   sysupgrade-jiyun_a10/root     ext4 rootfs (256 MiB)
#
# kernel -> SPI NOR mtd "Kernel" (the stock u-boot loads the FIT from there)
# root   -> eMMC /dev/mmcblk0p1 (the first-boot initramfs grows it to 7 GB)
#
# The tar EOF marker is followed by the metadata that fwtool appends.  tar(1)
# stops at the marker, so both the generic device check and the extraction
# below see a normal archive (verified with BusyBox tar 1.38 on the device).
#
# WARNING: this platform.sh is only installed in the podkop image (see
# scripts/prepare.sh).  A system that still has the generic platform.sh will
# treat the tar as a disk image and write it to the whole eMMC - copy
# /lib/upgrade/platform.sh from the new image to such a system before the
# first in-system upgrade.

. /lib/functions.sh

JY_BOARD="jiyun_a10"
JY_MTD="Kernel"
JY_FIT_MAGIC="d00dfeed"

# Stage 2 runs in a tiny ramfs: /tmp is lost on reboot, so keep a small log in
# the unused 1 MiB gap before p1 (LBA 1020; the initramfs uses LBA 1000).
# It survives the upgrade and can be read with
#   dd if=/dev/mmcblk0 bs=512 skip=1020 count=8 | strings
JY_LOG=/tmp/jy-upgrade.log
log_upgrade() {
	echo "$(date '+%H:%M:%S') $*" >> "$JY_LOG" 2>/dev/null
	dd if="$JY_LOG" of=/dev/mmcblk0 bs=512 seek=1020 conv=fsync 2>/dev/null
}

# Restore the sysupgrade config archive directly onto p1.  The stock preinit
# path (stage a sysupgrade.tgz, let 80_mount_root extract it) did not take
# effect on this board: the file was deleted by /etc/init.d/done without the
# marker in /etc/config/system changing.  Extracting here is deterministic and
# happens before the reboot, while p1 is unmounted.
jy_restore_config() {
	local dev="$1"
	local backup="${UPGRADE_BACKUP:-/tmp/sysupgrade.tgz}"
	local backup_file="${BACKUP_FILE:-sysupgrade.tgz}"

	[ -f "$backup" ] || {
		log_upgrade "restore_config: no backup at $backup"
		return 1
	}
	mount -o rw,noatime "/dev/$dev" /mnt || {
		log_upgrade "restore_config: mount failed"
		return 1
	}
	if tar -xzf "$backup" -C /mnt; then
		sync
		rm -f "/mnt/$backup_file"
		log_upgrade "restore_config: extracted"
		umount /mnt
		return 0
	fi
	# Fall back to the stock preinit mechanism.
	if cp -af "$backup" "/mnt/$backup_file"; then
		log_upgrade "restore_config: staged for preinit"
	else
		log_upgrade "restore_config: extract and stage both failed"
	fi
	sync
	umount /mnt
	return 1
}

platform_check_image() {
	local img="$1"
	local entries

	[ -f "$img" ] || {
		echo "image file not found: $img"
		return 1
	}

	entries="$(tar -tf "$img" 2>/dev/null)" || {
		echo "image is not a tar archive"
		return 1
	}
	echo "$entries" | grep -qx "sysupgrade-$JY_BOARD/CONTROL" || {
		echo "image has no sysupgrade-$JY_BOARD/CONTROL"
		return 1
	}
	echo "$entries" | grep -qx "sysupgrade-$JY_BOARD/root" || {
		echo "image has no sysupgrade-$JY_BOARD/root"
		return 1
	}
	echo "$entries" | grep -qx "sysupgrade-$JY_BOARD/kernel" || {
		echo "image has no sysupgrade-$JY_BOARD/kernel"
		return 1
	}

	return 0
}

platform_do_upgrade() {
	local img="$1"
	local fit="/tmp/jiyun-kernel.fit"
	local rootfs="/tmp/jiyun-root.ext4"
	local ctl="/tmp/jiyun-control"
	local rootdev rootfs_size fit_size

	export_bootdevice && export_partdevice rootdev 1 || {
		echo "cannot find the eMMC rootfs partition"
		log_upgrade "do_upgrade: cannot find rootfs partition"
		return 1
	}
	log_upgrade "do_upgrade: start rootdev=$rootdev backup=${UPGRADE_BACKUP:-none}"

	# The CONTROL file carries the sizes so a truncated tar is rejected
	# before anything is written to flash.
	rm -f "$ctl"
	tar -xOf "$img" "sysupgrade-$JY_BOARD/CONTROL" > "$ctl" 2>/dev/null || true
	rootfs_size="$(sed -n 's/^ROOTFS_SIZE=//p' "$ctl" 2>/dev/null)"
	fit_size="$(sed -n 's/^FIT_SIZE=//p' "$ctl" 2>/dev/null)"
	rm -f "$ctl"

	# 1. Kernel FIT first: if this fails the old rootfs is still intact.
	rm -f "$fit"
	tar -xOf "$img" "sysupgrade-$JY_BOARD/kernel" > "$fit" || {
		echo "failed to extract the kernel FIT"
		rm -f "$fit"
		return 1
	}
	[ "$(hexdump -v -n 4 -e '1/1 "%02x"' "$fit" 2>/dev/null)" = "$JY_FIT_MAGIC" ] || {
		echo "kernel payload is not a FIT image"
		rm -f "$fit"
		return 1
	}
	if [ -n "$fit_size" ] && [ "$(wc -c < "$fit")" -ne "$fit_size" ]; then
		echo "kernel FIT size mismatch (expected $fit_size)"
		rm -f "$fit"
		return 1
	fi
	mtd write "$fit" "$JY_MTD" || {
		echo "failed to write the kernel FIT to SPI NOR ($JY_MTD)"
		rm -f "$fit"
		return 1
	}
	rm -f "$fit"
	sync
	log_upgrade "do_upgrade: FIT written"

	# 2. Rootfs: extract first (so tar errors are visible), verify the size,
	#    then write the ext4 straight onto p1.
	rm -f "$rootfs"
	tar -xOf "$img" "sysupgrade-$JY_BOARD/root" > "$rootfs" || {
		echo "failed to extract the rootfs"
		rm -f "$rootfs"
		return 1
	}
	if [ -n "$rootfs_size" ] && [ "$(wc -c < "$rootfs")" -ne "$rootfs_size" ]; then
		echo "rootfs size mismatch (expected $rootfs_size)"
		rm -f "$rootfs"
		return 1
	fi
	dd if="$rootfs" of="/dev/$rootdev" bs=1M conv=fsync || {
		echo "failed to write the rootfs to /dev/$rootdev"
		rm -f "$rootfs"
		return 1
	}
	rm -f "$rootfs"
	sync
	log_upgrade "do_upgrade: rootfs written"

	# 3. Restore the sysupgrade config archive while p1 is still unmounted.
	jy_restore_config "$rootdev"

	return 0
}

platform_copy_config() {
	local partdev

	log_upgrade "copy_config: start"
	export_bootdevice && export_partdevice partdev 1 || {
		log_upgrade "copy_config: cannot find p1"
		return 1
	}
	jy_restore_config "$partdev"
}
