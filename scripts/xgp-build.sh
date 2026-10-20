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
# Both install /etc/init.d/sms_forwarder; catch it now instead of in
# package/install at the end of the build.
if grep -Fxq 'CONFIG_PACKAGE_sms-forwarder=y' .config && grep -Fxq 'CONFIG_PACKAGE_sms-forwarder-next=y' .config; then
  echo '::error::sms-forwarder and sms-forwarder-next are both selected; they install the same files and package/install would fail at the end of the build.'
  exit 1
fi

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

# mwan3 2.12 ships the upstream example config: all traffic goes to policy
# 'balanced', whose only enabled member is the Ethernet wan, and a policy
# without last_resort marks traffic unreachable while no member is online.
# With the WAN port unplugged and only a modem connected, plain ping fails
# with "Network unreachable", dnsmasq answers REFUSED and LAN clients have no
# internet. The old mwan3 2.8 config fell back to the main routing table
# (last_resort 'default'); do the same for policies that leave it unset.
# uci-defaults run again after every sysupgrade, so kept configs are fixed too.
cat > files/etc/uci-defaults/zz-mwan3-last-resort <<'EOF'
#!/bin/sh
[ -f /etc/config/mwan3 ] || exit 0
changed=0
for p in $(uci -q -X show mwan3 | sed -n 's/^mwan3\.\([^.=]*\)=policy$/\1/p'); do
	[ -n "$(uci -q get "mwan3.$p.last_resort")" ] && continue
	uci set "mwan3.$p.last_resort=default"
	changed=1
done
[ "$changed" = 0 ] || uci commit mwan3
exit 0
EOF

# Default LuCI theme: Design. Applied once; the marker in /etc/config/luci
# survives sysupgrade, so a theme picked later by the user is kept.
cat > files/etc/uci-defaults/zzzzz-luci-theme-design <<'EOF'
#!/bin/sh
[ -d /www/luci-static/design ] || exit 0
[ "$(uci -q get luci.main.default_theme_set)" = design ] && exit 0
uci set luci.themes.Design=/luci-static/design
uci set luci.main.mediaurlbase=/luci-static/design
uci set luci.main.default_theme_set=design
uci commit luci
exit 0
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

# report_errors, verbose_make and run_checked are the same helpers as in
# pcat-build.sh; keep the two copies in sync.

# Show the lines that explain a failure as ::error:: annotations, so the cause
# is visible on the run page without downloading the build-logs artifact:
# opkg errors from package/install (file clashes, missing dependencies),
# packages OpenWrt reports as failed, compiler errors and a full disk.
# $3 = head|tail: which matches to keep (first ones for a single package,
# last ones for a whole-target log).
report_errors() {
  local label="$1"
  local file="$2"
  local pick="${3:-tail}"
  local line
  [ -f "${file}" ] || return 0
  # Reporting must never be what fails the build (e.g. SIGPIPE from head).
  awk '
    /Collected errors:/ { grab = 1; next }
    grab && /^[ \t]+(\*|But that file)/ { print; next }
    { grab = 0 }
    /ERROR: .* failed to build/ || /No space left on device/ || /(^|[^A-Za-z-])error: / { print }
  ' "${file}" | sed -E 's/^[[:space:]]+//; s/%/%25/g' | awk '!seen[$0]++' | "${pick}" -n 10 |
    while IFS= read -r line; do
      printf '::error title=%s::%s\n' "${label}" "${line}"
    done || true
}

# Last-resort make -j1 V=s of a whole target. The output goes only to the log
# file: a verbose rebuild of `world` prints gigabytes, which floods the job log
# and the runner's small root disk. On failure, print the tail and annotate
# the error lines.
verbose_make() {
  local target="$1"
  local label="$2"
  local log="$3"
  echo "    full output goes to build-logs/${log##*/} (uploaded as the build-logs artifact)"
  if make "${target}" -j1 V=s >> "${log}" 2>&1; then
    return 0
  fi
  echo "::group::${label}: last 200 lines of make ${target} -j1 V=s"
  tail -n 200 "${log}"
  echo "::endgroup::"
  report_errors "${label}" "${log}" tail
  return 1
}

# Build a target in parallel. On failure, rebuild only the packages that
# failed with -j1 V=s (readable log, and it gets past parallel-build races),
# then resume in parallel. Rebuilding the whole target with -j1 V=s is only
# the last resort: doing that for `world` pushed the job past the 6h limit.
# All logs go to build-logs/, which the workflow uploads when a build fails.
run_checked() {
  local target="$1"
  local label="$2"
  local log="${log_dir}/${target//\//_}.log"
  local pkg retry_log
  local -a failed=() broken=()

  echo "==> ${label}: make ${target} -j${jobs}"
  if make "${target}" -j"${jobs}" 2>&1 | tee "${log}"; then
    return 0
  fi

  mapfile -t failed < <(failed_targets "${log}")
  if [ "${#failed[@]}" -eq 0 ]; then
    echo "::warning::${label} failed without naming a package; retrying make ${target} -j1 V=s"
    verbose_make "${target}" "${label}" "${log}" || return 1
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
      retry_log="${log_dir}/retry_${pkg//\//_}.log"
      echo "::error::${label}: ${pkg} failed to build; see ${retry_log##*/} in the build-logs artifact"
      report_errors "${pkg}" "${retry_log}" head
    done
    return 1
  fi

  echo "::warning::${label} still fails in parallel; last resort make ${target} -j1 V=s"
  verbose_make "${target}" "${label}" "${log}" || return 1
}

echo "==> download"
make download -j8 || make download -j1 V=s

run_checked world "XGP V3 firmware"

echo "==> outputs"
ls -lah bin/targets/rockchip/armv8/ || true
