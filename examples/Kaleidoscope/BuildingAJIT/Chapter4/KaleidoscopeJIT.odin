// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
package main

import "base:runtime"
import "core:fmt"
import "core:mem"

import llvm "../../../.."

OPTIMIZATION_PIPELINE :: "instcombine,reassociate,gvn,simplifycfg"

// LLVM's C ORC API does not expose the tutorial's explicit compile-layer
// construction. LLJIT supplies the execution session and compile layer; its
// builder selects the exposed RTDyld object layer and SectionMemoryManager.
Kaleidoscope_JIT :: struct {
    lljit:   llvm.OrcLLJITRef,
    main_jd: llvm.OrcJITDylibRef,
}

AST_Materialization_State :: struct {
    jit:       ^Kaleidoscope_JIT,
    fn:        ^Function_AST,
    allocator: mem.Allocator,
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

destroy_ast_state :: proc(state: ^AST_Materialization_State) {
    allocator := state.allocator
    if state.fn != nil {
        destroy_function_ast(state.fn, allocator)
    }
    free(state, allocator)
}

ast_materialize :: proc "c" (opaque: rawptr, responsibility: llvm.OrcMaterializationResponsibilityRef) {
    context = runtime.default_context()
    state := (^AST_Materialization_State)(opaque)
    jit := state.jit
    tsm, frontend_err := irgen_and_take_ownership(state.fn)
    destroy_ast_state(state)

    if !report_frontend_error(frontend_err) {
        llvm.OrcMaterializationResponsibilityFailMaterialization(responsibility)
        llvm.OrcDisposeMaterializationResponsibility(responsibility)
        return
    }
    llvm.OrcIRTransformLayerEmit(llvm.OrcLLJITGetIRTransformLayer(jit.lljit), responsibility, tsm)
}

ast_discard :: proc "c" (_: rawptr, _: llvm.OrcJITDylibRef, _: llvm.OrcSymbolStringPoolEntryRef) {
    // Kaleidoscope definitions are strong and rejected before replacement.
}

ast_destroy :: proc "c" (opaque: rawptr) {
    context = runtime.default_context()
    destroy_ast_state((^AST_Materialization_State)(opaque))
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
    return j, nil
}

jit_dispose :: proc(j: ^Kaleidoscope_JIT) -> llvm.ErrorRef {
    if j == nil {
        return nil
    }
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

jit_add_ast :: proc(j: ^Kaleidoscope_JIT, source: ^Function_AST) -> llvm.ErrorRef {
    // Parser nodes use the temporary allocator. Custom MU callbacks may run long
    // after the REPL iteration ends, so every node, string, argument, and binding
    // is recursively cloned into this explicitly owned state.
    allocator := context.allocator
    state := new(AST_Materialization_State, allocator)
    state^ = {
        jit       = j,
        fn        = clone_function_ast(source, allocator),
        allocator = allocator,
    }

    symbols := [1]llvm.OrcCSymbolFlagsMapPair {
        {Name = llvm.OrcLLJITMangleAndIntern(j.lljit, fmt.ctprint(source.proto.name)), Flags = callable_flags()},
    }
    mu := llvm.OrcCreateCustomMaterializationUnit(
        "KaleidoscopeAST",
        state,
        &symbols[0],
        1,
        nil,
        ast_materialize,
        ast_discard,
        ast_destroy,
    )
    if err := llvm.OrcJITDylibDefine(j.main_jd, mu); err != nil {
        // Define leaves ownership with caller on failure.
        llvm.OrcDisposeMaterializationUnit(mu)
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
    return llvm.OrcLLJITAddLLVMIRModule(j.lljit, j.main_jd, tsm)
}

jit_lookup :: proc(j: ^Kaleidoscope_JIT, name: string, result: ^llvm.OrcExecutorAddress) -> llvm.ErrorRef {
    return llvm.OrcLLJITLookup(j.lljit, result, fmt.ctprint(name))
}
