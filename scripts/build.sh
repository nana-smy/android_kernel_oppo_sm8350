#!/usr/bin/env bash
# =============================================================================
# OPPO SM8350 (Find X3 Pro / lahaina) 非 GKI 内核 CI 编译脚本
#
# 依赖两个仓库 + AOSP 布局：
#   $WORK/kernel/msm-5.4   <- android_kernel_oppo_sm8350
#   $WORK/vendor           <- android_kernel_modules_and_devicetree_oppo_sm8350 的 vendor/
# 内核里 78~96 个符号链接指向上面的 vendor/oplus 与 vendor/qcom/proprietary/devicetree，
# 布局错了 Kconfig 第一步就会报 "can't open file kernel/sched_assist/Kconfig"。
#
# 可选功能：
#   ENABLE_RESUKISU=true  -> 集成 ReSukiSU（drivers/kernelsu），CONFIG_KSU=y
#   ENABLE_SUSFS=true     -> 打 simonpunk/susfs4ksu 的 kernel-5.4 内核补丁 + KSU 侧内置 SUSFS
#   LTO=true              -> 保留 CONFIG_LTO_CLANG / CFI / SCS（需要匹配的 clang，内存 ≥16G）
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

KERNEL_REPO="${KERNEL_REPO:-https://github.com/nana-smy/android_kernel_oppo_sm8350.git}"
VENDOR_REPO="${VENDOR_REPO:-https://github.com/nana-smy/android_kernel_modules_and_devicetree_oppo_sm8350.git}"

KERNEL_BRANCH="${KERNEL_BRANCH:-oppo/sm8350_u_14.0.0_find_x3_pro}"
CLANG_VERSION="${CLANG_VERSION:-clang-r487747c}"
ENABLE_RESUKISU="${ENABLE_RESUKISU:-true}"
RESUKISU_REF="${RESUKISU_REF:-v4.2.0-rc3}"
ENABLE_SUSFS="${ENABLE_SUSFS:-true}"
SUSFS_REF="${SUSFS_REF:-kernel-5.4}"
LTO="${LTO:-false}"
BUILD_MODULES="${BUILD_MODULES:-true}"
AK3_DEVICES="${AK3_DEVICES:-}"          # 例如 "peux"，留空则不打 AnyKernel3
JOBS="${JOBS:-$(nproc)}"

WORK="${WORK:-$PWD/tree}"
ARTIFACTS="${ARTIFACTS:-$PWD/artifacts}"
mkdir -p "$WORK" "$ARTIFACTS"

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

# -----------------------------------------------------------------------------
# 1. 拉取内核 + vendor（两者分支名一一对应）
# -----------------------------------------------------------------------------
log "1/8 克隆内核与 vendor 仓库 (branch=$KERNEL_BRANCH)"
if [ ! -d "$WORK/kernel/msm-5.4/.git" ]; then
  mkdir -p "$WORK/kernel"
  git clone --depth 1 -b "$KERNEL_BRANCH" "$KERNEL_REPO" "$WORK/kernel/msm-5.4"
fi

if [ ! -d "$WORK/vendor/oplus" ]; then
  rm -rf "$WORK/vendor-src"
  git clone --depth 1 -b "$KERNEL_BRANCH" "$VENDOR_REPO" "$WORK/vendor-src"
  mv "$WORK/vendor-src/vendor" "$WORK/vendor"
  # vendor 仓库里的 techpack（audio/display/camera/dataipa/video）合并进内核树
  cp -a "$WORK/vendor-src/kernel/msm-5.4/techpack/." "$WORK/kernel/msm-5.4/techpack/" 2>/dev/null || true
  rm -rf "$WORK/vendor-src"
fi

K="$WORK/kernel/msm-5.4"
cd "$K"

BROKEN=$(find . -type l -not -name '*~*' ! -exec test -e {} \; -print 2>/dev/null | wc -l | tr -d ' ')
log "断链检查: $BROKEN 个"
if [ "$BROKEN" != "0" ]; then
  find . -type l -not -name '*~*' ! -exec test -e {} \; -print 2>/dev/null | head -20 || true
  echo "[-] 目录布局不正确，请检查 \$WORK/kernel/msm-5.4 与 \$WORK/vendor 的相对位置"
  exit 1
