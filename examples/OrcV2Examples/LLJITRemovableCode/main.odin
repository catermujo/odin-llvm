// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
package main

import "core:c"
import "core:c/libc"
import "core:sync"

import llvm "../../.."

FOO_MODULE :: "  define void @foo() {\n" + "  entry:\n" + "    ret void\n" + "  }\n"

BAR_MODULE :: "  define void @bar() {\n" + "  entry:\n" + "    ret void\n" + "  }\n"

BAZ_MODULE :: "  define void @baz() {\n" + "  entry:\n" + "    ret void\n" + "  }\n"

Lookup_Result :: struct {
    mutex:      sync.Mutex,
    condition:  sync.Cond,
    err:        llvm.ErrorRef,
    address:    llvm.OrcExecutorAddress,
    pair_count: c.size_t,
    completed:  bool,
}

handle_error :: proc(err: llvm.ErrorRef) -> int {
    message := llvm.GetErrorMessage(err)
    _ = libc.fprintf(libc.stderr, "Error: %s\n", message)
    llvm.DisposeErrorMessage(message)
    return 1
}

parse_module :: proc(source: string, name: cstring) -> (llvm.OrcThreadSafeModuleRef, llvm.ErrorRef) {
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
        return nil, err
    }

    thread_safe_ctx := llvm.OrcCreateNewThreadSafeContextFromLLVMContext(ctx)
    thread_safe_module := llvm.OrcCreateNewThreadSafeModule(module, thread_safe_ctx)
    llvm.OrcDisposeThreadSafeContext(thread_safe_ctx)
    return thread_safe_module, nil
}

add_module :: proc(
    jit: llvm.OrcLLJITRef,
    jit_dylib: llvm.OrcJITDylibRef,
    tracker: llvm.OrcResourceTrackerRef,
    source: string,
    name: cstring,
) -> llvm.ErrorRef {
    thread_safe_module, parse_err := parse_module(source, name)
    if parse_err != nil {
        return parse_err
    }

    add_err: llvm.ErrorRef
    if tracker == nil {
        add_err = llvm.OrcLLJITAddLLVMIRModule(jit, jit_dylib, thread_safe_module)
    } else {
        add_err = llvm.OrcLLJITAddLLVMIRModuleWithRT(jit, tracker, thread_safe_module)
    }
    // AddLLVMIRModule consumes thread_safe_module even when it returns an error.
    return add_err
}

lookup_complete :: proc "c" (err: llvm.ErrorRef, pairs: llvm.OrcCSymbolMapPairs, pair_count: c.size_t, ctx: rawptr) {
    result := transmute(^Lookup_Result)ctx
    sync.mutex_lock(&result.mutex)
    result^.err = err
    if err == nil {
        result^.pair_count = pair_count
        if pair_count == 1 {
            result^.address = pairs^.Sym.Address
        }
    }
    result^.completed = true
    sync.mutex_unlock(&result.mutex)
    sync.cond_signal(&result.condition)
}

lookup_symbol :: proc(
    jit: llvm.OrcLLJITRef,
    jit_dylib: llvm.OrcJITDylibRef,
    name: cstring,
) -> (
    llvm.OrcExecutorAddress,
    llvm.ErrorRef,
) {
    search_order := [1]llvm.OrcCJITDylibSearchOrderElement{{JD = jit_dylib, JDLookupFlags = .MatchAllSymbols}}
    symbols := [1]llvm.OrcCLookupSetElement {
        {Name = llvm.OrcLLJITMangleAndIntern(jit, name), LookupFlags = .RequiredSymbol},
    }
    // A lookup may complete on another thread. Keep callback state and the
    // lookup arrays alive until the callback signals completion.
    result := new(Lookup_Result)
    defer free(result)
    llvm.OrcExecutionSessionLookup(
        llvm.OrcLLJITGetExecutionSession(jit),
        .Static,
        raw_data(search_order[:]),
        1,
        raw_data(symbols[:]),
        1,
        lookup_complete,
        rawptr(result),
    )

    sync.mutex_lock(&result.mutex)
    for !result.completed {
        sync.cond_wait(&result.condition, &result.mutex)
    }
    address := result.address
    err := result.err
    pair_count := result.pair_count
    sync.mutex_unlock(&result.mutex)

    if err == nil && pair_count != 1 {
        return 0, llvm.CreateStringError("lookup returned an unexpected result count")
    }
    return address, err
}

