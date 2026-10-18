#!/usr/bin/env bash
# 在 LEDE 源码根目录执行：bash scripts/xgp-build.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> feeds update/install"
./scripts/feeds update -a
./scripts/feeds install -a
./scripts/feeds install -a -f -p qmodem

echo "==> QModem fixes (auto-dial default, kernel 6.18 net detection)"
bash scripts/qmodem-fixes.sh

echo "==> apply config"
cp xgp.config .config
make defconfig

echo "==> verify device selected"
grep -Fxq "CONFIG_TARGET_rockchip_armv8_DEVICE_nlnet_xiguapi-v3=y" .config

echo "==> qmodem default slots (XGP)"
mkdir -p files/etc/config
if [ -f feeds/qmodem/application/qmodem/files/etc/config/qmodem ]; then
  cat feeds/qmodem/application/qmodem/files/etc/config/qmodem > files/etc/config/qmodem
elif [ -f feeds/qmodem/luci/luci-app-qmodem/root/etc/config/qmodem ]; then
  cat feeds/qmodem/luci/luci-app-qmodem/root/etc/config/qmodem > files/etc/config/qmodem
fi

cat >> files/etc/config/qmodem <<'EOF'

config modem-slot 'wwan'
	option type 'usb'
	option slot '8-1'
	option net_led 'blue:net'
	option alias 'wwan'

config modem-slot 'mpcie1'
	option type 'pcie'
	option slot '0001:11:00.0'
	option net_led 'blue:net'
	option alias 'mpcie1'

config modem-slot 'mpcie2'
	option type 'pcie'
	option slot '0002:21:00.0'
	option net_led 'blue:net'
	option alias 'mpcie2'
EOF

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

jobs=$(nproc)
log_dir="${ROOT}/build-logs"
mkdir -p "${log_dir}"

# Make targets of the packages OpenWrt reported as failed in a build log:
#   "ERROR: package/feeds/x/foo failed to build."        -> package/feeds/x/foo/compile
#   "ERROR: package/feeds/x/foo [host] failed to build." -> package/feeds/x/foo/host/compile
failed_targets() {
  sed -nE \
    -e 's#.*ERROR: ([^ ]+) \[([a-z]+)\] failed to build.*#\1/\2/compile#p' \
    -e 't' \
    -e 's#.*ERROR: ([^ ]+) failed to build.*#\1/compile#p' \
    "$1" | sort -u
}

# Build a target in parallel. On failure, rebuild only the packages that
# failed with -j1 V=s (readable log, and it gets past parallel-build races),
# then resume in parallel. Rebuilding the whole target with -j1 V=s is only
# the last resort, because it can take longer than the 6h job limit.
# All logs go to build-logs/, which the workflow uploads when a build fails.
# Same helper as in pcat-build.sh; keep the two copies in sync.
run_checked() {
  local target="$1"
  local label="$2"
  local log="${log_dir}/${target//\//_}.log"
  local pkg
  local -a failed=() broken=()

  echo "==> ${label}: make ${target} -j${jobs}"
  if make "${target}" -j"${jobs}" 2>&1 | tee "${log}"; then
    return 0
  fi

  mapfile -t failed < <(failed_targets "${log}")
  if [ "${#failed[@]}" -eq 0 ]; then
    echo "::warning::${label} failed without naming a package; retrying make ${target} -j1 V=s"
    make "${target}" -j1 V=s 2>&1 | tee -a "${log}"
    return 0
  fi

  for pkg in "${failed[@]}"; do
    echo "::group::${label}: retry ${pkg} with -j1 V=s"
    if ! make "${pkg}" -j1 V=s 2>&1 | tee "${log_dir}/retry_${pkg//\//_}.log"; then
      broken+=("${pkg}")
    fi
    echo "::endgroup::"
  done

  echo "==> ${label}: resuming make ${target} -j${jobs}"
  if make "${target}" -j"${jobs}" 2>&1 | tee -a "${log}"; then
    return 0
  fi

  if [ "${#broken[@]}" -gt 0 ]; then
    for pkg in "${broken[@]}"; do
      echo "::error::${label}: ${pkg} failed to build; see retry_${pkg//\//_}.log in the build-logs artifact"
    done
    return 1
  fi

  echo "::warning::${label} still fails in parallel; last resort make ${target} -j1 V=s"
  make "${target}" -j1 V=s 2>&1 | tee -a "${log}"
}

echo "==> download"
make download -j8 || make download -j1 V=s

run_checked world "XGP V3 firmware"

echo "==> outputs"
ls -lah bin/targets/rockchip/armv8/ || true
