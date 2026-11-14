include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-macsplit
PKG_VERSION:=1.0.0
PKG_RELEASE:=1
PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=Jiyun A10

LUCI_TITLE:=LuCI per-MAC routing with PassWall2
LUCI_DESCRIPTION:=Bind LAN clients to PassWall2 nodes by MAC address; works for wired and wireless clients.
LUCI_DEPENDS:=+luci-compat +luci-lib-jsonc +luci-app-passwall2
LUCI_PKGARCH:=all

define Package/luci-app-macsplit/conffiles
/etc/config/macsplit
endef

include $(TOPDIR)/feeds/luci/luci.mk
