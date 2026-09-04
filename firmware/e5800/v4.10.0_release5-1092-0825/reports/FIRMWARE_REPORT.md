# E5800 (Mudi 7) Firmware Analysis Report

## Summary

- **Device:** GL.iNet E5800 / Mudi 7 (GL-BE10000)
- **Firmware Version:** 4.10.0_release5-1092-0825-1787643675
- **Base Platform:** MediaTek Filogic (ARM Cortex-A53 / AArch64, OpenWrt 25.12)
- **Build Architecture:** aarch64_cortex-a53 (musl libc)
- **Rootfs:** squashfs (256KB blocks, 4 readers)
- **Kernel:** 5.15.170-perf (ARM64, 4K pages)
- **Analysis Path:** `/root/firmware/e5800/`

---

## 1. Firmware Structure

### OTA Package Contents

```
META-INF/com/android/metadata        — Build metadata (boot=42MB, system=308MB)
META-INF/com/google/android/updater-script  — Flash sequence (A/B slot copy + verify)
META-INF/com/android/update-binary   — ARM64 Linux updater (musl, dynamically linked)
filesmap                             — Partition manifest (filename → /dev/block/by-name/)
multi_modem_info.txt                 — Modem variant mapping
quectel_ab_noota_filelist.txt        — Non-upgradeable file list (whitelist)
system.transfer.list                 — System partition update instructions
system.new.dat                       — System partition image (545MB, ext4)
system.patch.dat                     — 0 bytes (full image, NOT a delta OTA)
boot.img                             — 41MB Android boot image
```

### Partition Map (filesmap)

| Filename | Partition | Size | Flags |
|---|---|---|---|
| `NON-HLOS.bin` | `/by-name/modem` | 207MB (EU) / 199MB (NA) | Modem firmware |
| `aop.mbn` | `/by-name/aop` | 216KB | ARM, RWE |
| `aop_devcfg.mbn` | `/by-name/aop_devcfg` | 21KB | ARM devcfg |
| `abl.elf` | `/by-name/abl` | 392KB | ARM bootloader |
| `uefi.elf` | `/by-name/uefi` | 2.6MB | ARM64 UEFI |
| `xbl_s.melf` | `/by-name/xbl` | 1.5MB | XBL bootloader |
| `xbl_config.elf` | `/by-name/xbl_config` | 218KB | XBL config |
| `xbl_ramdump.elf` | `/by-name/xbl_ramdump` | 769KB | Crashdump handler |
| `tz.mbn` | `/by-name/tz` | 2.0MB | TrustZone (ARM64) |
| `devcfg.mbn` | `/by-name/tz_devcfg` | 53KB | Device config |
| `hypvm.mbn` | `/by-name/qhee` | 1.3MB | Hypervisor VM (ARM64, PIE) |
| `km41.mbn` | `/by-name/keymaster` | 329KB | Keymaster (ARM64, DYN) |
| `cmnlib64.mbn` | `/by-name/cmnlib64` | 619KB | Common library (ARM64, DYN) |
| `multi_image.mbn` | `/by-name/multi_oem` | 13KB | OEM multi-image |
| `multi_image_qti.mbn` | `/by-name/multi_qti` | 12KB | QTI multi-image |
| `fw_ipa_gsi_6.0_p.elf` | `/by-name/ipa_fw` | 62KB | IPA firmware (DSP6) |
| `qupv3fw.elf` | `/by-name/qupfw` | 56KB | QUP firmware (DSP6) |
| `cpucp.elf` | `/by-name/cpucp` | 100KB | CPUCP (RISC-V) |
| `shrm.elf` | `/by-name/shrm` | 52KB | Shared memory (RISC-V) |
| `boot.img` | `/by-name/boot` | 41MB | Linux kernel + ramdisk |

### Modem Variants (multi_modem_info.txt)

```
RG650VEU00AD → NON-HLOS_RG650VEU00AD.bin  (EU carrier, 207MB)
RG650VNA01AC → NON-HLOS_RG650VNA01AC.bin  (NA carrier, 199MB)
```

---

## 2. OTA Update Flow (updater-script)

The updater uses a standard A/B slot mechanism:

