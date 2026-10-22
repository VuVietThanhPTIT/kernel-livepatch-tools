#!/usr/bin/env bash
# clean.sh - Clean intermediate build artifacts across all target kernel versions
set -uo pipefail

W="${JAMMY_WORK:-/root/cve-2026-99999}"

echo "Starting cleanup of intermediate build artifacts..."

for VER in $(ls "$W/config" 2>/dev/null | grep -E '^ubuntu-config-5\.15\.0-[0-9]+\.[0-9]+$' | sed 's/^ubuntu-config-//' | sort -V); do
    echo ">>> Cleaning: $VER"
    rm -rf "/root/.kpatch-${VER}"
    SRCDIR="$W/kernel/linux-${VER}"
    if [ -d "$SRCDIR" ]; then
        git -C "$SRCDIR" reset --hard -q >/dev/null 2>&1 || true
        git -C "$SRCDIR" clean -fdxq -e .clone_ok >/dev/null 2>&1 || true
        make -C "$SRCDIR" -s mrproper >/dev/null 2>&1 || true
    fi
done

rm -rf /root/.kpatch /tmp/kpatch* 2>/dev/null || true

echo ""
echo "Cleanup completed. Current disk status:"
df -h "$W"
