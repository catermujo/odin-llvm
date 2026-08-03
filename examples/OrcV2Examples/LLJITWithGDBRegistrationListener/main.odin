// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
package main

import "base:runtime"
import "core:c/libc"
import "core:fmt"
import "core:os"
import "core:strings"

import llvm "../../.."

Options :: struct {
    entry:        string,
    input_files:  [dynamic]string,
    program_args: [dynamic]string,
    llvm_args:    [dynamic]cstring,
}

print_help :: proc(program: string) {
    fmt.printf("OVERVIEW: LLJITWithGDBRegistrationListener\n\n")
    fmt.printf("USAGE: %s [options] input files [--args <program arguments>...]\n\n", program)
    fmt.printf("OPTIONS:\n")
    fmt.printf("  --entry=<string> Symbol to call as main entry point\n")
    fmt.printf("  --help           Display available options\n")
}

parse_options :: proc() -> (options: Options, should_run: bool, status: int) {
    options.entry = "main"
    append(&options.llvm_args, runtime.args__[0])
    program_arguments := false
    positional_only := false

    for index := 1; index < len(os.args); index += 1 {
        argument := os.args[index]
        if program_arguments {
            append(&options.program_args, argument)
            continue
        }
        if !positional_only && (argument == "-args" || argument == "--args") {
            program_arguments = true
            continue
        }
        if !positional_only && argument == "--" {
            positional_only = true
            continue
        }
        if !positional_only && (argument == "-h" || argument == "-help" || argument == "--help") {
            print_help(os.args[0])
            return options, false, 0
        }

        if !positional_only && (argument == "-entry" || argument == "--entry") {
            if index + 1 == len(os.args) {
                fmt.eprintf("%s: for the --entry option: requires a value!\n", os.args[0])
                return options, false, 1
            }
            index += 1
            options.entry = os.args[index]
            continue
        }
        if !positional_only && strings.has_prefix(argument, "-entry=") {
            options.entry = argument[len("-entry="):]
            continue
        }
        if !positional_only && strings.has_prefix(argument, "--entry=") {
            options.entry = argument[len("--entry="):]
            continue
        }

        if !positional_only && strings.has_prefix(argument, "-") && argument != "-" {
            append(&options.llvm_args, runtime.args__[index])
            continue
        }
        append(&options.input_files, argument)
    }
    return options, true, 0
}

report_error :: proc(program: cstring, err: llvm.ErrorRef) -> int {
    message := llvm.GetErrorMessage(err)
    _ = libc.fprintf(libc.stderr, "%s: %s\n", program, message)
    llvm.DisposeErrorMessage(message)
    return 1
}

object_linking_layer_creator :: proc "c" (
    ctx: rawptr,
    execution_session: llvm.OrcExecutionSessionRef,
    _: cstring,
) -> llvm.OrcObjectLayerRef {
    layer := llvm.OrcCreateRTDyldObjectLinkingLayerWithSectionMemoryManager(execution_session)
    listener := llvm.CreateGDBRegistrationListener()
    llvm.OrcRTDyldObjectLinkingLayerRegisterJITEventListener(layer, listener)
    listener_registered := transmute(^bool)ctx
    listener_registered^ = true
    // LLVM-C cannot call RTDyldObjectLinkingLayer::setProcessAllSections(true).
    // Listener sees emitted sections, but debug sections stripped before emission
    // cannot be registered. This is not equivalent to canonical C++ behavior.
    return layer
}

parse_ir_file :: proc(program, path: string) -> (llvm.OrcThreadSafeModuleRef, bool) {
    buffer: llvm.MemoryBufferRef
    error_message: cstring
    failed: llvm.Bool
    if path == "-" {
        failed = llvm.CreateMemoryBufferWithSTDIN(&buffer, &error_message)
    } else {
        c_path, path_error := strings.clone_to_cstring(path, context.temp_allocator)
        if path_error != nil {
            fmt.eprintf("%s: invalid input path '%s'\n", program, path)
            return nil, false
        }
        failed = llvm.CreateMemoryBufferWithContentsOfFile(c_path, &buffer, &error_message)
    }
    if failed != 0 {
        fmt.eprintf("%s: %s: error: Could not open input file: %s\n", program, path, string(error_message))
        llvm.DisposeMessage(error_message)
        return nil, false
    }

    llvm_context := llvm.ContextCreate()
    module: llvm.ModuleRef
    failed = llvm.ParseIRInContext2(llvm_context, buffer, &module, &error_message)
    llvm.DisposeMemoryBuffer(buffer)
    if failed != 0 {
        fmt.eprintf("%s: %s\n", program, string(error_message))
        llvm.DisposeMessage(error_message)
        llvm.ContextDispose(llvm_context)
        return nil, false
    }

    thread_safe_context := llvm.OrcCreateNewThreadSafeContextFromLLVMContext(llvm_context)
    thread_safe_module := llvm.OrcCreateNewThreadSafeModule(module, thread_safe_context)
    llvm.OrcDisposeThreadSafeContext(thread_safe_context)
    return thread_safe_module, true
}

