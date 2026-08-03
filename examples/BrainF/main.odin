package main

import "core:c"
import "core:c/libc"
import "core:fmt"
import "core:os"

import llvm "../.."

TAPE_SIZE :: 65536

Options :: struct {
    input_filename:  string,
    output_filename: string,
    jit:             bool,
    array_bounds:    bool,
}

Token_Kind :: enum {
    Read,
    Write,
    Move,
    Change,
    Loop_Start,
    Loop_End,
}

Source_Location :: struct {
    line:   int,
    column: int,
}

Token :: struct {
    kind:     Token_Kind,
    amount:   int,
    location: Source_Location,
}

Compiler :: struct {
    ctx:          llvm.ContextRef,
    module:       llvm.ModuleRef,
    builder:      llvm.BuilderRef,
    brainf:       llvm.ValueRef,
    brainf_type:  llvm.TypeRef,
    getchar:      llvm.ValueRef,
    getchar_type: llvm.TypeRef,
    putchar:      llvm.ValueRef,
    putchar_type: llvm.TypeRef,
    i8_type:      llvm.TypeRef,
    i32_type:     llvm.TypeRef,
    pointer_type: llvm.TypeRef,
    tape:         llvm.ValueRef,
    tape_end:     llvm.ValueRef,
    head_slot:    llvm.ValueRef,
    end_block:    llvm.BasicBlockRef,
    error_block:  llvm.BasicBlockRef,
    array_bounds: bool,
}

print_usage :: proc() {
    fmt.println("usage: BrainF [-abc] [-jit] [-o filename] <input brainf>")
}

print_version :: proc() {
    major, minor, patch: u32
    llvm.GetVersion(&major, &minor, &patch)
    fmt.printfln("LLVM version %d.%d.%d", major, minor, patch)
}

parse_bool_option :: proc(arg, name: string) -> (value, matched, valid: bool) {
    option_value := ""
    short_value_index := len(name) + 2
    long_value_index := len(name) + 3
    if len(arg) >= short_value_index &&
       arg[0] == '-' &&
       arg[1:short_value_index - 1] == name &&
       arg[short_value_index - 1] == '=' {
        option_value = arg[short_value_index:]
    } else if len(arg) >= long_value_index &&
       arg[:2] == "--" &&
       arg[2:long_value_index - 1] == name &&
       arg[long_value_index - 1] == '=' {
        option_value = arg[long_value_index:]
    } else {
        return false, false, false
    }

    switch option_value {
    case "", "true", "TRUE", "True", "1":
        return true, true, true
    case "false", "FALSE", "False", "0":
        return false, true, true
    }
    return false, true, false
}

parse_options :: proc(args: []string) -> (options: Options, status: int) {
    parse_flags := true
    for i := 0; i < len(args); i += 1 {
        arg := args[i]
        if parse_flags && arg == "--" {
            parse_flags = false
            continue
        }

        if parse_flags {
            switch arg {
            case "-h", "-help", "--help":
                print_usage()
                return options, 2
            case "-version", "--version":
                print_version()
                return options, 2
            case "-jit", "--jit":
                options.jit = true
                continue
            case "-abc", "--abc":
                options.array_bounds = true
                continue
            case "-o", "--o":
                if i + 1 >= len(args) {
                    fmt.eprintln("Error: option '-o' requires a filename.")
                    return options, 1
                }
                i += 1
                options.output_filename = args[i]
                continue
            }

            value, matched, valid := parse_bool_option(arg, "jit")
            if matched {
                if !valid {
                    fmt.eprintfln("Error: invalid boolean value in option '%s'.", arg)
                    return options, 1
                }
                options.jit = value
                continue
            }
            value, matched, valid = parse_bool_option(arg, "abc")
            if matched {
                if !valid {
                    fmt.eprintfln("Error: invalid boolean value in option '%s'.", arg)
                    return options, 1
                }
                options.array_bounds = value
                continue
            }
            if len(arg) >= 3 && arg[:3] == "-o=" {
                options.output_filename = arg[3:]
                continue
            }
            if len(arg) >= 4 && arg[:4] == "--o=" {
                options.output_filename = arg[4:]
                continue
            }
            if len(arg) > 1 && arg[0] == '-' && arg != "-" {
                fmt.eprintfln("Error: unknown option '%s'.", arg)
                return options, 1
            }
        }

        if options.input_filename != "" {
            fmt.eprintln("Error: only one input filename may be specified.")
            return options, 1
        }
        options.input_filename = arg
    }

    if options.input_filename == "" {
        fmt.eprintln(
            "Error: You must specify the filename of the program to be compiled. Use --help to see the options.",
        )
        return options, 1
    }
    return options, 0
}

