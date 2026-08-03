// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
package main

import "core:fmt"
import "core:os"

import llvm "../.."

run :: proc() -> int {
    llvm.LinkInMCJIT()
    if llvm.InitializeNativeTarget() != 0 || llvm.InitializeNativeAsmPrinter() != 0 {
        fmt.eprintln("native LLVM target unavailable")
        return 1
    }

    llvm_context := llvm.ContextCreate()
    module := llvm.ModuleCreateWithNameInContext("test", llvm_context)
    int_type := llvm.Int32TypeInContext(llvm_context)

    add1_parameter_types := [1]llvm.TypeRef{int_type}
    add1_type := llvm.FunctionType(int_type, &add1_parameter_types[0], 1, 0)
    add1 := llvm.AddFunction(module, "add1", add1_type)
    add1_block := llvm.AppendBasicBlockInContext(llvm_context, add1, "EntryBlock")

    builder := llvm.CreateBuilderInContext(llvm_context)
    llvm.PositionBuilderAtEnd(builder, add1_block)
    one := llvm.ConstInt(int_type, 1, 0)
    argument := llvm.GetParam(add1, 0)
    llvm.SetValueName2(argument, "AnArg", 5)
    add := llvm.BuildAdd(builder, one, argument, "")
    llvm.BuildRet(builder, add)

    foo_type := llvm.FunctionType(int_type, nil, 0, 0)
    foo := llvm.AddFunction(module, "foo", foo_type)
    foo_block := llvm.AppendBasicBlockInContext(llvm_context, foo, "EntryBlock")
    llvm.PositionBuilderAtEnd(builder, foo_block)
    ten := llvm.ConstInt(int_type, 10, 0)
    call_arguments := [1]llvm.ValueRef{ten}
    add1_result := llvm.BuildCall2(builder, add1_type, add1, &call_arguments[0], 1, "")
    llvm.SetTailCall(add1_result, 1)
    llvm.BuildRet(builder, add1_result)
    llvm.DisposeBuilder(builder)

    execution_engine: llvm.ExecutionEngineRef
    error_message: cstring
    if llvm.CreateExecutionEngineForModule(&execution_engine, module, &error_message) != 0 {
        fmt.eprintf("%s: Failed to construct ExecutionEngine: %s\n", os.args[0], string(error_message))
        llvm.DisposeMessage(error_message)
        llvm.ContextDispose(llvm_context)
        llvm.Shutdown()
        return 1
    }

    fmt.print("We just constructed this LLVM module:\n\n")
    module_text := llvm.PrintModuleToString(module)
    fmt.print(string(module_text))
    llvm.DisposeMessage(module_text)
    fmt.print("\n\nRunning foo: ")
    _ = os.flush(os.stdout)

    result := llvm.RunFunction(execution_engine, foo, 0, nil)
    fmt.printf("Result: %d\n", i64(llvm.GenericValueToInt(result, 1)))
    llvm.DisposeGenericValue(result)

    llvm.DisposeExecutionEngine(execution_engine)
    llvm.ContextDispose(llvm_context)
    llvm.Shutdown()
    return 0
}

main :: proc() {
    os.exit(run())
}
