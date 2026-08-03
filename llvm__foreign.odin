#+build darwin, linux, windows

package llvm

CONFIGURED_LINK :: #config(LLVM_LINK, "shared" when ODIN_OS == .Windows else "system")
LINK :: "shared" when ODIN_OS == .Windows && CONFIGURED_LINK == "system" else CONFIGURED_LINK
SYSTEM_LIB :: #config(LLVM_SYSTEM_LIB, "system:LLVM")
LTO_SYSTEM_LIB :: #config(LLVM_LTO_SYSTEM_LIB, "system:LTO")

when LINK != "shared" && LINK != "system" {
    #panic("vendor/llvm supports shared and system linking only")
}

when LINK == "shared" && ODIN_ARCH != .amd64 && ODIN_ARCH != .arm64 {
    #panic("vendor/llvm shared libraries support amd64 and arm64 only")
}

when LINK == "shared" && ODIN_OS == .Windows && ODIN_ARCH != .amd64 {
    #panic("vendor/llvm shared libraries support Windows amd64 only")
}

@(export)
foreign import lib {SYSTEM_LIB when LINK == "system" else "windows_x64/LLVM-C.lib" when ODIN_OS == .Windows else "darwin_x64/libLLVM.dylib" when ODIN_OS == .Darwin && ODIN_ARCH == .amd64 else "darwin_arm64/libLLVM.dylib" when ODIN_OS == .Darwin && ODIN_ARCH == .arm64 else "linux_x64/libLLVM.so" when ODIN_OS == .Linux && ODIN_ARCH == .amd64 else "linux_arm64/libLLVM.so"}