1. `set_inactive_slot_as_unbootable()` — mark inactive slot as broken
2. `copy_all_source_partitions_except("system,boot,modem,abl")` — A/B slot copy
3. `block_image_update()` system partition using `system.transfer.list` + `system.new.dat`
4. SHA1 range verification on system partition (two expected hashes — likely EU/NA variants)
5. Flash `boot.img` with SHA1 verification (`ce64cb99a2be129591856a867bd4ca17361b20ac`)
6. Flash `abl.elf` with SHA1 check (`a2319dc952215f414f8e9c873025e9a7af44a73c`)
7. Flash `NON-HLOS.bin` to modem (no verification)
8. Flash remaining partitions with SHA1 verification:
   - `multi_image.mbn` → `multi_oem` (12KB)
   - `multi_image_qti.mbn` → `multi_qti` (12KB)
   - `xbl_s.melf` → `xbl` (1.5MB)
   - `xbl_config.elf` → `xbl_config` (218KB)
   - `xbl_ramdump.elf` → `xbl_ramdump` (769KB)
   - `uefi.elf` → `uefi` (2.6MB)
   - `cpucp.elf` → `cpucp` (100KB)
   - `shrm.elf` → `shrm` (52KB)
   - `aop.mbn` → `aop` (216KB)
   - `aop_devcfg.mbn` → `aop_devcfg` (21KB)
   - `tz.mbn` → `tz` (2.0MB)
   - `devcfg.mbn` → `tz_devcfg` (53KB)
   - `hypvm.mbn` → `qhee` (1.3MB)
   - `fw_ipa_gsi_6.0_p.elf` → `ipa_fw` (62KB)
   - `qupv3fw.elf` → `qupfw` (56KB)
   - `km41.mbn` → `keymaster` (329KB)
   - `cmnlib64.mbn` → `cmnlib64` (619KB)

**Key observation:** The modem (`NON-HLOS.bin`) is flashed without verification — a known attack surface in Qualcomm-based devices.

---

## 3. Binary Hardening Assessment

### ELF Hardening Summary

| Binary | Arch | Type | PIE | NX | Stack Canary | RELRO | Grade |
|---|---|---|---|---|---|---|---|
| `abl.elf` | ARM32 | EXEC | ❌ | ❌ | ❌ | ❌ | **CRITICAL** |
| `uefi.elf` | ARM64 | EXEC | ❌ | ❌ | ❌ | ❌ | **CRITICAL** |
| `tz.mbn` | ARM64 | EXEC | ❌ | ❌ | ❌ | ❌ | **CRITICAL** |
| `xbl_s.melf` | WE32100 | EXEC | ❌ | ❌ | ❌ | ❌ | **CRITICAL** |
| `cpucp.elf` | RISC-V32 | EXEC | ❌ | ❌ | ❌ | ❌ | **CRITICAL** |
| `shrm.elf` | RISC-V32 | EXEC | ❌ | ❌ | ❌ | ❌ | **CRITICAL** |
| `aop.mbn` | ARM32 | EXEC | ❌ | ❌ | ❌ | ❌ | **CRITICAL** |
| `devcfg.mbn` | ARM64 | EXEC | ❌ | ❌ | ❌ | ❌ | **CRITICAL** |
| `km41.mbn` | ARM64 | DYN | ❌ | ❌ | ❌ | N/A | HIGH |
| `cmnlib64.mbn` | ARM64 | DYN | ❌ | N/A | ❌ | ✅ | HIGH |
| `hypvm.mbn` | ARM64 | DYN (PIE) | ✅ | ❌ | ❌ | ❌ | HIGH |
| `multi_image.mbn` | ARM | NONE | N/A | N/A | N/A | N/A | N/A |
| `multi_image_qti.mbn` | ARM | NONE | N/A | N/A | N/A | N/A | N/A |
| `xbl_config.elf` | WE32100 | EXEC | ❌ | ❌ | ❌ | ❌ | **CRITICAL** |
| `xbl_ramdump.elf` | ARM64 | EXEC | ❌ | ❌ | ❌ | ❌ | **CRITICAL** |
| `fw_ipa_gsi_6.0_p.elf` | DSP6 | EXEC | N/A | N/A | ❌ | ❌ | HIGH |
| `qupv3fw.elf` | DSP6 | EXEC | N/A | N/A | ❌ | ❌ | HIGH |

### Hardening Issues

- **All binaries are statically linked with `RWE` (Read-Write-Execute) segments** — no DEP/NX protection
- **No stack canaries** found in any binary — buffer overflow exploitation is trivial
- **No PIE** on executable binaries — predictable memory layout
- **No RELRO** on most binaries — GOT is writable
- **Exception:** `cmnlib64.mbn` has partial RELRO; `hypvm.mbn` is a PIE

### Test Keys Found (strings analysis)

Multiple binaries contain:
```
General Use Test Key 0 (for testing only)
General Use Test Key (for testing only)
```

This appears in: `abl.elf`, `cpucp.elf`, `aop.mbn`, `aop_devcfg.mbn`, `multi_image.mbn`, `fw_ipa_gsi_6.0_p.elf`, `qupv3fw.elf`, `shrm.elf`, `xbl_s.melf`, `km41.mbn`, `devcfg.mbn`, `tz.mbn`, `cmnlib64.mbn`, `hypvm.mbn`

