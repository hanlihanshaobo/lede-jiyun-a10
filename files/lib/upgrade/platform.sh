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
		return 1
	}

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

	return 0
}

platform_copy_config() {
	local partdev

	export_bootdevice && export_partdevice partdev 1 || return 1
	mount -o rw,noatime "/dev/$partdev" /mnt || return 1
	cp -af "$UPGRADE_BACKUP" "/mnt/$BACKUP_FILE"
	sync
	umount /mnt
}
