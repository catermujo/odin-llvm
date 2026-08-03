// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
package main

import "core:c/libc"
import "core:fmt"
import "core:os"
import "core:strings"

import llvm "../.."

create_fib_function :: proc(module: llvm.ModuleRef, llvm_context: llvm.ContextRef) -> llvm.ValueRef {
    int_type := llvm.Int32TypeInContext(llvm_context)
    parameter_types := [1]llvm.TypeRef{int_type}
    fib_type := llvm.FunctionType(int_type, &parameter_types[0], 1, 0)
    fib := llvm.AddFunction(module, "fib", fib_type)

    entry_block := llvm.AppendBasicBlockInContext(llvm_context, fib, "EntryBlock")
    return_block := llvm.AppendBasicBlockInContext(llvm_context, fib, "return")
    recurse_block := llvm.AppendBasicBlockInContext(llvm_context, fib, "recurse")

    one := llvm.ConstInt(int_type, 1, 0)
    two := llvm.ConstInt(int_type, 2, 0)
    argument := llvm.GetParam(fib, 0)
    llvm.SetValueName2(argument, "AnArg", 5)

    builder := llvm.CreateBuilderInContext(llvm_context)
    defer llvm.DisposeBuilder(builder)

    llvm.PositionBuilderAtEnd(builder, entry_block)
    condition := llvm.BuildICmp(builder, .SLE, argument, two, "cond")
    llvm.BuildCondBr(builder, condition, return_block, recurse_block)

    llvm.PositionBuilderAtEnd(builder, return_block)
    llvm.BuildRet(builder, one)

    llvm.PositionBuilderAtEnd(builder, recurse_block)
    call_arguments: [1]llvm.ValueRef
    call_arguments[0] = llvm.BuildSub(builder, argument, one, "arg")
    fib_x1 := llvm.BuildCall2(builder, fib_type, fib, &call_arguments[0], 1, "fibx1")
    llvm.SetTailCall(fib_x1, 1)

    call_arguments[0] = llvm.BuildSub(builder, argument, two, "arg")
    fib_x2 := llvm.BuildCall2(builder, fib_type, fib, &call_arguments[0], 1, "fibx2")
    llvm.SetTailCall(fib_x2, 1)

    sum := llvm.BuildAdd(builder, fib_x1, fib_x2, "addresult")
    llvm.BuildRet(builder, sum)
    return fib
}

run :: proc() -> int {
    n: i32 = 24
    if len(os.args) > 1 {
        argument, _ := strings.clone_to_cstring(os.args[1], context.temp_allocator)
        n = libc.atoi(argument)
    }

    llvm.LinkInMCJIT()
    if llvm.InitializeNativeTarget() != 0 || llvm.InitializeNativeAsmPrinter() != 0 {
        fmt.eprintln("native LLVM target unavailable")
        return 1
    }

    llvm_context := llvm.ContextCreate()
    defer llvm.ContextDispose(llvm_context)

    module := llvm.ModuleCreateWithNameInContext("test", llvm_context)
    fib := create_fib_function(module, llvm_context)

    execution_engine: llvm.ExecutionEngineRef
    error_message: cstring
    if llvm.CreateExecutionEngineForModule(&execution_engine, module, &error_message) != 0 {
        fmt.eprintf("%s: Failed to construct ExecutionEngine: %s\n", os.args[0], string(error_message))
        llvm.DisposeMessage(error_message)
        return 1
    }
    defer llvm.DisposeExecutionEngine(execution_engine)

    fmt.eprint("verifying... ")
    verify_message: cstring
    if llvm.VerifyModule(module, .PrintMessage, &verify_message) != 0 {
        llvm.DisposeMessage(verify_message)
        fmt.eprintf("%s: Error constructing function!\n", os.args[0])
        return 1
    }
    llvm.DisposeMessage(verify_message)

    fmt.eprintln("OK")
    fmt.eprint("We just constructed this LLVM module:\n\n---------\n")
    module_text := llvm.PrintModuleToString(module)
    fmt.eprint(string(module_text))
    llvm.DisposeMessage(module_text)
    fmt.eprintf("---------\nstarting fibonacci(%d) with JIT...\n", n)

    argument := llvm.CreateGenericValueOfInt(llvm.Int32TypeInContext(llvm_context), u64(n), 0)
    defer llvm.DisposeGenericValue(argument)
    arguments := [1]llvm.GenericValueRef{argument}
    result := llvm.RunFunction(execution_engine, fib, 1, &arguments[0])
    defer llvm.DisposeGenericValue(result)

    fmt.printf("Result: %d\n", i64(llvm.GenericValueToInt(result, 1)))
    return 0
}

main :: proc() {
    os.exit(run())
}