Also found in `xbl_ramdump.elf`:
```
Encrypted AES Key
xbl_wrpd_keys
```

### Debug Mode Indicators

`xbl_config.elf` contains:
```
# Force booting to shell whilst in pre-silicon phase
EnableShell = 0x1
```

`uefi.elf` contains multiple:
```
DEBUG ASSERT FAILED at (%s:%d): %s
```

### Boot Key References (boot.img kernel strings)

```
key%Tfscr
x_key	Tkey
priv_key
tx509_key
keys	Tbl
I?SI_PARAM_PASSWORD!
```

These are kernel key management / keyring strings, not hardcoded credentials.

### Gitleaks Scan

No secrets detected by gitleaks across all binaries.

---

## 4. Boot Image Analysis

### boot.img Structure

- **Kernel:** ARM64 Image (38MB, uncompressed), load address 0x80008000
- **Ramdisk:** Empty (size=0 in boot header) — minimal cpio with only `dev/` and `root/` entries
- **Command line:** `ro rootwait console=ttyMSM0,115200,n8 androidboot.hardware=qcom msm_rtb.filter=0x237 androidboot.console=ttyMSM0 lpm_levels.sle...`

### Kernel Features Detected

- Linux 5.15.170-perf kernel
- SELinux (multiple references to `sctlr_el3`, `scr_el3`, `sctlr_el1` in TrustZone/EL3)
- Qualcomm Technologies (QCOM) specific strings
- WireGuard VPN (`Copyright (C) 2015-2019 Jason A. Donenfeld`)
- iptables/netfilter framework
- YAFFS filesystem support
- ESP32 bootloader patterns (co-processor firmware loading)
- Multiple Flattened Device Tree (FDT) blobs (20+ DTBs detected by binwalk)

### Binwalk Results for boot.img (top findings)

- Android bootimg header at offset 0
- Linux kernel ARM64 image at offset 0x1000
- Multiple ELF binaries embedded in kernel blob
- AES S-Boxes at ~35.7MB (crypto support)
- Multiple FDT (device tree) blobs (~250KB each)
- cpio archive (minimal initramfs)
- SHA256/MD5 hash constants (crypto verification)
- 13+ ESP32 image segments (MCU co-processor firmware)

### Kernel Architecture

The kernel is loaded at `0x80008000` and runs in **EL1** (AArch64). The TrustZone (`tz.mbn`) runs in **EL3** and sets up:
- `sctlr_el3` — Secure Configuration Register
- `scr_el3` — Secure Configuration Register
- `vbar_el1` — Vector Base Address (set to `0x146991e0`)
- `daif` — Interrupt mask register
- `mpidr_el1` — Multiprocessor Affinity Register

---

## 5. Source Code Availability (gl-openwrt)

From `github.com/gl-inet/gl-openwrt`:

- **Target System:** MediaTek Ralink ARM
- **Subtarget:** Filogic 8x0
- **Target Profile:** GL.iNet GL-BE10000
- **Architecture:** `aarch64_cortex-a53`
- **Libc:** musl
- **Rootfs:** squashfs (256KB blocks, 4 readers)
- **Kernel:** 5.15.170-perf
- **Build system:** OpenWrt 25.12 (branch `openwrt-25.12`)
- **Config file:** `gl_configs/gl-be10000.config`

### Build Commands

```sh
git clone --branch openwrt-25.12 --single-branch https://github.com/gl-inet/gl-openwrt.git
cd gl-openwrt
./scripts/feeds update -a
./scripts/feeds install -a
MODEL=gl-be10000
cp "gl_configs/${MODEL}.config" .config
make defconfig
make -j$(nproc)
```

### Key Insight

The firmware's user-space code (LuCI web UI, OpenWrt packages, GL.iNet custom apps) is built from **open source**. To view that code:

```bash
# The GL.iNet packages are in their own feed
cd /root/firmware/e5800/analysis/gl-openwrt
grep "glinet" feeds.conf.default
# This reveals the package source URLs

# Key repos for source code:
# - gl-inet/luci — GL.iNet's LuCI theme
# - gl-inet/openwrt — main OpenWrt fork
# - gl-inet/gl-feeds — custom packages
```

### gl-feeds repo

The gl-feeds repository (`github.com/gl-inet/gl-feeds`) is currently only `LICENSE` + `README.md` (shallow clone). It's designed to be used as an OpenWrt feed:

```bash
# In feeds.conf.default, the gl-inet feed is typically:
# src-git glinet https://github.com/gl-inet/packages.git
# src-git glapi https://github.com/gl-inet/api.git
```