append_token :: proc(tokens: ^[dynamic]Token, kind: Token_Kind, amount: int, location: Source_Location) {
    if (kind == .Move || kind == .Change) && len(tokens^) > 0 {
        last := &tokens^[len(tokens^) - 1]
        if last.kind == kind {
            last.amount += amount
            return
        }
    }
    append(tokens, Token{kind = kind, amount = amount, location = location})
}

tokenize :: proc(source: []byte) -> (tokens: [dynamic]Token, ok: bool) {
    tokens = make([dynamic]Token, context.allocator)
    open_brackets := make([dynamic]int, context.temp_allocator)
    line, column := 1, 1

    for character in source {
        location := Source_Location{line, column}
        switch character {
        case ',':
            append_token(&tokens, .Read, 0, location)
        case '.':
            append_token(&tokens, .Write, 0, location)
        case '<':
            append_token(&tokens, .Move, -1, location)
        case '>':
            append_token(&tokens, .Move, 1, location)
        case '-':
            append_token(&tokens, .Change, -1, location)
        case '+':
            append_token(&tokens, .Change, 1, location)
        case '[':
            append_token(&tokens, .Loop_Start, 0, location)
            append(&open_brackets, len(tokens) - 1)
        case ']':
            if len(open_brackets) == 0 {
                fmt.eprintfln("Error: extra ']' at line %d, column %d.", line, column)
                return tokens, false
            }
            append_token(&tokens, .Loop_End, 0, location)
            pop(&open_brackets)
        }

        if character == '\n' {
            line += 1
            column = 1
        } else {
            column += 1
        }
    }

    if len(open_brackets) != 0 {
        open_token := tokens[open_brackets[len(open_brackets) - 1]]
        fmt.eprintfln(
            "Error: missing ']' for '[' at line %d, column %d.",
            open_token.location.line,
            open_token.location.column,
        )
        return tokens, false
    }
    return tokens, true
}

const_i32 :: proc(compiler: ^Compiler, value: int) -> llvm.ValueRef {
    return llvm.ConstInt(compiler.i32_type, u64(i64(value)), 1)
}

const_i8 :: proc(compiler: ^Compiler, value: int) -> llvm.ValueRef {
    return llvm.ConstInt(compiler.i8_type, u64(i64(value)), 1)
}

load_head :: proc(compiler: ^Compiler) -> llvm.ValueRef {
    return llvm.BuildLoad2(compiler.builder, compiler.pointer_type, compiler.head_slot, "head")
}