run :: proc(options: ^Options) -> (main_result: int) {
    _ = llvm.InitializeNativeTarget()
    _ = llvm.InitializeNativeAsmPrinter()
    defer llvm.Shutdown()

    llvm.ParseCommandLineOptions(
        i32(len(options.llvm_args)),
        raw_data(options.llvm_args[:]),
        "LLJITWithGDBRegistrationListener",
    )
    if len(options.input_files) == 0 {
        fmt.eprintf("%s: Not enough positional command line arguments specified!\n", os.args[0])
        fmt.eprintf("Must specify at least 1 positional argument: See: %s --help\n", os.args[0])
        return 1
    }

    target_machine_builder: llvm.OrcJITTargetMachineBuilderRef
    if err := llvm.OrcJITTargetMachineBuilderDetectHost(&target_machine_builder); err != nil {
        return report_error(runtime.args__[0], err)
    }
    when ODIN_OS != .Linux {
        _ = libc.fprintf(libc.stderr, "Warning: This demo may not work for platforms other than Linux.\n")
    }

    builder := llvm.OrcCreateLLJITBuilder()
    llvm.OrcLLJITBuilderSetJITTargetMachineBuilder(builder, target_machine_builder)
    listener_registered := false
    llvm.OrcLLJITBuilderSetObjectLinkingLayerCreator(
        builder,
        object_linking_layer_creator,
        rawptr(&listener_registered),
    )

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
    if !listener_registered {
        fmt.eprintf("%s: GDB JIT event listener was not registered\n", os.args[0])
        return 1
    }
    fmt.println("Custom RTDyld layer registered GDB JIT event listener")
    fmt.println("process-all-sections unavailable through LLVM-C; emitted sections only")

    main_jit_dylib := llvm.OrcLLJITGetMainJITDylib(jit)
    for path in options.input_files {
        thread_safe_module, ok := parse_ir_file(os.args[0], path)
        if !ok {
            return 1
        }
        if err := llvm.OrcLLJITAddLLVMIRModule(jit, main_jit_dylib, thread_safe_module); err != nil {
            return report_error(runtime.args__[0], err)
        }
    }

    entry_name, entry_name_error := strings.clone_to_cstring(options.entry, context.temp_allocator)
    if entry_name_error != nil {
        fmt.eprintf("%s: could not allocate entry-point name\n", os.args[0])
        return 1
    }
    entry_address: llvm.OrcExecutorAddress
    if err := llvm.OrcLLJITLookup(jit, &entry_address, entry_name); err != nil {
        return report_error(runtime.args__[0], err)
    }

    argc := len(options.program_args) + 1
    argv := make([]cstring, argc + 1, context.temp_allocator)
    argv0, argv0_error := strings.clone_to_cstring(options.input_files[0], context.temp_allocator)
    if argv0_error != nil {
        fmt.eprintf("%s: could not allocate program name\n", os.args[0])
        return 1
    }
    argv[0] = argv0
    for argument, index in options.program_args {
        c_argument, argument_error := strings.clone_to_cstring(argument, context.temp_allocator)
        if argument_error != nil {
            fmt.eprintf("%s: could not allocate program argument\n", os.args[0])
            return 1
        }
        argv[index + 1] = c_argument
    }

    entry := transmute(proc "c" (_: i32, _: [^]cstring) -> i32)entry_address
    return int(entry(i32(argc), raw_data(argv)))
}

program_main :: proc() -> int {
    options, should_run, status := parse_options()
    defer delete(options.input_files)
    defer delete(options.program_args)
    defer delete(options.llvm_args)
    if should_run {
        status = run(&options)
    }
    return status
}

main :: proc() {
    os.exit(program_main())
}