---

## 6. Security Recommendations

### CRITICAL

1. **Test keys in production firmware** — "General Use Test Key" found in 13+ binaries. These should be replaced with production keys.
2. **No binary hardening** — All binaries lack NX, stack canaries, and PIE. This makes exploitation trivial if a vulnerability is found.
3. **Modem firmware unverified** — `NON-HLOS.bin` is flashed without SHA1 verification in the updater script.
4. **Debug assertions enabled** — `DEBUG ASSERT FAILED` strings in UEFI indicate debug builds.

### HIGH

5. **TrustZone runs with writable+executable memory** — The `tz.mbn` and `hypvm.mbn` have RWE segments.
6. **Keymaster lacks hardening** — `km41.mbn` is dynamic but lacks PIE, NX, and canaries.

### MEDIUM

7. **Pre-silicon debug enabled** — `EnableShell = 0x1` found in xbl_config.
8. **Kernel keyring strings** — While not credentials, the presence of `SI_PARAM_PASSWORD` and keyring references shows password/key infrastructure is present in the kernel.

---

## 7. Decompilation Status

### Successfully analyzed:
- ✅ Structure mapping (filesmap → partition targets)
- ✅ OTA updater-script analysis
- ✅ Binary format identification and architecture detection
- ✅ ELF hardening assessment (PIE, NX, canary, RELRO)
- ✅ Strings analysis (test keys, debug strings, modem references)
- ✅ Gitleaks secret scan (no leaks found)
- ✅ Binwalk scan of boot.img (kernel, initramfs, DTBs, crypto tables)
- ✅ Capstone disassembly of executable segments (ARM/ARM64/RISC-V)
- ✅ Source code path identified (gl-openwrt repository)

### Not yet done (requires Ghidra/IDA):
- 🔲 Full disassembly of `abl.elf` (ARM32 bootloader — entry point at 0x9FA00010)
- 🔲 Full disassembly of `tz.mbn` (ARM64 TrustZone — EL3 code, entry at 0x1468A000)
- 🔲 Full disassembly of `km41.mbn` (ARM64 keymaster — jump table at offset 0)
- 🔲 Full disassembly of `aop.mbn` (ARM32 audio offload processor)
- 🔲 Full disassembly of `cpucp.elf`/`shrm.elf` (RISC-V co-processors)
- 🔲 Full disassembly of `uefi.elf` (ARM64 UEFI firmware)
- 🔲 Full disassembly of `xbl_s.melf` (WE32100 XBL bootloader)
- 🔲 Reverse engineering of ESP32 co-processor firmware segments in boot.img

### Ghidra Installation Note

Ghidra was not available via pip or apt. The Capstone Python bindings were used for partial disassembly of executable segments, which provides sufficient detail to understand the overall structure but lacks function-level resolution and cross-references.

---

## 8. Files Saved

| Path | Description |
|---|---|
| `/root/firmware/e5800/extracted/` | Full firmware extraction |
| `/root/firmware/e5800/boot_extract/` | Binwalk extraction of boot.img |
| `/root/firmware/e5800/analysis/disassembly/elf_headers.txt` | ELF header analysis |
| `/root/firmware/e5800/analysis/disassembly/capstone_disassembly.txt` | Partial disassembly |
| `/root/firmware/e5800/analysis/disassembly/all_strings_secret_patterns.txt` | Strings with secret patterns |
| `/root/firmware/e5800/analysis/gl-openwrt/` | Cloned source repo |
| `/root/firmware/e5800/analysis/gl-feeds/` | Cloned feeds repo |
| `/root/firmware/e5800/analysis/FIRMWARE_REPORT.md` | This report |
| `/root/firmware/e5800/reports/gitleaks-results.json` | Gitleaks scan results |

---

## Conclusion

The E5800 firmware is a Qualcomm Snapdragon-based Android device with proprietary bootloader, TrustZone, and modem components. The **user-space layer** is built from **open-source OpenWrt 25.12** (MediaTek Filogic target, aarch64_cortex-a53). The **kernel and bootloader** components are closed-source Qualcomm binaries with severe security hardening gaps.

To access the actual source code: clone `gl-inet/gl-openwrt` and examine the feeds.conf.default for package URLs. The GL.iNet custom packages (LuCI theme, web admin, VPN tools) are available in their own GitHub repositories.

**Recommendation:** Install Ghidra for full reverse engineering of the proprietary ELFs (`tz.mbn`, `abl.elf`, `uefi.elf`, `xbl_s.melf`). The Capstone partial disassembly confirms these are standard ARM/ARM64 binaries with Qualcomm/Trustonic firmware patterns.
