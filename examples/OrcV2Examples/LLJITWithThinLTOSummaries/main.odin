// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
package main

import "core:fmt"
import "core:os"
import "core:strings"

import llvm "../../.."

Loaded_Module :: struct {
    path:         string,
    llvm_context: llvm.ContextRef,
    module:       llvm.ModuleRef,
}

print_help :: proc() {
    fmt.println("USAGE: LLJITWithThinLTOSummaries <module.ll|module.bc>...")
}

report_error :: proc(err: llvm.ErrorRef) {
    message := llvm.GetErrorMessage(err)
    fmt.eprintf("%s: %s\n", os.args[0], string(message))
    llvm.DisposeErrorMessage(message)
}

load_module :: proc(path: string) -> (loaded: Loaded_Module, ok: bool) {
    fmt.printf("About to load module: %s\n", path)
    c_path, path_error := strings.clone_to_cstring(path, context.temp_allocator)
    if path_error != nil {
        fmt.eprintf("%s: invalid input path `%s'\n", os.args[0], path)
        return loaded, false
    }

    buffer: llvm.MemoryBufferRef
    message: cstring
    if llvm.CreateMemoryBufferWithContentsOfFile(c_path, &buffer, &message) != 0 {
        fmt.eprintf("%s: %s: %s\n", os.args[0], path, string(message))
        llvm.DisposeMessage(message)
        return loaded, false
    }
    loaded.path = path
    loaded.llvm_context = llvm.ContextCreate()
    if llvm.ParseIRInContext(loaded.llvm_context, buffer, &loaded.module, &message) != 0 {
        fmt.eprintf("%s: %s: %s\n", os.args[0], path, string(message))
        llvm.DisposeMessage(message)
        llvm.ContextDispose(loaded.llvm_context)
        loaded.llvm_context = nil
        return loaded, false
    }
    return loaded, true
}

target_triples_compatible :: proc(left, right: cstring) -> bool {
    left_target, right_target: llvm.TargetRef
    message: cstring
    if llvm.GetTargetFromTriple(left, &left_target, &message) != 0 {
        if message != nil {
            llvm.DisposeMessage(message)
        }
        return false
    }
    if llvm.GetTargetFromTriple(right, &right_target, &message) != 0 {
        if message != nil {
            llvm.DisposeMessage(message)
        }
        return false
    }
    if left_target != right_target {
        return false
    }

    left_machine := llvm.CreateTargetMachine(left_target, left, "", "", .Default, .Default, .Default)
    if left_machine == nil {
        return false
    }
    defer llvm.DisposeTargetMachine(left_machine)
    right_machine := llvm.CreateTargetMachine(right_target, right, "", "", .Default, .Default, .Default)
    if right_machine == nil {
        return false
    }
    defer llvm.DisposeTargetMachine(right_machine)

    left_data_layout := llvm.CreateTargetDataLayout(left_machine)
    if left_data_layout == nil {
        return false
    }
    defer llvm.DisposeTargetData(left_data_layout)
    right_data_layout := llvm.CreateTargetDataLayout(right_machine)
    if right_data_layout == nil {
        return false
    }
    defer llvm.DisposeTargetData(right_data_layout)

    left_layout := llvm.CopyStringRepOfTargetData(left_data_layout)
    defer llvm.DisposeMessage(left_layout)
    right_layout := llvm.CopyStringRepOfTargetData(right_data_layout)
    defer llvm.DisposeMessage(right_layout)
    return string(left_layout) == string(right_layout)
}

