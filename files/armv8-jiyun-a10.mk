
define Device/jiyun_a10
  DEVICE_VENDOR := Jiyun
  DEVICE_MODEL := A10
  SOC := rk3568
  DEVICE_DTS := rk3568-jiyun-a10
  SUPPORTED_DEVICES += jiyun,a10
  UBOOT_DEVICE_NAME := generic-rk3568
  DEVICE_PACKAGES := kmod-dsa-rtl8365mb wpad-mbedtls kmod-mt7915e kmod-mt7916-firmware kmod-usb-net kmod-usb-storage
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
TARGET_DEVICES += jiyun_a10

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
