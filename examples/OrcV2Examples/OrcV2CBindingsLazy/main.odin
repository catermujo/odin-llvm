// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
package main

import "base:runtime"
import "core:c/libc"

import llvm "../../.."
import orc_support "../support"

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

lazy_compile_failure :: proc "c" () {
    _ = libc.fprintf(libc.stderr, "Error: Lazy compilation failed.\n")
    libc.exit(1)
}

add_module :: proc(
    jit: llvm.OrcLLJITRef,
    jit_dylib: llvm.OrcJITDylibRef,
    source: string,
    name: cstring,
) -> llvm.ErrorRef {
    thread_safe_module: llvm.OrcThreadSafeModuleRef
    if err := orc_support.parse_example_module(source, name, &thread_safe_module); err != nil {
        return err
    }
    if err := llvm.OrcLLJITAddLLVMIRModule(jit, jit_dylib, thread_safe_module); err != nil {
        return err
    }
    return nil
}

run :: proc() -> (main_result: int) {
    llvm.ParseCommandLineOptions(i32(len(runtime.args__)), raw_data(runtime.args__), "")
    _ = llvm.InitializeNativeTarget()
    _ = llvm.InitializeNativeAsmPrinter()
    defer llvm.Shutdown()

    jit: llvm.OrcLLJITRef
    if err := llvm.OrcCreateLLJIT(&jit, nil); err != nil {
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

    target_triple := llvm.OrcLLJITGetTripleString(jit)
    main_jit_dylib := llvm.OrcLLJITGetMainJITDylib(jit)
    if err := add_module(jit, main_jit_dylib, FOO_MODULE, "foo-mod"); err != nil {
        return orc_support.handle_error(err)
    }
    if err := add_module(jit, main_jit_dylib, BAR_MODULE, "bar-mod"); err != nil {
        return orc_support.handle_error(err)
    }
    if err := add_module(jit, main_jit_dylib, MAIN_MODULE, "main-mod"); err != nil {
        return orc_support.handle_error(err)
    }

    indirect_stubs_manager := llvm.OrcCreateLocalIndirectStubsManager(target_triple)
    lazy_call_through_manager: llvm.OrcLazyCallThroughManagerRef
    execution_session := llvm.OrcLLJITGetExecutionSession(jit)
    if err := llvm.OrcCreateLocalLazyCallThroughManager(
        target_triple,
        execution_session,
        llvm.OrcJITTargetAddress(uintptr(rawptr(lazy_compile_failure))),
        &lazy_call_through_manager,
    ); err != nil {
        llvm.OrcDisposeIndirectStubsManager(indirect_stubs_manager)
        return orc_support.handle_error(err)
    }
    defer {
        llvm.OrcDisposeIndirectStubsManager(indirect_stubs_manager)
        llvm.OrcDisposeLazyCallThroughManager(lazy_call_through_manager)
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
    materialization_unit := llvm.OrcLazyReexports(
        lazy_call_through_manager,
        indirect_stubs_manager,
        main_jit_dylib,
        raw_data(reexports[:]),
        2,
    )
    if err := llvm.OrcJITDylibDefine(main_jit_dylib, materialization_unit); err != nil {
        llvm.OrcDisposeMaterializationUnit(materialization_unit)
        return orc_support.handle_error(err)
    }

    entry_address: llvm.OrcExecutorAddress
    if err := llvm.OrcLLJITLookup(jit, &entry_address, "entry"); err != nil {
        return orc_support.handle_error(err)
    }

    entry := transmute(proc "c" (_: i32) -> i32)entry_address
    argc := i32(len(runtime.args__))
    result := entry(argc)
    _ = libc.printf("--- Result ---\n")
    _ = libc.printf("entry(%i) = %i\n", argc, result)
    return 0
}

main :: proc() {
    libc.exit(i32(run()))
}
