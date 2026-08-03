// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
package main

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"

import llvm "../../../.."

OPTIMIZATION_PIPELINE :: "instcombine,reassociate,gvn,simplifycfg"
LAZY_BODY_SUFFIX :: ".__orc_body"

// LLVM's C ORC API does not expose the tutorial's explicit compile-layer
// construction. LLJIT supplies the execution session and compile layer; its
// builder selects the exposed RTDyld object layer and SectionMemoryManager.
Kaleidoscope_JIT :: struct {
    lljit:   llvm.OrcLLJITRef,
    main_jd: llvm.OrcJITDylibRef,
    lctm:    llvm.OrcLazyCallThroughManagerRef,
    ism:     llvm.OrcIndirectStubsManagerRef,
}

Lazy_Module_State :: struct {
    jit:       ^Kaleidoscope_JIT,
    tsm:       llvm.OrcThreadSafeModuleRef,
    allocator: mem.Allocator,
}

Lazy_Module_Names :: struct {
    public_alias: llvm.OrcSymbolStringPoolEntryRef,
    body_mu:      llvm.OrcSymbolStringPoolEntryRef,
    body_alias:   llvm.OrcSymbolStringPoolEntryRef,
}

Lazy_Module_Prepare_Context :: struct {
    jit:   ^Kaleidoscope_JIT,
    names: ^Lazy_Module_Names,
}

callable_flags :: proc() -> llvm.JITSymbolFlags {
    return {Generic = {.Exported, .Callable}}
}

create_rt_dyld_layer :: proc "c" (
    _: rawptr,
    execution_session: llvm.OrcExecutionSessionRef,
    _: cstring,
) -> llvm.OrcObjectLayerRef {
    return llvm.OrcCreateRTDyldObjectLinkingLayerWithSectionMemoryManager(execution_session)
}

optimize_module :: proc "c" (_: rawptr, module: llvm.ModuleRef) -> llvm.ErrorRef {
    options := llvm.CreatePassBuilderOptions()
    defer llvm.DisposePassBuilderOptions(options)
    return llvm.RunPasses(module, OPTIMIZATION_PIPELINE, nil, options)
}

transform_module :: proc "c" (
    _: rawptr,
    module: ^llvm.OrcThreadSafeModuleRef,
    _: llvm.OrcMaterializationResponsibilityRef,
) -> llvm.ErrorRef {
    err := llvm.OrcThreadSafeModuleWithModuleDo(module^, optimize_module, nil)
    if err != nil {
        // IRTransformLayer requires a failed transform to consume and clear TSM.
        llvm.OrcDisposeThreadSafeModule(module^)
        module^ = nil
    }
    return err
}

prepare_lazy_module :: proc "c" (opaque: rawptr, module: llvm.ModuleRef) -> llvm.ErrorRef {
    context = runtime.default_context()
    prepare := (^Lazy_Module_Prepare_Context)(opaque)
    definition: llvm.ValueRef
    definition_count := 0
    for fn := llvm.GetFirstFunction(module); fn != nil; fn = llvm.GetNextFunction(fn) {
        if !bool(llvm.IsDeclaration(fn)) {
            definition = fn
            definition_count += 1
        }
    }
    if definition_count != 1 {
        return llvm.CreateStringError("Chapter3 lazy modules require exactly one function definition")
    }

    name_length: c.size_t
    public_cstring := llvm.GetValueName2(definition, &name_length)
    public_name := string(public_cstring)
    body_name := strings.concatenate({public_name, LAZY_BODY_SUFFIX})
    defer delete(body_name)

    prepare.names.public_alias = llvm.OrcLLJITMangleAndIntern(prepare.jit.lljit, public_cstring)
    prepare.names.body_mu = llvm.OrcLLJITMangleAndIntern(prepare.jit.lljit, fmt.ctprint(body_name))
    prepare.names.body_alias = llvm.OrcLLJITMangleAndIntern(prepare.jit.lljit, fmt.ctprint(body_name))
    llvm.SetValueName2(definition, fmt.ctprint(body_name), c.size_t(len(body_name)))
    return nil
}

lazy_module_materialize :: proc "c" (opaque: rawptr, responsibility: llvm.OrcMaterializationResponsibilityRef) {
    context = runtime.default_context()
    state := (^Lazy_Module_State)(opaque)
    jit := state.jit
    tsm := state.tsm
    allocator := state.allocator
    state.tsm = nil
    free(state, allocator)
    llvm.OrcIRTransformLayerEmit(llvm.OrcLLJITGetIRTransformLayer(jit.lljit), responsibility, tsm)
}

lazy_module_discard :: proc "c" (_: rawptr, _: llvm.OrcJITDylibRef, _: llvm.OrcSymbolStringPoolEntryRef) {
}

lazy_module_destroy :: proc "c" (opaque: rawptr) {
    context = runtime.default_context()
    state := (^Lazy_Module_State)(opaque)
    if state.tsm != nil {
        llvm.OrcDisposeThreadSafeModule(state.tsm)
    }
    free(state, state.allocator)
}

lazy_compile_failure :: proc "c" () {
    context = runtime.default_context()
    fmt.eprintln("Lazy compilation failed.")
    os.exit(1)
}

