// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
package main

import "base:runtime"
import "core:c"
import "core:c/libc"
import "core:sync"

import llvm "../../.."

FOO_MODULE :: "  define i32 @foo_body() {\n" + "  entry:\n" + "    ret i32 1\n" + "  }\n"

BAR_MODULE :: "  define i32 @bar_body() {\n" + "  entry:\n" + "    ret i32 2\n" + "  }\n"

MAIN_MODULE ::
    "  define i32 @entry(i32 %argc) {\n" +
    "  entry:\n" +
    "    %and = and i32 %argc, 1\n" +
    "    %tobool = icmp eq i32 %and, 0\n" +
    "    br i1 %tobool, label %if.end, label %if.then\n" +
    "\n" +
    "  if.then:\n" +
    "    %call = tail call i32 @foo()\n" +
    "    br label %return\n" +
    "\n" +
    "  if.end:\n" +
    "    %call1 = tail call i32 @bar()\n" +
    "    br label %return\n" +
    "\n" +
    "  return:\n" +
    "    %retval.0 = phi i32 [ %call, %if.then ], [ %call1, %if.end ]\n" +
    "    ret i32 %retval.0\n" +
    "  }\n" +
    "\n" +
    "  declare i32 @foo()\n" +
    "  declare i32 @bar()\n"

Compilation_State :: struct {
    mutex:      sync.Mutex,
    main_count: int,
    foo_count:  int,
    bar_count:  int,
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
    source: string,
    name: cstring,
) -> llvm.ErrorRef {
    thread_safe_module, parse_err := parse_module(source, name)
    if parse_err != nil {
        return parse_err
    }
    if add_err := llvm.OrcLLJITAddLLVMIRModule(jit, jit_dylib, thread_safe_module); add_err != nil {
        return add_err
    }
    return nil
}

print_module :: proc "c" (ctx: rawptr, module: llvm.ModuleRef) -> llvm.ErrorRef {
    context = runtime.default_context()
    state := transmute(^Compilation_State)ctx
    sync.mutex_lock(&state.mutex)
    if llvm.GetNamedFunction(module, "entry") != nil {
        state.main_count += 1
    }
    if llvm.GetNamedFunction(module, "foo_body") != nil {
        state.foo_count += 1
    }
    if llvm.GetNamedFunction(module, "bar_body") != nil {
        state.bar_count += 1
    }
    sync.mutex_unlock(&state.mutex)

    module_text := llvm.PrintModuleToString(module)
    _ = libc.fprintf(libc.stderr, "---Compiling---\n%s", module_text)
    llvm.DisposeMessage(module_text)
    return nil
}

print_compile_transform :: proc "c" (
    ctx: rawptr,
    module_in_out: ^llvm.OrcThreadSafeModuleRef,
    _: llvm.OrcMaterializationResponsibilityRef,
) -> llvm.ErrorRef {
    return llvm.OrcThreadSafeModuleWithModuleDo(module_in_out^, print_module, ctx)
}

compilation_counts :: proc(state: ^Compilation_State) -> (main_count, foo_count, bar_count: int) {
    sync.mutex_lock(&state.mutex)
    defer sync.mutex_unlock(&state.mutex)
    return state.main_count, state.foo_count, state.bar_count
}

