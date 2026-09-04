# GL.iNet E5800 (Mudi 7) Firmware Analysis

**Firmware Version:** `e5800-4.10.0_release5-1092-0825-1787643675`  
**Date:** 2026-09-04  
**Device:** GL.iNet E5800 (Mudi 7) / GL-BE10000  
**Base Platform:** MediaTek MT7988F (Filogic 880), OpenWrt 25.12  
**Architecture:** ARM64/AArch64 (kernel, UEFI, HypVM, Cmmlib) + ARM32 (ABL, XBL, AOP) + RISC-V (CPUCP, SHRM) + MIPS (modem)  

## Repository Structure

```
gl.inet_firmware/
├── firmware/
│   └── e5800/
│       └── v4.10.0_release5-1092-0825-1787643675/   ← Firmware version subdirectory
│           ├── reports/
│           │   ├── FIRMWARE_ANALYSIS_REPORT.md         # Main comprehensive analysis (23KB)
│           │   ├── FIRMWARE_REPORT.md                  # Initial extraction report
│           │   ├── ghidra_analysis_report.md           # Ghidra function analysis (12KB)
│           │   └── gitleaks-results.json               # Secret scan — 0 leaks (gitignore'd)
│           ├── analysis/
│           │   ├── disassembly/                        # Binary disassembly outputs
│           │   │   ├── ghidra_*_functions.txt            # Function lists for all 19 binaries
│           │   │   ├── strings_*.txt                    # CLI strings for all 19 binaries
│           │   │   ├── capstone_disassembly.txt         # ARM/ARM64 disassembly
│           │   │   ├── elf_headers.txt                  # Full ELF headers
│           │   │   ├── binary_hardening.txt             # PIE/canary/RELRO results
│           │   │   ├── comprehensive_binary_analysis.txt
│           │   │   ├── all_strings_secret_patterns.txt  # 226 lines — 0 secrets
│           │   │   ├── ExportFunctionsAndStrings.java   # Ghidra analysis script
│           │   │   └── run_ghidra_all.sh                # Batch runner script
│           │   ├── openwrt-config/
│           │   │   ├── gl-be10000.config               # OpenWrt 25.12 build config
│           │   │   ├── feeds.conf.default               # GL.iNet feeds config
│           │   │   └── gl-feeds-README.md              # GL-feeds README (empty)
│           │   └── gl-be10000.config                   # Duplicate (keep for compat)
│           └── boot_extraction/
│               └── boot_extraction_summary.txt          # binwalk extraction details
└── README.md
```

> **Note:** Each firmware version gets its own `firmware/<model>/<version>/` subdirectory. Future firmware versions (e.g., different E5800 releases or other GL.iNet models) can be added under `firmware/<model>/` by creating new version directories.

## Key Findings

1. **Platform:** MediaTek MT7988F (Filogic 880), OpenWrt 25.12 with Linux 5.15.170-perf kernel
2. **Architecture:** ARM64/AArch64 + ARM32 for SoC components; MIPS for modem; RISC-V for CPUCP/SHRM
3. **Binaries:** 19 fully stripped Qualcomm proprietary blobs (no section headers, no source available)
4. **Bootloader chain:** XBL → ABL → UEFI → TZ → QSEE → AOP → Modem
5. **Secrets:** Zero hardcoded credentials (Gitleaks + CLI strings scan across all binaries)
6. **Ghidra:** Successfully analyzed all 19 binaries via `analyzeHeadless` (pyghidra abandoned due to JVM OOM)
7. **Kernel headers:** 6,269 kernel headers extracted from boot.img (arm64/include, sound/sof, crypto)
8. **Device tree:** 30MB DTB found in boot.img with Qualcomm debug device tree fragments
9. **QSEE functions (km41.mbn):** 728 functions identified including full crypto API:
   - `qsee_SW_GENERIC_ECC_init`, `qsee_SW_GENERIC_ECDSA_sign`, `qsee_SW_GENERIC_ECDH_shared_key_derive`
   - `qsee_SW_CIPHER_Init`, `qsee_SW_AE_UpdateData`, `qsee_SW_Hash_Init`, `qsee_SW_Hmac`
   - `qsee_prng_getdata`, `qsee_log`, `qsee_get_uptime`
10. **UEFI functions (uefi.elf):** 1,004 functions (all auto-generated labels, entry at 0x87500000)

## Analysis Tools

- **binwalk** (v2.10.90) — Firmware extraction
- **Capstone** — Disassembly engine (ARM/ARM64)
- **Ghidra 12.1.3** — Interactive reverse engineering via `analyzeHeadless`
- **pyghidra 3.1.0** — Attempted but abandoned (JVM OOM kills, LockException)
- **gitleaks** — Secret scanning (0 leaks found)
- **readelf / objdump / strings** — Static ELF analysis

## Ghidra Headless Analysis

```bash
GHIDRA_HEADLESS_MAXMEM=512m \
/opt/ghidra_12.1.3_PUBLIC/support/analyzeHeadless \
  /tmp/ghidra_e5800 proj -import <binary> \
  -processor "AARCH64:LE:64:v8A" \
  -postScript ExportFunctionsAndStrings.java \
  -scriptPath /path/to/disassembly/
```

**Language IDs:**
- ARM64: `AARCH64:LE:64:v8A`
- ARM32: `ARM:LE:32:v7`

## Quick Start

```bash
# View the comprehensive analysis report
cat firmware/e5800/v4.10.0_release5-1092-0825-1787643675/reports/FIRMWARE_ANALYSIS_REPORT.md

# View Ghidra function analysis
cat firmware/e5800/v4.10.0_release5-1092-0825-1787643675/reports/ghidra_analysis_report.md

# Examine all Ghidra function listings
cat firmware/e5800/v4.10.0_release5-1092-0825-1787643675/analysis/disassembly/ghidra_*_functions.txt

# Examine the OpenWrt build config
cat firmware/e5800/v4.10.0_release5-1092-0825-1787643675/analysis/openwrt-config/gl-be10000.config
```

## License

GPL-3.0