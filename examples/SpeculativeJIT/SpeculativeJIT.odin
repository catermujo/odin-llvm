package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

import llvm "../.."

Options :: struct {
    input_files:  [dynamic]string,
    program_args: [dynamic]string,
    num_threads:  u32,
}

print_usage :: proc(program: string) {
    fmt.printf("OVERVIEW: Speculative JIT\n\n")
    fmt.printf("USAGE: %s [options] <input files> --args <program arguments>\n\n", program)
    fmt.printf("OPTIONS:\n")
    fmt.printf("  -args, --args         Separate input files from program arguments\n")
    fmt.printf("  --num-threads=<uint>  Compatibility option; accepted but ignored by LLVM-C\n")
    fmt.printf("  --help                Display available options\n")
}

parse_num_threads :: proc(program, value_text: string) -> (u32, bool) {
    value, ok := strconv.parse_uint(value_text, 10)
    if !ok || value > uint(max(u32)) {
        fmt.eprintf("%s: for the --num-threads option: '%s' value invalid for uint argument!\n", program, value_text)
        return 0, false
    }
    if value == 0 {
        fmt.eprintf("%s: --num-threads must be greater than zero\n", program)
        return 0, false
    }
    return u32(value), true
}

parse_options :: proc(args: []string) -> (Options, i32, bool) {
    program := args[0]
    options := Options {
        num_threads = 1,
    }
    program_arguments := false

    for index := 1; index < len(args); index += 1 {
        argument := args[index]
        if program_arguments {
            append(&options.program_args, argument)
            continue
        }

        if argument == "-args" || argument == "--args" || argument == "--" {
            program_arguments = true
            continue
        }
        if argument == "--help" || argument == "-h" {
            print_usage(program)
            return options, 0, false
        }

        value_text := ""
        if argument == "--num-threads" {
            if index + 1 == len(args) {
                fmt.eprintf("%s: for the --num-threads option: requires a value!\n", program)
                return options, 1, false
            }
            index += 1
            value_text = args[index]
        } else if strings.has_prefix(argument, "--num-threads=") {
            value_text = argument[len("--num-threads="):]
        }
        if value_text != "" || strings.has_prefix(argument, "--num-threads=") {
            value, ok := parse_num_threads(program, value_text)
            if !ok {
                return options, 1, false
            }
            options.num_threads = value
            continue
        }

        if strings.has_prefix(argument, "-") && argument != "-" {
            fmt.eprintf("%s: Unknown command line argument '%s'.  Try: '%s --help'\n", program, argument, program)
            return options, 1, false
        }
        append(&options.input_files, argument)
    }

    if len(options.input_files) == 0 {
        fmt.eprintf("%s: Not enough positional command line arguments specified!\n", program)
        fmt.eprintf("Must specify at least 1 positional argument: See: %s --help\n", program)
        return options, 1, false
    }
    return options, 0, true
}

initialize_native_target :: proc(program: string) -> bool {
    if llvm.InitializeNativeTarget() != 0 || llvm.InitializeNativeAsmPrinter() != 0 {
        fmt.eprintf("%s: native LLVM target unavailable\n", program)
        return false
    }
    return true
}

report_llvm_error :: proc(program: string, err: llvm.ErrorRef) {
    message := llvm.GetErrorMessage(err)
    fmt.eprintf("%s: %s\n", program, message)
    llvm.DisposeErrorMessage(message)
}

parse_ir_file :: proc(program, path: string) -> (llvm.ContextRef, llvm.ModuleRef, bool) {
    buffer: llvm.MemoryBufferRef
    message: cstring
    failed: llvm.Bool
    if path == "-" {
        failed = llvm.CreateMemoryBufferWithSTDIN(&buffer, &message)
    } else {
        c_path := strings.clone_to_cstring(path, context.temp_allocator)
        failed = llvm.CreateMemoryBufferWithContentsOfFile(c_path, &buffer, &message)
    }
    if failed != 0 {
        fmt.eprintf("%s: %s: error: Could not open input file: %s\n", program, path, message)
        llvm.DisposeMessage(message)
        return nil, nil, false
    }

    llvm_context := llvm.ContextCreate()
    module: llvm.ModuleRef
    failed = llvm.ParseIRInContext2(llvm_context, buffer, &module, &message)
    llvm.DisposeMemoryBuffer(buffer)
    if failed != 0 {
        fmt.eprintf("%s: %s\n", program, message)
        llvm.DisposeMessage(message)
        llvm.ContextDispose(llvm_context)
        return nil, nil, false
    }
    return llvm_context, module, true
}

add_ir_file :: proc(program, path: string, jit: llvm.OrcLLJITRef, source: llvm.OrcJITDylibRef) -> bool {
    llvm_context, module, ok := parse_ir_file(program, path)
    if !ok {
        return false
    }

    if string(llvm.GetDataLayoutStr(module)) == "" {
        llvm.SetDataLayout(module, llvm.OrcLLJITGetDataLayoutStr(jit))
    }
    if string(llvm.GetTarget(module)) == "" {
        llvm.SetTarget(module, llvm.OrcLLJITGetTripleString(jit))
    }

    thread_safe_context := llvm.OrcCreateNewThreadSafeContextFromLLVMContext(llvm_context)
    thread_safe_module := llvm.OrcCreateNewThreadSafeModule(module, thread_safe_context)
    llvm.OrcDisposeThreadSafeContext(thread_safe_context)

    // AddLLVMIRModule consumes module even when it returns an error.
    err := llvm.OrcLLJITAddLLVMIRModule(jit, source, thread_safe_module)
    if err != nil {
        report_llvm_error(program, err)
        return false
    }
    return true
}

