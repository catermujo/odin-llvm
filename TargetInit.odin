#+build darwin, linux, windows
package llvm

@(default_calling_convention = "c", link_prefix = "LLVM")
foreign lib {
    InitializeAArch64TargetInfo :: proc() ---
    InitializeAMDGPUTargetInfo :: proc() ---
    InitializeARMTargetInfo :: proc() ---
    InitializeAVRTargetInfo :: proc() ---
    InitializeBPFTargetInfo :: proc() ---
    InitializeHexagonTargetInfo :: proc() ---
    InitializeLanaiTargetInfo :: proc() ---
    InitializeLoongArchTargetInfo :: proc() ---
    InitializeMipsTargetInfo :: proc() ---
    InitializeMSP430TargetInfo :: proc() ---
    InitializeNVPTXTargetInfo :: proc() ---
    InitializePowerPCTargetInfo :: proc() ---
    InitializeRISCVTargetInfo :: proc() ---
    InitializeSparcTargetInfo :: proc() ---
    InitializeSPIRVTargetInfo :: proc() ---
    InitializeSystemZTargetInfo :: proc() ---
    InitializeVETargetInfo :: proc() ---
    InitializeWebAssemblyTargetInfo :: proc() ---
    InitializeX86TargetInfo :: proc() ---
    InitializeXCoreTargetInfo :: proc() ---

    InitializeAArch64Target :: proc() ---
    InitializeAMDGPUTarget :: proc() ---
    InitializeARMTarget :: proc() ---
    InitializeAVRTarget :: proc() ---
    InitializeBPFTarget :: proc() ---
    InitializeHexagonTarget :: proc() ---
    InitializeLanaiTarget :: proc() ---
    InitializeLoongArchTarget :: proc() ---
    InitializeMipsTarget :: proc() ---
    InitializeMSP430Target :: proc() ---
    InitializeNVPTXTarget :: proc() ---
    InitializePowerPCTarget :: proc() ---
    InitializeRISCVTarget :: proc() ---
    InitializeSparcTarget :: proc() ---
    InitializeSPIRVTarget :: proc() ---
    InitializeSystemZTarget :: proc() ---
    InitializeVETarget :: proc() ---
    InitializeWebAssemblyTarget :: proc() ---
    InitializeX86Target :: proc() ---
    InitializeXCoreTarget :: proc() ---

    InitializeAArch64TargetMC :: proc() ---
    InitializeAMDGPUTargetMC :: proc() ---
    InitializeARMTargetMC :: proc() ---
    InitializeAVRTargetMC :: proc() ---
    InitializeBPFTargetMC :: proc() ---
    InitializeHexagonTargetMC :: proc() ---
    InitializeLanaiTargetMC :: proc() ---
    InitializeLoongArchTargetMC :: proc() ---
    InitializeMipsTargetMC :: proc() ---
    InitializeMSP430TargetMC :: proc() ---
    InitializeNVPTXTargetMC :: proc() ---
    InitializePowerPCTargetMC :: proc() ---
    InitializeRISCVTargetMC :: proc() ---
    InitializeSparcTargetMC :: proc() ---
    InitializeSPIRVTargetMC :: proc() ---
    InitializeSystemZTargetMC :: proc() ---
    InitializeVETargetMC :: proc() ---
    InitializeWebAssemblyTargetMC :: proc() ---
    InitializeX86TargetMC :: proc() ---
    InitializeXCoreTargetMC :: proc() ---

    InitializeAArch64AsmPrinter :: proc() ---
    InitializeAMDGPUAsmPrinter :: proc() ---
    InitializeARMAsmPrinter :: proc() ---
    InitializeAVRAsmPrinter :: proc() ---
    InitializeBPFAsmPrinter :: proc() ---
    InitializeHexagonAsmPrinter :: proc() ---
    InitializeLanaiAsmPrinter :: proc() ---
    InitializeLoongArchAsmPrinter :: proc() ---
    InitializeMipsAsmPrinter :: proc() ---
    InitializeMSP430AsmPrinter :: proc() ---
    InitializeNVPTXAsmPrinter :: proc() ---
    InitializePowerPCAsmPrinter :: proc() ---
    InitializeRISCVAsmPrinter :: proc() ---
    InitializeSparcAsmPrinter :: proc() ---
    InitializeSPIRVAsmPrinter :: proc() ---
    InitializeSystemZAsmPrinter :: proc() ---
    InitializeVEAsmPrinter :: proc() ---
    InitializeWebAssemblyAsmPrinter :: proc() ---
    InitializeX86AsmPrinter :: proc() ---
    InitializeXCoreAsmPrinter :: proc() ---

    InitializeAArch64AsmParser :: proc() ---
    InitializeAMDGPUAsmParser :: proc() ---
    InitializeARMAsmParser :: proc() ---
    InitializeAVRAsmParser :: proc() ---
    InitializeBPFAsmParser :: proc() ---
    InitializeHexagonAsmParser :: proc() ---
    InitializeLanaiAsmParser :: proc() ---
    InitializeLoongArchAsmParser :: proc() ---
    InitializeMipsAsmParser :: proc() ---
    InitializeMSP430AsmParser :: proc() ---
    InitializePowerPCAsmParser :: proc() ---
    InitializeRISCVAsmParser :: proc() ---
    InitializeSparcAsmParser :: proc() ---
    InitializeSystemZAsmParser :: proc() ---
    InitializeVEAsmParser :: proc() ---
    InitializeWebAssemblyAsmParser :: proc() ---
    InitializeX86AsmParser :: proc() ---

    InitializeAArch64Disassembler :: proc() ---
    InitializeAMDGPUDisassembler :: proc() ---
    InitializeARMDisassembler :: proc() ---
    InitializeAVRDisassembler :: proc() ---
    InitializeBPFDisassembler :: proc() ---
    InitializeHexagonDisassembler :: proc() ---
    InitializeLanaiDisassembler :: proc() ---
    InitializeLoongArchDisassembler :: proc() ---
    InitializeMipsDisassembler :: proc() ---
    InitializeMSP430Disassembler :: proc() ---
    InitializePowerPCDisassembler :: proc() ---
    InitializeRISCVDisassembler :: proc() ---
    InitializeSparcDisassembler :: proc() ---
    InitializeSystemZDisassembler :: proc() ---
    InitializeVEDisassembler :: proc() ---
    InitializeWebAssemblyDisassembler :: proc() ---
    InitializeX86Disassembler :: proc() ---
    InitializeXCoreDisassembler :: proc() ---
}

