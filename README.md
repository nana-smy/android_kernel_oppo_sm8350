# OPPO SM8350 内核 CI

GitHub Actions 编译 `oppo/sm8350_*` 非 GKI 内核（ColorOS / Android 14，Linux 5.4.233），
ReSukiSU 与 SUSFS 均为**可选**。

配套 vendor 仓库：`nana-smy/android_kernel_modules_and_devicetree_oppo_sm8350`

## 用法

`Actions` → **Build OPPO SM8350 Kernel** → **Run workflow**

| 输入 | 说明 | 默认 |
| --- | --- | --- |
| `kernel_branch` | 内核 + vendor 同名分支（13 个可选） | `u_14.0.0_find_x3_pro` |
| `resukisu` / `resukisu_ref` | 集成 ReSukiSU 及版本 | true / `v4.2.0-rc3` |
| `susfs` / `susfs_ref` | 集成 SUSFS 及补丁来源（`nongki-5.4` 新版、`kernel-5.4` 官方） | true / `nongki-5.4` |
| `clang_version` | AOSP prebuilt clang | `clang-r383902b`（clang 12） |
| `lto` | 保留 LTO/CFI/SCS（吃内存） | false |
| `build_modules` | 编译 `.ko` | true |
| `ak3_enable` | 打包 AnyKernel3（关则只出裸 Image/dtb） | false |
| `ak3_devices` | 设备代号，空格分隔（`peux PEEM00`），仅校验开启时有效 | 空 |
| `ak3_devicecheck` | 刷入时校验代号；关则 `do.devicecheck=0` 且忽略代号 | true |
| `ak3_modules` | `.ko` 打成 ak3-helper 模块随 AK3 刷入（需 Magisk/KernelSU） | false |

产物：`Image`、`dtb/`（104 个）、`config-<branch>`、`modules/`（91 `.ko`）、可选 `kernel-AK3-<branch>.zip`。

## 为什么必须两个仓库

内核仓库有 96 个符号链接指向 `vendor/oplus/...` 与 `vendor/qcom/proprietary/devicetree`，
单克隆会报 `can't open file "kernel/sched_assist/Kconfig"`。脚本按 AOSP 布局组装：

```
$WORK/
├── kernel/msm-5.4   # 必须在 kernel/ 下一层，链接按 ../../../vendor 解析
└── vendor/
```

再把 vendor 的 `kernel/msm-5.4/techpack/{audio,camera,dataipa,display,video}` 合入内核树，断链非 0 直接失败。

## 关键处理

- **配置基准**：`configs/sm8350_defconfig`（实机导出，`CONFIG_QGKI=y`，provider/consumer 全 `=y`），`cp` 成 `out/.config` 后 `olddefconfig`。
- **-Werror 全清**：克隆后把树里所有 `Makefile`/`Kbuild`/`*.mk` 的 `-Werror` 改成 `-Wno-error`（`Makefile:492` 那批 `-Werror=strict-prototypes` 光靠 `-Wno-error` 压不住），另加 `DISABLE_WRAPPER=1` 关 `gcc-wrapper.py`。
- **ReSukiSU**：软链 `drivers/kernelsu` + `drivers/Makefile`/`Kconfig` 注入；配合 `scripts/susfs_inline_hook_patches.sh` 补 `ksu_handle_*` 钩子（non-GKI 必需）。
- **SUSFS**：`cp fs/susfs.c`、`include/linux/susfs{,_def}.h` 后 `patch -p1`；OPPO 改过的 `fs/proc/fd.c` 冲突由 `scripts/fix_fd_proc.py` 按原语义修正，其余 `.rej` 直接失败。
- **AK3**：`ak3_enable=false` 不出包；`ak3_devicecheck=false` 写 `do.devicecheck=0` 并忽略 `ak3_devices`；`ak3_modules=true` 时写 `do.modules=1` + `do.systemless=1`，自动生成可自清理的 ak3-helper 模块。
- `lto=false` 时关 `LTO_CLANG`/`CFI_CLANG`/`SHADOW_CALL_STACK`/`DEBUG_INFO`，避免 4 核 runner OOM。

## 限制

- `dtbo.img` 需 `mkdtboimg.py` 从 `*.dtbo` 另打。
- 可刷写的 `boot.img` 需 `mkbootimg` + 原机 header；临时验证建议 `fastboot boot`（需 boot.img 模板）。
- ReSukiSU Manager APK 自行从 Releases 下载。

## 参考

`JackA1ltman/NonGKI_Kernel_Build_2nd`、`ReSukiSU/ReSukiSU`、`simonpunk/susfs4ksu`（`kernel-5.4`）
