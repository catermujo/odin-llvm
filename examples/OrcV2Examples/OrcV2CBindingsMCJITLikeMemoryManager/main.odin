// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
package main

import "base:runtime"
import "core:c"
import "core:c/libc"

import llvm "../../.."
import orc_support "../support"

Section_Kind :: enum {
    Code,
    Read_Only_Data,
    Writable_Data,
}

Section :: struct {
    next:         ^Section,
    mapping_base: rawptr,
    mapping_size: uintptr,
    pointer:      rawptr,
    size:         uintptr,
    kind:         Section_Kind,
}

Memory_Context :: struct {
    sections: ^Section,
}

set_memory_error :: proc(error_message: ^cstring, message: cstring) {
    if error_message == nil {
        return
    }

    length := libc.strlen(message) + 1
    copy := libc.malloc(length)
    if copy != nil {
        _ = libc.memcpy(copy, rawptr(message), length)
        error_message^ = cstring(copy)
    }
}

add_section :: proc(state: ^Memory_Context, size: uintptr, alignment: u32, kind: Section_Kind) -> rawptr {
    if state == nil {
        return nil
    }

    page_size := memory_page_size()
    requested_alignment := uintptr(alignment)
    if requested_alignment == 0 {
        requested_alignment = 1
    }
    if page_size == 0 || page_size & (page_size - 1) != 0 || requested_alignment & (requested_alignment - 1) != 0 {
        return nil
    }

    mapping_alignment := max(page_size, requested_alignment)
    allocation_size := max(size, uintptr(1))
    alignment_padding := mapping_alignment - page_size
    if allocation_size > ~uintptr(0) - alignment_padding {
        return nil
    }
    required_size := allocation_size + alignment_padding
    page_padding := page_size - 1
    if required_size > ~uintptr(0) - page_padding {
        return nil
    }
    mapping_size := (required_size + page_padding) & ~page_padding

    section := (^Section)(libc.calloc(1, c.size_t(size_of(Section))))
    if section == nil {
        return nil
    }

    mapping_base := allocate_section_memory(mapping_size)
    if mapping_base == nil {
        libc.free(section)
        return nil
    }

    pointer := rawptr((uintptr(mapping_base) + mapping_alignment - 1) & ~(mapping_alignment - 1))
    section^ = {
        next         = state.sections,
        mapping_base = mapping_base,
        mapping_size = mapping_size,
        pointer      = pointer,
        size         = size,
        kind         = kind,
    }
    state.sections = section
    return pointer
}

memory_create_context :: proc "c" (_: rawptr) -> rawptr {
    state := (^Memory_Context)(libc.calloc(1, c.size_t(size_of(Memory_Context))))
    return rawptr(state)
}

memory_notify_terminating :: proc "c" (_: rawptr) {  }

memory_allocate_code :: proc "c" (ctx: rawptr, size: c.uintptr_t, alignment: u32, _: u32, name: cstring) -> ^u8 {
    context = runtime.default_context()
    pointer := add_section((^Memory_Context)(ctx), uintptr(size), alignment, .Code)
    if pointer == nil {
        _ = libc.fprintf(libc.stderr, "Could not allocate code section \"%s\".\n", name)
        return nil
    }
    _ = libc.printf("Allocated code section \"%s\"\n", name)
    return (^u8)(pointer)
}

memory_allocate_data :: proc "c" (
    ctx: rawptr,
    size: c.uintptr_t,
    alignment: u32,
    _: u32,
    name: cstring,
    is_read_only: llvm.Bool,
) -> ^u8 {
    context = runtime.default_context()
    kind: Section_Kind = .Read_Only_Data if is_read_only != 0 else .Writable_Data
    pointer := add_section((^Memory_Context)(ctx), uintptr(size), alignment, kind)
    if pointer == nil {
        _ = libc.fprintf(libc.stderr, "Could not allocate data section \"%s\".\n", name)
        return nil
    }
    _ = libc.printf("Allocated data section \"%s\"\n", name)
    return (^u8)(pointer)
}

memory_finalize :: proc "c" (ctx: rawptr, error_message: ^cstring) -> llvm.Bool {
    context = runtime.default_context()
    if error_message != nil {
        error_message^ = nil
    }

    state := (^Memory_Context)(ctx)
    if state == nil {
        set_memory_error(error_message, "Invalid JIT memory context")
        return 1
    }

    _ = libc.printf("Marking code sections as executable ..\n")
    for section := state.sections; section != nil; section = section.next {
        if !protect_section_memory(section.mapping_base, section.mapping_size, section.kind) {
            set_memory_error(error_message, "Could not apply JIT section memory permissions")
            return 1
        }
        if section.kind == .Code && !flush_instruction_cache(section.pointer, section.size) {
            set_memory_error(error_message, "Could not flush JIT code instruction cache")
            return 1
        }
    }
    return 0
}

memory_destroy :: proc "c" (ctx: rawptr) {
    context = runtime.default_context()
    state := (^Memory_Context)(ctx)
    if state == nil {
        return
    }

    _ = libc.printf("Releasing section memory ..\n")
    section := state.sections
    for section != nil {
        next := section.next
        if section.mapping_base != nil {
            if !release_section_memory(section.mapping_base, section.mapping_size) {
                _ = libc.fprintf(libc.stderr, "Could not release section memory.\n")
            }
            section.mapping_base = nil
        }
        libc.free(section)
        section = next
    }
    state.sections = nil
    libc.free(state)
}

object_linking_layer_creator :: proc "c" (
    _: rawptr,
    execution_session: llvm.OrcExecutionSessionRef,
    _: cstring,
) -> llvm.OrcObjectLayerRef {
    return llvm.OrcCreateRTDyldObjectLinkingLayerWithMCJITMemoryManagerLikeCallbacks(
        execution_session,
        nil,
        memory_create_context,
        memory_notify_terminating,
        memory_allocate_code,
        memory_allocate_data,
        memory_finalize,
        memory_destroy,
    )
}

run :: proc() -> (main_result: int) {
    llvm.ParseCommandLineOptions(i32(len(runtime.args__)), raw_data(runtime.args__), "")
    _ = llvm.InitializeNativeTarget()
    _ = llvm.InitializeNativeAsmPrinter()
    defer llvm.Shutdown()

    builder := llvm.OrcCreateLLJITBuilder()
    llvm.OrcLLJITBuilderSetObjectLinkingLayerCreator(builder, object_linking_layer_creator, nil)

    jit: llvm.OrcLLJITRef
    if err := llvm.OrcCreateLLJIT(&jit, builder); err != nil {
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
