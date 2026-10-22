#!/usr/bin/env bash
# check_req.sh - Preflight verification for kernel livepatch builds
# Checks tools, environment, configs, vmlinux, source trees, and patch compatibility.

W="${JAMMY_WORK:-/root/cve-2026-99999}"
P="$W/patches/0001-FCI-Fix-critical-security-KVM-vulnerabilities_5.15.x-y.z.diff"

echo "================================================================================"
echo "          PREFLIGHT ENVIRONMENT & TOOL CHECK                                    "
echo "================================================================================"

# 1. Check build tools
TOOLS=(kpatch-build s3cmd git gcc make bc flex bison readelf objcopy objdump)
MISSING_TOOLS=()
for t in "${TOOLS[@]}"; do
    if command -v "$t" >/dev/null 2>&1; then
        printf "  [OK]    Tool: %-15s (%s)\n" "$t" "$(command -v "$t")"
    else
        printf "  [FAIL]  Tool: %-15s (NOT FOUND)\n" "$t"
        MISSING_TOOLS+=("$t")
    fi
done

# Check GCC version
if command -v gcc >/dev/null 2>&1; then
    echo "  [INFO]  GCC Version: $(gcc --version | head -n1)"
fi

# 2. Check patch file
if [ -f "$P" ]; then
    echo "  [OK]    Patch file: $P"
else
    # Fallback check
    FALLBACK_P=$(ls "$W"/patches/*.diff "$W"/patches/*.patch 2>/dev/null | head -n1)
    if [ -n "$FALLBACK_P" ] && [ -f "$FALLBACK_P" ]; then
        echo "  [WARN]  Default patch not found, found fallback: $FALLBACK_P"
        P="$FALLBACK_P"
    else
        echo "  [FAIL]  Missing patch file in $W/patches/"
    fi
fi

# 3. Check disk space (MIN 40GB)
AVAIL_GB=$(df -BG --output=avail "$W" 2>/dev/null | tail -n1 | tr -dc '0-9')
if [ -n "$AVAIL_GB" ]; then
    if [ "$AVAIL_GB" -ge 40 ]; then
        echo "  [OK]    Free disk space: ${AVAIL_GB}GB (>= 40GB required)"
    else
        echo "  [WARN]  Free disk space: ${AVAIL_GB}GB (< 40GB - may run out of space!)"
    fi
fi

echo ""
echo "================================================================================"
echo "          TARGET KERNEL VERSIONS STATUS MATRIX                                  "
echo "================================================================================"
printf "%-22s %-8s %-9s %-8s %-10s %-13s %s\n" "VERSION" "CONFIG" "VMLINUX" "SOURCE" "CERTS" "PATCH-APPLY" "KO-STATUS"
echo "--------------------------------------------------------------------------------------------------"

# Discover all target versions from config, ignoring .orig and backup files
VERSIONS=()
if [ -d "$W/config" ]; then
    for c in "$W"/config/ubuntu-config-5.15.0-*; do
        [ -f "$c" ] || continue
        [[ "$c" =~ \.orig$ ]] && continue
        v=$(basename "$c" | sed 's/^ubuntu-config-//')
        VERSIONS+=("$v")
    done
fi

# Deduplicate and sort versions
readarray -t SORTED_VERSIONS < <(printf '%s\n' "${VERSIONS[@]}" | sort -u -V)

READY_COUNT=0
BUILT_COUNT=0
TOTAL_COUNT=0

for ver in "${SORTED_VERSIONS[@]}"; do
    [ -n "$ver" ] || continue
    ((TOTAL_COUNT++))
    
    cfg="$W/config/ubuntu-config-$ver"
    vm="$W/vmlinux/vmlinux-$ver-generic"
    src="$W/kernel/linux-$ver"
    ko_file="$W/ko/aio-fci-cve-def-${ver//./-}.ko"
    
    st_cfg="THIEU"
    st_vm="THIEU"
    st_src="THIEU"
    st_certs="-"
    st_patch="-"
    st_ko="CHUA_BUILD"
    
    [ -f "$cfg" ] && st_cfg="OK"
    [ -f "$vm" ] && st_vm="OK"
    [ -f "$src/Makefile" ] && st_src="OK"
    if [ -s "$ko_file" ]; then
        st_ko="DA_BUILD"
        ((BUILT_COUNT++))
    fi
    
    # Check certs patched
    if [ "$st_cfg" = "OK" ]; then
        if grep -qE '^CONFIG_SYSTEM_TRUSTED_KEYS=""' "$cfg" 2>/dev/null && \
           grep -qE '^CONFIG_MODULE_SIG_KEY=""' "$cfg" 2>/dev/null; then
            st_certs="OK"
        elif grep -qE '^CONFIG_SYSTEM_TRUSTED_KEYS=""' "$cfg" 2>/dev/null; then
            st_certs="PARTIAL"
        else
            st_certs="CHUA_VA"
        fi
    fi
    
    # Check patch apply test
    if [ "$st_src" = "OK" ] && [ -f "$P" ]; then
        if git -C "$src" apply --check "$P" >/dev/null 2>&1; then
            st_patch="OK"
        else
            st_patch="KHONG_APPLY"
        fi
    fi
    
    printf "%-22s %-8s %-9s %-8s %-10s %-13s %s\n" "$ver" "$st_cfg" "$st_vm" "$st_src" "$st_certs" "$st_patch" "$st_ko"
    
    if [ "$st_cfg" = "OK" ] && [ "$st_vm" = "OK" ] && [ "$st_src" = "OK" ] && [ "$st_patch" = "OK" ]; then
        ((READY_COUNT++))
    fi
done

echo "--------------------------------------------------------------------------------------------------"
echo "Summary: $BUILT_COUNT ALREADY BUILT | $READY_COUNT / $TOTAL_COUNT READY to build."
echo ""
