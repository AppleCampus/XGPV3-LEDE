#!/usr/bin/env bash
# Build-time fixes for the QModem feed, shared by xgp-build.sh and pcat-build.sh.
# Run from the LEDE root after `./scripts/feeds install`:
#   bash scripts/qmodem-fixes.sh
#
# The real files in feeds/qmodem/ are patched: package/feeds/qmodem/* are only
# symlinks into it, and find does not descend into symlinks (that is why the
# old per-script patches never found modem_dial.sh and were silently skipped).
# Every fix is verified afterwards, and the build fails rather than shipping
# firmware without it. Works for both QModem versions in use (XGP V3 follows
# main, Photonicat 2 is pinned to an older commit with different code).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fail() {
  echo "::error::QModem: $*" >&2
  exit 1
}

qm_dir=feeds/qmodem/application/qmodem/files/usr/share/qmodem
if [ ! -f "${qm_dir}/modem_dial.sh" ]; then
  dial_sh=$(find feeds/qmodem -path '*/files/usr/share/qmodem/modem_dial.sh' 2>/dev/null | head -1)
  [ -n "${dial_sh}" ] || fail "modem_dial.sh not found under feeds/qmodem; did the feed layout change?"
  qm_dir=$(dirname "${dial_sh}")
fi
qm_files=${qm_dir%/usr/share/qmodem}
dial_sh="${qm_dir}/modem_dial.sh"
echo "==> QModem fixes in ${qm_files}"

# 1) Default per-modem enable_dial to 1 when it is unset.
#    init.d/qmodem_network and LuCI already treat an unset enable_dial as
#    enabled, but modem_dial.sh treats it as disabled, so modems whose config
#    section predates the option get stuck at "sim card is ready". An explicit
#    '0' is still respected.
sed -i -E 's/^([[:space:]]*config_get enable_dial \$modem_config enable_dial)[[:space:]]*$/\1 "1"/' "${dial_sh}"
grep -Eq '^[[:space:]]*config_get enable_dial \$modem_config enable_dial "?1"?[[:space:]]*$' "${dial_sh}" \
  || fail "the enable_dial default patch no longer applies to ${dial_sh}; review it"
echo "    enable_dial defaults to 1 when unset"

# 2) Kernel 6.18 also lists the QMAP child interfaces in a net/ directory
#    nested under the modem's own net device (.../8-1:1.4/net/wwan0/net), so
#    `find <modem path> -name net` returns two directories: current QModem
#    gives up (dial stuck at "sim card is ready", modem_netdev.sh fails) and
#    the older one picks the nested directory (`tail -1`). Skip net/
#    directories that sit inside another net/ directory. Unlike -maxdepth this
#    does not depend on how deep net/ is, so PCIe/MHI modems keep working.
#    The trailing slash on $modem_path makes BusyBox find descend into the
#    /sys/bus/... symlink.
nested_skip="! -path '*/net/*'"
net_find_re='find .*-name net([[:space:])|]|$)'
mapfile -t net_files < <(grep -rlE -- "${net_find_re}" "${qm_files}" || true)
[ "${#net_files[@]}" -gt 0 ] || fail "no 'find ... -name net' found; review the 6.18 net detection fix"
for f in "${net_files[@]}"; do
  sed -i -E \
    -e "/${net_find_re}/ {" \
    -e "  /\\*\\/net\\/\\*/! s#-name net([[:space:])|]|\$)#-name net ${nested_skip}\\1#" \
    -e '  s#find "\$modem_path" #find "$modem_path"/ #' \
    -e '  s#find \$modem_path #find $modem_path/ #' \
    -e '}' "$f"
done
if grep -rnE -- "${net_find_re}" "${qm_files}" | grep -vF -- "${nested_skip}"; then
  fail "the 'find ... -name net' above was not patched; review the 6.18 net detection fix"
fi
grep -qF -- "-name net ${nested_skip}" "${dial_sh}" \
  || fail "net device detection in ${dial_sh} changed upstream; review the 6.18 net detection fix"
grep -rnF -- "${nested_skip}" "${qm_files}" | sed 's/^/    /'
echo "    nested net/ directories (kernel 6.18 QMAP) are ignored"