initialize_compiler :: proc(array_bounds: bool) -> Compiler {
    compiler := Compiler {
        array_bounds = array_bounds,
    }
    compiler.ctx = llvm.ContextCreate()
    compiler.module = llvm.ModuleCreateWithNameInContext("BrainF", compiler.ctx)
    compiler.builder = llvm.CreateBuilderInContext(compiler.ctx)
    compiler.i8_type = llvm.Int8TypeInContext(compiler.ctx)
    compiler.i32_type = llvm.Int32TypeInContext(compiler.ctx)
    compiler.pointer_type = llvm.PointerTypeInContext(compiler.ctx, 0)
    void_type := llvm.VoidTypeInContext(compiler.ctx)

    compiler.getchar_type = llvm.FunctionType(compiler.i32_type, nil, 0, 0)
    compiler.getchar = llvm.AddFunction(compiler.module, "getchar", compiler.getchar_type)
    putchar_parameters := [1]llvm.TypeRef{compiler.i32_type}
    compiler.putchar_type = llvm.FunctionType(compiler.i32_type, &putchar_parameters[0], 1, 0)
    compiler.putchar = llvm.AddFunction(compiler.module, "putchar", compiler.putchar_type)

    compiler.brainf_type = llvm.FunctionType(void_type, nil, 0, 0)
    compiler.brainf = llvm.AddFunction(compiler.module, "brainf", compiler.brainf_type)
    entry_block := llvm.AppendBasicBlockInContext(compiler.ctx, compiler.brainf, "brainf")
    compiler.end_block = llvm.AppendBasicBlockInContext(compiler.ctx, compiler.brainf, "brainf.end")
    if array_bounds {
        compiler.error_block = llvm.AppendBasicBlockInContext(compiler.ctx, compiler.brainf, "brainf.aberror")
    }

    llvm.PositionBuilderAtEnd(compiler.builder, entry_block)
    memory_size := const_i32(&compiler, TAPE_SIZE)
    compiler.tape = llvm.BuildArrayMalloc(compiler.builder, compiler.i8_type, memory_size, "arr")
    _ = llvm.BuildMemSet(compiler.builder, compiler.tape, const_i8(&compiler, 0), memory_size, 1)
    compiler.head_slot = llvm.BuildAlloca(compiler.builder, compiler.pointer_type, "head.addr")
    initial_offset := const_i32(&compiler, TAPE_SIZE / 2)
    initial_head := llvm.BuildGEP2(compiler.builder, compiler.i8_type, compiler.tape, &initial_offset, 1, "head")
    _ = llvm.BuildStore(compiler.builder, initial_head, compiler.head_slot)
    if array_bounds {
        end_offset := const_i32(&compiler, TAPE_SIZE)
        compiler.tape_end = llvm.BuildGEP2(compiler.builder, compiler.i8_type, compiler.tape, &end_offset, 1, "arrmax")
    }

    llvm.PositionBuilderAtEnd(compiler.builder, compiler.end_block)
    _ = llvm.BuildFree(compiler.builder, compiler.tape)
    _ = llvm.BuildRetVoid(compiler.builder)

    if array_bounds {
        puts_parameters := [1]llvm.TypeRef{compiler.pointer_type}
        puts_type := llvm.FunctionType(compiler.i32_type, &puts_parameters[0], 1, 0)
        puts_function := llvm.AddFunction(compiler.module, "puts", puts_type)
        llvm.PositionBuilderAtEnd(compiler.builder, compiler.error_block)
        message := llvm.BuildGlobalStringPtr(compiler.builder, "Error: The head has left the tape.", "aberrormsg")
        puts_args := [1]llvm.ValueRef{message}
        _ = llvm.BuildCall2(compiler.builder, puts_type, puts_function, &puts_args[0], 1, "")
        _ = llvm.BuildBr(compiler.builder, compiler.end_block)
    }

    llvm.PositionBuilderAtEnd(compiler.builder, entry_block)
    return compiler
}

emit_move :: proc(compiler: ^Compiler, amount: int) {
    head := load_head(compiler)
    offset := const_i32(compiler, amount)
    next_head := llvm.BuildGEP2(compiler.builder, compiler.i8_type, head, &offset, 1, "head")

    if compiler.array_bounds {
        past_end := llvm.BuildICmp(compiler.builder, .UGE, next_head, compiler.tape_end, "test")
        before_start := llvm.BuildICmp(compiler.builder, .ULT, next_head, compiler.tape, "test")
        out_of_bounds := llvm.BuildOr(compiler.builder, past_end, before_start, "test")
        continue_block := llvm.AppendBasicBlockInContext(compiler.ctx, compiler.brainf, "brainf")
        _ = llvm.BuildCondBr(compiler.builder, out_of_bounds, compiler.error_block, continue_block)
        llvm.PositionBuilderAtEnd(compiler.builder, continue_block)
    }
    _ = llvm.BuildStore(compiler.builder, next_head, compiler.head_slot)
}

