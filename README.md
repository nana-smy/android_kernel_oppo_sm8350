# OPPO SM8350 内核 CI

本仓库内置 GitHub Actions 流水线：`.github/workflows/build-kernel.yml` + `scripts/build.sh`，按需编译 `oppo/sm8350_*`
系列分支的非 GKI 内核，可选集成 **ReSukiSU** 与 **SUSFS**。

- 默认分支：`oppo/sm8350_u_14.0.0_find_x3_pro`（Linux 5.4.233，ColorOS 14 / Android 14）
- 配套 vendor 仓库：`nana-smy/android_kernel_modules_and_devicetree_oppo_sm8350`（`vendor/oplus`、`vendor/qcom/proprietary/devicetree`、techpack）

## 使用

`Actions` → **Build OPPO SM8350 Kernel** → **Run workflow**：

| 输入 | 说明 | 默认 |
| --- | --- | --- |
| `kernel_branch` | 内核 + vendor 同时使用的分支（两者分支名一一对应） | `oppo/sm8350_u_14.0.0_find_x3_pro` |
| `resukisu` | 是否集成 ReSukiSU | true |
| `resukisu_ref` | ReSukiSU 版本 | `v4.2.0-rc3` |
| `susfs` | 是否打 SUSFS 内核补丁 | true |
| `susfs_ref` | susfs4ksu 分支 | `kernel-5.4` |
| `clang_version` | AOSP prebuilt clang | `clang-r487747c` |
| `lto` | 保留 LTO/CFI/SCS（吃内存） | false |
| `build_modules` | 编译 .ko | true |
| `ak3_enable` | 是否打包 AnyKernel3 刷机包（关则只出裸 Image/dtb） | false |
| `ak3_devices` | 设备代号，空格分隔（`peux PEEM00`）；仅在校验开启时使用 | 空 |
| `ak3_devicecheck` | 刷入时校验设备代号；关闭则 `do.devicecheck=0` 且忽略代号 | true |

产物：`Image` / `Image.gz`、`dtb/`（含 dtbo）、`config-<branch>`、`modules/`、可选 `kernel-AK3-<branch>.zip`。

## 为什么必须两个仓库一起拉

本内核仓库有 78~96 个符号链接指向仓库外的 `vendor/oplus/...`（充电、触控、性能调度、thermal、sensor、secureguard 等 OPPO 私有代码），
`arch/arm64/boot/dts/vendor` 指向 `vendor/qcom/proprietary/devicetree`（lahaina 设备树）。
只克隆内核仓库时 Kconfig 会直接报 `can't open file "kernel/sched_assist/Kconfig"`。

脚本按 AOSP 布局组装：

```
$WORK/
├── kernel/msm-5.4     # 内核（必须在 kernel/ 下一层，符号链接按 ../../../vendor 解析）
└── vendor/
    ├── oplus/...
    └── qcom/proprietary/devicetree
```

并把 vendor 仓库的 `kernel/msm-5.4/techpack/{audio,camera,dataipa,display,video}` 合并进内核树。
脚本开头做断链检查，非 0 直接失败并打印清单。

## ReSukiSU 集成

```bash
git clone --depth 1 -b v4.2.0-rc3 https://github.com/ReSukiSU/ReSukiSU.git KernelSU
ln -sfn ../KernelSU/kernel drivers/kernelsu
# drivers/Makefile: obj-$(CONFIG_KSU) += kernelsu/
# drivers/Kconfig:  source "drivers/kernelsu/Kconfig"
```

`v4.2.x` 起 ReSukiSU 的 `kernel/Kconfig` 已自带 `KSU_SUSFS` 菜单；`v4.1.0` 没有（脚本会提示）。
`CONFIG_KSU_SUSFS` 依赖 `THREAD_INFO_IN_TASK && 64BIT`，sm8350 满足。

## SUSFS 集成（官方顺序）

```bash
cp kernel_patches/fs/susfs.c                fs/
cp kernel_patches/include/linux/susfs.h \
   kernel_patches/include/linux/susfs_def.h include/linux/
patch -p1 --forward --fuzz=3 < kernel_patches/50_add_susfs_in_kernel-5.4.patch
```

官方 5.4 补丁在 OPPO 魔改的 `fs/proc/fd.c` 上有 1 个 hunk 冲突（OPPO 删了 `seq_show` 的 `ino` 字段），
`scripts/fix_fd_proc.py` 按 SUSFS 原语义补回 `sus_mount` 假 mnt_id 逻辑，同时保留 OPPO 的输出格式。
其余任何 `.rej` 都会让流水线失败并打印，避免产出“看起来成功”的坏内核。

开启的配置：`CONFIG_KSU_SUSFS`、`_SUS_PATH`、`_SUS_MOUNT`、`_SUS_KSTAT`、`_SPOOF_UNAME`、`_ENABLE_LOG`、
`_HIDE_KSU_SUSFS_SYMBOLS`、`_SPOOF_CMDLINE_OR_BOOTCONFIG`、`_OPEN_REDIRECT`、`_SUS_MAP`。

## 编译参数要点

- `DISABLE_WRAPPER=1`：内核默认用 `scripts/gcc-wrapper.py` 把任何新告警升级为致命错误，老 vendor 代码在 clang 下过不了。
- 放宽 `-Wno-error=strict-prototypes` 等历史告警（只影响告警等级）。
- `lto=false` 时关闭 `LTO_CLANG` / `CFI_CLANG` / `SHADOW_CALL_STACK` / `DEBUG_INFO`，避免 4 核 runner OOM。

## 验证状态

已在本地（Ubuntu + clang-12）对 `oppo/sm8350_u_14.0.0_find_x3_pro`（5.4.233）实测：

- 两仓库组装后断链 0
- SUSFS 补丁 + `fd.c` 兼容修正后，`fs/susfs.o`、`fs/proc/fd.o`、`fs/namespace.o`、`fs/open.o` 编译通过
- ReSukiSU v4.2.0-rc3 集成后 `olddefconfig` 输出 `CONFIG_KSU=y`、`CONFIG_KSU_SUSFS=y` 及全部子项 y

## 已知限制

- 12.1 分支存在 vendor 仓库缺失的 `include/soc/oplus/oppo_project.h`（唯一残留断链）；u_14 分支断链为 0。
- `dtbo.img` 需用 `mkdtboimg.py` 从 `*.dtbo` 另行打包。
- 可刷写的 `boot.img` 需要 `mkbootimg` + 原机参数，建议用 AnyKernel3。
- ReSukiSU Manager APK 需自行从 `ReSukiSU/ReSukiSU` Releases 下载。

## 参考

- `JackA1ltman/NonGKI_Kernel_Build_2nd`（Actions 结构与 SUSFS/AnyKernel3 处理方式）
- `ReSukiSU/ReSukiSU`（`kernel/setup.sh`、`kernel/Kconfig` 的 KSU_SUSFS 菜单）
- `simonpunk/susfs4ksu` 分支 `kernel-5.4`（`50_add_susfs_in_kernel-5.4.patch`、`fs/susfs.c`、`include/linux/susfs*.h`）
