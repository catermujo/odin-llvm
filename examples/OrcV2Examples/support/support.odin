// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
package support

import "core:c"
import "core:c/libc"

import llvm "../../.."

handle_error :: proc(err: llvm.ErrorRef) -> int {
    message := llvm.GetErrorMessage(err)
    _ = libc.fprintf(libc.stderr, "Error: %s\n", message)
    llvm.DisposeErrorMessage(message)
    return 1
}

create_demo_module :: proc(ctx: llvm.ContextRef) -> llvm.ModuleRef {
    module := llvm.ModuleCreateWithNameInContext("demo", ctx)
    int32_type := llvm.Int32TypeInContext(ctx)
    parameter_types := [2]llvm.TypeRef{int32_type, int32_type}
    sum_type := llvm.FunctionType(int32_type, raw_data(parameter_types[:]), 2, 0)
    sum_function := llvm.AddFunction(module, "sum", sum_type)
    entry := llvm.AppendBasicBlockInContext(ctx, sum_function, "entry")
    builder := llvm.CreateBuilderInContext(ctx)
    llvm.PositionBuilderAtEnd(builder, entry)
    sum_arg0 := llvm.GetParam(sum_function, 0)
    sum_arg1 := llvm.GetParam(sum_function, 1)
    result := llvm.BuildAdd(builder, sum_arg0, sum_arg1, "result")
    _ = llvm.BuildRet(builder, result)
    llvm.DisposeBuilder(builder)
    return module
}

create_demo_thread_safe_module :: proc() -> llvm.OrcThreadSafeModuleRef {
    ctx := llvm.ContextCreate()
    module := create_demo_module(ctx)
    thread_safe_ctx := llvm.OrcCreateNewThreadSafeContextFromLLVMContext(ctx)
    thread_safe_module := llvm.OrcCreateNewThreadSafeModule(module, thread_safe_ctx)
    llvm.OrcDisposeThreadSafeContext(thread_safe_ctx)
    return thread_safe_module
}

parse_example_module :: proc(
    source: string,
    name: cstring,
    thread_safe_module: ^llvm.OrcThreadSafeModuleRef,
) -> llvm.ErrorRef {
    ctx := llvm.ContextCreate()
    module: llvm.ModuleRef
    error_message: cstring
    buffer := llvm.CreateMemoryBufferWithMemoryRange(cstring(raw_data(source)), c.size_t(len(source)), name, 0)
    failed := llvm.ParseIRInContext2(ctx, buffer, &module, &error_message)
    llvm.DisposeMemoryBuffer(buffer)

    if failed != 0 {
        err := llvm.CreateStringError(error_message)
        llvm.DisposeMessage(error_message)
        llvm.ContextDispose(ctx)
        return err
    }

    thread_safe_ctx := llvm.OrcCreateNewThreadSafeContextFromLLVMContext(ctx)
    thread_safe_module^ = llvm.OrcCreateNewThreadSafeModule(module, thread_safe_ctx)
    llvm.OrcDisposeThreadSafeContext(thread_safe_ctx)
    return nil
}
