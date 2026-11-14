include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-macsplit
PKG_VERSION:=1.0.0
PKG_RELEASE:=1
PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=Jiyun A10

LUCI_TITLE:=LuCI multi-device routing (MAC to PassWall2)
LUCI_DESCRIPTION:=Assign each LAN device to a different PassWall2 line by MAC address; wired and wireless.
LUCI_DEPENDS:=+luci-compat +luci-lib-jsonc +luci-app-passwall2
LUCI_PKGARCH:=all

define Package/luci-app-macsplit/conffiles
/etc/config/macsplit
endef

include $(TOPDIR)/feeds/luci/luci.mk
