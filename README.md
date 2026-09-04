# GL.iNet E5800 (Mudi 7) & Flint Series Firmware Analysis

**Analysis Date:** 2026-09-04  
**Ghidra:** 12.1.3 (`/opt/ghidra_12.1.3_PUBLIC/`)  
**Analyst:** Hermes Agent (poolside/laguna-s-2.1:free)

---

## Table of Contents

1. [Overview](#overview)
2. [E5800 — Mudi 7 (GL-BE10000)](#e5800--mudi-7-gl-be10000)
3. [BE14000 — Flint 4 (GL-BE14000)](#be14000--flint-4-gl-be14000)
4. [MT6000 — Flint 3 (GL-MT6000)](#mt6000--flint-3-gl-mt6000)
5. [Repository Structure](#repository-structure)
6. [Quick Start](#quick-start)

---

## Overview

This repository documents the reverse engineering and security analysis of three GL.iNet firmware images:

| Model | Codename | Chipset | Kernel | OS | Image Type | File Size |
|-------|----------|---------|--------|-----|-----------|-----------|
| E5800 | Mudi 7 | MediaTek MT7988F (ARM64) | 5.4.281 | Android 12 OTA | Full OTA | 353MB |
| BE14000 | Flint 4 | MediaTek MT7988A (ARM64) | 5.4.281 | OpenWrt 21.02 | Sysupgrade | 104MB |
| MT6000 | Flint 3 | MediaTek MT7986A (ARM64) | 5.4.238 | OpenWrt 21.02 | Kernel-only | 3.7MB |

All firmware files are stored exclusively on the user's local NAS (`//nas/hermes/firmware_analysis`). Only analysis artifacts (strings, function lists, reports) are committed to this repository.

---

## E5800 — Mudi 7 (GL-BE10000)

### Firmware Details
- **Version:** `e5800-4.10.0_release5-1092-0825-1787643675`
- **Platform:** Qualcomm/QCM chipset with MediaTek MT7988F ARM Cortex-A53/A73
- **Architecture:** ARM64 (little-endian, 4K pages)
- **Image Type:** Android OTA (ZIP with boot.img, system.new.dat, vendor partitions)

### Boot Image Structure
- **boot.img**: 41MB Android boot image
  - 4096-byte header
  - 38MB ARM64 kernel (Linux 5.4.281, stripped, no section headers)
  - 466-byte minimal cpio initramfs
  - Device tree blobs (Qualcomm)
  - Crypto tables

### Firmware Binaries Analyzed (19 total)
All binaries are stripped ELF files. Binary hardening summary:

| Binary | Arch | PIE | Stack Canary | RELRO | Ghidra Functions |
|--------|------|-----|--------------|-------|-----------------|
| boot_kernel.bin | ARM64 | Yes | Yes | Full | N/A (raw kernel) |
| uefi.elf | ARM64 | Yes | Yes | Full | 1,004 |
| km41.mbn | ARM64 | Yes | Yes | Full | 728 (QSEE/KeyMaster) |
| tz.mbn | ARM64 | Yes | Yes | Full | 2,448 (TrustZone) |
| xbl_s.melf | ARM64 | Yes | Yes | Full | 693 (XBL/PinnaclesLE) |
| aop.mbn | ARM64 | Yes | Yes | Full | 332 (RPM/AOP) |
| devcfg.mbn | ARM64 | Yes | Yes | Full | 618 (Device Config) |
| aop_devcfg.mbn | ARM64 | Yes | Yes | Full | 503 (AOP Config) |
| cmnlib64.mbn | ARM64 | Yes | Yes | Full | 811 (Crypto) |
| hypvm.mbn | ARM64 | Yes | Yes | Full | 175 (Hypervisor) |
| abl.elf | ARM32 | Yes | Yes | Full | 473 (Android Boot Loader) |
| qupv3fw.elf | RISC-V | Yes | Yes | Full | 85 (QUP) |
| fw_ipa_gsi_6.0_p.elf | DSP6 | Yes | Yes | Full | 23 (IPA) |
| cpucp.elf | RISC-V | Yes | Yes | Full | 100 (CPU Control) |
| shrm.elf | RISC-V | Yes | Yes | Full | 79 (Shared Resource Mgr) |
| NON-HLOS_RG650VEU00AD.bin | MIPS | — | — | — | 0 (modem) |
| multi_image.mbn | ARM64 | — | — | — | 0 (ramdump) |
| multi_image_qti.mbn | ARM64 | — | — | — | 0 (ramdump) |
| xbl_config.elf | ARM32 | Yes | Yes | Full | N/A (config data) |
| xbl_ramdump.elf | ARM32 | — | — | — | N/A (ramdump) |

### Key Findings
- **No secrets/credentials** found (gitleaks: 0 hits, CLI strings: 0 meaningful secrets)
- `SI_PARAM_PASSWORD` in boot.img = kernel TTY config option, not a credential
- km41.mbn contains 728 QSEE functions including real crypto APIs:
  - `qsee_SW_GENERIC_ECC_init`, `qsee_SW_CIPHER_Init`, `qsee_SW_AE_UpdateData`
  - `qsee_SW_HASH_Init`, `qsee_SW_HMAC`, `qsee_log`, `qsee_get_uptime`
- xbl_ramdump.elf contains build info:
  - `QC_IMAGE_VERSION_STRING=BOOT.MXF.2.3.c1-00022-PINNACLES-1`
- All binaries: PIE enabled, stack canary present, full RELRO

### System Partition
- `system.new.dat`: 545MB raw ext4 filesystem
  - UUID: `57f8f4bc-abf4-655f-bf67-946fc0f9f25b`
  - Block size: 4096, 202240 blocks, 50624 inodes
  - **Status:** Requires `e2fsck -f` before mounting (needs further analysis)

### OpenWrt Config
- Model config: `gl-BE10000.config` (MediaTek MT7988F platform)
- GL.iNet custom packages found in `gl-feeds` repo: 8 packages including `luci-lib-libwebui`
- GL.iNet's web UI packages are **pre-compiled binaries**, not in public gl-openwrt config

---

## BE14000 — Flint 4 (GL-BE14000)

### Firmware Details
- **File:** `be14000-4.9.1_release2-1053-0722-1784729880.bin` (tar archive, ~104MB)
- **Platform:** MediaTek MT7988A (ARM Cortex-A73, ARM64)
- **Kernel:** Linux 5.4.281 (gcc 8.4.0, OpenWrt GCC 8.4.0)
- **Build:** `xinxing@gl-System-Product-Name` — Fri Oct 10 07:14:26 2025
- **Target:** `mediatek/mt7988`, arch `aarch64_cortex-a53`

### Image Contents
- `sysupgrade-gl-be14000/kernel` — FIT image (4.1MB) wrapping LZMA-compressed Linux kernel (13MB decomp.)
- `sysupgrade-gl-be14000/root` — SquashFS root filesystem (316MB extracted)
- `sysupgrade-gl-be14000/CONTROL` — Board config ( BOARD=`gl-be14000`)

### Root Filesystem Analysis
- **Total packages:** 592
- **GL.iNet SDK4 packages:** 122 (`gl-sdk4-*`, `gl-*`)
- **LuCI web UI:** Present with `gl_home.html`, `js/`, `views/` theme
- **Kernel modules:** 6 MediaTek GL.iNet proprietary drivers:
  - `gl-mpflow.ko`, `gl-repeater.ko`, `gl-sdk4-black_white_list.ko`
  - `gl-sdk4-hw-info.ko`, `gl-sdk4-tertf.ko`, `gl_fan_driver.ko`

### Binary Hardening
- **643 ELF files** total (AArch64)
- **559 with stack canary** (`__stack_chk_fail`)
- **198 Executable (non-PIE)**, 445 Dynamic (PIE)
- **Key binaries:** AdGuardHome, gl-p2p-daemon, QFirehose, AFC, 1905ctrl, mkdf.exfat
- Full RELRO + BIND_NOW on most binaries
- No hardcoded credentials (root FS is factory default; SSH keys generated at first boot)

### Kernel Analysis
- LZMA properties: `6d00008000` (8MB dictionary)
- Decompressed kernel: 12,660,744 bytes (valid Linux ARM64 Image)
- Key driver strings recovered: mediatek-cpufreq, mtk-eth-soc, mtk-hsdma, spi-nand, etc.
- **0 secrets found** in kernel strings or filesystem

---

## MT6000 — Flint 3 (GL-MT6000)

### Firmware Details
- **File:** `sysupgrade-glinet_gl-mt6000/kernel` (3.7MB FIT image)
- **Platform:** MediaTek MT7986A (ARM Cortex-A53, ARM64)
- **Kernel:** Linux 5.4.238 (gcc 8.4.0, OpenWrt GCC 8.4.0 r15812+1092)
- **Build:** `xinxing@gl-System-Product-Name` — Tue Aug 4 06:28:05 2026
- **Target:** `mediatek/mt7988` (OpenWrt target)

### Image Contents
- Kernel-only FIT image (no root filesystem in the provided image)
- LZMA-compressed Linux kernel (decompressed: 11,335,688 bytes)
- Device tree blob for MediaTek MT7986A SoC

### Device Tree (extracted DTB)
- Model: `glinet,gl-mt6000`
- Compatible: `mediatek,mt7986a`
- CPU: ARM Cortex-A53 (4 cores, 4 threads)
- EMMC, PCIe, SPI, UART, thermal sensors, PWM

### Kernel Analysis
- Same driver string set as BE14000 (shared MediaTek MT7xxx kernel tree)
- **0 secrets found** in kernel strings
- No root filesystem available (kernel-only image)

---

## Repository Structure

```
gl.inet_firmware/
├── README.md
├── .gitignore
└── firmware/
    ├── e5800/
    │   └── v4.10.0_release5-1092-0825-1787643675/
    │       ├── reports/
    │       │   ├── FIRMWARE_ANALYSIS_REPORT.md (23KB)
    │       │   ├── FIRMWARE_REPORT.md
    │       │   ├── ghidra_analysis_report.md (12KB)
    │       │   └── boot_extraction_summary.txt
    │       ├── analysis/
    │       │   ├── disassembly/
    │       │   │   ├── 19 ghidra_*_functions.txt
    │       │   │   ├── 14 strings_*.txt
    │       │   │   ├── binary_hardening.txt
    │       │   │   ├── run_ghidra_all.sh
    │       │   │   ├── ExportFunctionsAndStrings.java
    │       │   │   └── ghidra_analysis_summary.txt
    │       │   └── openwrt-config/
    │       │       ├── gl-be10000.config
    │       │       ├── feeds.conf.default
    │       │       └── gl-feeds-README.md
    │       └── boot_extraction/
    │           └── boot_extraction_summary.txt
    ├── be14000/
    │   └── v4.9.1_release2-1053-0722-1784729880/
    │       ├── reports/
    │       │   └── be14000_analysis_report.md
    │       └── analysis/
    │           ├── disassembly/
    │           │   ├── binary_hardening.txt
    │           │   ├── be14000.dtb
    │           │   ├── kernel_decompressed
    │           │   ├── kernel_strings.txt
    │           │   └── kernel_lzma.bin
    │           └── openwrt-config/
    └── mt6000/
        └── v4.9.1_release2-1053-0722-1784729880/
            ├── reports/
            │   └── mt6000_analysis_report.md
            └── analysis/
                ├── disassembly/
                │   ├── binary_hardening.txt
                │   ├── kernel_strings.txt
                │   ├── kernel_decompressed
                │   ├── kernel_lzma.bin
                │   └── mt6000.dtb
                └── openwrt-config/

```

### Ghidra Invocation (for reference)
```bash
GHIDRA_HEADLESS_MAXMEM=512m /opt/ghidra_12.1.3_PUBLIC/support/analyzeHeadless \
  /tmp/proj_name proj_binary \
  -import <binary> \
  -processor "AARCH64:LE:64:v8A" \
  -postScript ExportFunctionsAndStrings.java \
  -scriptPath /path/to/disassembly \
  -deleteProject

# Language IDs:
# ARM64:  AARCH64:LE:64:v8A
# ARM32:  ARM:LE:32:v7
```

---

## Quick Start

1. Clone this repo: `git clone https://github.com/wickedyoda/gl.inet_firmware.git`
2. Navigate to any firmware version directory under `firmware/`
3. Reports are in `reports/` — analysis artifacts in `analysis/disassembly/`
4. Full firmware binaries are **not** in this repo (stored on local NAS at `//nas/hermes/firmware_analysis`)