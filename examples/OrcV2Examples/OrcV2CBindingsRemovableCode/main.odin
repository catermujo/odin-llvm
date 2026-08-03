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

    thread_safe_module := orc_support.create_demo_thread_safe_module()
    main_jit_dylib := llvm.OrcLLJITGetMainJITDylib(jit)
    resource_tracker := llvm.OrcJITDylibCreateResourceTracker(main_jit_dylib)
    defer {
        _ = libc.printf("Releasing resource tracker...\n")
        llvm.OrcReleaseResourceTracker(resource_tracker)
        _ = libc.printf("Destroying LLJIT instance and exiting.\n")
        if err := llvm.OrcDisposeLLJIT(jit); err != nil {
            new_failure_result := orc_support.handle_error(err)
            if main_result == 0 {
                main_result = new_failure_result
            }
        }
    }

    if err := llvm.OrcLLJITAddLLVMIRModuleWithRT(jit, resource_tracker, thread_safe_module); err != nil {
        return orc_support.handle_error(err)
    }

    _ = libc.printf("Looking up before removal...\n")
    sum_address: llvm.OrcExecutorAddress
    if err := llvm.OrcLLJITLookup(jit, &sum_address, "sum"); err != nil {
        return orc_support.handle_error(err)
    }

    sum := transmute(proc "c" (_: i32, _: i32) -> i32)sum_address
    result := sum(1, 2)
    _ = libc.printf("1 + 2 = %i\n", result)

    if err := llvm.OrcResourceTrackerRemove(resource_tracker); err != nil {
        return orc_support.handle_error(err)
    }

    _ = libc.printf("Attempting to remove code / symbols...\n")
    throw_away_address: llvm.OrcExecutorAddress
    if err := llvm.OrcLLJITLookup(jit, &throw_away_address, "sum"); err != nil {
        _ = libc.printf("Received error as expected:\n")
        _ = orc_support.handle_error(err)
    } else {
        _ = libc.printf("Failure: Second lookup should have generated an error.\n")
        main_result = 1
    }

    return main_result
}

main :: proc() {
    libc.exit(i32(run()))
}
