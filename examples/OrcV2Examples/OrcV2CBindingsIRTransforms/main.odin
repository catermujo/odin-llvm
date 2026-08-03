// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
package main

import "base:runtime"
import "core:c/libc"

import llvm "../../.."
import orc_support "../support"

module_transform :: proc "c" (_: rawptr, module: llvm.ModuleRef) -> llvm.ErrorRef {
    options := llvm.CreatePassBuilderOptions()
    err := llvm.RunPasses(module, "instcombine", nil, options)
    llvm.DisposePassBuilderOptions(options)
    return err
}

transform :: proc "c" (
    ctx: rawptr,
    module_in_out: ^llvm.OrcThreadSafeModuleRef,
    _: llvm.OrcMaterializationResponsibilityRef,
) -> llvm.ErrorRef {
    err := llvm.OrcThreadSafeModuleWithModuleDo(module_in_out^, module_transform, ctx)
    if err != nil {
        llvm.OrcDisposeThreadSafeModule(module_in_out^)
        module_in_out^ = nil
    }
    return err
}

run :: proc() -> (main_result: int) {
    llvm.ParseCommandLineOptions(i32(len(runtime.args__)), raw_data(runtime.args__), "")
    _ = llvm.InitializeNativeTarget()
    _ = llvm.InitializeNativeAsmPrinter()
    defer llvm.Shutdown()

    dump_objects := llvm.OrcCreateDumpObjects("", "")
    defer llvm.OrcDisposeDumpObjects(dump_objects)

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

    transform_layer := llvm.OrcLLJITGetIRTransformLayer(jit)
    llvm.OrcIRTransformLayerSetTransform(transform_layer, transform, nil)

    thread_safe_module := orc_support.create_demo_thread_safe_module()
    main_jit_dylib := llvm.OrcLLJITGetMainJITDylib(jit)
    if err := llvm.OrcLLJITAddLLVMIRModule(jit, main_jit_dylib, thread_safe_module); err != nil {
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
