// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
package main

import "base:runtime"
import "core:c"
import "core:c/libc"

import llvm "../../.."

MODULE_WITH_INITIALIZER ::
    "  @InitializersRunFlag = external global i32\n" +
    "  @DeinitializersRunFlag = external global i32\n" +
    "\n" +
    "  declare i32 @__cxa_atexit(void (i8*)*, i8*, i8*)\n" +
    "  @__dso_handle = external hidden global i8\n" +
    "\n" +
    "  @llvm.global_ctors =\n" +
    "    appending global [1 x { i32, void ()*, i8* }]\n" +
    "      [{ i32, void ()*, i8* } { i32 65535, void ()* @init_func, i8* null }]\n" +
    "\n" +
    "  define void @init_func() {\n" +
    "  entry:\n" +
    "    store i32 1, i32* @InitializersRunFlag\n" +
    "    %0 = call i32 @__cxa_atexit(void (i8*)* @deinit_func, i8* null,\n" +
    "                                i8* @__dso_handle)\n" +
    "    ret void\n" +
    "  }\n" +
    "\n" +
    "  define internal void @deinit_func(i8* %0) {\n" +
    "    store i32 1, i32* @DeinitializersRunFlag\n" +
    "    ret void\n" +
    "  }\n"

handle_error :: proc(err: llvm.ErrorRef) -> int {
    message := llvm.GetErrorMessage(err)
    _ = libc.fprintf(libc.stderr, "Error: %s\n", message)
    llvm.DisposeErrorMessage(message)
    return 1
}

parse_module :: proc(source: string, name: cstring) -> (llvm.OrcThreadSafeModuleRef, llvm.ErrorRef) {
    ctx := llvm.ContextCreate()
    module: llvm.ModuleRef
    error_message: cstring
    buffer := llvm.CreateMemoryBufferWithMemoryRange(cstring(raw_data(source)), c.size_t(len(source)), name, 0)
    failed := llvm.ParseIRInContext2(ctx, buffer, &module, &error_message)
    llvm.DisposeMemoryBuffer(buffer)

    if failed != 0 {
        err := llvm.CreateStringError(error_message)
        llvm.DisposeMessage(error_message)
        llvm.ContextDispose(ctx)
        return nil, err
    }

    thread_safe_ctx := llvm.OrcCreateNewThreadSafeContextFromLLVMContext(ctx)
    thread_safe_module := llvm.OrcCreateNewThreadSafeModule(module, thread_safe_ctx)
    llvm.OrcDisposeThreadSafeContext(thread_safe_ctx)
    return thread_safe_module, nil
}

run :: proc() -> (main_result: int) {
    _ = llvm.InitializeNativeTarget()
    _ = llvm.InitializeNativeAsmPrinter()
    llvm.ParseCommandLineOptions(i32(len(runtime.args__)), raw_data(runtime.args__), "LLJITWithInitializers")
    defer llvm.Shutdown()

    jit: llvm.OrcLLJITRef
    if err := llvm.OrcCreateLLJIT(&jit, nil); err != nil {
        return handle_error(err)
    }
    defer {
        if err := llvm.OrcDisposeLLJIT(jit); err != nil {
            failure := handle_error(err)
            if main_result == 0 {
                main_result = failure
            }
        }
    }

    thread_safe_module, parse_err := parse_module(MODULE_WITH_INITIALIZER, "M")
    if parse_err != nil {
        return handle_error(parse_err)
    }

    main_jit_dylib := llvm.OrcLLJITGetMainJITDylib(jit)
    if err := llvm.OrcLLJITAddLLVMIRModule(jit, main_jit_dylib, thread_safe_module); err != nil {
        return handle_error(err)
    }

    initializers_run_flag: i32
    deinitializers_run_flag: i32
    exported_flags: llvm.JITSymbolFlags = {
        Generic = {.Exported},
    }
    symbols := [2]llvm.OrcCSymbolMapPair {
        {
            Name = llvm.OrcLLJITMangleAndIntern(jit, "InitializersRunFlag"),
            Sym = {Address = u64(uintptr(&initializers_run_flag)), Flags = exported_flags},
        },
        {
            Name = llvm.OrcLLJITMangleAndIntern(jit, "DeinitializersRunFlag"),
            Sym = {Address = u64(uintptr(&deinitializers_run_flag)), Flags = exported_flags},
        },
    }
    absolute_symbols := llvm.OrcAbsoluteSymbols(raw_data(symbols[:]), 2)
    if err := llvm.OrcJITDylibDefine(main_jit_dylib, absolute_symbols); err != nil {
        llvm.OrcDisposeMaterializationUnit(absolute_symbols)
        return handle_error(err)
    }

    // LLVM-C has no LLJIT initialize/deinitialize calls. Export init_func only
    // for this lookup, then run its genuinely registered dtor through ORC.
    init_address: llvm.OrcExecutorAddress
    if err := llvm.OrcLLJITLookup(jit, &init_address, "init_func"); err != nil {
        return handle_error(err)
    }
    init_func := transmute(proc "c" ())init_address
    init_func()

    run_atexits_address: llvm.OrcExecutorAddress
    if err := llvm.OrcLLJITLookup(jit, &run_atexits_address, "__lljit_run_atexits"); err != nil {
        return handle_error(err)
    }
    run_atexits := transmute(proc "c" ())run_atexits_address
    run_atexits()

    _ = libc.printf("InitializerRanFlag = %i\n", initializers_run_flag)
    _ = libc.printf("DeinitializersRunFlag = %i\n", deinitializers_run_flag)
    return 0
}

main :: proc() {
    libc.exit(i32(run()))
}