fi

# -----------------------------------------------------------------------------
# 2. 工具链：AOSP prebuilt clang
# -----------------------------------------------------------------------------
log "2/8 准备 clang ($CLANG_VERSION)"
case "$CLANG_VERSION" in
  clang-r383902b) CLANG_BRANCH=android12-release ;;
  clang-r416183b) CLANG_BRANCH=android13-release ;;
  clang-r450784d|clang-r450784e) CLANG_BRANCH=android13-release ;;
  clang-r487747c|clang-r487747) CLANG_BRANCH=android14-release ;;
  *) echo "[-] 未知 clang 版本 $CLANG_VERSION"; exit 1 ;;
esac

if [ ! -d "$WORK/clang-aosp" ]; then
  git clone --depth 1 -b "$CLANG_BRANCH" \
    https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86 \
    "$WORK/clang-aosp"
fi

CLANG_DIR="$WORK/clang-aosp/$CLANG_VERSION"
if [ ! -x "$CLANG_DIR/bin/clang" ]; then
  echo "[!] 未找到 $CLANG_VERSION，预置目录内容如下："
  ls -1 "$WORK/clang-aosp" | head -30
  CLANG_DIR=""
  for d in "$WORK"/clang-aosp/clang-r*; do
    [ -x "$d/bin/clang" ] && CLANG_DIR="$d"
  done
  [ -n "$CLANG_DIR" ] && echo "[!] 回退使用 $CLANG_DIR"
fi
if [ -z "${CLANG_DIR:-}" ] || [ ! -x "$CLANG_DIR/bin/clang" ]; then
  echo "[-] 没有可用的 clang 可执行文件"
  exit 1
fi
export PATH="$CLANG_DIR/bin:$PATH"
export LD_LIBRARY_PATH="$CLANG_DIR/lib:$CLANG_DIR/lib64:${LD_LIBRARY_PATH:-}"
clang --version | head -2

# -----------------------------------------------------------------------------
# 3. ReSukiSU（可选）
# -----------------------------------------------------------------------------
if [ "$ENABLE_RESUKISU" = "true" ]; then
  log "3/8 集成 ReSukiSU ($RESUKISU_REF)"
  rm -rf KernelSU
  git clone --depth 1 -b "$RESUKISU_REF" https://github.com/ReSukiSU/ReSukiSU.git KernelSU
  ln -sfn ../KernelSU/kernel drivers/kernelsu
  grep -q "kernelsu" drivers/Makefile || printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> drivers/Makefile
  grep -q 'drivers/kernelsu/Kconfig' drivers/Kconfig || \
    sed -i '/endmenu/i\source "drivers/kernelsu/Kconfig"' drivers/Kconfig
  # ReSukiSU v4.2+ 的 kernel/Kconfig 自带 KSU_SUSFS 菜单（依赖 THREAD_INFO_IN_TASK）
  if grep -q "KSU_SUSFS" drivers/kernelsu/Kconfig; then
    echo "[+] ReSukiSU 内置 SUSFS 支持"
  else
    echo "[!] 该 ReSukiSU 版本无内置 SUSFS，SUSFS 将只能依赖内核补丁"
  fi
else
  log "3/8 跳过 ReSukiSU"
fi

