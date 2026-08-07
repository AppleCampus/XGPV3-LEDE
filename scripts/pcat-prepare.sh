#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> feeds.conf"
cp feeds.conf.default feeds.conf
cat >> feeds.conf <<'EOF'

src-git qmodem https://github.com/FUjr/QModem.git;main
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

echo "==> official Photonicat packages"
official_dir=/tmp/photonicat-openwrt
rm -rf "$official_dir"
git clone --depth 1 --filter=blob:none --sparse \
  https://github.com/photonicat/photonicat_openwrt.git "$official_dir"
git -C "$official_dir" sparse-checkout set \
  package/lean/default-settings \
  package/lean/pcat-manager \
  package/lean/pcat-manager-web \
  package/lean/pcat2-display-mini
git -C "$official_dir" rev-parse HEAD > .pcat-source-sha

for package_name in default-settings pcat-manager pcat-manager-web pcat2-display-mini; do
  rm -rf "package/lean/$package_name"
  cp -a "$official_dir/package/lean/$package_name" "package/lean/$package_name"
done

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

[ -x /etc/init.d/pcat-manager ] && /etc/init.d/pcat-manager enable
[ -x /etc/init.d/pcat-manager-web ] && /etc/init.d/pcat-manager-web enable
[ -x /etc/init.d/pcat2-display-mini ] && /etc/init.d/pcat2-display-mini enable

exit 0
EOF
chmod 0755 files/etc/uci-defaults/98-photonicat2-webui

echo "Photonicat 2 prepare done"
