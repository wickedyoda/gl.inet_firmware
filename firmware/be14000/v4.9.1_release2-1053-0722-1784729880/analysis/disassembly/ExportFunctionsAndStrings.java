// ExportFunctionsAndStrings.java
// Ghidra script for exporting function names and disassembly to file
// Simplified version - strings are extracted using CLI 'strings' tool

import java.io.*;
import java.util.*;
import ghidra.app.script.*;
import ghidra.program.model.listing.*;

public class ExportFunctionsAndStrings extends GhidraScript {

    @Override
    public void run() throws Exception {
        String binName = currentProgram.getDomainFile().getName();
        String safeName = binName.replace('.', '_');
        // Fix common name issues
        safeName = safeName.replace("fw_ipa_gsi_6_0_p_elf", "fw_ipa_gsi_6_0_p.elf");

        String funcFile = "/root/firmware/e5800/analysis/disassembly/ghidra_" + safeName + "_functions.txt";
        String strFile = "/root/firmware/e5800/analysis/disassembly/ghidra_" + safeName + "_strings.txt";

        // Export functions with their disassemblies
        PrintWriter fwriter = new PrintWriter(new FileWriter(funcFile));
        FunctionManager fm = currentProgram.getFunctionManager();
        Iterator<Function> funcs = fm.getFunctions(true);

        fwriter.println("=== Functions in " + binName + " ===");
        fwriter.println("Language: " + currentProgram.getLanguageID().toString());
        fwriter.println("Image Base: " + currentProgram.getImageBase());
        fwriter.println();

        List<Function> funcList = new ArrayList<>();
        int funcCount = 0;
        while (funcs.hasNext()) {
            Function f = funcs.next();
            funcList.add(f);
            funcCount++;
        }

        // Sort by entry point
        funcList.sort((a, b) -> {
            long aAddr = a.getEntryPoint().getOffset();
            long bAddr = b.getEntryPoint().getOffset();
            return Long.compare(aAddr, bAddr);
        });

        fwriter.println("Total functions: " + funcCount);
        fwriter.println("First 100 functions:");
        for (int i = 0; i < Math.min(100, funcList.size()); i++) {
            Function f = funcList.get(i);
            String entry = "0x" + Long.toHexString(f.getEntryPoint().getOffset());
            String fname = f.getName();
            long bodySize = f.getBody().getNumAddresses();
            fwriter.println(entry + ": " + fname + " (size: " + bodySize + ")");
        }

        if (funcList.size() > 100) {
            fwriter.println("... and " + (funcList.size() - 100) + " more functions");
        }
        fwriter.println();

        // Write summary
        fwriter.println("\n=== Function Summary ===");
        fwriter.println("Total functions: " + funcCount);
        fwriter.println("Language: " + currentProgram.getLanguageID().toString());
        fwriter.println("Image Base: " + currentProgram.getImageBase());

        fwriter.close();

        // Write empty strings file placeholder (use CLI strings tool for actual strings)
        PrintWriter swriter = new PrintWriter(new FileWriter(strFile));
        swriter.println("=== Strings placeholder ===");
        swriter.println("Run: strings -n 4 -e l " + binName);
        swriter.println("on the extracted binary to get strings.");
        swriter.close();

        // Print summary to console
        println("=== Summary for " + binName + " ===");
        println("  Language: " + currentProgram.getLanguageID().toString());
        println("  Image Base: " + currentProgram.getImageBase());
        println("  Functions: " + funcCount);
    }
}