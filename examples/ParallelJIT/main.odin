package main

import "core:c"
import "core:c/libc"
import "core:fmt"
import "core:sync"
import "core:thread"

import llvm "../.."

THREAD_COUNT :: 3

Start_Gate :: struct {
    mutex:     sync.Mutex,
    condition: sync.Cond,
    ready:     int,
    released:  bool,
}

Thread_Params :: struct {
    gate:     ^Start_Gate,
    engine:   llvm.ExecutionEngineRef,
    function: llvm.ValueRef,
    arg_type: llvm.TypeRef,
    value:    i32,
    result:   u64,
    success:  bool,
}

create_add1 :: proc(module: llvm.ModuleRef, ctx: llvm.ContextRef, builder: llvm.BuilderRef) -> llvm.ValueRef {
    i32_type := llvm.Int32TypeInContext(ctx)
    parameters := [1]llvm.TypeRef{i32_type}
    function_type := llvm.FunctionType(i32_type, &parameters[0], 1, 0)
    function := llvm.AddFunction(module, "add1", function_type)
    argument := llvm.GetParam(function, 0)
    llvm.SetValueName2(argument, "AnArg", 5)

    entry := llvm.AppendBasicBlockInContext(ctx, function, "EntryBlock")
    llvm.PositionBuilderAtEnd(builder, entry)
    one := llvm.ConstInt(i32_type, 1, 0)
    result := llvm.BuildAdd(builder, one, argument, "addresult")
    _ = llvm.BuildRet(builder, result)
    return function
}

create_fib :: proc(module: llvm.ModuleRef, ctx: llvm.ContextRef, builder: llvm.BuilderRef) -> llvm.ValueRef {
    i32_type := llvm.Int32TypeInContext(ctx)
    parameters := [1]llvm.TypeRef{i32_type}
    function_type := llvm.FunctionType(i32_type, &parameters[0], 1, 0)
    function := llvm.AddFunction(module, "fib", function_type)
    argument := llvm.GetParam(function, 0)
    llvm.SetValueName2(argument, "AnArg", 5)
    one := llvm.ConstInt(i32_type, 1, 0)
    two := llvm.ConstInt(i32_type, 2, 0)

    entry := llvm.AppendBasicBlockInContext(ctx, function, "EntryBlock")
    return_block := llvm.AppendBasicBlockInContext(ctx, function, "return")
    recurse_block := llvm.AppendBasicBlockInContext(ctx, function, "recurse")

    llvm.PositionBuilderAtEnd(builder, entry)
    condition := llvm.BuildICmp(builder, .SLE, argument, two, "cond")
    _ = llvm.BuildCondBr(builder, condition, return_block, recurse_block)

    llvm.PositionBuilderAtEnd(builder, return_block)
    _ = llvm.BuildRet(builder, one)

    llvm.PositionBuilderAtEnd(builder, recurse_block)
    arg_x1 := llvm.BuildSub(builder, argument, one, "arg")
    args_x1 := [1]llvm.ValueRef{arg_x1}
    fib_x1 := llvm.BuildCall2(builder, function_type, function, &args_x1[0], 1, "fibx1")
    arg_x2 := llvm.BuildSub(builder, argument, two, "arg")
    args_x2 := [1]llvm.ValueRef{arg_x2}
    fib_x2 := llvm.BuildCall2(builder, function_type, function, &args_x2[0], 1, "fibx2")
    sum := llvm.BuildAdd(builder, fib_x1, fib_x2, "addresult")
    _ = llvm.BuildRet(builder, sum)
    return function
}

verify_module :: proc(module: llvm.ModuleRef) -> bool {
    message: cstring
    failed := bool(llvm.VerifyModule(module, .ReturnStatus, &message))
    if message != nil {
        defer llvm.DisposeMessage(message)
    }
    if failed {
        fmt.eprintln("Error: module verification failed.")
        if message != nil {
            fmt.eprintln(message)
        }
        return false
    }
    return true
}

wait_for_release :: proc(gate: ^Start_Gate) {
    sync.mutex_lock(&gate.mutex)
    gate.ready += 1
    sync.cond_broadcast(&gate.condition)
    for !gate.released {
        sync.cond_wait(&gate.condition, &gate.mutex)
    }
    sync.mutex_unlock(&gate.mutex)
}

