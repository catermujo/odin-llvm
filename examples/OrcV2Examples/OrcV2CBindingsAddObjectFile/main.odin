// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
package main

import "base:runtime"
import "core:c/libc"

import llvm "../../.."
import orc_support "../support"

run :: proc() -> (main_result: int) {
    llvm.ParseCommandLineOptions(i32(len(runtime.args__)), raw_data(runtime.args__), "")
    _ = llvm.InitializeNativeTarget()
    _ = llvm.InitializeNativeAsmPrinter()
    defer llvm.Shutdown()

    jit: llvm.OrcLLJITRef
    if err := llvm.OrcCreateLLJIT(&jit, nil); err != nil {
        return orc_support.handle_error(err)
    }
    defer {
        if err := llvm.OrcDisposeLLJIT(jit); err != nil {
            new_failure_result := orc_support.handle_error(err)
            if main_result == 0 {
                main_result = new_failure_result
            }
        }
    }

    ctx := llvm.ContextCreate()
    module := orc_support.create_demo_module(ctx)
    triple := llvm.OrcLLJITGetTripleString(jit)
    target: llvm.TargetRef
    error_message: cstring
    if llvm.GetTargetFromTriple(triple, &target, &error_message) != 0 {
        _ = libc.fprintf(libc.stderr, "Error getting target for %s: %s\n", triple, error_message)
        llvm.DisposeMessage(error_message)
        llvm.DisposeModule(module)
        llvm.ContextDispose(ctx)
        return 1
    }

    target_machine := llvm.CreateTargetMachine(target, triple, "", "", .None, .Default, .Default)
    object_file_buffer: llvm.MemoryBufferRef
    if llvm.TargetMachineEmitToMemoryBuffer(
           target_machine,
           module,
           .ObjectFile,
           &error_message,
           &object_file_buffer,
       ) !=
       0 {
        _ = libc.fprintf(libc.stderr, "Error emitting object: %s\n", error_message)
        llvm.DisposeMessage(error_message)
        if object_file_buffer != nil {
            llvm.DisposeMemoryBuffer(object_file_buffer)
        }
        llvm.DisposeTargetMachine(target_machine)
        llvm.DisposeModule(module)
        llvm.ContextDispose(ctx)
        return 1
    }

    llvm.DisposeModule(module)
    llvm.ContextDispose(ctx)
    llvm.DisposeTargetMachine(target_machine)

    main_jit_dylib := llvm.OrcLLJITGetMainJITDylib(jit)
    if err := llvm.OrcLLJITAddObjectFile(jit, main_jit_dylib, object_file_buffer); err != nil {
        return orc_support.handle_error(err)
    }

    sum_address: llvm.OrcExecutorAddress
    if err := llvm.OrcLLJITLookup(jit, &sum_address, "sum"); err != nil {
        return orc_support.handle_error(err)
    }

    sum := transmute(proc "c" (_: i32, _: i32) -> i32)sum_address
    result := sum(1, 2)
    _ = libc.printf("1 + 2 = %i\n", result)
    return 0
}

main :: proc() {
    libc.exit(i32(run()))
}