# -----------------------------------------------------------------------------
# 4. SUSFS 内核补丁（可选）
# -----------------------------------------------------------------------------
if [ "$ENABLE_SUSFS" = "true" ]; then
  log "4/8 打 SUSFS 内核补丁 (susfs4ksu@$SUSFS_REF)"
  rm -rf "$WORK/susfs4ksu"
  git clone --depth 1 -b "$SUSFS_REF" https://gitlab.com/simonpunk/susfs4ksu.git "$WORK/susfs4ksu"
  S="$WORK/susfs4ksu/kernel_patches"

  # 官方补丁不含新文件，需要先拷贝
  cp "$S/fs/susfs.c" fs/
  cp "$S/include/linux/susfs.h" "$S/include/linux/susfs_def.h" include/linux/

  set +e
  patch -p1 --forward --fuzz=3 < "$S/50_add_susfs_in_kernel-5.4.patch" > /tmp/susfs.log 2>&1
  set -e
  grep -E '^patching file' /tmp/susfs.log | wc -l | xargs -I{} echo "[+] 打进 {} 个文件" || true

  if [ -f fs/proc/fd.c.rej ]; then
    echo "[!] fs/proc/fd.c 有冲突（OPPO 改过 seq_show），执行兼容修正"
    python3 "$SCRIPT_DIR/fix_fd_proc.py" fs/proc/fd.c
    rm -f fs/proc/fd.c.rej
  fi

  REJ=$(find . -name '*.rej' -not -path './.git/*' | wc -l | tr -d ' ')
  if [ "$REJ" != "0" ]; then
    echo "[-] 仍有 $REJ 个 .rej，SUSFS 补丁不完整："
    find . -name '*.rej' -not -path './.git/*' | head -20
    exit 1
  fi
  find . -name '*.orig' -not -path './.git/*' -delete 2>/dev/null || true

  # SUSFS Inline Hook：ReSukiSU/BakaSU 在 non-GKI 内核上要求 ksu_handle_* 钩子，
  # 官方脚本把钩子插入 fs/exec.c、fs/open.c、fs/stat.c、kernel/sys.c 等处
  log "4b/8 注入 SUSFS inline hooks"
  bash "$SCRIPT_DIR/susfs_inline_hook_patches.sh" > /tmp/hooks.log 2>&1 || {
    tail -30 /tmp/hooks.log; echo "[-] inline hook 注入失败"; exit 1;
  }
  grep -c "ksu_handle" kernel/sys.c fs/exec.c fs/open.c fs/stat.c fs/read_write.c kernel/reboot.c drivers/input/input.c 2>/dev/null | sed 's/^/   /' 
else
  log "4/8 跳过 SUSFS"
fi

# -----------------------------------------------------------------------------
# 5. 生成 defconfig（gki + lahaina GKI + lahaina QGKI）
# -----------------------------------------------------------------------------
log "5/8 生成 defconfig"
rm -rf out && mkdir -p out
ARCH=arm64 ./scripts/kconfig/merge_config.sh -m -O out \
  arch/arm64/configs/gki_defconfig \
  arch/arm64/configs/vendor/lahaina_GKI.config \
  arch/arm64/configs/vendor/lahaina_QGKI.config > /dev/null

if [ "$ENABLE_RESUKISU" = "true" ]; then
cat >> out/.config <<'EOF'
CONFIG_KSU=y
EOF
fi

if [ "$ENABLE_RESUKISU" = "true" ] && [ "$ENABLE_SUSFS" = "true" ]; then
cat >> out/.config <<'EOF'
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_ENABLE_LOG=y
CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
CONFIG_KSU_SUSFS_SUS_MAP=y
CONFIG_THREAD_INFO_IN_TASK=y
EOF
fi

# CONFIG_WERROR 会把 clang 的任意新告警变成致命错误，OPPO 私有代码在 clang 12 下过不了
./scripts/config --file out/.config -d WERROR || true

if [ "$LTO" != "true" ]; then
  # 4G/2 核或 4 核 runner 上 LTO/CFI 极易 OOM；关闭后功能不受影响
  ./scripts/config --file out/.config \
    -d LTO_CLANG -d CFI_CLANG -d SHADOW_CALL_STACK -d DEBUG_INFO
fi

MAKE_ARGS=(
  ARCH=arm64
  O=out
  CROSS_COMPILE=aarch64-linux-gnu-
  CLANG_TRIPLE=aarch64-linux-gnu-
  CC=clang
  REAL_CC=clang
  LD=ld.lld
  AR=llvm-ar
  NM=llvm-nm
  OBJCOPY=llvm-objcopy
  OBJDUMP=llvm-objdump
  READELF=llvm-readelf
  STRIP=llvm-strip
  DISABLE_WRAPPER=1            # 关掉 gcc-wrapper.py，否则普通告警即致命错误
)
KCFLAGS="-Wno-unknown-warning-option -Wno-error=strict-prototypes \
-Wno-error=implicit-function-declaration -Wno-error=implicit-int -Wno-error=return-type \
-Wno-error=incompatible-pointer-types -Wno-error=date-time"

