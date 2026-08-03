// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
package main

import "core:fmt"
import "core:os"

import llvm "../.."

print_llvm_error :: proc(err: llvm.ErrorRef) {
    message := llvm.GetErrorMessage(err)
    fmt.eprintf("%s: %s\n", os.args[0], string(message))
    llvm.DisposeErrorMessage(message)
}

print_usage :: proc() {
    fmt.printfln("USAGE: %s [options]", os.args[0])
    fmt.println("\nOPTIONS:")
    fmt.println("  -h, --help  Display available options")
    fmt.println("  --version   Display the version of this program")
}

print_version :: proc() {
    major, minor, patch: u32
    llvm.GetVersion(&major, &minor, &patch)
    fmt.printfln("LLVM version %d.%d.%d", major, minor, patch)
}

run :: proc() -> int {
    parse_options := true
    for arg in os.args[1:] {
        if parse_options && arg == "--" {
            parse_options = false
            continue
        }
        if parse_options {
            switch arg {
            case "-h", "--h", "-help", "--help":
                print_usage()
                return 0
            case "-version", "--version":
                print_version()
                return 0
            }
        }
        fmt.eprintfln("%s: Unknown command line argument '%s'.  Try: '%s --help'", os.args[0], arg, os.args[0])
        return 1
    }

    if llvm.InitializeNativeTarget() != 0 || llvm.InitializeNativeAsmPrinter() != 0 {
        fmt.eprintln("native LLVM target unavailable")
        return 1
    }

    lljit_builder := llvm.OrcCreateLLJITBuilder()
    if lljit_builder == nil {
        fmt.eprintf("%s: Could not create LLJIT builder\n", os.args[0])
        return 1
    }

    jit: llvm.OrcLLJITRef
    if err := llvm.OrcCreateLLJIT(&jit, lljit_builder); err != nil {
        print_llvm_error(err)
        return 1
    }

    llvm_context := llvm.ContextCreate()
    module := llvm.ModuleCreateWithNameInContext("test", llvm_context)
    int_type := llvm.Int32TypeInContext(llvm_context)
    parameter_types := [1]llvm.TypeRef{int_type}
    add1_type := llvm.FunctionType(int_type, &parameter_types[0], 1, 0)
    add1 := llvm.AddFunction(module, "add1", add1_type)
    block := llvm.AppendBasicBlockInContext(llvm_context, add1, "EntryBlock")

    builder := llvm.CreateBuilderInContext(llvm_context)
    llvm.PositionBuilderAtEnd(builder, block)
    one := llvm.ConstInt(int_type, 1, 0)
    argument := llvm.GetParam(add1, 0)
    llvm.SetValueName2(argument, "AnArg", 5)
    add := llvm.BuildAdd(builder, one, argument, "")
    llvm.BuildRet(builder, add)
    llvm.DisposeBuilder(builder)

    thread_safe_context := llvm.OrcCreateNewThreadSafeContextFromLLVMContext(llvm_context)
    thread_safe_module := llvm.OrcCreateNewThreadSafeModule(module, thread_safe_context)
    llvm.OrcDisposeThreadSafeContext(thread_safe_context)

    main_jit_dylib := llvm.OrcLLJITGetMainJITDylib(jit)
    if err := llvm.OrcLLJITAddLLVMIRModule(jit, main_jit_dylib, thread_safe_module); err != nil {
        print_llvm_error(err)
        _ = llvm.OrcDisposeLLJIT(jit)
        return 1
    }

    address: llvm.OrcExecutorAddress
    if err := llvm.OrcLLJITLookup(jit, &address, "add1"); err != nil {
        print_llvm_error(err)
        _ = llvm.OrcDisposeLLJIT(jit)
        return 1
    }

    add1_function := transmute(proc "c" (_: i32) -> i32)address
    result := add1_function(42)
    fmt.printf("add1(42) = %d\n", result)

    if err := llvm.OrcDisposeLLJIT(jit); err != nil {
        print_llvm_error(err)
        return 1
    }
    return 0
}

main :: proc() {
    os.exit(run())
}
