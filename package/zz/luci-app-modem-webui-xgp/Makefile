include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-modem-webui-xgp
PKG_VERSION:=1.0.9
PKG_RELEASE:=1

PKG_MAINTAINER:=Local ARM64 router port
PKG_LICENSE:=GPL-2.0-only

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-modem-webui-xgp
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=5G module WebUI for XiGuaPi V3 / Photonicat 2
  DEPENDS:=+luci-base +uci
  PKGARCH:=aarch64_generic
endef

define Package/luci-app-modem-webui-xgp/description
  5G module WebUI port for XiGuaPi V3 and Ariaboard PhotoniCat 2.
  Includes an ARM64 modem WebUI server, two modem frontends,
  automatic modem selection, and a LuCI menu entry under Modem.
  (Prebuilt binary package; LuCI entry moved from Network to Modem.)
endef

IPK_FILE:=$(CURDIR)/luci-app-modem-webui-xgp_1.0.9-1_aarch64_generic.ipk

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)/ipk $(PKG_BUILD_DIR)/data
	tar xzf $(IPK_FILE) -C $(PKG_BUILD_DIR)/ipk
	tar xzf $(PKG_BUILD_DIR)/ipk/data.tar.gz -C $(PKG_BUILD_DIR)/data
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/luci-app-modem-webui-xgp/install
	$(INSTALL_DIR) $(1)
	$(CP) $(PKG_BUILD_DIR)/data/* $(1)/
	chmod 0755 $(1)/usr/bin/webuiserver-xgp
	chmod 0755 $(1)/etc/init.d/modem-webui-xgp
	chmod 0755 $(1)/usr/libexec/modem-webui-xgp/cat $(1)/usr/libexec/modem-webui-xgp/sendat
endef

define Package/luci-app-modem-webui-xgp/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	/etc/init.d/modem-webui-xgp enable
	/etc/init.d/modem-webui-xgp start
}
exit 0
endef

$(eval $(call BuildPackage,luci-app-modem-webui-xgp))