make "${MAKE_ARGS[@]}" olddefconfig > /tmp/olddef.log 2>&1 || {
  tail -40 /tmp/olddef.log
  exit 1
}
echo "[+] 关键配置："
grep -E "^CONFIG_(KSU=|KSU_SUSFS=|LTO_CLANG=|CFI_CLANG=|LOCALVERSION)" out/.config || true

# -----------------------------------------------------------------------------
# 6. 编译
# -----------------------------------------------------------------------------
log "6/8 编译 Image + dtbs (jobs=$JOBS)"
time make -j"$JOBS" "${MAKE_ARGS[@]}" KCFLAGS="$KCFLAGS" Image dtbs

if [ "$BUILD_MODULES" = "true" ]; then
  log "6/8 编译 modules"
  make -j"$JOBS" "${MAKE_ARGS[@]}" KCFLAGS="$KCFLAGS" modules || echo "[!] modules 编译失败，继续打包内核"
fi

# -----------------------------------------------------------------------------
# 7. 收集产物
# -----------------------------------------------------------------------------
log "7/8 收集产物"
BOOT="$K/out/arch/arm64/boot"
cp "$BOOT/Image" "$ARTIFACTS/"
if [ -f "$BOOT/Image.gz" ]; then cp "$BOOT/Image.gz" "$ARTIFACTS/"; fi
cp "$K/out/.config" "$ARTIFACTS/config-${KERNEL_BRANCH//\//_}"
mkdir -p "$ARTIFACTS/dtb"
find "$K/out/arch/arm64/boot/dts" -name '*.dtb' -o -name '*.dtbo' 2>/dev/null | xargs -r -I{} cp {} "$ARTIFACTS/dtb/"

if [ "$BUILD_MODULES" = "true" ]; then
  KTAG="$(make -s "${MAKE_ARGS[@]}" kernelrelease 2>/dev/null || echo '')"
  if [ -n "$KTAG" ]; then
    rm -rf "$ARTIFACTS/modules"
    make "${MAKE_ARGS[@]}" INSTALL_MOD_PATH="$ARTIFACTS/modules" modules_install >/dev/null 2>&1 || true
    # 去掉 build/source 软链接，避免解压时指向 CI 路径
    rm -f "$ARTIFACTS/modules/lib/modules/$KTAG/build" "$ARTIFACTS/modules/lib/modules/$KTAG/source" 2>/dev/null || true
  fi
fi

# -----------------------------------------------------------------------------
# 8. 可选 AnyKernel3 打包
# -----------------------------------------------------------------------------
if [ -n "$AK3_DEVICES" ]; then
  log "8/8 打包 AnyKernel3 ($AK3_DEVICES)"
  AK3="$WORK/AnyKernel3"
  rm -rf "$AK3"
  git clone --depth 1 https://github.com/osm0sis/AnyKernel3.git "$AK3"
  rm -rf "$AK3/.git" "$AK3/README.md"
  cp "$BOOT/Image" "$AK3/Image"
  grep -q "kernel.string=.*" "$AK3/anykernel.sh" || true
  sed -i "s/^device.name1=.*/device.name1=$AK3_DEVICES/" "$AK3/anykernel.sh" || true
  if ls "$ARTIFACTS"/dtb/*.dtb >/dev/null 2>&1; then
    mkdir -p "$AK3/dtb"
    cp "$ARTIFACTS"/dtb/*.dtb "$AK3/dtb/"
    sed -i 's/^#do.devicecheck=1/do.devicecheck=0/' "$AK3/anykernel.sh" || true
  fi
  (cd "$AK3" && zip -r9 "$ARTIFACTS/kernel-AK3-${KERNEL_BRANCH//\//_}.zip" . -x '*.git*' >/dev/null)
fi

(cd "$ARTIFACTS" && ls -lh)
echo "[+] 全部完成"