emit_change :: proc(compiler: ^Compiler, amount: int) {
    head := load_head(compiler)
    old_value := llvm.BuildLoad2(compiler.builder, compiler.i8_type, head, "tape")
    new_value := llvm.BuildAdd(compiler.builder, old_value, const_i8(compiler, amount), "tape")
    _ = llvm.BuildStore(compiler.builder, new_value, head)
}

emit_read :: proc(compiler: ^Compiler) {
    head := load_head(compiler)
    input := llvm.BuildCall2(compiler.builder, compiler.getchar_type, compiler.getchar, nil, 0, "tape")
    byte_value := llvm.BuildTrunc(compiler.builder, input, compiler.i8_type, "tape")
    _ = llvm.BuildStore(compiler.builder, byte_value, head)
}

emit_write :: proc(compiler: ^Compiler) {
    head := load_head(compiler)
    byte_value := llvm.BuildLoad2(compiler.builder, compiler.i8_type, head, "tape")
    character := llvm.BuildSExt(compiler.builder, byte_value, compiler.i32_type, "tape")
    args := [1]llvm.ValueRef{character}
    _ = llvm.BuildCall2(compiler.builder, compiler.putchar_type, compiler.putchar, &args[0], 1, "")
}

emit_sequence :: proc(compiler: ^Compiler, tokens: []Token, index: ^int) {
    for index^ < len(tokens) {
        token := tokens[index^]
        index^ += 1
        switch token.kind {
        case .Read:
            emit_read(compiler)
        case .Write:
            emit_write(compiler)
        case .Move:
            emit_move(compiler, token.amount)
        case .Change:
            emit_change(compiler, token.amount)
        case .Loop_Start:
            test_block := llvm.AppendBasicBlockInContext(compiler.ctx, compiler.brainf, "brainf.loop.test")
            body_block := llvm.AppendBasicBlockInContext(compiler.ctx, compiler.brainf, "brainf.loop.body")
            after_block := llvm.AppendBasicBlockInContext(compiler.ctx, compiler.brainf, "brainf.loop.end")
            _ = llvm.BuildBr(compiler.builder, test_block)

            llvm.PositionBuilderAtEnd(compiler.builder, test_block)
            head := load_head(compiler)
            value := llvm.BuildLoad2(compiler.builder, compiler.i8_type, head, "tape")
            condition := llvm.BuildICmp(compiler.builder, .NE, value, const_i8(compiler, 0), "test")
            _ = llvm.BuildCondBr(compiler.builder, condition, body_block, after_block)

            llvm.PositionBuilderAtEnd(compiler.builder, body_block)
            emit_sequence(compiler, tokens, index)
            _ = llvm.BuildBr(compiler.builder, test_block)
            llvm.PositionBuilderAtEnd(compiler.builder, after_block)
        case .Loop_End:
            return
        }
    }
}

add_main_function :: proc(compiler: ^Compiler) {
    parameters := [2]llvm.TypeRef{compiler.i32_type, compiler.pointer_type}
    main_type := llvm.FunctionType(compiler.i32_type, &parameters[0], 2, 0)
    main_function := llvm.AddFunction(compiler.module, "main", main_type)
    llvm.SetValueName2(llvm.GetParam(main_function, 0), "argc", 4)
    llvm.SetValueName2(llvm.GetParam(main_function, 1), "argv", 4)
    entry := llvm.AppendBasicBlockInContext(compiler.ctx, main_function, "main.0")
    llvm.PositionBuilderAtEnd(compiler.builder, entry)
    _ = llvm.BuildCall2(compiler.builder, compiler.brainf_type, compiler.brainf, nil, 0, "")
    _ = llvm.BuildRet(compiler.builder, const_i32(compiler, 0))
}

compile_program :: proc(tokens: []Token, array_bounds: bool) -> Compiler {
    compiler := initialize_compiler(array_bounds)
    index := 0
    emit_sequence(&compiler, tokens, &index)
    _ = llvm.BuildBr(compiler.builder, compiler.end_block)
    add_main_function(&compiler)
    llvm.DisposeBuilder(compiler.builder)
    compiler.builder = nil
    return compiler
}

