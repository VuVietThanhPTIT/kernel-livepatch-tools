#!/bin/bash
ACTION="$1"
FILE="$2"

usage() {
    echo "Usage: $0 load <module.ko> | $0 unload [patch_name]"
    echo "Available .ko files:"
    ls -1 *.ko 2>/dev/null | grep -v '\.orig$' | sed 's/^/  /'
    exit 1
}

unstall() {
    trigger_vm_transition "$@"
}

trigger_vm_transition() {
    local target="$1"
    for s in /proc/[0-9]*/task/[0-9]*/patch_state; do
        [ -f "$s" ] || continue
        if [ "$(cat "$s" 2>/dev/null)" = "$target" ]; then
            local tid=$(echo "$s" | cut -d/ -f5)
            if grep -q "KVM" "/proc/$tid/comm" 2>/dev/null; then
                local tgid=$(awk '/^Tgid:/ {print $2}' "/proc/$tid/status" 2>/dev/null)
                local vm=$(tr '\0' '\n' < "/proc/$tgid/cmdline" 2>/dev/null | grep -A1 "^-name$" | tail -n1 | sed -E 's/^guest=([^,]+).*/\1/')
                if [ -n "$vm" ] && [ "$vm" != "Unknown" ]; then
                    echo "  [!] Triggering VM transition: $vm (TID: $tid)..."
                    docker exec -u0 nova_libvirt virsh suspend "$vm" 2>/dev/null
                    sleep 0.5
                    docker exec -u0 nova_libvirt virsh resume "$vm" 2>/dev/null
                fi
            fi
        fi
    done
}

if [ "$ACTION" = "load" ]; then
    [ -z "$FILE" ] || [ ! -f "$FILE" ] && usage
    FULL="$(realpath "$FILE")"
    NAME=$(modinfo -F name "$FULL" 2>/dev/null)
    [ -z "$NAME" ] && NAME=$(basename "$FULL" .ko | tr '-' '_')
    SYS="/sys/kernel/livepatch/$NAME"

    echo "==> kpatch load $FULL..."
    kpatch load "$FULL" &
    KPID=$!

    while [ -d "/proc/$KPID" ]; do
        sleep 2
        [ -d "$SYS" ] && [ "$(cat "$SYS/transition" 2>/dev/null)" = "1" ] && trigger_vm_transition "0"
    done
    wait "$KPID"
    kpatch list

elif [ "$ACTION" = "unload" ]; then
    NAME="$FILE"
    [ -z "$NAME" ] && NAME=$(kpatch list 2>/dev/null | awk '/\[enabled\]|\[disabled\]/ {print $1}' | head -n1)
    [ -z "$NAME" ] && { echo "No active patch found."; exit 0; }
    SYS="/sys/kernel/livepatch/$NAME"

    echo "==> kpatch unload $NAME..."
    kpatch unload "$NAME" &
    KPID=$!

    while [ -d "/proc/$KPID" ]; do
        sleep 2
        [ -d "$SYS" ] && [ "$(cat "$SYS/transition" 2>/dev/null)" = "1" ] && trigger_vm_transition "1"
    done
    wait "$KPID"
    kpatch list

else
    usage
fi

