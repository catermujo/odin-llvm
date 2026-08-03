// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
package main

import "base:runtime"
import "core:c/libc"
import "core:fmt"
import "core:os"
import "core:strings"

import llvm "../../.."
import orc_support "../support"

ADD1_MODULE :: `
  define i32 @add1(i32 %x) {
  entry:
    %r = add nsw i32 %x, 1
    ret i32 %r
  }
`

Options :: struct {
    dump_jitted_objects: bool,
    dump_dir:            string,
    dump_file_stem:      string,
    llvm_args:           [dynamic]cstring,
}

print_help :: proc(program: string) {
    fmt.printf("OVERVIEW: LLJITDumpObjects\n\n")
    fmt.printf("USAGE: %s [options]\n\n", program)
    fmt.printf("OPTIONS:\n")
    fmt.printf("  --dump-dir=<string>             Directory to dump objects to\n")
    fmt.printf("  --dump-file-stem=<string>       Override default dump names\n")
    fmt.printf("  --dump-jitted-objects=<boolean> Dump jitted objects\n")
    fmt.printf("  --help                          Display available options\n")
}

parse_bool :: proc(program, option, value: string) -> (bool, bool) {
    switch value {
    case "true", "TRUE", "True", "1":
        return true, true
    case "false", "FALSE", "False", "0":
        return false, true
    case:
        fmt.eprintf("%s: for the %s option: '%s' is invalid value for boolean argument!\n", program, option, value)
        return false, false
    }
}

parse_options :: proc() -> (options: Options, should_run: bool, status: int) {
    options.dump_jitted_objects = true
    append(&options.llvm_args, runtime.args__[0])

    for index := 1; index < len(os.args); index += 1 {
        argument := os.args[index]

        if argument == "-h" || argument == "-help" || argument == "--help" {
            print_help(os.args[0])
            return options, false, 0
        }

        if argument == "-dump-jitted-objects" || argument == "--dump-jitted-objects" {
            options.dump_jitted_objects = true
            continue
        }
        bool_prefix := ""
        if strings.has_prefix(argument, "-dump-jitted-objects=") {
            bool_prefix = "-dump-jitted-objects="
        } else if strings.has_prefix(argument, "--dump-jitted-objects=") {
            bool_prefix = "--dump-jitted-objects="
        }
        if bool_prefix != "" {
            value, ok := parse_bool(os.args[0], "--dump-jitted-objects", argument[len(bool_prefix):])
            if !ok {
                return options, false, 1
            }
            options.dump_jitted_objects = value
            continue
        }

        if argument == "-dump-dir" || argument == "--dump-dir" {
            if index + 1 == len(os.args) {
                fmt.eprintf("%s: for the --dump-dir option: requires a value!\n", os.args[0])
                return options, false, 1
            }
            index += 1
            options.dump_dir = os.args[index]
            continue
        }
        if strings.has_prefix(argument, "-dump-dir=") {
            options.dump_dir = argument[len("-dump-dir="):]
            continue
        }
        if strings.has_prefix(argument, "--dump-dir=") {
            options.dump_dir = argument[len("--dump-dir="):]
            continue
        }

        if argument == "-dump-file-stem" || argument == "--dump-file-stem" {
            if index + 1 == len(os.args) {
                fmt.eprintf("%s: for the --dump-file-stem option: requires a value!\n", os.args[0])
                return options, false, 1
            }
            index += 1
            options.dump_file_stem = os.args[index]
            continue
        }
        if strings.has_prefix(argument, "-dump-file-stem=") {
            options.dump_file_stem = argument[len("-dump-file-stem="):]
            continue
        }
        if strings.has_prefix(argument, "--dump-file-stem=") {
            options.dump_file_stem = argument[len("--dump-file-stem="):]
            continue
        }

        append(&options.llvm_args, runtime.args__[index])
    }
    return options, true, 0
}

report_error :: proc(program: cstring, err: llvm.ErrorRef) -> int {
    message := llvm.GetErrorMessage(err)
    _ = libc.fprintf(libc.stderr, "%s: %s\n", program, message)
    llvm.DisposeErrorMessage(message)
    return 1
}

dump_objects_transform :: proc "c" (ctx: rawptr, object_in_out: ^llvm.MemoryBufferRef) -> llvm.ErrorRef {
    dump_objects := transmute(^llvm.OrcDumpObjectsRef)ctx
    return llvm.OrcDumpObjects_CallOperator(dump_objects^, object_in_out)
}

run :: proc(options: ^Options) -> (main_result: int) {
    _ = llvm.InitializeNativeTarget()
    _ = llvm.InitializeNativeAsmPrinter()
    defer llvm.Shutdown()

    llvm.ParseCommandLineOptions(i32(len(options.llvm_args)), raw_data(options.llvm_args[:]), "LLJITDumpObjects")

    _ = libc.printf(
        "Usage notes:\n" +
        "  Use -debug-only=orc on debug builds to see log messages of objects being dumped\n" +
        "  Specify -dump-dir to specify a dump directory\n" +
        "  Specify -dump-file-stem to override the dump file stem\n" +
        "  Specify -dump-jitted-objects=false to disable dumping\n",
    )

    dump_objects: llvm.OrcDumpObjectsRef
    if options.dump_jitted_objects {
        dump_dir, dump_dir_error := strings.clone_to_cstring(options.dump_dir, context.temp_allocator)
        if dump_dir_error != nil {
            fmt.eprintf("%s: could not allocate dump directory string\n", os.args[0])
            return 1
        }
        dump_file_stem, dump_file_stem_error := strings.clone_to_cstring(
            options.dump_file_stem,
            context.temp_allocator,
        )
        if dump_file_stem_error != nil {
            fmt.eprintf("%s: could not allocate dump file stem string\n", os.args[0])
            return 1
        }
        dump_objects = llvm.OrcCreateDumpObjects(dump_dir, dump_file_stem)
    }
    defer {
        if dump_objects != nil {
            llvm.OrcDisposeDumpObjects(dump_objects)
        }
    }

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

    if dump_objects != nil {
        llvm.OrcObjectTransformLayerSetTransform(
            llvm.OrcLLJITGetObjTransformLayer(jit),
            dump_objects_transform,
            rawptr(&dump_objects),
        )
    }

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

program_main :: proc() -> int {
    options, should_run, status := parse_options()
    defer delete(options.llvm_args)
    if should_run {
        status = run(&options)
    }
    return status
}

main :: proc() {
    os.exit(program_main())
}