verify_module :: proc(module: llvm.ModuleRef) -> bool {
    message: cstring
    failed := bool(llvm.VerifyModule(module, .ReturnStatus, &message))
    if message != nil {
        defer llvm.DisposeMessage(message)
    }
    if failed {
        fmt.eprintln("Error: module failed verification. This shouldn't happen.")
        if message != nil {
            fmt.eprintln(message)
        }
        return false
    }
    return true
}

run_jit :: proc(compiler: ^Compiler) -> bool {
    if bool(llvm.InitializeNativeTarget()) || bool(llvm.InitializeNativeAsmPrinter()) {
        fmt.eprintln("Error: native LLVM target initialization failed.")
        return false
    }
    llvm.LinkInMCJIT()

    fmt.println("------- Running JIT -------")
    options: llvm.MCJITCompilerOptions
    llvm.InitializeMCJITCompilerOptions(&options, c.size_t(size_of(options)))
    engine: llvm.ExecutionEngineRef
    error_message: cstring
    failed := bool(
        llvm.CreateMCJITCompilerForModule(
            &engine,
            compiler.module,
            &options,
            c.size_t(size_of(options)),
            &error_message,
        ),
    )
    compiler.module = nil
    if failed {
        fmt.eprint("Error: execution engine creation failed")
        if error_message != nil {
            fmt.eprintfln(": %s", error_message)
            llvm.DisposeMessage(error_message)
        } else {
            fmt.eprintln(".")
        }
        return false
    }
    defer llvm.DisposeExecutionEngine(engine)

    result := llvm.RunFunction(engine, compiler.brainf, 0, nil)
    if result == nil {
        fmt.eprintln("Error: JIT execution failed.")
        return false
    }
    llvm.DisposeGenericValue(result)
    _ = libc.fflush(libc.stdout)
    return true
}

write_bitcode :: proc(module: llvm.ModuleRef, filename: string) -> bool {
    // LLVM treats path "-" as stdout and switches it to binary mode on Windows.
    result := llvm.WriteBitcodeToFile(module, fmt.ctprint(filename))
    if result != 0 {
        fmt.eprintfln("Error: could not write bitcode to '%s'.", filename)
        return false
    }
    return true
}

read_source :: proc(filename: string) -> ([]byte, os.Error) {
    if filename == "-" {
        return os.read_entire_file(os.stdin, context.allocator)
    }
    return os.read_entire_file(filename, context.allocator)
}

run :: proc() -> int {
    options, status := parse_options(os.args[1:])
    if status == 2 {
        return 0
    }
    if status != 0 {
        return 1
    }

    source, read_error := read_source(options.input_filename)
    if read_error != nil {
        fmt.eprintfln("Error: could not read '%s': %v", options.input_filename, read_error)
        return 1
    }
    defer delete(source)

    tokens, tokens_ok := tokenize(source)
    defer delete(tokens)
    if !tokens_ok {
        return 1
    }

    compiler := compile_program(tokens[:], options.array_bounds)
    defer {
        if compiler.module != nil {
            llvm.DisposeModule(compiler.module)
        }
        llvm.ContextDispose(compiler.ctx)
    }
    if !verify_module(compiler.module) {
        return 1
    }

    if options.jit {
        if !run_jit(&compiler) {
            return 1
        }
        return 0
    }

    output_filename := options.output_filename
    owned_output_filename := ""
    defer {
        if owned_output_filename != "" {
            delete(owned_output_filename)
        }
    }
    if output_filename == "" {
        base := options.input_filename
        if base == "-" {
            base = "a"
        }
        owned_output_filename = fmt.aprintf("%s.bc", base)
        output_filename = owned_output_filename
    }
    if !write_bitcode(compiler.module, output_filename) {
        return 1
    }
    return 0
}

main :: proc() {
    libc.exit(i32(run()))
}
