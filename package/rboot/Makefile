#
# rboot - reboot into a Rockchip boot mode (loader / maskrom / recovery)
#
# The mode name is passed to the kernel through reboot(RESTART2, name); the
# syscon-reboot-mode driver (PMU GRF offset 0x200) writes the magic value and
# the stock RK U-Boot picks it up on the next boot.
#
include $(TOPDIR)/rules.mk

PKG_NAME:=rboot
PKG_VERSION:=1.0
PKG_RELEASE:=1

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)

include $(INCLUDE_DIR)/package.mk

define Package/rboot
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=Rockchip reboot-mode helper (loader/maskrom)
  DEPENDS:=@TARGET_rockchip
endef

define Package/rboot/description
  Reboot the board into Rockchip loader, maskrom, recovery, fastboot or
  normal mode by writing the PMU GRF boot-mode register through the kernel
  syscon-reboot-mode driver.
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ./src/* $(PKG_BUILD_DIR)/
endef

define Build/Compile
	$(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_LDFLAGS) \
		-o $(PKG_BUILD_DIR)/rboot $(PKG_BUILD_DIR)/rboot.c
endef

define Package/rboot/install
	$(INSTALL_DIR) $(1)/sbin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/rboot $(1)/sbin/rboot
endef

$(eval $(call BuildPackage,rboot))
