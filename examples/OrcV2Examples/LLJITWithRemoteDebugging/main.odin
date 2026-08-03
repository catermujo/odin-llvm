// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
package main

import "core:fmt"
import "core:io"
import "core:os"
import "core:strings"

import llvm "../../.."

Options :: struct {
    input_files:       [dynamic]string,
    program_args:      [dynamic]string,
    dylibs:            [dynamic]string,
    wait_for_debugger: bool,
}

print_help :: proc() {
    fmt.println(
        "USAGE: LLJITWithRemoteDebugging [--wait-for-debugger] [--dlopen <path>] <input files>... [--args <program arguments>...]",
    )
    fmt.println("       Remote --executor and --connect modes are unavailable through LLVM-C.")
}

remote_option :: proc(argument: string) -> bool {
    return(
        argument == "-executor" ||
        argument == "--executor" ||
        argument == "-connect" ||
        argument == "--connect" ||
        strings.has_prefix(argument, "-executor=") ||
        strings.has_prefix(argument, "--executor=") ||
        strings.has_prefix(argument, "-connect=") ||
        strings.has_prefix(argument, "--connect=") \
    )
}

parse_options :: proc() -> (options: Options, run_program: bool, status: int) {
    options.input_files = make([dynamic]string, context.temp_allocator)
    options.program_args = make([dynamic]string, context.temp_allocator)
    options.dylibs = make([dynamic]string, context.temp_allocator)

    for index := 1; index < len(os.args); index += 1 {
        argument := os.args[index]
        if remote_option(argument) {
            fmt.eprintf("%s: `%s' unavailable: LLVM-C cannot construct SimpleRemoteEPC\n", os.args[0], argument)
            return options, false, 1
        }

        switch argument {
        case "-h", "--help":
            print_help()
            return options, false, 0
        case "--wait-for-debugger":
            options.wait_for_debugger = true
        case "--args":
            for program_argument in os.args[index + 1:] {
                append(&options.program_args, program_argument)
            }
            index = len(os.args)
        case "-dlopen", "--dlopen":
            index += 1
            if index == len(os.args) {
                fmt.eprintf("%s: missing value for %s\n", os.args[0], argument)
                return options, false, 1
            }
            append(&options.dylibs, os.args[index])
        case:
            if strings.has_prefix(argument, "-dlopen=") {
                append(&options.dylibs, argument[len("-dlopen="):])
            } else if strings.has_prefix(argument, "--dlopen=") {
                append(&options.dylibs, argument[len("--dlopen="):])
            } else if strings.has_prefix(argument, "-") {
                fmt.eprintf("%s: unknown option `%s'\n", os.args[0], argument)
                return options, false, 1
            } else {
                append(&options.input_files, argument)
            }
        }
    }

    if len(options.input_files) == 0 {
        fmt.eprintf("%s: at least one input IR file is required\n", os.args[0])
        return options, false, 1
    }
    return options, true, 0
}

report_error :: proc(err: llvm.ErrorRef) {
    message := llvm.GetErrorMessage(err)
    fmt.eprintf("%s: %s\n", os.args[0], string(message))
    llvm.DisposeErrorMessage(message)
}

add_ir_file :: proc(jit: llvm.OrcLLJITRef, jit_dylib: llvm.OrcJITDylibRef, path: string) -> bool {
    fmt.printf("Parsing input IR code from: %s\n", path)
    c_path, path_error := strings.clone_to_cstring(path, context.temp_allocator)
    if path_error != nil {
        fmt.eprintf("%s: invalid input path `%s'\n", os.args[0], path)
        return false
    }

    buffer: llvm.MemoryBufferRef
    message: cstring
    if llvm.CreateMemoryBufferWithContentsOfFile(c_path, &buffer, &message) != 0 {
        fmt.eprintf("%s: %s: %s\n", os.args[0], path, string(message))
        llvm.DisposeMessage(message)
        return false
    }

    llvm_context := llvm.ContextCreate()
    module: llvm.ModuleRef
    failed := llvm.ParseIRInContext(llvm_context, buffer, &module, &message)
    if failed != 0 {
        fmt.eprintf("%s: %s: %s\n", os.args[0], path, string(message))
        llvm.DisposeMessage(message)
        llvm.ContextDispose(llvm_context)
        return false
    }

    if string(llvm.GetTarget(module)) == "" {
        llvm.SetTarget(module, llvm.OrcLLJITGetTripleString(jit))
    }
    if string(llvm.GetDataLayoutStr(module)) == "" {
        llvm.SetDataLayout(module, llvm.OrcLLJITGetDataLayoutStr(jit))
    }

    thread_safe_context := llvm.OrcCreateNewThreadSafeContextFromLLVMContext(llvm_context)
    thread_safe_module := llvm.OrcCreateNewThreadSafeModule(module, thread_safe_context)
    llvm.OrcDisposeThreadSafeContext(thread_safe_context)
    if err := llvm.OrcLLJITAddLLVMIRModule(jit, jit_dylib, thread_safe_module); err != nil {
        report_error(err)
        return false
    }
    return true
}

