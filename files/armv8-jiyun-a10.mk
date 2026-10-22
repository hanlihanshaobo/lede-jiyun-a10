
define Device/jiyun_a10
  DEVICE_VENDOR := Jiyun
  DEVICE_MODEL := A10
  SOC := rk3568
  DEVICE_DTS := rk3568-jiyun-a10
  UBOOT_DEVICE_NAME := generic-rk3568
  IMAGE/sysupgrade.img.gz := boot-common | boot-script | pine64-img | gzip | append-metadata
  DEVICE_PACKAGES := kmod-switch-rtl8367b kmod-mt7915e kmod-mt7916-firmware kmod-usb-net kmod-usb-storage
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
