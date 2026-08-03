// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
package main

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"

import llvm "../.."

Tutorial_Version :: enum {
    V1,
    V2,
    V3,
}

Options :: struct {
    input:   string,
    version: Tutorial_Version,
}

print_help :: proc() {
    fmt.println("USAGE: IRTransforms [-tut-simplifycfg-version=v1|v2|v3] [input.ll|-]")
}

parse_version :: proc(arg: string) -> (version: Tutorial_Version, matched: bool, valid: bool) {
    value: string
    switch {
    case arg == "-tut-simplifycfg-version" || arg == "--tut-simplifycfg-version":
        return .V3, true, true
    case strings.has_prefix(arg, "-tut-simplifycfg-version="):
        value = arg[len("-tut-simplifycfg-version="):]
    case strings.has_prefix(arg, "--tut-simplifycfg-version="):
        value = arg[len("--tut-simplifycfg-version="):]
    case:
        return .V1, false, false
    }

    switch value {
    case "v1":
        return .V1, true, true
    case "v2":
        return .V2, true, true
    case "v3", "":
        return .V3, true, true
    case:
        return .V1, true, false
    }
}

parse_options :: proc() -> (options: Options, run: bool, status: int) {
    options.input = "-"
    has_input := false

    for arg in os.args[1:] {
        version, matched, valid := parse_version(arg)
        if matched {
            if !valid {
                fmt.eprintf("IRTransforms: invalid tutorial version in `%s'\n", arg)
                return options, false, 1
            }
            options.version = version
            continue
        }

        switch arg {
        case "-h", "--help":
            print_help()
            return options, false, 0
        case:
            if strings.has_prefix(arg, "-") && arg != "-" {
                fmt.eprintf("IRTransforms: unknown option `%s'\n", arg)
                return options, false, 1
            }
            if has_input {
                fmt.eprintf("IRTransforms: unexpected positional argument `%s'\n", arg)
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
            print_llvm_error("IRTransforms", message)
            return nil, false
        }
    } else {
        path, path_error := strings.clone_to_cstring(input, context.temp_allocator)
        if path_error != nil {
            fmt.eprintf("IRTransforms: invalid input path `%s'\n", input)
            return nil, false
        }
        if llvm.CreateMemoryBufferWithContentsOfFile(path, &buffer, &message) != 0 {
            print_llvm_error("IRTransforms", message)
            return nil, false
        }
    }
    if llvm.ParseIRInContext(llvm_context, buffer, &module, &message) != 0 {
        print_llvm_error("IRTransforms", message)
        return nil, false
    }
    return module, true
}

verify_module :: proc(module: llvm.ModuleRef, description: string) -> bool {
    message: cstring
    if llvm.VerifyModule(module, .ReturnStatus, &message) != 0 {
        print_llvm_error(description, message)
        return false
    }
    if message != nil {
        llvm.DisposeMessage(message)
    }
    return true
}

value_name_copy :: proc(value: llvm.ValueRef) -> string {
    name_length: c.size_t
    name_data := llvm.GetValueName2(value, &name_length)
    if name_length == 0 {
        return ""
    }
    name := strings.string_from_ptr(cast(^byte)name_data, int(name_length))
    return strings.clone(name, context.temp_allocator)
}

restore_value_name :: proc(value: llvm.ValueRef, name: string) {
    if len(name) != 0 {
        llvm.SetValueName2(value, strings.unsafe_string_to_cstring(name), c.size_t(len(name)))
    }
}

copy_instruction_metadata :: proc(source, destination: llvm.ValueRef) {
    llvm.InstructionSetDebugLoc(destination, llvm.InstructionGetDebugLoc(source))

    entry_count: c.size_t
    entries := llvm.InstructionGetAllMetadataOtherThanDebugLoc(source, &entry_count)
    defer if entries != nil {
        llvm.DisposeValueMetadataEntries(entries)
    }

    llvm_context := llvm.GetTypeContext(llvm.TypeOf(source))
    for index in 0 ..< int(entry_count) {
        kind := llvm.ValueMetadataEntriesGetKind(entries, u32(index))
        metadata := llvm.ValueMetadataEntriesGetMetadata(entries, u32(index))
        llvm.SetMetadata(destination, kind, llvm.MetadataAsValue(llvm_context, metadata))
    }
}

phi_constant_value :: proc(phi: llvm.ValueRef, values: []llvm.ValueRef) -> (llvm.ValueRef, bool) {
    candidate := values[0]
    for value in values[1:] {
        if value != candidate && value != phi {
            if candidate != phi {
                return nil, false
            }
            candidate = value
        }
    }
    if candidate == phi {
        return llvm.GetPoison(llvm.TypeOf(phi)), true
    }
    return candidate, true
}

remove_predecessor_from_phi :: proc(phi: llvm.ValueRef, predecessor: llvm.BasicBlockRef, builder: llvm.BuilderRef) {
    incoming_count := int(llvm.CountIncoming(phi))
    removed_index := -1
    for index in 0 ..< incoming_count {
        if llvm.GetIncomingBlock(phi, u32(index)) == predecessor {
            removed_index = index
            break
        }
    }
    if removed_index < 0 {
        return
    }

    remaining_count := incoming_count - 1
    if remaining_count == 0 {
        llvm.ReplaceAllUsesWith(phi, llvm.GetPoison(llvm.TypeOf(phi)))
        llvm.InstructionEraseFromParent(phi)
        return
    }

    values := make([dynamic]llvm.ValueRef, 0, remaining_count, context.temp_allocator)
    blocks := make([dynamic]llvm.BasicBlockRef, 0, remaining_count, context.temp_allocator)
    defer delete(values)
    defer delete(blocks)

    for index in 0 ..< remaining_count {
        source_index := index
        if index == removed_index {
            source_index = incoming_count - 1
        }
        append(&values, llvm.GetIncomingValue(phi, u32(source_index)))
        append(&blocks, llvm.GetIncomingBlock(phi, u32(source_index)))
    }

    if replacement, constant := phi_constant_value(phi, values[:]); constant {
        llvm.ReplaceAllUsesWith(phi, replacement)
        llvm.InstructionEraseFromParent(phi)
        return
    }

    // LLVM-C has no PHI incoming-edge removal, so preserve the survivors by rebuilding the PHI.
    name := value_name_copy(phi)
    llvm.PositionBuilderBefore(builder, phi)
    replacement := llvm.BuildPhi(builder, llvm.TypeOf(phi), "")
    llvm.AddIncoming(replacement, &values[0], &blocks[0], u32(remaining_count))
    copy_instruction_metadata(phi, replacement)
    llvm.ReplaceAllUsesWith(phi, replacement)
    llvm.InstructionEraseFromParent(phi)
    restore_value_name(replacement, name)
}

remove_predecessor :: proc(block: llvm.BasicBlockRef, predecessor: llvm.BasicBlockRef, builder: llvm.BuilderRef) {
    phi := llvm.GetFirstInstruction(block)
    for phi != nil && llvm.IsAPHINode(phi) != nil {
        next := llvm.GetNextInstruction(phi)
        remove_predecessor_from_phi(phi, predecessor, builder)
        phi = next
    }
}

eliminate_constant_branches :: proc(function: llvm.ValueRef, builder: llvm.BuilderRef) -> bool {
    changed := false
    for block := llvm.GetFirstBasicBlock(function); block != nil; block = llvm.GetNextBasicBlock(block) {
        branch := llvm.GetBasicBlockTerminator(block)
        if branch == nil || llvm.GetInstructionOpcode(branch) != .Br || !bool(llvm.IsConditional(branch)) {
            continue
        }

        condition := llvm.GetCondition(branch)
        if llvm.IsAConstantInt(condition) == nil {
            continue
        }

        condition_is_true := llvm.ConstIntGetZExtValue(condition) == 1
        taken_index: u32 = 0 if condition_is_true else 1
        removed_index: u32 = 1 if condition_is_true else 0
        taken_successor := llvm.GetSuccessor(branch, taken_index)
        removed_successor := llvm.GetSuccessor(branch, removed_index)
        remove_predecessor(removed_successor, block, builder)

        llvm.PositionBuilderBefore(builder, branch)
        llvm.BuildBr(builder, taken_successor)
        llvm.InstructionEraseFromParent(branch)
        changed = true
    }
    return changed
}

single_predecessor :: proc(function: llvm.ValueRef, target: llvm.BasicBlockRef) -> llvm.BasicBlockRef {
    predecessor: llvm.BasicBlockRef
    for block := llvm.GetFirstBasicBlock(function); block != nil; block = llvm.GetNextBasicBlock(block) {
        terminator := llvm.GetBasicBlockTerminator(block)
        if terminator == nil {
            continue
        }
        for index in 0 ..< llvm.GetNumSuccessors(terminator) {
            if llvm.GetSuccessor(terminator, index) != target {
                continue
            }
            if predecessor != nil {
                return nil
            }
            predecessor = block
        }
    }
    return predecessor
}

has_predecessor :: proc(function: llvm.ValueRef, target: llvm.BasicBlockRef) -> bool {
    for block := llvm.GetFirstBasicBlock(function); block != nil; block = llvm.GetNextBasicBlock(block) {
        terminator := llvm.GetBasicBlockTerminator(block)
        if terminator == nil {
            continue
        }
        for index in 0 ..< llvm.GetNumSuccessors(terminator) {
            if llvm.GetSuccessor(terminator, index) == target {
                return true
            }
        }
    }
    return false
}

move_instruction_before :: proc(instruction: llvm.ValueRef, before: llvm.ValueRef, builder: llvm.BuilderRef) {
    name := value_name_copy(instruction)
    llvm.InstructionRemoveFromParent(instruction)
    llvm.PositionBuilderBefore(builder, before)
    llvm.InsertIntoBuilder(builder, instruction)
    restore_value_name(instruction, name)
}

merge_single_predecessor_blocks :: proc(function: llvm.ValueRef, builder: llvm.BuilderRef) -> bool {
    changed := false
    block := llvm.GetFirstBasicBlock(function)
    for block != nil {
        next_block := llvm.GetNextBasicBlock(block)
        predecessor := single_predecessor(function, block)
        if predecessor == nil || predecessor == block {
            block = next_block
            continue
        }

        predecessor_terminator := llvm.GetBasicBlockTerminator(predecessor)
        if predecessor_terminator == nil ||
           llvm.GetNumSuccessors(predecessor_terminator) != 1 ||
           llvm.GetSuccessor(predecessor_terminator, 0) != block {
            block = next_block
            continue
        }

        llvm.ReplaceAllUsesWith(llvm.BasicBlockAsValue(block), llvm.BasicBlockAsValue(predecessor))
        instruction := llvm.GetFirstInstruction(block)
        for instruction != nil && llvm.IsAPHINode(instruction) != nil {
            next_instruction := llvm.GetNextInstruction(instruction)
            llvm.ReplaceAllUsesWith(instruction, llvm.GetIncomingValue(instruction, 0))
            llvm.InstructionEraseFromParent(instruction)
            instruction = next_instruction
        }

        for instruction != nil {
            next_instruction := llvm.GetNextInstruction(instruction)
            move_instruction_before(instruction, predecessor_terminator, builder)
            instruction = next_instruction
        }

        llvm.InstructionEraseFromParent(predecessor_terminator)
        llvm.DeleteBasicBlock(block)
        changed = true
        block = next_block
    }
    return changed
}

remove_dead_blocks :: proc(function: llvm.ValueRef, builder: llvm.BuilderRef) -> bool {
    changed := false
    entry := llvm.GetEntryBasicBlock(function)
    block := llvm.GetFirstBasicBlock(function)
    for block != nil {
        next_block := llvm.GetNextBasicBlock(block)
        if block == entry || has_predecessor(function, block) {
            block = next_block
            continue
        }

        terminator := llvm.GetBasicBlockTerminator(block)
        if terminator != nil {
            for index in 0 ..< llvm.GetNumSuccessors(terminator) {
                remove_predecessor(llvm.GetSuccessor(terminator, index), block, builder)
            }
        }

        for instruction := llvm.GetLastInstruction(block);
            instruction != nil;
            instruction = llvm.GetLastInstruction(block) {
            if llvm.GetFirstUse(instruction) != nil {
                llvm.ReplaceAllUsesWith(instruction, llvm.GetPoison(llvm.TypeOf(instruction)))
            }
            llvm.InstructionEraseFromParent(instruction)
        }
        llvm.DeleteBasicBlock(block)
        changed = true
        block = next_block
    }
    return changed
}

simplify_function :: proc(function: llvm.ValueRef, version: Tutorial_Version, builder: llvm.BuilderRef) -> bool {
    // LLVM-C exposes no pass-plugin registration or DominatorTree updates; all versions share observable rewrites here.
    _ = version
    changed := eliminate_constant_branches(function, builder)
    changed = merge_single_predecessor_blocks(function, builder) || changed
    changed = remove_dead_blocks(function, builder) || changed
    return changed
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

    if !verify_module(module, "IRTransforms: input module is invalid") {
        return 1
    }

    builder := llvm.CreateBuilderInContext(llvm_context)
    defer llvm.DisposeBuilder(builder)

    for function := llvm.GetFirstFunction(module); function != nil; function = llvm.GetNextFunction(function) {
        if !bool(llvm.IsDeclaration(function)) {
            simplify_function(function, options.version, builder)
        }
    }

    if !verify_module(module, "IRTransforms: transformed module is invalid") {
        return 1
    }

    module_text := llvm.PrintModuleToString(module)
    fmt.print(string(module_text))
    llvm.DisposeMessage(module_text)
    return 0
}

main :: proc() {
    status := run()
    if status != 0 {
        os.exit(status)
    }
}
