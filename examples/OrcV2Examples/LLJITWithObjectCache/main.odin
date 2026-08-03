// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
package main

import "base:runtime"
import "core:c"
import "core:c/libc"

import llvm "../../.."

ADD1_MODULE ::
    "  define i32 @add1(i32 %x) {\n" + "  entry:\n" + "    %r = add nsw i32 %x, 1\n" + "    ret i32 %r\n" + "  }\n"

Object_Cache :: struct {
    object: llvm.MemoryBufferRef,
}

handle_error :: proc(err: llvm.ErrorRef) -> int {
    message := llvm.GetErrorMessage(err)
    _ = libc.fprintf(libc.stderr, "Error: %s\n", message)
    llvm.DisposeErrorMessage(message)
    return 1
}

emit_object :: proc(jit: llvm.OrcLLJITRef) -> (llvm.MemoryBufferRef, int) {
    ctx := llvm.ContextCreate()
    defer llvm.ContextDispose(ctx)

    module: llvm.ModuleRef
    error_message: cstring
    source: string = ADD1_MODULE
    source_buffer := llvm.CreateMemoryBufferWithMemoryRange(
        cstring(raw_data(source)),
        c.size_t(len(source)),
        "add1",
        0,
    )
    failed := llvm.ParseIRInContext2(ctx, source_buffer, &module, &error_message)
    llvm.DisposeMemoryBuffer(source_buffer)
    if failed != 0 {
        _ = libc.fprintf(libc.stderr, "Error: %s\n", error_message)
        llvm.DisposeMessage(error_message)
        return nil, 1
    }
    defer llvm.DisposeModule(module)

    triple := llvm.OrcLLJITGetTripleString(jit)
    llvm.SetTarget(module, triple)
    llvm.SetDataLayout(module, llvm.OrcLLJITGetDataLayoutStr(jit))

    target: llvm.TargetRef
    if llvm.GetTargetFromTriple(triple, &target, &error_message) != 0 {
        _ = libc.fprintf(libc.stderr, "Error getting target for %s: %s\n", triple, error_message)
        llvm.DisposeMessage(error_message)
        return nil, 1
    }

    target_machine := llvm.CreateTargetMachine(target, triple, "", "", .Default, .Default, .Default)
    if target_machine == nil {
        _ = libc.fprintf(libc.stderr, "Error creating target machine for %s\n", triple)
        return nil, 1
    }
    defer llvm.DisposeTargetMachine(target_machine)

    object: llvm.MemoryBufferRef
    if llvm.TargetMachineEmitToMemoryBuffer(target_machine, module, .ObjectFile, &error_message, &object) != 0 {
        _ = libc.fprintf(libc.stderr, "Error emitting object: %s\n", error_message)
        llvm.DisposeMessage(error_message)
        return nil, 1
    }
    return object, 0
}

run_jit_with_cache :: proc(cache: ^Object_Cache) -> (main_result: int) {
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

    // LLVM-C has no LLJIT object-cache hook. Cache one genuinely emitted
    // object, then give each LLJIT its own real buffer copy.
    if cache.object == nil {
        _ = libc.fprintf(libc.stderr, "No object for add1 in cache. Compiling.\n")
        object, status := emit_object(jit)
        if status != 0 {
            return status
        }
        cache.object = object
    } else {
        _ = libc.fprintf(libc.stderr, "Object for add1 loaded from cache.\n")
    }

    object_copy := llvm.CreateMemoryBufferWithMemoryRangeCopy(
        llvm.GetBufferStart(cache.object),
        llvm.GetBufferSize(cache.object),
        "add1",
    )
    main_jit_dylib := llvm.OrcLLJITGetMainJITDylib(jit)
    if err := llvm.OrcLLJITAddObjectFile(jit, main_jit_dylib, object_copy); err != nil {
        return handle_error(err)
    }

    add1_address: llvm.OrcExecutorAddress
    if err := llvm.OrcLLJITLookup(jit, &add1_address, "add1"); err != nil {
        return handle_error(err)
    }

    add1 := transmute(proc "c" (_: i32) -> i32)add1_address
    result := add1(42)
    _ = libc.printf("add1(42) = %i\n", result)
    return 0
}

run :: proc() -> int {
    _ = llvm.InitializeNativeTarget()
    _ = llvm.InitializeNativeAsmPrinter()
    llvm.ParseCommandLineOptions(i32(len(runtime.args__)), raw_data(runtime.args__), "LLJITWithObjectCache")
    defer llvm.Shutdown()

    cache: Object_Cache
    defer {
        if cache.object != nil {
            llvm.DisposeMemoryBuffer(cache.object)
        }
    }

    if result := run_jit_with_cache(&cache); result != 0 {
        return result
    }
    return run_jit_with_cache(&cache)
}

main :: proc() {
    libc.exit(i32(run()))
}
