// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
package main

import "base:runtime"
import "core:c/libc"

import llvm "../../.."
import orc_support "../support"

MAIN_MODULE :: `
  define i32 @fac(i32 %n) {
  entry:
    %tobool = icmp eq i32 %n, 0
    br i1 %tobool, label %return, label %if.then

  if.then:
    %arg = add nsw i32 %n, -1
    %call_result = call i32 @fac(i32 %arg)
    %result = mul nsw i32 %n, %call_result
    br label %return

  return:
    %final_result = phi i32 [ %result, %if.then ], [ 1, %entry ]
    ret i32 %final_result
  }

  define i32 @entry() {
  entry:
    %result = call i32 @fac(i32 5)
    ret i32 %result
  }
`

report_error :: proc(program: cstring, err: llvm.ErrorRef) -> int {
    message := llvm.GetErrorMessage(err)
    _ = libc.fprintf(libc.stderr, "%s: %s\n", program, message)
    llvm.DisposeErrorMessage(message)
    return 1
}

print_module :: proc(header: cstring, module: llvm.ModuleRef) {
    module_text := llvm.PrintModuleToString(module)
    _ = libc.fprintf(libc.stderr, "%s\n%s\n", header, module_text)
    llvm.DisposeMessage(module_text)
}

optimize_module :: proc "c" (_: rawptr, module: llvm.ModuleRef) -> llvm.ErrorRef {
    context = runtime.default_context()
    print_module("--- BEFORE OPTIMIZATION ---", module)

    options := llvm.CreatePassBuilderOptions()
    err := llvm.RunPasses(module, "function(tailcallelim,simplifycfg)", nil, options)
    llvm.DisposePassBuilderOptions(options)
    if err != nil {
        return err
    }

    print_module("--- AFTER OPTIMIZATION ---", module)
    return nil
}

transform :: proc "c" (
    _: rawptr,
    module_in_out: ^llvm.OrcThreadSafeModuleRef,
    _: llvm.OrcMaterializationResponsibilityRef,
) -> llvm.ErrorRef {
    return llvm.OrcThreadSafeModuleWithModuleDo(module_in_out^, optimize_module, nil)
}

run :: proc() -> (main_result: int) {
    _ = llvm.InitializeNativeTarget()
    _ = llvm.InitializeNativeAsmPrinter()
    defer llvm.Shutdown()

    jit: llvm.OrcLLJITRef
    if err := llvm.OrcCreateLLJIT(&jit, nil); err != nil {
        return report_error(runtime.args__[0], err)
    }
    defer {
        if err := llvm.OrcDisposeLLJIT(jit); err != nil {
            failure_result := report_error(runtime.args__[0], err)
            if main_result == 0 {
                main_result = failure_result
            }
        }
    }

    llvm.OrcIRTransformLayerSetTransform(llvm.OrcLLJITGetIRTransformLayer(jit), transform, nil)

    thread_safe_module: llvm.OrcThreadSafeModuleRef
    if err := orc_support.parse_example_module(MAIN_MODULE, "MainMod", &thread_safe_module); err != nil {
        return report_error(runtime.args__[0], err)
    }
    if err := llvm.OrcLLJITAddLLVMIRModule(jit, llvm.OrcLLJITGetMainJITDylib(jit), thread_safe_module); err != nil {
        return report_error(runtime.args__[0], err)
    }

    entry_address: llvm.OrcExecutorAddress
    if err := llvm.OrcLLJITLookup(jit, &entry_address, "entry"); err != nil {
        return report_error(runtime.args__[0], err)
    }

    entry := transmute(proc "c" () -> i32)entry_address
    result := entry()
    _ = libc.printf("--- Result ---\nentry() = %i\n", result)
    return 0
}

main :: proc() {
    libc.exit(i32(run()))
}