call_function :: proc(thread_value: ^thread.Thread) {
    params := (^Thread_Params)(thread_value.data)
    argument := llvm.CreateGenericValueOfInt(params.arg_type, u64(params.value), 1)
    if argument == nil {
        return
    }
    defer llvm.DisposeGenericValue(argument)

    wait_for_release(params.gate)
    arguments := [1]llvm.GenericValueRef{argument}
    result := llvm.RunFunction(params.engine, params.function, 1, &arguments[0])
    if result == nil {
        return
    }
    defer llvm.DisposeGenericValue(result)
    params.result = llvm.GenericValueToInt(result, 0)
    params.success = true
}

release_threads :: proc(gate: ^Start_Gate, ready_count: int) {
    sync.mutex_lock(&gate.mutex)
    for gate.ready < ready_count {
        sync.cond_wait(&gate.condition, &gate.mutex)
    }
    gate.released = true
    sync.cond_broadcast(&gate.condition)
    sync.mutex_unlock(&gate.mutex)
}

cleanup_threads :: proc(gate: ^Start_Gate, threads: []^thread.Thread) {
    release_threads(gate, 0)
    for worker in threads {
        if worker != nil {
            thread.destroy(worker)
        }
    }
}

run :: proc() -> int {
    if bool(llvm.InitializeNativeTarget()) || bool(llvm.InitializeNativeAsmPrinter()) {
        fmt.eprintln("Error: native LLVM target initialization failed.")
        return 1
    }
    if !bool(llvm.IsMultithreaded()) {
        fmt.eprintln("Error: LLVM was built without thread support.")
        return 1
    }
    llvm.LinkInMCJIT()

    ctx := llvm.ContextCreate()
    defer llvm.ContextDispose(ctx)
    module := llvm.ModuleCreateWithNameInContext("test", ctx)
    builder := llvm.CreateBuilderInContext(ctx)
    add1_function := create_add1(module, ctx, builder)
    fib_function := create_fib(module, ctx, builder)
    llvm.DisposeBuilder(builder)
    if !verify_module(module) {
        llvm.DisposeModule(module)
        return 1
    }

    options: llvm.MCJITCompilerOptions
    llvm.InitializeMCJITCompilerOptions(&options, c.size_t(size_of(options)))
    engine: llvm.ExecutionEngineRef
    error_message: cstring
    failed := bool(
        llvm.CreateMCJITCompilerForModule(&engine, module, &options, c.size_t(size_of(options)), &error_message),
    )
    if failed {
        fmt.eprint("Error: execution engine creation failed")
        if error_message != nil {
            fmt.eprintfln(": %s", error_message)
            llvm.DisposeMessage(error_message)
        } else {
            fmt.eprintln(".")
        }
        return 1
    }
    defer llvm.DisposeExecutionEngine(engine)

    gate: Start_Gate
    i32_type := llvm.Int32TypeInContext(ctx)
    params := [THREAD_COUNT]Thread_Params {
        {gate = &gate, engine = engine, function = add1_function, arg_type = i32_type, value = 1000},
        {gate = &gate, engine = engine, function = fib_function, arg_type = i32_type, value = 39},
        {gate = &gate, engine = engine, function = fib_function, arg_type = i32_type, value = 42},
    }
    threads: [THREAD_COUNT]^thread.Thread
    defer cleanup_threads(&gate, threads[:])
    for i in 0 ..< THREAD_COUNT {
        threads[i] = thread.create(call_function)
        if threads[i] == nil {
            fmt.eprintln("Error: could not create thread.")
            return 1
        }
        threads[i].data = &params[i]
        thread.start(threads[i])
    }

    release_threads(&gate, THREAD_COUNT)
    thread.join_multiple(..threads[:])

    for param in params {
        if !param.success {
            fmt.eprintln("Error: JIT call failed.")
            return 1
        }
    }
    fmt.printfln("Add1 returned %d", params[0].result)
    fmt.printfln("Fib1 returned %d", params[1].result)
    fmt.printfln("Fib2 returned %d", params[2].result)
    return 0
}

main :: proc() {
    libc.exit(i32(run()))
}
