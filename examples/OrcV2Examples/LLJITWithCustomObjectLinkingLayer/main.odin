// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
package main

import "base:runtime"
import "core:c/libc"

import llvm "../../.."
import orc_support "../support"

ADD1_MODULE :: `
  define i32 @add1(i32 %x) {
  entry:
    %r = add nsw i32 %x, 1
    ret i32 %r
  }
`

Object_Layer_State :: struct {
    program: cstring,
    created: bool,
}

report_error :: proc(program: cstring, err: llvm.ErrorRef) -> int {
    message := llvm.GetErrorMessage(err)
    _ = libc.fprintf(libc.stderr, "%s: %s\n", program, message)
    llvm.DisposeErrorMessage(message)
    return 1
}

create_small_host_target_machine_builder :: proc(program: cstring) -> llvm.OrcJITTargetMachineBuilderRef {
    triple := llvm.GetDefaultTargetTriple()
    defer llvm.DisposeMessage(triple)

    target: llvm.TargetRef
    error_message: cstring
    if llvm.GetTargetFromTriple(triple, &target, &error_message) != 0 {
        _ = libc.fprintf(libc.stderr, "%s: %s\n", program, error_message)
        llvm.DisposeMessage(error_message)
        return nil
    }

    cpu := llvm.GetHostCPUName()
    defer llvm.DisposeMessage(cpu)
    features := llvm.GetHostCPUFeatures()
    defer llvm.DisposeMessage(features)
    target_machine := llvm.CreateTargetMachine(target, triple, cpu, features, .Default, .Default, .Small)
    if target_machine == nil {
        _ = libc.fprintf(libc.stderr, "%s: Could not allocate target machine\n", program)
        return nil
    }
    return llvm.OrcJITTargetMachineBuilderCreateFromTargetMachine(target_machine)
}

object_linking_layer_creator :: proc "c" (
    ctx: rawptr,
    execution_session: llvm.OrcExecutionSessionRef,
    _: cstring,
) -> llvm.OrcObjectLayerRef {
    context = runtime.default_context()
    state := transmute(^Object_Layer_State)ctx
    layer: llvm.OrcObjectLayerRef
    if err := llvm.OrcCreateObjectLinkingLayerWithInProcessMemoryManager(&layer, execution_session); err != nil {
        _ = report_error(state.program, err)
        libc.exit(1)
    }
    state.created = true
    return layer
}

run :: proc() -> (main_result: int) {
    _ = llvm.InitializeNativeTarget()
    _ = llvm.InitializeNativeAsmPrinter()
    defer llvm.Shutdown()

    llvm.ParseCommandLineOptions(
        i32(len(runtime.args__)),
        raw_data(runtime.args__),
        "LLJITWithCustomObjectLinkingLayer",
    )

    target_machine_builder := create_small_host_target_machine_builder(runtime.args__[0])
    if target_machine_builder == nil {
        return 1
    }
    builder := llvm.OrcCreateLLJITBuilder()
    llvm.OrcLLJITBuilderSetJITTargetMachineBuilder(builder, target_machine_builder)
    layer_state := Object_Layer_State {
        program = runtime.args__[0],
    }
    llvm.OrcLLJITBuilderSetObjectLinkingLayerCreator(builder, object_linking_layer_creator, rawptr(&layer_state))

    jit: llvm.OrcLLJITRef
    if err := llvm.OrcCreateLLJIT(&jit, builder); err != nil {
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
    if !layer_state.created {
        _ = libc.fprintf(libc.stderr, "%s: custom object linking layer was not created\n", runtime.args__[0])
        return 1
    }
    _ = libc.printf("Custom JITLink object linking layer created with in-process memory manager\n")

    thread_safe_module: llvm.OrcThreadSafeModuleRef
    if err := orc_support.parse_example_module(ADD1_MODULE, "add1", &thread_safe_module); err != nil {
        return report_error(runtime.args__[0], err)
    }
    if err := llvm.OrcLLJITAddLLVMIRModule(jit, llvm.OrcLLJITGetMainJITDylib(jit), thread_safe_module); err != nil {
        return report_error(runtime.args__[0], err)
    }

    add1_address: llvm.OrcExecutorAddress
    if err := llvm.OrcLLJITLookup(jit, &add1_address, "add1"); err != nil {
        return report_error(runtime.args__[0], err)
    }

    add1 := transmute(proc "c" (_: i32) -> i32)add1_address
    result := add1(42)
    _ = libc.printf("add1(42) = %i\n", result)
    return 0
}

main :: proc() {
    libc.exit(i32(run()))
}
