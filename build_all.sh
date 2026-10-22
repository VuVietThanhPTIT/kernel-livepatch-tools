#!/usr/bin/env bash
# ==============================================================================
# build_all.sh - Automated Batch Kernel Livepatch Builder
# Targets: All 5.15.0-NN.MMM Ubuntu kernels
# ==============================================================================
set -uo pipefail

W="${JAMMY_WORK:-/root/cve-2026-99999}"
PATCH_FILE="$W/patches/0001-FCI-Fix-critical-security-KVM-vulnerabilities_5.15.x-y.z.diff"
OUTPUT_DIR="$W/ko"
LOG_DIR="$W/logs"
MIN_FREE_GB=40

mkdir -p "$OUTPUT_DIR" "$LOG_DIR"

# 1. Kiem tra patch file
[ -f "$PATCH_FILE" ] || PATCH_FILE=$(ls "$W"/patches/*.diff "$W"/patches/*.patch 2>/dev/null | head -n1)
if [ ! -f "$PATCH_FILE" ]; then
    echo "[ERROR] Missing patch file in $W/patches/" >&2
    exit 1
fi

# 2. Lay danh sach FULL cac ban kernel, loai bo triet de .orig va file rac
if [ "$#" -gt 0 ]; then
    VERSIONS=("$@")
else
    mapfile -t VERSIONS < <(ls "$W/config" 2>/dev/null | grep -E '^ubuntu-config-5\.15\.0-[0-9]+\.[0-9]+$' | grep -v '\.orig' | sed 's/^ubuntu-config-//' | sort -V)
fi

if [ ${#VERSIONS[@]} -eq 0 ]; then
    echo "[ERROR] No valid kernel versions found in $W/config." >&2
    exit 1
fi

echo "================================================================================"
echo " Starting Build: ${#VERSIONS[@]} versions"
echo " Patch:   $PATCH_FILE"
echo " Output:  $OUTPUT_DIR"
echo " Cores:   $(nproc)"
echo "================================================================================"

SUCCESS_LIST=()
FAILED_LIST=()
SKIPPED_LIST=()

for VER in "${VERSIONS[@]}"; do
    [ -n "$VER" ] || continue

    # Tu dong map neu nguoi dung truyen dang 5.15.0-94-generic
    if [[ "$VER" =~ ^5\.15\.0-[0-9]+-generic$ ]]; then
        matched=$(ls "$W/config"/ubuntu-config-"${VER%-generic}".* 2>/dev/null | grep -v '\.orig' | head -n1 | sed 's/.*ubuntu-config-//')
        [ -n "$matched" ] && VER="$matched"
    fi

    echo ""
    echo ">>> Processing Target: $VER"

    CFG="$W/config/ubuntu-config-${VER}"
    VMLINUX="$W/vmlinux/vmlinux-${VER}-generic"
    SRCDIR="$W/kernel/linux-${VER}"
    TARGET_RELEASE="${VER%.*}-generic"
    KPATCH_NAME="aio-fci-cve-def-${VER//./-}"
    OUTPUT_KO="$OUTPUT_DIR/${KPATCH_NAME}.ko"
    CACHEDIR="/root/.kpatch-${VER}"
    BUILD_LOG="$LOG_DIR/${VER}_build.log"

    # 0. Kiem tra neu da build thanh cong tu truoc thi bo qua luon
    if [ -s "$OUTPUT_KO" ]; then
        echo "  [SKIP] Already built successfully: $OUTPUT_KO"
        SUCCESS_LIST+=("$VER (Already built: $KPATCH_NAME.ko)")
        continue
    fi

    # Kiem tra dung luong dia con lai
    AVAIL=$(df -BG --output=avail "$W" 2>/dev/null | tail -n1 | tr -dc '0-9')
    if [ -n "$AVAIL" ] && [ "$AVAIL" -lt "$MIN_FREE_GB" ]; then
        echo "  [ABORT] Disk space ${AVAIL}GB < ${MIN_FREE_GB}GB required. Stopping!" >&2
        SKIPPED_LIST+=("$VER (No disk space)")
        break
    fi

    # Kiem tra dau vao
    if [ ! -f "$CFG" ] || [ ! -f "$VMLINUX" ] || [ ! -f "$SRCDIR/Makefile" ]; then
        echo "  [SKIP] Missing input files (config, vmlinux or source) for $VER"
        SKIPPED_LIST+=("$VER (Missing inputs)")
        continue
    fi

    # Dam bao da va 2 dong certs
    sed -i 's/^CONFIG_SYSTEM_TRUSTED_KEYS=.*/CONFIG_SYSTEM_TRUSTED_KEYS=""/' "$CFG"
    sed -i 's/^CONFIG_MODULE_SIG_KEY=.*/CONFIG_MODULE_SIG_KEY=""/' "$CFG"

    # Bat CONFIG_DEBUG_SECTION_MISMATCH=y truc tiep trong file config
    sed -i 's/^CONFIG_DEBUG_SECTION_MISMATCH=.*/CONFIG_DEBUG_SECTION_MISMATCH=y/' "$CFG"
    grep -q '^CONFIG_DEBUG_SECTION_MISMATCH=y' "$CFG" || echo 'CONFIG_DEBUG_SECTION_MISMATCH=y' >> "$CFG"

    # Kiem tra patch apply duoc len source
    if ! git -C "$SRCDIR" apply --check "$PATCH_FILE" >/dev/null 2>&1; then
        echo "  [SKIP] Patch cannot be applied cleanly to $VER!"
        git -C "$SRCDIR" apply --check -v "$PATCH_FILE" > "$LOG_DIR/${VER}_patch_reject.log" 2>&1
        SKIPPED_LIST+=("$VER (Patch conflict)")
        continue
    fi

    # Reset va phuc hoi nguyen trang source truoc khi build
    git -C "$SRCDIR" reset --hard >/dev/null 2>&1
    git -C "$SRCDIR" checkout -f >/dev/null 2>&1
    git -C "$SRCDIR" clean -fdx >/dev/null 2>&1

    echo "  [*] Building: $KPATCH_NAME (KREL: $TARGET_RELEASE)..."
    rm -f "$OUTPUT_KO"
    START_TIME=$(date +%s)

    # Thiet lap co MAKEFLAGS va KCFLAGS chong lech ham inline
    export MAKEFLAGS="${MAKEFLAGS:+$MAKEFLAGS }CONFIG_DEBUG_SECTION_MISMATCH=y"
    export KCFLAGS="-fno-inline-functions-called-once -fno-ipa-sra -fno-ipa-cp-clone -fno-partial-inlining"

    KPATCH_ARGS=(
        -a "$TARGET_RELEASE"
        -s "$SRCDIR"
        -v "$VMLINUX"
        -c "$CFG"
        -j "$(nproc)"
        -n "$KPATCH_NAME"
        -o "$OUTPUT_DIR"
        --skip-compiler-check
        "$PATCH_FILE"
    )

    BUILD_OK=0
    if CACHEDIR="$CACHEDIR" kpatch-build "${KPATCH_ARGS[@]}" > "$BUILD_LOG" 2>&1; then
        [ -s "$OUTPUT_KO" ] && BUILD_OK=1
    fi

    DURATION=$(( $(date +%s) - START_TIME ))

    if [ "$BUILD_OK" -eq 1 ]; then
        echo "  [SUCCESS] Built: $OUTPUT_KO (${DURATION}s)"
        SUCCESS_LIST+=("$VER ($KPATCH_NAME.ko)")
    else
        echo "  [FAILED] Build failed for $VER (${DURATION}s)!" >&2
        echo "           Last 20 lines of build log:" >&2
        echo "--------------------------------------------------" >&2
        tail -n 20 "$BUILD_LOG" >&2
        echo "--------------------------------------------------" >&2
        FAILED_LIST+=("$VER (See $BUILD_LOG)")
    fi

    # =========================================================================
    # DỌN DẸP DÙ ĐÃ BUILD XONG HAY BUILD DỞ / LỖI
    # =========================================================================
    rm -rf "$CACHEDIR"
    rm -rf /root/.kpatch /tmp/kpatch* 2>/dev/null || true
    if [ -d "$SRCDIR" ]; then
        git -C "$SRCDIR" reset --hard -q >/dev/null 2>&1
        git -C "$SRCDIR" checkout -f -q >/dev/null 2>&1
        git -C "$SRCDIR" clean -fdxq -e .clone_ok >/dev/null 2>&1
        make -C "$SRCDIR" -s mrproper >/dev/null 2>&1 || true
    fi

    AVAIL_AFTER=$(df -h "$W" 2>/dev/null | tail -n1 | awk '{print $4}')
    echo "  [*] Intermediate build artifacts cleared. Disk free: $AVAIL_AFTER"
done

echo ""
echo "================================================================================"
echo "                       FINAL BUILD SUMMARY                                      "
echo "================================================================================"
echo " SUCCESSFUL (${#SUCCESS_LIST[@]}):"
for s in "${SUCCESS_LIST[@]}"; do echo "   - $s"; done
echo ""
echo " FAILED (${#FAILED_LIST[@]}):"
for f in "${FAILED_LIST[@]}"; do echo "   - $f"; done
echo ""
echo " SKIPPED (${#SKIPPED_LIST[@]}):"
for sk in "${SKIPPED_LIST[@]}"; do echo "   - $sk"; done
echo "================================================================================"

rm -rf /root/.kpatch /tmp/kpatch* 2>/dev/null || true
echo ""
echo "Disk status:"
df -h "$W"