InitializeNativeTarget :: proc() -> Bool {
    when ODIN_ARCH == .amd64 {
        InitializeX86TargetInfo()
        InitializeX86Target()
        InitializeX86TargetMC()
    } else when ODIN_ARCH == .arm64 {
        InitializeAArch64TargetInfo()
        InitializeAArch64Target()
        InitializeAArch64TargetMC()
    } else {
        #panic("vendor/llvm supports native target initialization on amd64 and arm64 only")
    }
    return 0
}

InitializeNativeAsmParser :: proc() -> Bool {
    when ODIN_ARCH == .amd64 {
        InitializeX86AsmParser()
    } else when ODIN_ARCH == .arm64 {
        InitializeAArch64AsmParser()
    } else {
        #panic("vendor/llvm supports native asm parser initialization on amd64 and arm64 only")
    }
    return 0
}

InitializeNativeAsmPrinter :: proc() -> Bool {
    when ODIN_ARCH == .amd64 {
        InitializeX86AsmPrinter()
    } else when ODIN_ARCH == .arm64 {
        InitializeAArch64AsmPrinter()
    } else {
        #panic("vendor/llvm supports native asm printer initialization on amd64 and arm64 only")
    }
    return 0
}

InitializeNativeDisassembler :: proc() -> Bool {
    when ODIN_ARCH == .amd64 {
        InitializeX86Disassembler()
    } else when ODIN_ARCH == .arm64 {
        InitializeAArch64Disassembler()
    } else {
        #panic("vendor/llvm supports native disassembler initialization on amd64 and arm64 only")
    }
    return 0
}
