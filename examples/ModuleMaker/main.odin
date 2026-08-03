// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
package main

import "core:fmt"
import "core:os"

import llvm "../.."

run :: proc() -> int {
    llvm_context := llvm.ContextCreate()
    defer llvm.ContextDispose(llvm_context)

    module := llvm.ModuleCreateWithNameInContext("test", llvm_context)
    defer llvm.DisposeModule(module)

    int_type := llvm.Int32TypeInContext(llvm_context)
    main_type := llvm.FunctionType(int_type, nil, 0, 0)
    main_function := llvm.AddFunction(module, "main", main_type)
    entry_block := llvm.AppendBasicBlockInContext(llvm_context, main_function, "EntryBlock")

    builder := llvm.CreateBuilderInContext(llvm_context)
    defer llvm.DisposeBuilder(builder)
    llvm.PositionBuilderAtEnd(builder, entry_block)

    two := llvm.ConstInt(int_type, 2, 0)
    three := llvm.ConstInt(int_type, 3, 0)

    // C IRBuilder folds a direct 2 + 3. Seed an instruction, then replace its
    // operands so emitted bitcode retains canonical add instruction.
    scratch := llvm.BuildAlloca(builder, int_type, "")
    scratch_value := llvm.BuildLoad2(builder, int_type, scratch, "")
    add := llvm.BuildAdd(builder, scratch_value, scratch_value, "addresult")
    llvm.SetOperand(add, 0, two)
    llvm.SetOperand(add, 1, three)
    llvm.InstructionEraseFromParent(scratch_value)
    llvm.InstructionEraseFromParent(scratch)

    llvm.BuildRet(builder, add)
    // LLVM treats path "-" as stdout and switches it to binary mode on Windows.
    if llvm.WriteBitcodeToFile(module, "-") != 0 {
        fmt.eprintln("Could not write bitcode to stdout")
        return 1
    }
    return 0
}

main :: proc() {
    os.exit(run())
}
