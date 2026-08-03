// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
package main

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"

import llvm "../../.."

TEST_MODULE ::
    "  define i32 @callee() {  \n" +
    "  entry:                  \n" +
    "    ret i32 7             \n" +
    "  }                       \n" +
    "                          \n" +
    "  define i32 @entry() {   \n" +
    "  entry:                  \n" +
    "    %0 = call i32 @callee()\n" +
    "    ret i32 %0            \n" +
    "  }                       \n"

Options :: struct {
    entry:   string,
    objects: [dynamic]string,
}

print_help :: proc() {
    fmt.println("USAGE: LLJITWithObjectLinkingLayerPlugin [--entry <symbol>] [input objects]...")
}

parse_options :: proc() -> (options: Options, run_program: bool, status: int) {
    options.entry = "entry"
    options.objects = make([dynamic]string, context.temp_allocator)

    positional_only := false
    for index := 1; index < len(os.args); index += 1 {
        argument := os.args[index]
        if positional_only {
            append(&options.objects, argument)
            continue
        }

        switch argument {
        case "-h", "--help":
            print_help()
            return options, false, 0
        case "--":
            positional_only = true
        case "-entry", "--entry":
            index += 1
            if index == len(os.args) {
                fmt.eprintf("%s: missing value for %s\n", os.args[0], argument)
                return options, false, 1
            }
            options.entry = os.args[index]
        case:
            if strings.has_prefix(argument, "-entry=") {
                options.entry = argument[len("-entry="):]
            } else if strings.has_prefix(argument, "--entry=") {
                options.entry = argument[len("--entry="):]
            } else if strings.has_prefix(argument, "-") {
                fmt.eprintf("%s: unknown option `%s'\n", os.args[0], argument)
                return options, false, 1
            } else {
                append(&options.objects, argument)
            }
        }
    }

    if options.entry == "" {
        fmt.eprintf("%s: entry symbol cannot be empty\n", os.args[0])
        return options, false, 1
    }
    return options, true, 0
}

report_error :: proc(err: llvm.ErrorRef) {
    message := llvm.GetErrorMessage(err)
    fmt.eprintf("%s: %s\n", os.args[0], string(message))
    llvm.DisposeErrorMessage(message)
}

object_transform :: proc "c" (_: rawptr, object_in_out: ^llvm.MemoryBufferRef) -> llvm.ErrorRef {
    context = runtime.default_context()
    fmt.printf("Stage: object transform before link (%d bytes)\n", llvm.GetBufferSize(object_in_out^))
    return nil
}

parse_demo_module :: proc() -> (llvm.OrcThreadSafeModuleRef, bool) {
    llvm_context := llvm.ContextCreate()
    source: string = TEST_MODULE
    buffer := llvm.CreateMemoryBufferWithMemoryRange(
        cstring(raw_data(source)),
        c.size_t(len(source)),
        "test-module",
        0,
    )
    module: llvm.ModuleRef
    message: cstring
    failed := llvm.ParseIRInContext(llvm_context, buffer, &module, &message)
    if failed != 0 {
        fmt.eprintf("%s: %s\n", os.args[0], string(message))
        llvm.DisposeMessage(message)
        llvm.ContextDispose(llvm_context)
        return nil, false
    }

    thread_safe_context := llvm.OrcCreateNewThreadSafeContextFromLLVMContext(llvm_context)
    thread_safe_module := llvm.OrcCreateNewThreadSafeModule(module, thread_safe_context)
    llvm.OrcDisposeThreadSafeContext(thread_safe_context)
    return thread_safe_module, true
}

add_object_file :: proc(jit: llvm.OrcLLJITRef, jit_dylib: llvm.OrcJITDylibRef, path: string) -> bool {
    c_path, path_error := strings.clone_to_cstring(path, context.temp_allocator)
    if path_error != nil {
        fmt.eprintf("%s: invalid input path `%s'\n", os.args[0], path)
        return false
    }

    object_buffer: llvm.MemoryBufferRef
    message: cstring
    if llvm.CreateMemoryBufferWithContentsOfFile(c_path, &object_buffer, &message) != 0 {
        fmt.eprintf("%s: %s: %s\n", os.args[0], path, string(message))
        llvm.DisposeMessage(message)
        return false
    }

    fmt.printf("Loading object: %s\n", path)
    if err := llvm.OrcLLJITAddObjectFile(jit, jit_dylib, object_buffer); err != nil {
        report_error(err)
        return false
    }
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

    // LLVM-C has no ObjectLinkingLayer::Plugin or JITLink LinkGraph pass hooks.
    // ObjectTransformLayer is the pre-link substitute; lookup below is completion, not notifyEmitted.
    llvm.OrcObjectTransformLayerSetTransform(llvm.OrcLLJITGetObjTransformLayer(jit), object_transform, nil)

    main_jit_dylib := llvm.OrcLLJITGetMainJITDylib(jit)
    if len(options.objects) == 0 {
        fmt.println("No input objects specified. Using demo module:")
        fmt.print(TEST_MODULE)
        fmt.println()
        thread_safe_module, ok := parse_demo_module()
        if !ok {
            return 1
        }
        if err := llvm.OrcLLJITAddLLVMIRModule(jit, main_jit_dylib, thread_safe_module); err != nil {
            report_error(err)
            return 1
        }
    } else {
        for path in options.objects {
            if !add_object_file(jit, main_jit_dylib, path) {
                return 1
            }
        }
    }

    entry_name, entry_error := strings.clone_to_cstring(options.entry, context.temp_allocator)
    if entry_error != nil {
        fmt.eprintf("%s: invalid entry symbol `%s'\n", os.args[0], options.entry)
        return 1
    }
    entry_address: llvm.OrcExecutorAddress
    if err := llvm.OrcLLJITLookup(jit, &entry_address, entry_name); err != nil {
        report_error(err)
        return 1
    }
    fmt.printf("Stage: lookup materialized and linked `%s'\n", options.entry)

    entry := transmute(proc "c" () -> i32)entry_address
    result := entry()
    fmt.println("---Result---")
    fmt.printf("%s() = %d\n", options.entry, result)
    return 0
}

main :: proc() {
    os.exit(run())
}
