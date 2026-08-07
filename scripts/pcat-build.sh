#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> feeds update/install"
./scripts/feeds update -a
./scripts/feeds install -a
./scripts/feeds install -a -f -p qmodem

echo "==> apply Photonicat 2 config"
cp xgp.config .config
sed -i \
  -e 's/^CONFIG_TARGET_rockchip_armv8_DEVICE_nlnet_xiguapi-v3=y$/# CONFIG_TARGET_rockchip_armv8_DEVICE_nlnet_xiguapi-v3 is not set/' \
  -e 's/^# CONFIG_TARGET_rockchip_armv8_DEVICE_ariaboard_photonicat2 is not set$/CONFIG_TARGET_rockchip_armv8_DEVICE_ariaboard_photonicat2=y/' \
  -e 's/^CONFIG_TARGET_PROFILE=.*/CONFIG_TARGET_PROFILE="DEVICE_ariaboard_photonicat2"/' \
  .config

ensure_config_package() {
  local package_option="$1"
  sed -i "/^# ${package_option} is not set$/d" .config
  sed -i "/^${package_option}=/d" .config
  printf '%s=y\n' "$package_option" >> .config
}

ensure_config_package CONFIG_PACKAGE_pcat-manager
ensure_config_package CONFIG_PACKAGE_pcat-manager-web
ensure_config_package CONFIG_PACKAGE_pcat2-display-mini
ensure_config_package CONFIG_PACKAGE_kmod-aic8800-usb
ensure_config_package CONFIG_PACKAGE_luci-app-alpha-config
ensure_config_package CONFIG_PACKAGE_luci-theme-alpha

make defconfig

echo "==> verify Photonicat 2 selection"
grep -Fxq 'CONFIG_TARGET_rockchip_armv8_DEVICE_ariaboard_photonicat2=y' .config
if grep -Fxq 'CONFIG_TARGET_rockchip_armv8_DEVICE_nlnet_xiguapi-v3=y' .config; then
  echo 'ERROR: XGP V3 target remained selected in Photonicat build.' >&2
  exit 1
fi
grep -Fxq 'CONFIG_PACKAGE_pcat-manager=y' .config
grep -Fxq 'CONFIG_PACKAGE_pcat-manager-web=y' .config
grep -Fxq 'CONFIG_PACKAGE_pcat2-display-mini=y' .config

year=$(date +%y)
month=$(date +%-m)
day=$(date +%-d)
hour=$(date +%-H)
mkdir -p files/etc/uci-defaults
cat > files/etc/uci-defaults/zzzz-version <<EOF
echo "DISTRIB_REVISION='R${year}.${month}.${day}.${hour}'" >> /etc/openwrt_release
/bin/sync
EOF

echo "ZZ_BUILD_DATE='$(date "+%Y-%m-%d %H:%M:%S %z")'" > files/etc/zz_build_id
echo "ZZ_BUILD_HOST='$(hostname)'" >> files/etc/zz_build_id
echo "ZZ_BUILD_LEDE_HASH='$(git rev-parse HEAD)'" >> files/etc/zz_build_id
if [ -s .pcat-source-sha ]; then
  echo "ZZ_BUILD_PHOTONICAT_HASH='$(cat .pcat-source-sha)'" >> files/etc/zz_build_id
fi

echo "==> download"
make download -j8

echo "==> compile"
make V=s -j"$(nproc)"

echo "==> outputs"
ls -lah bin/targets/rockchip/armv8/ || true