lazy_compile_failure :: proc "c" (_: i32, _: [^]cstring) -> i32 {
    return 1
}

install_lazy_main :: proc(
    program: string,
    jit: llvm.OrcLLJITRef,
    source: llvm.OrcJITDylibRef,
    lazy_manager: llvm.OrcLazyCallThroughManagerRef,
    stubs_manager: llvm.OrcIndirectStubsManagerRef,
) -> bool {
    main_name := llvm.OrcLLJITMangleAndIntern(jit, "main")
    llvm.OrcRetainSymbolStringPoolEntry(main_name)
    alias := llvm.OrcCSymbolAliasMapPair {
        Name = main_name,
        Entry = {Name = main_name, Flags = {Generic = {.Exported, .Callable}}},
    }

    unit := llvm.OrcLazyReexports(lazy_manager, stubs_manager, source, &alias, 1)
    if unit == nil {
        fmt.eprintf("%s: could not create lazy main reexport\n", program)
        return false
    }
    err := llvm.OrcJITDylibDefine(llvm.OrcLLJITGetMainJITDylib(jit), unit)
    if err != nil {
        llvm.OrcDisposeMaterializationUnit(unit)
        report_llvm_error(program, err)
        return false
    }
    return true
}

cleanup_jit :: proc(
    program: string,
    jit: llvm.OrcLLJITRef,
    lazy_manager: ^llvm.OrcLazyCallThroughManagerRef,
    stubs_manager: ^llvm.OrcIndirectStubsManagerRef,
) {
    if stubs_manager^ != nil {
        llvm.OrcDisposeIndirectStubsManager(stubs_manager^)
    }
    if lazy_manager^ != nil {
        llvm.OrcDisposeLazyCallThroughManager(lazy_manager^)
    }
    if dispose_err := llvm.OrcDisposeLLJIT(jit); dispose_err != nil {
        report_llvm_error(program, dispose_err)
    }
}

run :: proc(options: ^Options, program: string) -> i32 {
    if !initialize_native_target(program) {
        return 1
    }

    jit: llvm.OrcLLJITRef
    err := llvm.OrcCreateLLJIT(&jit, nil)
    if err != nil {
        report_llvm_error(program, err)
        return 1
    }

    lazy_manager: llvm.OrcLazyCallThroughManagerRef
    stubs_manager: llvm.OrcIndirectStubsManagerRef
    defer cleanup_jit(program, jit, &lazy_manager, &stubs_manager)

    session := llvm.OrcLLJITGetExecutionSession(jit)
    source: llvm.OrcJITDylibRef
    err = llvm.OrcExecutionSessionCreateJITDylib(session, &source, "SpeculativeJIT.source")
    if err != nil {
        report_llvm_error(program, err)
        return 1
    }

    process_symbols: llvm.OrcDefinitionGeneratorRef
    err = llvm.OrcCreateDynamicLibrarySearchGeneratorForProcess(
        &process_symbols,
        llvm.OrcLLJITGetGlobalPrefix(jit),
        nil,
        nil,
    )
    if err != nil {
        report_llvm_error(program, err)
        return 1
    }
    llvm.OrcJITDylibAddGenerator(source, process_symbols)

    // LLVM-C has no SpeculationLayer, IRSpeculationAnalysis, or LLJIT task
    // dispatcher control. Keep canonical thread validation, while LLJIT uses its
    // C-API default dispatcher; lazy reexports still defer compilation to call.
    _ = options.num_threads

    triple := llvm.OrcLLJITGetTripleString(jit)
    err = llvm.OrcCreateLocalLazyCallThroughManager(
        triple,
        session,
        llvm.OrcJITTargetAddress(uintptr(rawptr(lazy_compile_failure))),
        &lazy_manager,
    )
    if err != nil {
        report_llvm_error(program, err)
        return 1
    }
    stubs_manager = llvm.OrcCreateLocalIndirectStubsManager(triple)
    if stubs_manager == nil {
        fmt.eprintf("%s: could not create local indirect stubs manager\n", program)
        return 1
    }

    for path in options.input_files {
        if !add_ir_file(program, path, jit, source) {
            return 1
        }
    }
    if !install_lazy_main(program, jit, source, lazy_manager, stubs_manager) {
        return 1
    }

    main_address: llvm.OrcExecutorAddress
    err = llvm.OrcLLJITLookup(jit, &main_address, "main")
    if err != nil {
        report_llvm_error(program, err)
        return 1
    }

    argc := len(options.program_args) + 1
    argv := make([]cstring, argc + 1, context.temp_allocator)
    argv[0] = strings.clone_to_cstring(options.input_files[0], context.temp_allocator)
    for argument, index in options.program_args {
        argv[index + 1] = strings.clone_to_cstring(argument, context.temp_allocator)
    }
    main_fn := transmute(proc "c" (_: i32, _: [^]cstring) -> i32)main_address
    return main_fn(i32(argc), raw_data(argv))
}

program_main :: proc() -> int {
    options, status, should_run := parse_options(os.args)
    defer delete(options.input_files)
    defer delete(options.program_args)
    if should_run {
        status = run(&options, os.args[0])
    }
    return int(status)
}

main :: proc() {
    os.exit(program_main())
}
