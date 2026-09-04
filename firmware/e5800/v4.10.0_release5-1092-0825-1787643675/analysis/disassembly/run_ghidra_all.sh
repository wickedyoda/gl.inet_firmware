#!/usr/bin/env bash
# Run Ghidra analyzeHeadless on all 14 E5800 firmware binaries
# Each binary uses the correct processor based on ELF header analysis

GRD=/opt/ghidra_12.1.3_PUBLIC
SCRIPTPATH="/root/firmware/e5800/analysis/disassembly"

# Each binary: name, processor
declare -A PROCS=(
    ["uefi.elf"]="AARCH64:LE:64:v8A"
    ["tz.mbn"]="AARCH64:LE:64:v8A"
    ["xbl_s.melf"]="ARM:LE:32:v7"
    ["km41.mbn"]="AARCH64:LE:64:v8A"
    ["cmnlib64.mbn"]="AARCH64:LE:64:v8A"
    ["hypvm.mbn"]="AARCH64:LE:64:v8A"
    ["abl.elf"]="ARM:LE:32:v7"
    ["aop.mbn"]="ARM:LE:32:v7"
    ["aop_devcfg.mbn"]="ARM:LE:32:v7"
    ["shrm.elf"]="ARM:LE:32:v7"
    ["cpucp.elf"]="ARM:LE:32:v7"
    ["fw_ipa_gsi_6.0_p.elf"]="ARM:LE:32:v7"
    ["qupv3fw.elf"]="ARM:LE:32:v7"
    ["devcfg.mbn"]="AARCH64:LE:64:v8A"
)

BINARYDIR="/root/firmware/e5800/extracted"
PROJD="/tmp/ghidra_e5800"
mkdir -p "$PROJD"

for bin in "${!PROCS[@]}"; do
    proc="${PROCS[$bin]}"
    binpath="$BINARYDIR/$bin"
    
    if [ ! -f "$binpath" ]; then
        echo "SKIP: $bin not found"; continue
    fi
    
    safename=$(echo "$bin" | tr '.' '_')
    projdir="$PROJD/proj_${safename}"
    find "$projdir" -name "*.lock" -delete 2>/dev/null || true
    
    echo "=== $bin ($proc) ==="
    
    GHIDRA_HEADLESS_MAXMEM=512m "$GRD/support/analyzeHeadless" "$projdir" "proj_${safename}" \
        -import "$binpath" \
        -processor "$proc" \
        -postScript ExportFunctionsAndStrings.java \
        -scriptPath "$SCRIPTPATH/" \
        2>&1 | grep -E "Functions:|Total strings|Interesting|Summary|Language|Image Base|ERROR|error:|IMPORT|Using loader"
    
    echo "Done: $bin"
    sleep 5
done

echo ""
echo "=== ALL DONE ==="
ls -la "$SCRIPTPATH"/ghidra_*_functions.txt "$SCRIPTPATH"/ghidra_*_strings.txt 2>/dev/null

# Create combined summary
{
    echo "============================================================"
    echo "Ghidra Analysis Summary - E5800 Firmware Binaries"
    echo "============================================================"
    echo ""
    
    for bin in "${!PROCS[@]}"; do
        safename=$(echo "$bin" | tr '.' '_')
        funcfile="$SCRIPTPATH/ghidra_${safename}_functions.txt"
        strfile="$SCRIPTPATH/ghidra_${safename}_strings.txt"
        
        echo "=== $bin (${PROCS[$bin]}) ==="
        if [ -f "$funcfile" ]; then
            head -8 "$funcfile"
        else
            echo "  ERROR: analysis file not found"
        fi
        echo ""
    done
} > "$SCRIPTPATH/ghidra_analysis_summary.txt"

echo "Summary: $SCRIPTPATH/ghidra_analysis_summary.txt"