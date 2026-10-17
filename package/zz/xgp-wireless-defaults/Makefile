include $(TOPDIR)/rules.mk

PKG_NAME:=xgp-wireless-defaults
PKG_VERSION:=1.0
PKG_RELEASE:=1

PKG_MAINTAINER:=XGP
PKG_LICENSE:=GPL-2.0-only

include $(INCLUDE_DIR)/package.mk

define Package/xgp-wireless-defaults
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=XGP first-boot wireless defaults
  PKGARCH:=all
endef

define Package/xgp-wireless-defaults/description
  First-boot wireless defaults for XGP devices.
  When a MediaTek MT7922 is detected, defaults its AP to 5GHz
  (channel 40, 160MHz) instead of 6GHz, so wireless works out
  of the box on a clean install.
endef

define Build/Compile
	true
endef

define Package/xgp-wireless-defaults/install
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/etc/uci-defaults/12-xgp-mt7922-wifi $(1)/etc/uci-defaults/
endef

$(eval $(call BuildPackage,xgp-wireless-defaults))