print_symbol :: proc(jit: llvm.OrcLLJITRef, jit_dylib: llvm.OrcJITDylibRef, name: cstring) {
    _ = libc.fprintf(libc.stderr, "%s = ", name)
    address, err := lookup_symbol(jit, jit_dylib, name)
    if err != nil {
        message := llvm.GetErrorMessage(err)
        _ = libc.fprintf(libc.stderr, "error: %s\n", message)
        llvm.DisposeErrorMessage(message)
        return
    }
    _ = libc.fprintf(libc.stderr, "0x%llx\n", address)
}

run :: proc() -> (main_result: int) {
    _ = llvm.InitializeNativeTarget()
    _ = llvm.InitializeNativeAsmPrinter()
    defer llvm.Shutdown()

    jit: llvm.OrcLLJITRef
    if err := llvm.OrcCreateLLJIT(&jit, nil); err != nil {
        return handle_error(err)
    }
    defer {
        if jit != nil {
            if err := llvm.OrcDisposeLLJIT(jit); err != nil {
                failure := handle_error(err)
                if main_result == 0 {
                    main_result = failure
                }
            }
        }
    }

    execution_session := llvm.OrcLLJITGetExecutionSession(jit)
    jit_dylib: llvm.OrcJITDylibRef
    if err := llvm.OrcExecutionSessionCreateJITDylib(execution_session, &jit_dylib, "JD"); err != nil {
        return handle_error(err)
    }

    if err := add_module(jit, jit_dylib, nil, FOO_MODULE, "foo"); err != nil {
        return handle_error(err)
    }

    bar_tracker := llvm.OrcJITDylibCreateResourceTracker(jit_dylib)
    defer {
        if bar_tracker != nil {
            llvm.OrcReleaseResourceTracker(bar_tracker)
        }
    }
    if err := add_module(jit, jit_dylib, bar_tracker, BAR_MODULE, "bar"); err != nil {
        return handle_error(err)
    }

    baz_tracker := llvm.OrcJITDylibCreateResourceTracker(jit_dylib)
    defer {
        if baz_tracker != nil {
            llvm.OrcReleaseResourceTracker(baz_tracker)
        }
    }
    if err := add_module(jit, jit_dylib, baz_tracker, BAZ_MODULE, "baz"); err != nil {
        return handle_error(err)
    }

    _ = libc.fprintf(libc.stderr, "Initially:\n")
    print_symbol(jit, jit_dylib, "foo")
    print_symbol(jit, jit_dylib, "bar")
    print_symbol(jit, jit_dylib, "baz")

    llvm.OrcReleaseResourceTracker(baz_tracker)
    baz_tracker = nil

    _ = libc.fprintf(libc.stderr, "After implicitly transferring ownership of baz to JD's default tracker:\n")
    print_symbol(jit, jit_dylib, "foo")
    print_symbol(jit, jit_dylib, "bar")
    print_symbol(jit, jit_dylib, "baz")

    if err := llvm.OrcResourceTrackerRemove(bar_tracker); err != nil {
        return handle_error(err)
    }
    llvm.OrcReleaseResourceTracker(bar_tracker)
    bar_tracker = nil

    _ = libc.fprintf(libc.stderr, "After removing bar (lookup for bar should yield a missing symbol error):\n")
    print_symbol(jit, jit_dylib, "foo")
    print_symbol(jit, jit_dylib, "bar")
    print_symbol(jit, jit_dylib, "baz")

    _ = libc.fprintf(libc.stderr, "After clearing JD (lookup should yield missing symbol errors for all symbols):\n")
    if err := llvm.OrcJITDylibClear(jit_dylib); err != nil {
        return handle_error(err)
    }
    print_symbol(jit, jit_dylib, "foo")
    print_symbol(jit, jit_dylib, "bar")
    print_symbol(jit, jit_dylib, "baz")

    _ = libc.fprintf(libc.stderr, "Removing JD.\n")
    // LLVM-C cannot remove one JITDylib. Disposing LLJIT really removes JD here,
    // but also ends its ExecutionSession.
    if err := llvm.OrcDisposeLLJIT(jit); err != nil {
        jit = nil
        return handle_error(err)
    }
    jit = nil
    _ = libc.fprintf(libc.stderr, "done.\n")
    return 0
}

main :: proc() {
    libc.exit(i32(run()))
}
