include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-multiwifi
PKG_VERSION:=1.0.0
PKG_RELEASE:=1
PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=Jiyun A10

LUCI_TITLE:=LuCI multi-SSID routing with PassWall2
LUCI_DESCRIPTION:=Create up to N independent SSIDs per radio and bind each one to a PassWall2 node.
LUCI_DEPENDS:=+luci-compat +luci-lib-jsonc +luci-app-passwall2
LUCI_PKGARCH:=all

define Package/luci-app-multiwifi/conffiles
/etc/config/multiwifi
endef

include $(TOPDIR)/feeds/luci/luci.mk
