#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> feeds.conf"
cp feeds.conf.default feeds.conf
cat >> feeds.conf <<'EOF'

src-git qmodem https://github.com/FUjr/QModem.git^667060a8f89d5e8e0bbfe95f5bd5607dc6699c7f
src-git pcat_packages https://github.com/photonicat/rockchip_rk3568_openwrt_packages.git^1e1aa5bab1352e132dd39b0da5f6bae5293e1381
EOF

mkdir -p package/zz
clone_or_pull() {
  local url="$1" dir="$2"
  if [ -d "$dir/.git" ]; then
    git -C "$dir" pull --ff-only || git -C "$dir" pull
  else
    rm -rf "$dir"
    git clone --depth 1 "$url" "$dir"
  fi
}

echo "==> common LEDE packages"
clone_or_pull https://github.com/jerrykuku/luci-app-argon-config.git package/zz/luci-app-argon-config
clone_or_pull https://github.com/animegasan/luci-app-alpha-config.git package/zz/luci-app-alpha-config
clone_or_pull https://github.com/derisamedia/luci-theme-alpha.git package/zz/luci-theme-alpha

alpha_config_file=package/zz/luci-app-alpha-config/Makefile
if [[ ! -f "$alpha_config_file" ]]; then
  echo "ERROR: alpha-config Makefile is missing." >&2
  exit 1
fi
if grep -Eq '^PKG_NAME:=' "$alpha_config_file"; then
  grep -Fxq 'PKG_NAME:=luci-app-alpha-config' "$alpha_config_file"
else
  sed -i '/^include .*rules\.mk$/a\
PKG_NAME:=luci-app-alpha-config\
PKG_RELEASE:=1\
LUCI_PKGARCH:=all' "$alpha_config_file"
fi

echo "==> official Photonicat packages and hardware DTS"
official_dir=/tmp/photonicat-openwrt
rm -rf "$official_dir"
git clone --depth 1 --filter=blob:none --sparse \
  https://github.com/photonicat/photonicat_openwrt.git "$official_dir"
git -C "$official_dir" sparse-checkout set \
  package/lean/default-settings \
  package/lean/pcat-manager \
  package/lean/pcat-manager-web \
  package/lean/pcat2-display-mini \
  target/linux/rockchip/files/arch/arm64/boot/dts/rockchip/rk3576-photonicat2.dts
git -C "$official_dir" rev-parse HEAD > .pcat-source-sha

for package_name in default-settings pcat-manager pcat-manager-web pcat2-display-mini; do
  rm -rf "package/lean/$package_name"
  cp -a "$official_dir/package/lean/$package_name" "package/lean/$package_name"
done

target_dts=target/linux/rockchip/files/arch/arm64/boot/dts/rockchip/rk3576-photonicat2.dts
test -s "$official_dir/$target_dts"
mkdir -p "$(dirname "$target_dts")"
cp "$official_dir/$target_dts" "$target_dts"
grep -Fq 'brightness-levels = <' "$target_dts"
grep -Fq 'default-brightness-level = <40>;' "$target_dts"
grep -Fq 'fan {' "$target_dts"

echo "==> pin compatible Photonicat package revisions"
pcat_manager_makefile=package/lean/pcat-manager/Makefile
pcat_web_makefile=package/lean/pcat-manager-web/Makefile
pcat_display_makefile=package/lean/pcat2-display-mini/Makefile
sed -i 's/^PKG_RELEASE:=.*/PKG_RELEASE:=47/' "$pcat_manager_makefile"
sed -i 's|^PKG_SOURCE_DATE:=.*|PKG_SOURCE_DATE:=2026-06-08|' "$pcat_manager_makefile"
sed -i 's|^PKG_SOURCE_VERSION:=.*|PKG_SOURCE_VERSION:=9a7de25141b3b9e759759e0cd36befe3ea4af338|' "$pcat_manager_makefile"
sed -i 's/^PKG_RELEASE:=.*/PKG_RELEASE:=125/' "$pcat_web_makefile"
sed -i 's|^PKG_SOURCE_DATE:=.*|PKG_SOURCE_DATE:=2026-06-11|' "$pcat_web_makefile"
sed -i 's|^PKG_SOURCE_VERSION:=.*|PKG_SOURCE_VERSION:=937c7ffedefce50e16e79d27de56b52099a508dc|' "$pcat_web_makefile"
sed -i 's/^PKG_RELEASE:=.*/PKG_RELEASE:=47/' "$pcat_display_makefile"
sed -i 's|^PKG_SOURCE_DATE:=.*|PKG_SOURCE_DATE:=2026-08-06|' "$pcat_display_makefile"
sed -i 's|^PKG_SOURCE_VERSION:=.*|PKG_SOURCE_VERSION:=9d7bf987754570abf6e021d6805aa8c442db52cd|' "$pcat_display_makefile"

if ! grep -Fq '+libpam' "$pcat_web_makefile"; then
  sed -i '/+python3-pam/ s/+python3-pam/+python3-pam +libpam/' "$pcat_web_makefile"
fi
grep -Fq '+python3-pam +libpam' "$pcat_web_makefile"

echo "==> Photonicat 2 first-boot settings"
rm -rf files
mkdir -p files/etc/uci-defaults
cat > files/etc/uci-defaults/98-photonicat2-webui <<'EOF'
#!/bin/sh

uci -q delete uhttpd.main.listen_http
uci add_list uhttpd.main.listen_http='0.0.0.0:8080'
uci add_list uhttpd.main.listen_http='[::]:8080'
uci set network.lan.ipaddr='172.16.0.1'
uci commit uhttpd
uci commit network

display_config=/etc/pcat2_mini_display-config.json
if [ -f "$display_config" ]; then
	sed -i 's/"screen_dimmer_time_on_battery_seconds": 60/"screen_dimmer_time_on_battery_seconds": 86400/' "$display_config"
fi
[ -w /sys/class/backlight/backlight/brightness ] && echo 100 > /sys/class/backlight/backlight/brightness

[ -x /etc/init.d/pcat-manager ] && /etc/init.d/pcat-manager enable
[ -x /etc/init.d/pcat-manager-web ] && /etc/init.d/pcat-manager-web enable
[ -x /etc/init.d/pcat2-display-mini ] && /etc/init.d/pcat2-display-mini enable

exit 0
EOF
chmod 0755 files/etc/uci-defaults/98-photonicat2-webui

echo "Photonicat 2 prepare done"