load_dylib :: proc(jit: llvm.OrcLLJITRef, jit_dylib: llvm.OrcJITDylibRef, path: string) -> bool {
    c_path, path_error := strings.clone_to_cstring(path, context.temp_allocator)
    if path_error != nil {
        fmt.eprintf("%s: invalid dynamic library path `%s'\n", os.args[0], path)
        return false
    }

    // EPCDynamicLibrarySearchGenerator is remote-only; this generator searches a local dylib.
    generator: llvm.OrcDefinitionGeneratorRef
    if err := llvm.OrcCreateDynamicLibrarySearchGeneratorForPath(
        &generator,
        c_path,
        llvm.OrcLLJITGetGlobalPrefix(jit),
        nil,
        nil,
    ); err != nil {
        report_error(err)
        return false
    }
    llvm.OrcJITDylibAddGenerator(jit_dylib, generator)
    fmt.printf("Loaded in-process dynamic library: %s\n", path)
    return true
}

run :: proc() -> (status: int) {
    options, run_program, option_status := parse_options()
    if !run_program {
        return option_status
    }

    if llvm.InitializeNativeTarget() != 0 || llvm.InitializeNativeAsmPrinter() != 0 {
        fmt.eprintln("native LLVM target unavailable")
        return 1
    }
    defer llvm.Shutdown()

    if options.wait_for_debugger {
        fmt.printf("Attach a debugger to this process (PID %d) and press any key to continue.\n", os.get_pid())
        _ = os.flush(os.stdout)
        _, _ = io.read_byte(os.to_reader(os.stdin))
    }

    fmt.println("Initializing in-process LLJIT with debug support")
    jit: llvm.OrcLLJITRef
    if err := llvm.OrcCreateLLJIT(&jit, nil); err != nil {
        report_error(err)
        return 1
    }
    defer {
        if err := llvm.OrcDisposeLLJIT(jit); err != nil {
            report_error(err)
            if status == 0 {
                status = 1
            }
        }
    }

    // LLVM-C has no SimpleRemoteEPC transport or LLJIT EPC setter.
    // Local LLJIT plus LLVMOrcLLJITEnableDebugSupport preserves debugger registration.
    if err := llvm.OrcLLJITEnableDebugSupport(jit); err != nil {
        report_error(err)
        return 1
    }
    fmt.println("In-process LLJIT debugger support plugin enabled")

    main_jit_dylib := llvm.OrcLLJITGetMainJITDylib(jit)
    for path in options.dylibs {
        if !load_dylib(jit, main_jit_dylib, path) {
            return 1
        }
    }
    for path in options.input_files {
        if !add_ir_file(jit, main_jit_dylib, path) {
            return 1
        }
    }

    main_address: llvm.OrcExecutorAddress
    if err := llvm.OrcLLJITLookup(jit, &main_address, "main"); err != nil {
        report_error(err)
        return 1
    }

    fmt.print("Running: main(")
    for argument, index in options.program_args {
        if index != 0 {
            fmt.print(", ")
        }
        fmt.printf("\"%s\"", argument)
    }
    fmt.println(")")

    argc := len(options.program_args) + 1
    argv := make([]cstring, argc + 1, context.temp_allocator)
    argv[0] = "LLJITWithRemoteDebugging"
    for argument, index in options.program_args {
        c_argument, argument_error := strings.clone_to_cstring(argument, context.temp_allocator)
        if argument_error != nil {
            fmt.eprintf("%s: invalid program argument\n", os.args[0])
            return 1
        }
        argv[index + 1] = c_argument
    }

    // Direct C-ABI invocation replaces remote ExecutorProcessControl::runAsMain.
    main_function := transmute(proc "c" (_: i32, _: [^]cstring) -> i32)main_address
    result := main_function(i32(argc), raw_data(argv))
    fmt.printf("Exit code: %d\n", result)
    return 0
}

main :: proc() {
    os.exit(run())
}
