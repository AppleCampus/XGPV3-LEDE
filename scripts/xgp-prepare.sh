#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> feeds.conf"
cp feeds.conf.default feeds.conf
cat >> feeds.conf <<'EOF'

src-git qmodem https://github.com/FUjr/QModem.git;main
EOF

echo "==> clone extra packages"
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

clone_or_pull https://github.com/jerrykuku/luci-app-argon-config.git package/zz/luci-app-argon-config
clone_or_pull https://github.com/animegasan/luci-app-alpha-config.git package/zz/luci-app-alpha-config

alpha_config_file=package/zz/luci-app-alpha-config/Makefile
if [[ ! -f "$alpha_config_file" ]]; then
  echo "ERROR: alpha-config Makefile is missing." >&2
  exit 1
fi
if grep -Eq '^PKG_NAME:=' "$alpha_config_file"; then
  if ! grep -Fxq 'PKG_NAME:=luci-app-alpha-config' "$alpha_config_file"; then
    echo "ERROR: alpha-config package name changed upstream; patch needs review." >&2
    exit 1
  fi
else
  sed -i '/^include .*rules\.mk$/a\
PKG_NAME:=luci-app-alpha-config\
PKG_RELEASE:=1\
LUCI_PKGARCH:=all' "$alpha_config_file"
fi
grep -Fxq 'PKG_NAME:=luci-app-alpha-config' "$alpha_config_file"
grep -Fxq 'LUCI_PKGARCH:=all' "$alpha_config_file"

clone_or_pull https://github.com/derisamedia/luci-theme-alpha.git package/zz/luci-theme-alpha
clone_or_pull https://github.com/zzzz0317/kmod-fb-tft-gc9307.git package/zz/kmod-fb-tft-gc9307
clone_or_pull https://github.com/zzzz0317/xgp-v3-screen.git package/zz/xgp-v3-screen

# Linux 6.18 renamed struct platform_driver.remove_new back to .remove
# (upstream zzzz0317/kmod-fb-tft-gc9307 still uses .remove_new).
fb_h=package/zz/kmod-fb-tft-gc9307/src/fbtft.h
sed -i 's/\.remove_new = fbtft_driver_remove_pdev,/.remove = fbtft_driver_remove_pdev,/' "$fb_h"
grep -Fq '.remove = fbtft_driver_remove_pdev,' "$fb_h" || {
  echo "ERROR: fbtft.h platform remove hook not in expected form; patch needs review." >&2
  exit 1
}

echo "==> overlay files"
# Keep repository files when present; otherwise fetch the default XGP overlay.
if [ ! -d files/etc ]; then
  echo "files/ is incomplete; fetching the default XGP overlay"
  rm -rf /tmp/xgp-files
  git clone --depth 1 https://github.com/zzzz0317/lede-xgp-auto-build.git /tmp/xgp-files
  rm -rf files
  cp -a /tmp/xgp-files/files .
fi

echo "==> config"
if [ ! -f xgp.config ]; then
  echo "xgp.config is missing; downloading the default config"
  curl -fsSL -o xgp.config \
    https://raw.githubusercontent.com/zzzz0317/lede-xgp-auto-build/main/xgp.config
fi

# Keep the XGP V3 target selected.
if ! grep -q 'CONFIG_TARGET_rockchip_armv8_DEVICE_nlnet_xiguapi-v3=y' xgp.config; then
  echo "ERROR: xgp.config does not select nlnet_xiguapi-v3" >&2
  exit 1
fi

# Keep the Alpha theme and its configuration app selected after upstream sync.
ensure_config_package() {
  local package_option="$1"
  sed -i "/^# ${package_option} is not set$/d" xgp.config
  if ! grep -Fxq "${package_option}=y" xgp.config; then
    printf '%s\n' "${package_option}=y" >> xgp.config
  fi
}

ensure_config_package CONFIG_PACKAGE_luci-app-alpha-config
ensure_config_package CONFIG_PACKAGE_luci-theme-alpha
ensure_config_package CONFIG_PACKAGE_luci-app-modem-webui-xgp
grep -Fxq 'CONFIG_PACKAGE_luci-app-alpha-config=y' xgp.config
grep -Fxq 'CONFIG_PACKAGE_luci-theme-alpha=y' xgp.config

# panfrost on 6.12+ requires drm_shmem_helper.
if grep -q 'CONFIG_PACKAGE_kmod-drm-panfrost=y' xgp.config; then
  if ! grep -q 'CONFIG_PACKAGE_kmod-drm-shmem-helper=y' xgp.config; then
    echo 'CONFIG_PACKAGE_kmod-drm-shmem-helper=y' >> xgp.config
  fi
fi

echo "prepare done"

