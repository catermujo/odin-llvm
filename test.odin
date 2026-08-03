#+test

package llvm

import "core:testing"

@(test)
test_flag_values :: proc(t: ^testing.T) {
    generic := JITSymbolGenericFlags{.Exported, .Callable}
    testing.expect_value(t, transmute(LLVM_C_Enum)generic, LLVM_C_Enum(0b0101))

    symbol_flags: JITSymbolFlags = {
        Generic = {.Exported, .Callable},
    }
    testing.expect_value(t, transmute(u8)symbol_flags.Generic, u8(0b0101))
    testing.expect_value(t, transmute(LLVM_C_Enum)DIFlagPublic, LLVM_C_Enum(0b0011))
    testing.expect_value(t, transmute(u32)FastMathFlags{.AllowReassoc, .ApproxFunc}, u32(0x41))
    testing.expect_value(t, transmute(u32)GEPNoWrapFlags{.InBounds, .NUSW}, u32(0x03))
    testing.expect_value(t, transmute(u64)DisassemblerOptions{.UseMarkup, .Color}, u64(0x21))
}

@(test)
test_llvm_runtime :: proc(t: ^testing.T) {
    major, minor, patch: u32
    GetVersion(&major, &minor, &patch)
    testing.expect_value(t, major, u32(22))

    ctx := ContextCreate()
    if !testing.expect(t, ctx != nil) {
        return
    }
    defer ContextDispose(ctx)

    module := ModuleCreateWithNameInContext("llvm-smoke", ctx)
    if !testing.expect(t, module != nil) {
        return
    }
    defer DisposeModule(module)

    testing.expect_value(t, InitializeNativeTarget(), Bool(0))
    testing.expect_value(t, InitializeNativeAsmPrinter(), Bool(0))
    testing.expect(t, lto_get_version() != nil)
}