run :: proc() -> (main_result: int) {
    _ = llvm.InitializeNativeTarget()
    _ = llvm.InitializeNativeAsmPrinter()
    llvm.ParseCommandLineOptions(i32(len(runtime.args__)), raw_data(runtime.args__), "LLJITWithLazyReexports")
    defer llvm.Shutdown()

    jit: llvm.OrcLLJITRef
    if err := llvm.OrcCreateLLJIT(&jit, nil); err != nil {
        return handle_error(err)
    }
    defer {
        if err := llvm.OrcDisposeLLJIT(jit); err != nil {
            failure := handle_error(err)
            if main_result == 0 {
                main_result = failure
            }
        }
    }

    compilation_state: Compilation_State
    llvm.OrcIRTransformLayerSetTransform(
        llvm.OrcLLJITGetIRTransformLayer(jit),
        print_compile_transform,
        rawptr(&compilation_state),
    )

    target_triple := llvm.OrcLLJITGetTripleString(jit)
    indirect_stubs_manager := llvm.OrcCreateLocalIndirectStubsManager(target_triple)
    if indirect_stubs_manager == nil {
        _ = libc.fprintf(libc.stderr, "Error: Could not create stubs manager for %s\n", target_triple)
        return 1
    }
    defer llvm.OrcDisposeIndirectStubsManager(indirect_stubs_manager)

    lazy_call_through_manager: llvm.OrcLazyCallThroughManagerRef
    execution_session := llvm.OrcLLJITGetExecutionSession(jit)
    if err := llvm.OrcCreateLocalLazyCallThroughManager(
        target_triple,
        execution_session,
        0,
        &lazy_call_through_manager,
    ); err != nil {
        return handle_error(err)
    }
    defer llvm.OrcDisposeLazyCallThroughManager(lazy_call_through_manager)

    main_jit_dylib := llvm.OrcLLJITGetMainJITDylib(jit)
    if err := add_module(jit, main_jit_dylib, FOO_MODULE, "foo-mod"); err != nil {
        return handle_error(err)
    }
    if err := add_module(jit, main_jit_dylib, BAR_MODULE, "bar-mod"); err != nil {
        return handle_error(err)
    }
    if err := add_module(jit, main_jit_dylib, MAIN_MODULE, "main-mod"); err != nil {
        return handle_error(err)
    }

    callable_flags: llvm.JITSymbolFlags = {
        Generic = {.Exported, .Callable},
    }
    reexports := [2]llvm.OrcCSymbolAliasMapPair {
        {
            Name = llvm.OrcLLJITMangleAndIntern(jit, "foo"),
            Entry = {Name = llvm.OrcLLJITMangleAndIntern(jit, "foo_body"), Flags = callable_flags},
        },
        {
            Name = llvm.OrcLLJITMangleAndIntern(jit, "bar"),
            Entry = {Name = llvm.OrcLLJITMangleAndIntern(jit, "bar_body"), Flags = callable_flags},
        },
    }
    lazy_reexports := llvm.OrcLazyReexports(
        lazy_call_through_manager,
        indirect_stubs_manager,
        main_jit_dylib,
        raw_data(reexports[:]),
        2,
    )
    if err := llvm.OrcJITDylibDefine(main_jit_dylib, lazy_reexports); err != nil {
        llvm.OrcDisposeMaterializationUnit(lazy_reexports)
        return handle_error(err)
    }

    main_count, foo_count, bar_count := compilation_counts(&compilation_state)
    if main_count != 0 || foo_count != 0 || bar_count != 0 {
        _ = libc.fprintf(
            libc.stderr,
            "Error: modules compiled before lookup: main=%i foo=%i bar=%i\n",
            main_count,
            foo_count,
            bar_count,
        )
        return 1
    }

    _ = libc.fprintf(libc.stderr, "---Session state---\n")
    // LLVM-C has no ExecutionSession::dump. Keep delimiter, but do not invent
    // state or force symbol lookups that would destroy lazy behavior.
    _ = libc.fprintf(libc.stderr, "\n")

    entry_address: llvm.OrcExecutorAddress
    if err := llvm.OrcLLJITLookup(jit, &entry_address, "entry"); err != nil {
        return handle_error(err)
    }
    main_count, foo_count, bar_count = compilation_counts(&compilation_state)
    if main_count != 1 || foo_count != 0 || bar_count != 0 {
        _ = libc.fprintf(
            libc.stderr,
            "Error: entry lookup compiled unexpected modules: main=%i foo=%i bar=%i\n",
            main_count,
            foo_count,
            bar_count,
        )
        return 1
    }
    _ = libc.fprintf(libc.stderr, "Laziness: entry lookup compiled main-mod only\n")

    entry := transmute(proc "c" (_: i32) -> i32)entry_address
    argc := i32(len(runtime.args__))
    result := entry(argc)
    expected_foo_count := 0
    expected_bar_count := 1
    selected_module: cstring = "bar-mod"
    if argc & 1 == 1 {
        expected_foo_count = 1
        expected_bar_count = 0
        selected_module = "foo-mod"
    }
    main_count, foo_count, bar_count = compilation_counts(&compilation_state)
    if main_count != 1 || foo_count != expected_foo_count || bar_count != expected_bar_count {
        _ = libc.fprintf(
            libc.stderr,
            "Error: lazy call compiled unexpected modules: main=%i foo=%i bar=%i\n",
            main_count,
            foo_count,
            bar_count,
        )
        return 1
    }
    _ = libc.fprintf(libc.stderr, "Laziness: entry call compiled %s only\n", selected_module)
    _ = libc.printf("---Result---\n")
    _ = libc.printf("entry(%i) = %i\n", argc, result)
    return 0
}

main :: proc() {
    libc.exit(i32(run()))
}
