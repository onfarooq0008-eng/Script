#!/bin/bash
# ============================================================================
# FastVPN — remove idle/never-connected WireGuard peers
# Run this as root on a node VPS (same box running wg0 from setup-wireguard.sh).
#
# A peer counts as "not connected" if:
#   - it has never completed a handshake at all, OR
#   - its most recent handshake is older than MAX_IDLE_SECONDS
#
# Usage:
#   sudo bash remove-idle-peers.sh [max_idle_seconds] [--dry-run]
#
#   max_idle_seconds defaults to 3600 (1 hour), matching the backend's
#   PENDING_REGISTRATION_MAX_AGE_MS cutoff for peers that never handshaked.
#   Pass a larger value (e.g. 2592000 for 30 days) if you want this to match
#   STALE_REGISTRATION_MAX_AGE_MS behavior for peers that connected before.
#
#   --dry-run just lists what would be removed, without removing anything.
# ============================================================================
set -e

WG_IFACE="wg0"
MAX_IDLE_SECONDS="${1:-3600}"
DRY_RUN=false

for arg in "$@"; do
  if [[ "$arg" == "--dry-run" ]]; then
    DRY_RUN=true
  fi
done

if ! command -v wg >/dev/null 2>&1; then
  echo "ERROR: 'wg' command not found. Run this on the WireGuard node."
  exit 1
fi

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: must run as root (needs to run 'wg set' and edit ${WG_IFACE}.conf)."
  exit 1
fi

NOW=$(date +%s)
REMOVED_COUNT=0

echo "==> Checking peers on ${WG_IFACE} (idle cutoff: ${MAX_IDLE_SECONDS}s)..."

# wg show <iface> dump columns:
# public_key  preshared_key  endpoint  allowed_ips  latest_handshake  transfer_rx  transfer_tx  keepalive
# Skip the first line, which is the interface's own row (no public_key/endpoint fields the same way).
wg show "${WG_IFACE}" dump | tail -n +2 | while IFS=$'\t' read -r PUBKEY _PSK ENDPOINT ALLOWED_IPS LATEST_HANDSHAKE _RX _TX _KEEPALIVE; do
  if [[ "$LATEST_HANDSHAKE" == "0" || -z "$LATEST_HANDSHAKE" ]]; then
    REASON="never connected"
    IDLE_FOR="n/a"
    SHOULD_REMOVE=true
  else
    IDLE_SECONDS=$(( NOW - LATEST_HANDSHAKE ))
    if (( IDLE_SECONDS > MAX_IDLE_SECONDS )); then
      REASON="idle"
      IDLE_FOR="${IDLE_SECONDS}s"
      SHOULD_REMOVE=true
    else
      SHOULD_REMOVE=false
    fi
  fi

  if [[ "$SHOULD_REMOVE" == true ]]; then
    echo "  - ${PUBKEY} (${ALLOWED_IPS}) [${REASON}, idle_for=${IDLE_FOR}]"
    if [[ "$DRY_RUN" == false ]]; then
      # Remove live from the running interface first...
      wg set "${WG_IFACE}" peer "${PUBKEY}" remove
      # ...then strip its [Peer] block from the saved config so it doesn't
      # come back on the next wg-quick up / reboot.
      python3 - "$WG_IFACE" "$PUBKEY" << 'PYEOF'
import sys, re
iface, pubkey = sys.argv[1], sys.argv[2]
path = f"/etc/wireguard/{iface}.conf"
with open(path) as f:
    content = f.read()
# Match this peer's [Peer] block up to (but not including) the next
# [Peer]/[Interface] header or end of file.
pattern = re.compile(
    r"\[Peer\]\n(?:(?!\[Peer\]|\[Interface\]).)*PublicKey = " + re.escape(pubkey) +
    r"\n(?:(?!\[Peer\]|\[Interface\]).)*",
    re.DOTALL,
)
new_content, n = pattern.subn("", content)
if n:
    with open(path, "w") as f:
        f.write(new_content)
PYEOF
    fi
  fi
done

if [[ "$DRY_RUN" == true ]]; then
  echo "==> Dry run complete. No peers were removed."
else
  echo "==> Done."
fi
