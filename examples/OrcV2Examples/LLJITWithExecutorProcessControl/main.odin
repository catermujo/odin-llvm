// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
package main

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:os"
import "core:sync"

import llvm "../../.."

FOO_MODULE ::
    "  define i32 @foo_body() { \n" +
    "  entry:                   \n" +
    "    ret i32 1              \n" +
    "  }                        \n"

BAR_MODULE ::
    "  define i32 @bar_body() { \n" +
    "  entry:                   \n" +
    "    ret i32 2              \n" +
    "  }                        \n"

MAIN_MODULE ::
    "  define i32 @entry(i32 %argc) {                                 \n" +
    "  entry:                                                         \n" +
    "    %and = and i32 %argc, 1                                      \n" +
    "    %tobool = icmp eq i32 %and, 0                                \n" +
    "    br i1 %tobool, label %if.end, label %if.then                 \n" +
    "                                                                 \n" +
    "  if.then:                                                       \n" +
    "    %call = tail call i32 @foo()                                 \n" +
    "    br label %return                                             \n" +
    "                                                                 \n" +
    "  if.end:                                                        \n" +
    "    %call1 = tail call i32 @bar()                                \n" +
    "    br label %return                                             \n" +
    "                                                                 \n" +
    "  return:                                                        \n" +
    "    %retval.0 = phi i32 [ %call, %if.then ], [ %call1, %if.end ] \n" +
    "    ret i32 %retval.0                                            \n" +
    "  }                                                              \n" +
    "                                                                 \n" +
    "  declare i32 @foo()                                             \n" +
    "  declare i32 @bar()                                             \n"

Compilation_State :: struct {
    mutex:      sync.Mutex,
    main_count: int,
    foo_count:  int,
    bar_count:  int,
}

report_error :: proc(err: llvm.ErrorRef) {
    message := llvm.GetErrorMessage(err)
    fmt.eprintf("%s: %s\n", os.args[0], string(message))
    llvm.DisposeErrorMessage(message)
}

parse_module :: proc(source: string, name: cstring) -> (llvm.OrcThreadSafeModuleRef, bool) {
    llvm_context := llvm.ContextCreate()
    buffer := llvm.CreateMemoryBufferWithMemoryRange(cstring(raw_data(source)), c.size_t(len(source)), name, 0)
    module: llvm.ModuleRef
    message: cstring
    failed := llvm.ParseIRInContext(llvm_context, buffer, &module, &message)
    if failed != 0 {
        fmt.eprintf("%s: %s\n", os.args[0], string(message))
        llvm.DisposeMessage(message)
        llvm.ContextDispose(llvm_context)
        return nil, false
    }

    thread_safe_context := llvm.OrcCreateNewThreadSafeContextFromLLVMContext(llvm_context)
    thread_safe_module := llvm.OrcCreateNewThreadSafeModule(module, thread_safe_context)
    llvm.OrcDisposeThreadSafeContext(thread_safe_context)
    return thread_safe_module, true
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

    fmt.println("---Compiling---")
    module_text := llvm.PrintModuleToString(module)
    fmt.print(string(module_text))
    llvm.DisposeMessage(module_text)
    return nil
}

print_transform :: proc "c" (
    ctx: rawptr,
    module_in_out: ^llvm.OrcThreadSafeModuleRef,
    _: llvm.OrcMaterializationResponsibilityRef,
) -> llvm.ErrorRef {
    context = runtime.default_context()
    return llvm.OrcThreadSafeModuleWithModuleDo(module_in_out^, print_module, ctx)
}

compilation_counts :: proc(state: ^Compilation_State) -> (main_count, foo_count, bar_count: int) {
    sync.mutex_lock(&state.mutex)
    defer sync.mutex_unlock(&state.mutex)
    return state.main_count, state.foo_count, state.bar_count
}

add_module :: proc(jit: llvm.OrcLLJITRef, jit_dylib: llvm.OrcJITDylibRef, source: string, name: cstring) -> bool {
    thread_safe_module, ok := parse_module(source, name)
    if !ok {
        return false
    }
    if err := llvm.OrcLLJITAddLLVMIRModule(jit, jit_dylib, thread_safe_module); err != nil {
        report_error(err)
        return false
    }
    return true
}

lazy_compile_failure :: proc "c" () {
    context = runtime.default_context()
    fmt.eprintln("Unable to lazily compile function.")
    os.exit(1)
}

print_help :: proc() {
    fmt.println("USAGE: LLJITWithExecutorProcessControl [program arguments]...")
}

