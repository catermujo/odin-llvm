// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
package main

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"

import llvm "../.."

Options :: struct {
    input: string,
    wave:  bool,
}

print_help :: proc() {
    fmt.println("USAGE: Bye [-wave-goodbye] [input.ll|-]")
}

parse_options :: proc() -> (options: Options, run: bool, status: int) {
    options.input = "-"
    has_input := false

    for arg in os.args[1:] {
        switch arg {
        case "-wave-goodbye", "--wave-goodbye":
            options.wave = true
        case "-h", "--help":
            print_help()
            return options, false, 0
        case:
            if strings.has_prefix(arg, "-") && arg != "-" {
                fmt.eprintf("Bye: unknown option `%s'\n", arg)
                return options, false, 1
            }
            if has_input {
                fmt.eprintf("Bye: unexpected positional argument `%s'\n", arg)
                return options, false, 1
            }
            options.input = arg
            has_input = true
        }
    }
    return options, true, 0
}

print_llvm_error :: proc(tool: string, message: cstring) {
    if message != nil {
        fmt.eprintf("%s: %s\n", tool, string(message))
        llvm.DisposeMessage(message)
    } else {
        fmt.eprintf("%s: unknown LLVM error\n", tool)
    }
}

parse_ir :: proc(llvm_context: llvm.ContextRef, input: string) -> (module: llvm.ModuleRef, ok: bool) {
    buffer: llvm.MemoryBufferRef
    message: cstring

    if input == "-" {
        if llvm.CreateMemoryBufferWithSTDIN(&buffer, &message) != 0 {
            print_llvm_error("Bye", message)
            return nil, false
        }
    } else {
        path, path_error := strings.clone_to_cstring(input, context.temp_allocator)
        if path_error != nil {
            fmt.eprintf("Bye: invalid input path `%s'\n", input)
            return nil, false
        }
        if llvm.CreateMemoryBufferWithContentsOfFile(path, &buffer, &message) != 0 {
            print_llvm_error("Bye", message)
            return nil, false
        }
    }
    if llvm.ParseIRInContext(llvm_context, buffer, &module, &message) != 0 {
        print_llvm_error("Bye", message)
        return nil, false
    }
    return module, true
}

verify_module :: proc(module: llvm.ModuleRef) -> bool {
    message: cstring
    if llvm.VerifyModule(module, .ReturnStatus, &message) != 0 {
        print_llvm_error("Bye: input module is invalid", message)
        return false
    }
    if message != nil {
        llvm.DisposeMessage(message)
    }
    return true
}

escaped_name :: proc(name: string) -> string {
    result := make([dynamic]byte, 0, len(name) * 4, context.temp_allocator)
    for index in 0 ..< len(name) {
        value := name[index]
        switch value {
        case '\\':
            append(&result, '\\')
            append(&result, '\\')
        case '\t':
            append(&result, '\\')
            append(&result, 't')
        case '\n':
            append(&result, '\\')
            append(&result, 'n')
        case '"':
            append(&result, '\\')
            append(&result, '"')
        case:
            if value >= 0x20 && value <= 0x7e {
                append(&result, value)
            } else {
                append(&result, '\\')
                append(&result, '0' + (value >> 6 & 7))
                append(&result, '0' + (value >> 3 & 7))
                append(&result, '0' + (value & 7))
            }
        }
    }
    return string(result[:])
}

run :: proc() -> int {
    options, should_run, status := parse_options()
    if !should_run {
        return status
    }

    llvm_context := llvm.ContextCreate()
    defer llvm.ContextDispose(llvm_context)

    module, ok := parse_ir(llvm_context, options.input)
    if !ok {
        return 1
    }
    defer llvm.DisposeModule(module)

    if !verify_module(module) {
        return 1
    }

    // LLVM-C cannot register PassBuilder plugins, so this driver performs the same function-pass traversal.
    if options.wave {
        for function := llvm.GetFirstFunction(module); function != nil; function = llvm.GetNextFunction(function) {
            if bool(llvm.IsDeclaration(function)) {
                continue
            }
            name_length: c.size_t
            name_data := llvm.GetValueName2(function, &name_length)
            name := strings.string_from_ptr(cast(^byte)name_data, int(name_length))
            fmt.eprintf("Bye: %s\n", escaped_name(name))
        }
    }
    return 0
}

main :: proc() {
    status := run()
    if status != 0 {
        os.exit(status)
    }
}
