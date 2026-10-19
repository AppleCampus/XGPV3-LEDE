#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> feeds update/install"
./scripts/feeds update -a
while read -r feed_name; do
  ./scripts/feeds install -a -p "${feed_name}"
done < <(awk '$1 ~ /^src-/ && $2 != "qmodem" && $2 != "pcat_packages" { print $2 }' feeds.conf)
./scripts/feeds install -a -f -p qmodem

echo "==> QModem fixes (auto-dial default, kernel 6.18 net detection)"
bash scripts/qmodem-fixes.sh

echo "==> adapt Photonicat Python packages to LEDE"
test -f feeds/packages/lang/python/pypi.mk
test -f feeds/packages/lang/python/python3-package.mk
for dependency in python-legacy-cgi python-blinker python-pam; do
  source_makefile="feeds/pcat_packages/lang/python/${dependency}/Makefile"
  test -f "${source_makefile}"
  sed -i \
    -e 's|^include ../pypi.mk$|include $(TOPDIR)/feeds/packages/lang/python/pypi.mk|' \
    -e 's|^include ../python3-package.mk$|include $(TOPDIR)/feeds/packages/lang/python/python3-package.mk|' \
    "${source_makefile}"
  grep -Fxq 'include $(TOPDIR)/feeds/packages/lang/python/pypi.mk' "${source_makefile}"
  grep -Fxq 'include $(TOPDIR)/feeds/packages/lang/python/python3-package.mk' "${source_makefile}"
done

legacy_cgi_makefile="feeds/pcat_packages/lang/python/python-legacy-cgi/Makefile"
test -f "${legacy_cgi_makefile}"
if ! grep -Fxq 'PKG_BUILD_DEPENDS:=python-hatchling/host' "${legacy_cgi_makefile}"; then
  sed -i '/^PKG_RELEASE:=/a PKG_BUILD_DEPENDS:=python-hatchling/host' "${legacy_cgi_makefile}"
  fi
  grep -Fxq 'PKG_BUILD_DEPENDS:=python-hatchling/host' "${legacy_cgi_makefile}"
./scripts/feeds install -f -p pcat_packages \
  python3-legacy-cgi python3-blinker python3-pam

git -C feeds/pcat_packages rev-parse HEAD > .pcat-packages-sha

for dependency in python-legacy-cgi python-blinker python-pam; do
  test -f "package/feeds/pcat_packages/${dependency}/Makefile"
done

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

disable_config_package() {
  local package_option="$1"
  sed -i "/^# ${package_option} is not set$/d" .config
  sed -i "/^${package_option}=/d" .config
  printf '# %s is not set\n' "$package_option" >> .config
}

# xgp.config follows QModem main, whose luci-app-qmodem-sms uses
# sms-forwarder-next. Photonicat pins an older QModem whose luci-app-qmodem-sms
# still selects sms-forwarder. Both install /etc/init.d/sms_forwarder, so
# keeping both breaks package/install at the very end of a 3h build. Keep only
# the one this QModem's SMS app depends on.
qmodem_sms_makefile=feeds/qmodem/luci/luci-app-qmodem-sms/Makefile
if [ -f "$qmodem_sms_makefile" ] && grep -q '+sms-forwarder-next' "$qmodem_sms_makefile"; then
  disable_config_package CONFIG_PACKAGE_sms-forwarder
else
  disable_config_package CONFIG_PACKAGE_sms-forwarder-next
fi

make defconfig

echo "==> verify Photonicat 2 selection"
grep -Fxq 'CONFIG_TARGET_rockchip_armv8_DEVICE_ariaboard_photonicat2=y' .config
if grep -Fxq 'CONFIG_TARGET_rockchip_armv8_DEVICE_nlnet_xiguapi-v3=y' .config; then
  echo 'ERROR: XGP V3 target remained selected in Photonicat build.' >&2
  exit 1
fi
if grep -Fxq 'CONFIG_PACKAGE_sms-forwarder=y' .config && grep -Fxq 'CONFIG_PACKAGE_sms-forwarder-next=y' .config; then
  echo '::error::sms-forwarder and sms-forwarder-next are both selected; they install the same files and package/install would fail at the end of the build.'
  exit 1
fi
grep -Fxq 'CONFIG_PACKAGE_pcat-manager=y' .config
grep -Fxq 'CONFIG_PACKAGE_pcat-manager-web=y' .config
grep -Fxq 'CONFIG_PACKAGE_pcat2-display-mini=y' .config
grep -Fxq 'CONFIG_PACKAGE_kmod-aic8800-usb=y' .config

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
if [ -s .pcat-packages-sha ]; then
  echo "ZZ_BUILD_PHOTONICAT_PACKAGES_HASH='$(cat .pcat-packages-sha)'" >> files/etc/zz_build_id
fi

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

run_checked tools/compile "host tools"
run_checked toolchain/compile "cross toolchain"
run_checked target/compile "kernel and target"
run_checked package/feeds/pcat_packages/python-legacy-cgi/compile "python3-legacy-cgi compatibility"
run_checked package/feeds/pcat_packages/python-blinker/compile "python3-blinker compatibility"
run_checked package/feeds/pcat_packages/python-pam/compile "python3-pam compatibility"

run_checked package/pcat-manager/compile "pcat-manager"
run_checked package/pcat-manager-web/compile "pcat-manager-web"
run_checked package/pcat2-display-mini/compile "pcat2-display-mini"
run_checked world "Photonicat 2 firmware"

echo "==> outputs"
ls -lah bin/targets/rockchip/armv8/ || true
