#!/bin/bash
# remove-inactive-peers.sh
#
# Run this directly on a NODE VPS (not the brain). Removes WireGuard peers
# that have NEVER completed a handshake -- i.e. registered but stuck/dead,
# never actually connected even once. Leaves alone any peer that connected
# before and is just idle right now (that's normal, not "stuck").
#
# Usage:
#   sudo bash remove-inactive-peers.sh            # dry run, just lists them
#   sudo bash remove-inactive-peers.sh --apply     # actually removes them

set -euo pipefail

IFACE="wg0"
APPLY=false
[[ "${1:-}" == "--apply" ]] && APPLY=true

if ! command -v wg >/dev/null 2>&1; then
  echo "wg command not found -- run this on the VPN node, not your local machine." >&2
  exit 1
fi

echo "Checking interface: $IFACE"
echo

NEVER_CONNECTED=()
while read -r pubkey ts; do
  [[ -z "$pubkey" ]] && continue
  if [[ "$ts" == "0" ]]; then
    NEVER_CONNECTED+=("$pubkey")
  fi
done < <(wg show "$IFACE" latest-handshakes)

TOTAL=$(wg show "$IFACE" peers | wc -l)
COUNT=${#NEVER_CONNECTED[@]}

echo "Total peers on $IFACE: $TOTAL"
echo "Never completed a handshake (stuck/pending): $COUNT"
echo

if [[ "$COUNT" -eq 0 ]]; then
  echo "Nothing to remove."
  exit 0
fi

for pubkey in "${NEVER_CONNECTED[@]}"; do
  echo "  $pubkey"
done
echo

if [[ "$APPLY" == false ]]; then
  echo "Dry run only -- nothing was removed."
  echo "Re-run with --apply to actually remove these peers:"
  echo "  sudo bash remove-inactive-peers.sh --apply"
  exit 0
fi

for pubkey in "${NEVER_CONNECTED[@]}"; do
  wg set "$IFACE" peer "$pubkey" remove
  echo "Removed: $pubkey"
done

# Persist the removal so peers don't come back on reboot / wg-quick restart
wg-quick save "$IFACE"
echo
echo "Done. Removed $COUNT peer(s) and saved config."
echo
echo "NOTE: this only cleans up WireGuard on THIS node. The brain VPS's own"
echo "registration database still has bookkeeping rows for these devices --"
echo "they'll get cleaned up there automatically on its next pending-registration"
echo "sweep (every 5 min, once its updated server.js/store.js are deployed),"
echo "or you can just leave it -- the brain will attempt to remove-peer again,"
echo "safely no-op since the peer is already gone."
