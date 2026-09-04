# BE14000 (Flint 4) Firmware Analysis Report

## Firmware Information
- **File:** `be14000-4.9.1_release2-1053-0722-1784729880.bin` (tar archive)
- **Model:** GL.iNet GL-BE14000 (Flint 4)
- **Version:** 4.9.1 release2-1053-0722-1784729880
- **Chipset:** MediaTek MT7988A (ARM Cortex-A73, ARM64)
- **Kernel:** Linux 5.4.281, gcc 8.4.0 (OpenWrt GCC 8.4.0)
- **Target:** mediatek/mt7988, aarch64_cortex-a53
- **OS:** OpenWrt 21.02-SNAPSHOT

## Image Structure
| File | Size | Type | Notes |
|------|------|------|-------|
| kernel | 4.1MB | FIT image | LZMA-compressed ARM64 Linux kernel |
| root | ~110MB | SquashFS | 316MB extracted root filesystem |
| CONTROL | 23B | Text | `BOARD=gl-be14000` |

## Kernel Analysis
- **LZMA props:** 6d00008000 (8MB dictionary)
- **Decompressed size:** 12,660,744 bytes
- **Kernel type:** Linux kernel ARM64 boot executable Image, little-endian, 4K pages
- **Build:** `xinxing@gl-System-Product-Name`, Fri Oct 10 07:14:26 2025
- **Key strings:** See `kernel_strings.txt`

## Root Filesystem Analysis
### Package Inventory
- 1,817 total files across root filesystem
- 592 installed packages
- 122 GL.iNet SDK4 packages (`gl-sdk4-*`, `gl-*`)
- OpenWrt 21.02 packages (luci, opkg, etc.)

### Key Directories
- `usr/bin/`: 53 executables (AdGuardHome, gl-p2p-daemon, amneziawg_watchdog, etc.)
- `usr/local/lib/lua/5.4/`: Lua extensions including `gl/cloud.so`
- `lib/modules/5.4.281/`: 6 GL.iNet kernel modules + standard MediaTek modules
- `etc/config/`: OpenWrt UCI configs (glconfig, network, wireless)
- `etc/luci_ipks/`: Pre-packaged .ipk files (24 packages)

### GL.iNet SDK4 Kernel Modules
1. `gl-mpflow.ko` — Multi-PATH flow control
2. `gl-repeater.ko` — WiFi repeater mode
3. `gl-sdk4-black_white_list.ko` — Traffic filtering
4. `gl-sdk4-hw-info.ko` — Hardware info collection
5. `gl-sdk4-tertf.ko` — Traffic shaping
6. `gl_fan_driver.ko` — Fan speed control

## Binary Hardening
- **643 ELF files** (AArch64)
- **559 with stack canary**, 84 without
- **445 PIE (dynamic)**, 198 non-PIE (executable)
- Full RELRO + BIND_NOW on AdGuardHome, QFirehose, and most key binaries
- `gl-p2p-daemon`: GNU_STACK only (no RELRO) — potential hardening gap

## Credentials & Secrets
- `gitleaks`: 0 secrets found
- `/etc/passwd`: root:x:0:0:root:/root:/bin/ash (no hardcoded passwords)
- Dropbear: No SSH host keys in image (generated at first boot)
- `wireless_cert*` files: ASCII text certificates (not credentials)
- `0 meaningful secrets` found in kernel or filesystem

## Ghidra Analysis
- Kernel image is raw ARM64 Linux Image (not ELF) — loaded as Raw Binary at 0x80000
- Function extraction: see `ghidra_*_functions.txt`

## OpenWrt Configuration
- `/etc/openwrt_release`: DISTRIB_ID=OpenWrt, DISTRIB_RELEASE=21.02-SNAPSHOT
- Target: mediatek/mt7988 (MediaTek MT7988 SoC family)
- Architecture: aarch64_cortex-a53
