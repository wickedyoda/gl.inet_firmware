# GL.iNet E5800 (Mudi 7) Firmware Analysis

**Firmware Version:** `e5800-4.10.0_release5-1092-0825-1787643675`  
**Date:** 2026-09-04  
**Device:** GL.iNet E5800 (Mudi 7) / GL-BE10000  
**Base Platform:** MediaTek MT7988F (Filogic 880), OpenWrt 25.12

## Repository Structure

```
gl.inet_firmware/
├── firmware/
│   └── e5800/
│       └── v4.10.0_release5-1092-0825-1787643675/
│           ├── reports/              # Full analysis reports
│           │   ├── FIRMWARE_ANALYSIS_REPORT.md  # Main comprehensive report
│           │   ├── FIRMWARE_REPORT.md            # Initial report
│           │   └── gitleaks-results.json          # Secret scan results (0 leaks)
│           ├── disassembly/          # Binary disassembly outputs
│           │   ├── capstone_disassembly.txt      # Capstone disassembly of 14 binaries
│           │   ├── comprehensive_binary_analysis.txt
│           │   ├── elf_analysis.txt
│           │   ├── elf_headers.txt
│           │   ├── binary_hardening.txt
│           │   └── ghidra_analyze.py              # Ghidra analysis script
│           ├── strings/              # String analysis extracts
│           │   ├── all_strings_secret_patterns.txt
│           │   └── component_strings.txt
│           ├── boot_extraction/      # Boot.img binwalk extraction
│           │   └── boot_extraction_summary.txt
│           └── analysis/             # Source code and configs
│               └── gl-be10000.config   # E5800 OpenWrt build configuration
├── gl_openwrt/                      # GL.iNet OpenWrt repo reference
│   └── gl-be10000.config
└── README.md
```

## Key Findings

1. **Platform:** MediaTek MT7988F (Filogic 880), OpenWrt 25.12
2. **Architecture:** ARM64/AArch64 + ARM32 for SoC components
3. **Binaries:** 14 fully stripped Qualcomm proprietary blobs (no section headers)
4. **Bootloader chain:** XBL → ABL → UEFI → TZ → QSEE → AOP → Modem
5. **Secrets:** Zero hardcoded credentials (Gitleaks scan)
6. **Ghidra:** v12.1.3 + pyghidra 3.1.0 installed
7. **Kernel headers:** 6,269 kernel headers extracted from boot.img
8. **Device tree:** 30MB DTB found in boot.img

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
cat firmware/e5800/v4.10.0_release5-1092-0825-1787643675/reports/FIRMWARE_ANALYSIS_REPORT.md

# Examine Capstone disassembly
cat firmware/e5800/v4.10.0_release5-1092-0825-1787643675/disassembly/capstone_disassembly.txt
```

## License

GPL-3.0