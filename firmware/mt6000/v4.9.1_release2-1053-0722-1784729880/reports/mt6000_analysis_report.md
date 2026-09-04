# MT6000 (Flint 3) Firmware Analysis Report

## Firmware Information
- **File:** `sysupgrade-glinet_gl-mt6000/kernel` (3.7MB FIT image)
- **Model:** GL.iNet GL-MT6000 (Flint 3)
- **Version:** 4.9.1 release2-1053-0722
- **Chipset:** MediaTek MT7986A (ARM Cortex-A53, ARM64)
- **Kernel:** Linux 5.4.238, gcc 8.4.0 (OpenWrt GCC 8.4.0 r15812+1092)
- **Build:** `xinxing@gl-System-Product-Name`, Tue Aug 4 06:28:05 2026
- **OS:** OpenWrt 21.02 (kernel-only sysupgrade image)

## Image Structure
| Offset | Type | Description |
|--------|------|-------------|
| 0x0 | Flattened Device Tree | FIT wrapper (3.7MB total) |
| 0xE8 (232) | LZMA compressed | Linux kernel (uncompressed: 11,335,688 bytes) |
| 0x38632A | JBOOT STAG | U-Boot staging header |
| 0x3959E0 | Device Tree Blob | MT7986A DTB (23,289 bytes) |

## Kernel Analysis
- **Decompressed size:** 11,335,688 bytes
- **Kernel type:** Linux kernel ARM64 boot executable Image, little-endian, 4K pages
- **LZMA props:** 6d00008000 (8MB dictionary)
- **CPU:** ARM Cortex-A53 (4 cores, 4 threads)

## Device Tree (MT6000 DTB)
- **Model:** `glinet,gl-mt6000`
- **Compatible:** `mediatek,mt7986a`
- **CPU:** ARM Cortex-A53, smp (4 cores)
- **Peripherals:** EMMC, PCIe, SPI, UART, thermal, PWM, WED (Wireless Engine Domain)
- See `mt6000.dtb` for full extracted device tree

## Kernel Driver Strings
- Mediatek-specific drivers: cpufreq, eth-soc, hsdma, spi-nand, thermal, watchdog
- Standard kernel drivers: ata/libahci, bluetooth/hci_serdev, crypto, usb, net/wireless

## Binary Hardening
- Kernel-only image (no root filesystem)
- No user-space binaries available for hardening analysis
- Kernel compiled with standard MediaTek MT7986A configuration

## Credentials & Secrets
- No root filesystem → no user-space credentials to find
- Kernel strings: 0 secrets (see `kernel_strings.txt`)
- No hardcoded WiFi passwords, SSH keys, or API tokens

## Notes
- This is a kernel-only sysupgrade image (no root filesystem)
- The `CONTROL` file in the original directory was misconfigured — it listed `BOARD=glinet_gl-be14000` but the directory was named for MT6000
- No Ghidra function analysis performed (raw kernel binary, not ELF)
