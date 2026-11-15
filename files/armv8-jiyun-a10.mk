# Shared hardware recipe for the Jiyun A10 firmware variants.
#
# This is a template, not a device: only the entries in TARGET_DEVICES are
# built.  Keeping the DTS/SOC/image layout here means jiyun_a10 and
# jiyun_a10_podkop cannot drift apart in the parts that the bootloader cares
# about; they only differ in DEVICE_PACKAGES.
define Device/jiyun_a10_base
  DEVICE_VENDOR := Jiyun
  DEVICE_MODEL := A10
  SOC := rk3568
  DEVICE_DTS := rk3568-jiyun-a10
  SUPPORTED_DEVICES += jiyun,a10
  UBOOT_DEVICE_NAME := generic-rk3568
  #
  # Only one image is produced here: the eMMC flashing package (MBR + root.ext4).
  # The SPI NOR package needs the stock loader/u-boot plus the FIT built from the
  # kernel Image, so it is assembled afterwards by the CI "assemble" job
  # (tools/mk-spi-img.py). Together they are the only two files needed to bring
  # up a completely blank device.
  #
  IMAGES := emmc.img
  IMAGE/emmc.img := jiyun-a10-emmc-img
  #
  # NOTE: this device block is appended at the end of armv8.mk, so it inherits the
  # global image variables set by earlier devices (wxy_oec-turbo-4g sets
  # IMAGE_BOOTFS/IMAGE_GPT/IMAGE_PART_OFFSET/IMAGE_PART_ALIGN/BOOTLOADER_IMAGE/
  # ENV_IMAGE). Reset them here so nothing leaks into our image.
  #
  IMAGE_BOOTFS :=
  IMAGE_GPT :=
  IMAGE_PART_OFFSET :=
  IMAGE_PART_ALIGN :=
  BOOTLOADER_IMAGE :=
  BOOTLOADER_OFFSET :=
  ENV_IMAGE :=
  ENV_OFFSET :=
endef

# Mainline firmware (the rolling "latest" release).
define Device/jiyun_a10
  $(Device/jiyun_a10_base)
  DEVICE_PACKAGES := kmod-dsa-rtl8365mb wpad-mbedtls kmod-mt7915e kmod-mt7916-firmware \
	kmod-usb-net kmod-usb-storage \
	luci-theme-design luci-theme-argon \
	luci-app-openclash luci-app-zerotier \
	luci-app-passwall2 \
	luci-app-emmc-health mmc-utils \
	luci-app-qmodem-next \
	luci-app-diskman \
	resize2fs
endef
TARGET_DEVICES += jiyun_a10

# Slim "podkop" variant.
#
# Lean's DEFAULT_PACKAGES.router installs luci-app-ssr-plus, luci-app-vlmcsd and
# luci-app-vsftpd on every image.  A package prefixed with "-" removes it from
# the merged profile list (scripts/target-metadata.pl merges DEFAULT_PACKAGES
# and DEVICE_PACKAGES this way), so the entries below both keep the Kconfig
# defaults from selecting them and keep them out of the rootfs.
#
# Podkop itself comes from its own feed and CONFLICTS with luci-app-passwall2.
# The PassWall2 app is kept in this variant, so prepare.sh removes just that
# one conflict word from podkop's Makefile; at runtime only one of the two may
# manage nftables/dnsmasq.
define Device/jiyun_a10_podkop
  $(Device/jiyun_a10_base)
  DEVICE_VARIANT := Podkop
  DEVICE_PACKAGES := kmod-dsa-rtl8365mb wpad-mbedtls kmod-mt7915e kmod-mt7916-firmware \
	kmod-usb-net kmod-usb-storage \
	luci-theme-design luci-theme-argon \
	luci-app-zerotier \
	luci-app-passwall2 \
	luci-app-diskman \
	resize2fs \
	-luci-app-openclash \
	-luci-app-emmc-health -mmc-utils \
	-luci-app-qmodem-next -qmodem \
	-luci-app-ssr-plus -luci-app-vlmcsd -luci-app-vsftpd
endef
TARGET_DEVICES += jiyun_a10_podkop

# eMMC flashing package: MBR (p1 @ LBA 2048, type 0x83) followed by root.ext4.
#
# The stock bootloader stays in the SPI NOR and loads the FIT from its "Kernel"
# partition, so no idbloader/u-boot.itb must ever be written here - writing the
# generic rk3568 u-boot would break the stock boot flow (and only rootfs belongs
# on the eMMC).
define Build/jiyun-a10-emmc-img
	rm -f $@
	python3 $(TOPDIR)/scripts/mk-emmc-img.py $(IMAGE_ROOTFS) $@
endef
