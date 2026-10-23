
define Device/jiyun_a10
  DEVICE_VENDOR := Jiyun
  DEVICE_MODEL := A10
  SOC := rk3568
  DEVICE_DTS := rk3568-jiyun-a10
  UBOOT_DEVICE_NAME := generic-rk3568
  IMAGE/sysupgrade.img.gz := boot-common | boot-script | jiyun-a10-img | gzip | append-metadata
  DEVICE_PACKAGES := swconfig kmod-switch-rtl8367b kmod-mt7915e kmod-mt7916-firmware kmod-usb-net kmod-usb-storage
  #
  # NOTE: this device block is appended at the end of armv8.mk, so it inherits the
  # global image variables set by earlier devices (wxy_oec-turbo-4g sets
  # IMAGE_BOOTFS/IMAGE_GPT/IMAGE_PART_OFFSET/IMAGE_PART_ALIGN/BOOTLOADER_IMAGE/
  # ENV_IMAGE). Those make pine64-img look for "$@.bootimg" and shift the
  # partition layout, so reset them here.
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

# Disk image without idbloader/u-boot.itb.
#
# The stock bootloader stays in the SPI NOR (we only replace the "Kernel"
# partition there), so a generic rk3568 u-boot must NOT be written to the
# image - it would clobber the stock boot flow. This is the same as
# Build/pine64-img, minus the bootloader/environment dd.
define Build/jiyun-a10-img
	PADDING=1 $(SCRIPT_DIR)/gen_image_generic.sh \
		$@ \
		$(CONFIG_TARGET_KERNEL_PARTSIZE) $@.boot \
		$(CONFIG_TARGET_ROOTFS_PARTSIZE) $(IMAGE_ROOTFS) \
		$(if $(IMAGE_PART_ALIGN),$(IMAGE_PART_ALIGN),32768)
endef