run :: proc() -> (status: int) {
    if len(os.args) == 2 && (os.args[1] == "-h" || os.args[1] == "--help") {
        print_help()
        return 0
    }
    if len(os.args) < 2 {
        print_help()
        return 1
    }
    for argument in os.args[1:] {
        if strings.has_prefix(argument, "-") {
            fmt.eprintf("%s: unknown option `%s'\n", os.args[0], argument)
            return 1
        }
    }

    if llvm.InitializeNativeTarget() != 0 || llvm.InitializeNativeAsmPrinter() != 0 {
        fmt.eprintln("native LLVM target unavailable")
        return 1
    }
    defer llvm.Shutdown()

    // LLVM-C has no ModuleSummaryIndex parser or iterator. Explicit module arguments
    // replace index path discovery; C-API module inspection still finds unique main.
    modules := make([dynamic]Loaded_Module, 0, len(os.args) - 1, context.temp_allocator)
    defer {
        for module in modules {
            if module.module != nil {
                llvm.DisposeModule(module.module)
            }
            if module.llvm_context != nil {
                llvm.ContextDispose(module.llvm_context)
            }
        }
    }
    for path in os.args[1:] {
        loaded, ok := load_module(path)
        if !ok {
            return 1
        }
        append(&modules, loaded)
    }

    main_module_path := ""
    main_module_index := -1
    for module, index in modules {
        main_function := llvm.GetNamedFunction(module.module, "main")
        if main_function == nil || llvm.IsDeclaration(main_function) != 0 {
            continue
        }
        if main_module_path != "" {
            fmt.eprintf("%s: duplicate definition of `main' in %s and %s\n", os.args[0], main_module_path, module.path)
            return 1
        }
        main_module_path = module.path
        main_module_index = index
    }
    if main_module_path == "" {
        fmt.eprintf("%s: no definition of `main' in input modules\n", os.args[0])
        return 1
    }

    target_machine_builder: llvm.OrcJITTargetMachineBuilderRef
    if err := llvm.OrcJITTargetMachineBuilderDetectHost(&target_machine_builder); err != nil {
        report_error(err)
        return 1
    }
    defer {
        if target_machine_builder != nil {
            llvm.OrcDisposeJITTargetMachineBuilder(target_machine_builder)
        }
    }

    host_triple := llvm.OrcJITTargetMachineBuilderGetTargetTriple(target_machine_builder)
    defer llvm.DisposeMessage(host_triple)
    effective_triple := host_triple
    main_triple := llvm.GetTarget(modules[main_module_index].module)
    if string(main_triple) != "" {
        if !target_triples_compatible(main_triple, host_triple) {
            fmt.eprintf(
                "%s: %s: target triple `%s' is incompatible with host `%s'\n",
                os.args[0],
                main_module_path,
                main_triple,
                host_triple,
            )
            return 1
        }
        effective_triple = main_triple
        // LLVM-C exposes the main module's triple setter, but no LLJITBuilder
        // data-layout setter. AddLLVMIRModule validates explicit layouts using
        // LLJIT's semantic DataLayout comparison.
        llvm.OrcJITTargetMachineBuilderSetTargetTriple(target_machine_builder, main_triple)
    }

    for module in modules {
        module_triple := llvm.GetTarget(module.module)
        if string(module_triple) != "" && !target_triples_compatible(module_triple, effective_triple) {
            fmt.eprintf(
                "%s: %s: target triple `%s' contradicts `%s' selected by main module %s\n",
                os.args[0],
                module.path,
                module_triple,
                effective_triple,
                main_module_path,
            )
            return 1
        }
    }

    builder := llvm.OrcCreateLLJITBuilder()
    llvm.OrcLLJITBuilderSetJITTargetMachineBuilder(builder, target_machine_builder)
    target_machine_builder = nil
    jit: llvm.OrcLLJITRef
    if err := llvm.OrcCreateLLJIT(&jit, builder); err != nil {
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

    main_jit_dylib := llvm.OrcLLJITGetMainJITDylib(jit)
    for index in 0 ..< len(modules) {
        module := &modules[index]
        if string(llvm.GetTarget(module.module)) == "" {
            llvm.SetTarget(module.module, llvm.OrcLLJITGetTripleString(jit))
        }
        if string(llvm.GetDataLayoutStr(module.module)) == "" {
            llvm.SetDataLayout(module.module, llvm.OrcLLJITGetDataLayoutStr(jit))
        }

        thread_safe_context := llvm.OrcCreateNewThreadSafeContextFromLLVMContext(module.llvm_context)
        thread_safe_module := llvm.OrcCreateNewThreadSafeModule(module.module, thread_safe_context)
        llvm.OrcDisposeThreadSafeContext(thread_safe_context)
        module.llvm_context = nil
        module.module = nil
        // AddLLVMIRModule consumes thread_safe_module on success and failure.
        if err := llvm.OrcLLJITAddLLVMIRModule(jit, main_jit_dylib, thread_safe_module); err != nil {
            report_error(err)
            return 1
        }
    }

    main_address: llvm.OrcExecutorAddress
    if err := llvm.OrcLLJITLookup(jit, &main_address, "main"); err != nil {
        report_error(err)
        return 1
    }

    argv0, argv_error := strings.clone_to_cstring(main_module_path, context.temp_allocator)
    if argv_error != nil {
        fmt.eprintf("%s: invalid main module path `%s'\n", os.args[0], main_module_path)
        return 1
    }
    argv := [2]cstring{argv0, nil}
    main_function := transmute(proc "c" (_: i32, _: [^]cstring) -> i32)main_address
    result := main_function(1, raw_data(argv[:]))
    fmt.printf("'main' finished with exit code: %d\n", result)
    return 0
}

main :: proc() {
    os.exit(run())
}