run :: proc() -> (status: int) {
    for argument in os.args[1:] {
        if argument == "-h" || argument == "--help" {
            print_help()
            return 0
        }
    }

    if llvm.InitializeNativeTarget() != 0 || llvm.InitializeNativeAsmPrinter() != 0 {
        fmt.eprintln("native LLVM target unavailable")
        return 1
    }
    defer llvm.Shutdown()

    jit: llvm.OrcLLJITRef
    if err := llvm.OrcCreateLLJIT(&jit, nil); err != nil {
        report_error(err)
        return 1
    }
    defer {
        if err := llvm.OrcDisposeLLJIT(jit); err != nil {
            report_error(err)
            if status == 0 {
                status = 1
            }
        }
    }

    compilation_state: Compilation_State
    llvm.OrcIRTransformLayerSetTransform(
        llvm.OrcLLJITGetIRTransformLayer(jit),
        print_transform,
        rawptr(&compilation_state),
    )

    execution_session := llvm.OrcLLJITGetExecutionSession(jit)
    target_triple := llvm.OrcLLJITGetTripleString(jit)
    lazy_manager: llvm.OrcLazyCallThroughManagerRef
    if err := llvm.OrcCreateLocalLazyCallThroughManager(
        target_triple,
        execution_session,
        llvm.OrcJITTargetAddress(uintptr(rawptr(lazy_compile_failure))),
        &lazy_manager,
    ); err != nil {
        report_error(err)
        return 1
    }
    indirect_stubs_manager := llvm.OrcCreateLocalIndirectStubsManager(target_triple)
    if indirect_stubs_manager == nil {
        fmt.eprintf("%s: could not create local indirect stubs manager\n", os.args[0])
        llvm.OrcDisposeLazyCallThroughManager(lazy_manager)
        return 1
    }
    defer {
        llvm.OrcDisposeIndirectStubsManager(indirect_stubs_manager)
        llvm.OrcDisposeLazyCallThroughManager(lazy_manager)
    }

    main_jit_dylib := llvm.OrcLLJITGetMainJITDylib(jit)
    if !add_module(jit, main_jit_dylib, FOO_MODULE, "foo-mod") ||
       !add_module(jit, main_jit_dylib, BAR_MODULE, "bar-mod") ||
       !add_module(jit, main_jit_dylib, MAIN_MODULE, "main-mod") {
        return 1
    }

    flags: llvm.JITSymbolFlags = {
        Generic = {.Exported, .Callable},
    }
    reexports := [2]llvm.OrcCSymbolAliasMapPair {
        {
            Name = llvm.OrcLLJITMangleAndIntern(jit, "foo"),
            Entry = {Name = llvm.OrcLLJITMangleAndIntern(jit, "foo_body"), Flags = flags},
        },
        {
            Name = llvm.OrcLLJITMangleAndIntern(jit, "bar"),
            Entry = {Name = llvm.OrcLLJITMangleAndIntern(jit, "bar_body"), Flags = flags},
        },
    }
    lazy_reexports := llvm.OrcLazyReexports(
        lazy_manager,
        indirect_stubs_manager,
        main_jit_dylib,
        raw_data(reexports[:]),
        2,
    )
    if lazy_reexports == nil {
        fmt.eprintf("%s: could not create local lazy reexports\n", os.args[0])
        return 1
    }
    if err := llvm.OrcJITDylibDefine(main_jit_dylib, lazy_reexports); err != nil {
        llvm.OrcDisposeMaterializationUnit(lazy_reexports)
        report_error(err)
        return 1
    }

    main_count, foo_count, bar_count := compilation_counts(&compilation_state)
    if main_count != 0 || foo_count != 0 || bar_count != 0 {
        fmt.eprintf(
            "%s: modules compiled before lookup: main=%d foo=%d bar=%d\n",
            os.args[0],
            main_count,
            foo_count,
            bar_count,
        )
        return 1
    }

    // LLVM-C has no SelfExecutorProcessControl, EPCIndirectionUtils, or LLJIT EPC setter.
    // Local C-API managers preserve lazy reexports; this manifest replaces ExecutionSession::dump.
    fmt.println("---Session state---")
    fmt.println("local lazy reexport: foo -> foo_body")
    fmt.println("local lazy reexport: bar -> bar_body")
    fmt.println()

    entry_address: llvm.OrcExecutorAddress
    if err := llvm.OrcLLJITLookup(jit, &entry_address, "entry"); err != nil {
        report_error(err)
        return 1
    }
    main_count, foo_count, bar_count = compilation_counts(&compilation_state)
    if main_count != 1 || foo_count != 0 || bar_count != 0 {
        fmt.eprintf(
            "%s: entry lookup compiled unexpected modules: main=%d foo=%d bar=%d\n",
            os.args[0],
            main_count,
            foo_count,
            bar_count,
        )
        return 1
    }
    fmt.println("Laziness: entry lookup compiled main-mod only")

    entry := transmute(proc "c" (_: i32) -> i32)entry_address
    argc := i32(len(os.args))
    result := entry(argc)
    expected_foo_count := 0
    expected_bar_count := 1
    selected_module := "bar-mod"
    if argc & 1 == 1 {
        expected_foo_count = 1
        expected_bar_count = 0
        selected_module = "foo-mod"
    }
    main_count, foo_count, bar_count = compilation_counts(&compilation_state)
    if main_count != 1 || foo_count != expected_foo_count || bar_count != expected_bar_count {
        fmt.eprintf(
            "%s: lazy call compiled unexpected modules: main=%d foo=%d bar=%d\n",
            os.args[0],
            main_count,
            foo_count,
            bar_count,
        )
        return 1
    }
    fmt.printf("Laziness: entry call compiled %s only\n", selected_module)
    fmt.println("---Result---")
    fmt.printf("entry(%d) = %d\n", argc, result)
    return 0
}

main :: proc() {
    os.exit(run())
}
