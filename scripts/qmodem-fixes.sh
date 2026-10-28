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

# 2) Pick the QMAP child as the data interface. Vendor drivers register it
#    in a net/ directory under the modem's own net device, e.g.
#    .../8-1:1.4/net/wwan0/net/wwan0_1 (qmi_wwan_q; RM520N/RM500Q always use
#    it) or .../net/rmnet_mhi0/net/rmnet_mhi0.1 (PCIe/MHI). quectel-CM puts
#    the address on that child, and QModem derives the control interface
#    from its name (wwan0_1 -> wwan0, rmnet_mhi0.1 -> rmnet_mhi0), so netifd
#    must use the child: DHCP on wwan0 never gets a lease, which leaves the
#    modem without DNS and outside the wan firewall zone ("no internet").
#    Older QModem got this with `find ... -name net | tail -1`. Current QModem
#    requires exactly one net/ directory and gives up as soon as the child
#    exists (dial stuck at "sim card is ready"). Restore the old choice: keep
#    the last, i.e. deepest, net/ directory. This is not specific to any
#    kernel version. The trailing slash on $modem_path makes BusyBox find
#    descend into the /sys/bus/... symlink.
#    QModem main since e00a306 (2026-10-20) does this itself: dialing uses
#    modem_netdev.sh, which skips a net device that has its own net/ child.
#    That file is then left alone; other `find ... -name net` uses still get
#    the fix.
net_find_re='find .*-name net([[:space:])|]|$)'
picks_child_re='-name net[^|]*[|] ?tail -(n ?)?1'
netdev_sh="${qm_dir}/modem_netdev.sh"
native_child=0
if [ -f "${netdev_sh}" ] && grep -Fq '[ ! -d "$entry/net" ]' "${netdev_sh}"; then
  grep -Fq 'modem_netdev.sh' "${dial_sh}" \
    || fail "modem_netdev.sh picks the QMAP child but ${dial_sh} no longer uses it; review the QMAP net detection fix"
  native_child=1
  echo "    upstream modem_netdev.sh already picks the QMAP child"
fi
mapfile -t net_files < <(grep -rlE -- "${net_find_re}" "${qm_files}" | { [ "${native_child}" = 1 ] && grep -vFx -- "${netdev_sh}" || cat; } || true)
[ "${#net_files[@]}" -gt 0 ] || [ "${native_child}" = 1 ] || fail "no 'find ... -name net' found; review the QMAP net detection fix"
for f in "${net_files[@]}"; do
  sed -i -E \
    -e "/${net_find_re}/ {" \
    -e '  /tail -(n ?)?1/! s#(find [^)|]*-name net[^)|]*)\)#\1 | tail -n 1)#' \
    -e '  s#find "\$modem_path" #find "$modem_path"/ #' \
    -e '  s#find \$modem_path #find $modem_path/ #' \
    -e '}' "$f"
done
if [ "${#net_files[@]}" -gt 0 ] && grep -nE -- "${net_find_re}" "${net_files[@]}" | grep -vE -- "${picks_child_re}"; then
  fail "the 'find ... -name net' above does not pick the QMAP child; review the QMAP net detection fix"
fi
if [ "${native_child}" = 0 ]; then
  grep -qE -- "${picks_child_re}" "${dial_sh}" \
    || fail "net device detection in ${dial_sh} changed upstream; review the QMAP net detection fix"
fi
[ "${#net_files[@]}" -eq 0 ] || grep -nE -- "${net_find_re}" "${net_files[@]}" | sed 's/^/    /'
echo "    the QMAP child (deepest net/ directory) is used as the data interface"
