#!/bin/sh
# entrypoint.sh — nft-firewall DaemonSet entry point
#
# Lifecycle:
#   1. Idempotently apply /etc/nft/rules.nft:
#        a. Delete the named table if it exists (removes stale rules).
#        b. Load the rules file from scratch.
#   2. Sleep forever, re-applying periodically when REAPPLY_INTERVAL > 0.
#   3. On SIGTERM (pod deletion / node drain): remove the table, then exit.
#
# Environment variables (all optional):
#   NFT_TABLE          Name of the nftables table to manage. Must match the
#                      table name declared in rules.nft. Default: nft-custom
#   RULES_FILE         Path to the nftables rules file.
#                      Default: /etc/nft/rules.nft
#   REAPPLY_INTERVAL   Re-apply rules every N seconds (0 = disabled).
#                      Default: 0
set -e

NFT_TABLE="${NFT_TABLE:-nft-custom}"
RULES_FILE="${RULES_FILE:-/etc/nft/rules.nft}"
REAPPLY_INTERVAL="${REAPPLY_INTERVAL:-0}"

# ── Rule application ──────────────────────────────────────────────────────────
apply_rules() {
    echo "[nft-firewall] Flushing table inet ${NFT_TABLE} (if present)..."
    nft delete table inet "${NFT_TABLE}" 2>/dev/null || true

    echo "[nft-firewall] Loading ${RULES_FILE}..."
    nft -f "${RULES_FILE}"

    echo "[nft-firewall] Active rules:"
    nft list table inet "${NFT_TABLE}"
}

# ── Cleanup on pod termination ────────────────────────────────────────────────
cleanup() {
    echo "[nft-firewall] SIGTERM — removing table inet ${NFT_TABLE}..."
    nft delete table inet "${NFT_TABLE}" 2>/dev/null || true
    echo "[nft-firewall] Cleanup complete."
    exit 0
}

trap cleanup TERM INT

# ── Main ──────────────────────────────────────────────────────────────────────
apply_rules

if [ "${REAPPLY_INTERVAL}" -gt 0 ] 2>/dev/null; then
    echo "[nft-firewall] Will re-apply rules every ${REAPPLY_INTERVAL}s."
    while true; do
        sleep "${REAPPLY_INTERVAL}" &
        wait "$!"
        apply_rules
    done
else
    echo "[nft-firewall] Rules in place. Sleeping until pod is deleted."
    while true; do
        sleep 3600 &
        wait "$!"
    done
fi
