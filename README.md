# GL.iNet E5800 (Mudi 7) Firmware Analysis

**Firmware Version:** `e5800-4.10.0_release5-1092-0825-1787643675`  
**Date:** 2026-09-04  
**Device:** GL.iNet E5800 (Mudi 7) / GL-BE10000

## Summary

Complete firmware analysis of the GL.iNet E5800 (Mudi 7) router firmware. This repository contains all findings from source code comparison, binary disassembly, and reverse engineering.

## Repository Structure

```
gl.inet_firmware/
├── reports/                 # Full analysis reports
│   ├── FIRMWARE_ANALYSIS_REPORT.md   # Main comprehensive report
│   ├── FIRMWARE_REPORT.md             # Initial report
│   └── gitleaks-results.json          # Secret scan results (0 leaks)
├── disassembly/             # Binary disassembly outputs
│   ├── capstone_disassembly.txt       # Capstone disassembly of all 14 binaries
│   ├── comprehensive_binary_analysis.txt  # Full binary analysis
│   ├── elf_analysis.txt
│   ├── elf_headers.txt
│   └── binary_hardening.txt
├── strings/                 # String analysis extracts
│   ├── all_strings_secret_patterns.txt  # Potential secret patterns
│   └── component_strings.txt             # Component-specific strings
├── boot_extraction/         # Boot.img extraction
│   └── boot_extraction_summary.txt
├── gl_openwrt/             # GL.iNet OpenWrt source repo
│   └── gl-be10000.config   # E5800 build configuration
├── gl_feeds/               # GL.iNet package feeds
├── ghidra_project/         # Ghidra project directory
└── README.md
```

## Key Findings

1. **Platform:** MediaTek MT7988F (Filogic 880), OpenWrt 25.12
2. **Architecture:** ARM64/AArch64 + ARM32 for SoC components
3. **Binaries:** 14 fully stripped Qualcomm proprietary binaries (no section headers)
4. **Bootloader chain:** XBL → ABL → UEFI → TZ → QSEE → AOP → Modem
5. **Secrets:** Zero hardcoded credentials found (Gitleaks scan)
6. **Ghidra:** Installed v12.1.3 + pyghidra 3.1.0
7. **Kernel headers:** 6,269 kernel headers extracted from boot.img
8. **Device tree:** 30MB DTB found embedded in boot.img

## Analysis Tools

- `binwalk` — Firmware extraction
- `Capstone` — Disassembly engine
- `Ghidra 12.1.3` — Interactive reverse engineering
- `pyghidra 3.1.0` — Python API for Ghidra
- `gitleaks` — Secret scanning
- `readelf` / `objdump` / `strings` — Static analysis

## Quick Start

```bash
# View the full report
cat reports/FIRMWARE_ANALYSIS_REPORT.md

# Examine Capstone disassembly
cat disassembly/capstone_disassembly.txt

# Check binary hardening
cat disassembly/binary_hardening.txt
```

## Firmware Files

The actual firmware files are stored locally at `/root/firmware/e5800/`. Due to size constraints, they are not stored in this repository but all analysis artifacts are.

## License

GPL-3.0