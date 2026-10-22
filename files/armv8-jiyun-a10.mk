
define Device/jiyun_a10
  DEVICE_VENDOR := Jiyun
  DEVICE_MODEL := A10
  SOC := rk3568
  DEVICE_DTS := rk3568-jiyun-a10
  UBOOT_DEVICE_NAME := generic-rk3568
  IMAGE/sysupgrade.img.gz := boot-common | boot-script | pine64-img | gzip | append-metadata
  DEVICE_PACKAGES := kmod-switch-rtl8367b kmod-mt7915e kmod-mt7916-firmware kmod-usb-net kmod-usb-storage
endef
TARGET_DEVICES += jiyun_a10
