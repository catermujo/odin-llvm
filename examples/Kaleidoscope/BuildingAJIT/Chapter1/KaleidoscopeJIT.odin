// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
package main

import "core:fmt"

import llvm "../../../.."

// LLVM's C ORC API does not expose the tutorial's explicit compile-layer
// construction. LLJIT supplies the execution session and compile layer; its
// builder selects the exposed RTDyld object layer and SectionMemoryManager.
Kaleidoscope_JIT :: struct {
    lljit:   llvm.OrcLLJITRef,
    main_jd: llvm.OrcJITDylibRef,
}

create_rt_dyld_layer :: proc "c" (
    _: rawptr,
    execution_session: llvm.OrcExecutionSessionRef,
    _: cstring,
) -> llvm.OrcObjectLayerRef {
    return llvm.OrcCreateRTDyldObjectLinkingLayerWithSectionMemoryManager(execution_session)
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