jit_create :: proc() -> (^Kaleidoscope_JIT, llvm.ErrorRef) {
    j := new(Kaleidoscope_JIT)
    lljit_builder := llvm.OrcCreateLLJITBuilder()
    llvm.OrcLLJITBuilderSetObjectLinkingLayerCreator(lljit_builder, create_rt_dyld_layer, nil)
    if err := llvm.OrcCreateLLJIT(&j.lljit, lljit_builder); err != nil {
        free(j)
        return nil, err
    }
    j.main_jd = llvm.OrcLLJITGetMainJITDylib(j.lljit)
    transform_layer := llvm.OrcLLJITGetIRTransformLayer(j.lljit)
    llvm.OrcIRTransformLayerSetTransform(transform_layer, transform_module, nil)

    j.ism = llvm.OrcCreateLocalIndirectStubsManager(llvm.OrcLLJITGetTripleString(j.lljit))
    if j.ism == nil {
        _ = llvm.OrcDisposeLLJIT(j.lljit)
        free(j)
        return nil, llvm.CreateStringError("could not create local indirect stubs manager")
    }
    if err := llvm.OrcCreateLocalLazyCallThroughManager(
        llvm.OrcLLJITGetTripleString(j.lljit),
        llvm.OrcLLJITGetExecutionSession(j.lljit),
        llvm.OrcJITTargetAddress(uintptr(rawptr(lazy_compile_failure))),
        &j.lctm,
    ); err != nil {
        llvm.OrcDisposeIndirectStubsManager(j.ism)
        _ = llvm.OrcDisposeLLJIT(j.lljit)
        free(j)
        return nil, err
    }
    return j, nil
}

jit_dispose :: proc(j: ^Kaleidoscope_JIT) -> llvm.ErrorRef {
    if j == nil {
        return nil
    }
    llvm.OrcDisposeIndirectStubsManager(j.ism)
    llvm.OrcDisposeLazyCallThroughManager(j.lctm)
    err := llvm.OrcDisposeLLJIT(j.lljit)
    free(j)
    return err
}

jit_data_layout :: proc(j: ^Kaleidoscope_JIT) -> cstring {
    return llvm.OrcLLJITGetDataLayoutStr(j.lljit)
}

jit_create_resource_tracker :: proc(j: ^Kaleidoscope_JIT) -> llvm.OrcResourceTrackerRef {
    return llvm.OrcJITDylibCreateResourceTracker(j.main_jd)
}

jit_add_lazy_module :: proc(j: ^Kaleidoscope_JIT, tsm: llvm.OrcThreadSafeModuleRef) -> llvm.ErrorRef {
    // LLVM's C ORC API cannot construct IRPartitionLayer or CompileOnDemandLayer.
    // The frontend emits one definition per module, so a custom MU holds each body
    // and a lazy reexport provides its compile-on-first-call stub. Multi-definition
    // IR partitioning remains unavailable.
    names: Lazy_Module_Names
    prepare := Lazy_Module_Prepare_Context {
        jit   = j,
        names = &names,
    }
    if err := llvm.OrcThreadSafeModuleWithModuleDo(tsm, prepare_lazy_module, &prepare); err != nil {
        llvm.OrcDisposeThreadSafeModule(tsm)
        return err
    }

    allocator := context.allocator
    state := new(Lazy_Module_State, allocator)
    state^ = {
        jit       = j,
        tsm       = tsm,
        allocator = allocator,
    }
    body_symbol := [1]llvm.OrcCSymbolFlagsMapPair{{Name = names.body_mu, Flags = callable_flags()}}
    body_mu := llvm.OrcCreateCustomMaterializationUnit(
        "KaleidoscopeLazyIR",
        state,
        &body_symbol[0],
        1,
        nil,
        lazy_module_materialize,
        lazy_module_discard,
        lazy_module_destroy,
    )
    if err := llvm.OrcJITDylibDefine(j.main_jd, body_mu); err != nil {
        llvm.OrcDisposeMaterializationUnit(body_mu)
        llvm.OrcReleaseSymbolStringPoolEntry(names.public_alias)
        llvm.OrcReleaseSymbolStringPoolEntry(names.body_alias)
        return err
    }

    aliases := [1]llvm.OrcCSymbolAliasMapPair {
        {Name = names.public_alias, Entry = {Name = names.body_alias, Flags = callable_flags()}},
    }
    alias_mu := llvm.OrcLazyReexports(j.lctm, j.ism, j.main_jd, &aliases[0], 1)
    if err := llvm.OrcJITDylibDefine(j.main_jd, alias_mu); err != nil {
        llvm.OrcDisposeMaterializationUnit(alias_mu)
        return err
    }
    return nil
}

jit_add_module :: proc(
    j: ^Kaleidoscope_JIT,
    tsm: llvm.OrcThreadSafeModuleRef,
    tracker: llvm.OrcResourceTrackerRef = nil,
) -> llvm.ErrorRef {
    if tracker != nil {
        // Tracked modules are removable top-level expressions and stay on LLJIT's
        // eager IR path.
        return llvm.OrcLLJITAddLLVMIRModuleWithRT(j.lljit, tracker, tsm)
    }
    return jit_add_lazy_module(j, tsm)
}

jit_lookup :: proc(j: ^Kaleidoscope_JIT, name: string, result: ^llvm.OrcExecutorAddress) -> llvm.ErrorRef {
    return llvm.OrcLLJITLookup(j.lljit, result, fmt.ctprint(name))
}
