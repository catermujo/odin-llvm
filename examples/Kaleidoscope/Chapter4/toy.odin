package main

import "core:c/libc"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

import llvm "../../../"

require_llvm_version :: proc() {
    major, minor, patch: u32
    llvm.GetVersion(&major, &minor, &patch)
    if major != 22 || minor != 1 || patch != 8 {
        fmt.eprintfln("Kaleidoscope requires LLVM 22.1.8, found %d.%d.%d", major, minor, patch)
        os.exit(1)
    }
}

TOK_EOF :: i32(-1)
TOK_DEF :: i32(-2)
TOK_EXTERN :: i32(-3)
TOK_IDENTIFIER :: i32(-4)
TOK_NUMBER :: i32(-5)

OPTIMIZATION_PASSES :: "instcombine,reassociate,gvn,simplifycfg"

identifier: string
number_value: f64
last_char: i32 = ' '
current_token: i32
binop_precedence: [128]int
process_failed: bool

Prototype_Info :: struct {
    arity:   int,
    defined: bool,
}

function_prototypes: map[string]Prototype_Info

Number_Expr :: struct {
    value: f64,
}

Variable_Expr :: struct {
    name: string,
}

Binary_Expr :: struct {
    op:       i32,
    lhs, rhs: ^Expr,
}

Call_Expr :: struct {
    callee: string,
    args:   [dynamic]^Expr,
}

Expr :: union #no_nil {
    Number_Expr,
    Variable_Expr,
    Binary_Expr,
    Call_Expr,
}

Prototype_AST :: struct {
    name: string,
    args: [dynamic]string,
}

Function_AST :: struct {
    proto: Prototype_AST,
    body:  ^Expr,
}

is_ascii_space :: proc(c: i32) -> bool {
    return c == ' ' || c == '\t' || c == '\n' || c == '\v' || c == '\f' || c == '\r'
}

is_ascii_alpha :: proc(c: i32) -> bool {
    return c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z'
}

is_ascii_digit :: proc(c: i32) -> bool {
    return c >= '0' && c <= '9'
}

is_ascii_alnum :: proc(c: i32) -> bool {
    return is_ascii_alpha(c) || is_ascii_digit(c)
}

read_char :: proc() -> i32 {
    return i32(libc.getchar())
}

get_token :: proc() -> i32 {
    for {
        for is_ascii_space(last_char) {
            last_char = read_char()
        }

        if is_ascii_alpha(last_char) {
            chars := make([dynamic]byte, context.temp_allocator)
            for is_ascii_alnum(last_char) {
                append(&chars, byte(last_char))
                last_char = read_char()
            }

            if identifier != "" {
                delete(identifier)
            }
            identifier = strings.clone(string(chars[:]))

            if identifier == "def" {
                return TOK_DEF
            }
            if identifier == "extern" {
                return TOK_EXTERN
            }
            return TOK_IDENTIFIER
        }

        if is_ascii_digit(last_char) || last_char == '.' {
            chars := make([dynamic]byte, context.temp_allocator)
            for is_ascii_digit(last_char) || last_char == '.' {
                append(&chars, byte(last_char))
                last_char = read_char()
            }
            number_value, _ = strconv.parse_f64(string(chars[:]))
            return TOK_NUMBER
        }

        if last_char == '#' {
            for last_char != TOK_EOF && last_char != '\n' && last_char != '\r' {
                last_char = read_char()
            }
            if last_char != TOK_EOF {
                continue
            }
        }

        if last_char == TOK_EOF {
            return TOK_EOF
        }

        this_char := last_char
        last_char = read_char()
        return this_char
    }
}

get_next_token :: proc() -> i32 {
    current_token = get_token()
    return current_token
}

get_token_precedence :: proc() -> int {
    if current_token < 0 || current_token >= len(binop_precedence) {
        return -1
    }

    token_precedence := binop_precedence[current_token]
    if token_precedence <= 0 {
        return -1
    }
    return token_precedence
}

parse_number_expr :: proc() -> (^Expr, string) {
    result := new(Expr, context.temp_allocator)
    result^ = Number_Expr{number_value}
    get_next_token()
    return result, ""
}

parse_paren_expr :: proc() -> (^Expr, string) {
    get_next_token()
    value, err := parse_expression()
    if err != "" {
        return nil, err
    }

    if current_token != ')' {
        return nil, "expected ')'"
    }
    get_next_token()
    return value, ""
}

parse_identifier_expr :: proc() -> (^Expr, string) {
    name := strings.clone(identifier, context.temp_allocator)
    get_next_token()

    if current_token != '(' {
        result := new(Expr, context.temp_allocator)
        result^ = Variable_Expr{name}
        return result, ""
    }

    get_next_token()
    args := make([dynamic]^Expr, context.temp_allocator)
    if current_token != ')' {
        for {
            arg, err := parse_expression()
            if err != "" {
                return nil, err
            }
            append(&args, arg)

            if current_token == ')' {
                break
            }
            if current_token != ',' {
                return nil, "Expected ')' or ',' in argument list"
            }
            get_next_token()
        }
    }

    get_next_token()
    result := new(Expr, context.temp_allocator)
    result^ = Call_Expr{name, args}
    return result, ""
}

parse_primary :: proc() -> (^Expr, string) {
    switch current_token {
    case TOK_IDENTIFIER:
        return parse_identifier_expr()
    case TOK_NUMBER:
        return parse_number_expr()
    case '(':
        return parse_paren_expr()
    }
    return nil, "unknown token when expecting an expression"
}

parse_bin_op_rhs :: proc(expression_precedence: int, lhs: ^Expr) -> (^Expr, string) {
    left := lhs
    for {
        token_precedence := get_token_precedence()
        if token_precedence < expression_precedence {
            return left, ""
        }

        binary_op := current_token
        get_next_token()

        rhs, err := parse_primary()
        if err != "" {
            return nil, err
        }

        next_precedence := get_token_precedence()
        if token_precedence < next_precedence {
            rhs, err = parse_bin_op_rhs(token_precedence + 1, rhs)
            if err != "" {
                return nil, err
            }
        }

        result := new(Expr, context.temp_allocator)
        result^ = Binary_Expr{binary_op, left, rhs}
        left = result
    }
}

parse_expression :: proc() -> (^Expr, string) {
    lhs, err := parse_primary()
    if err != "" {
        return nil, err
    }
    return parse_bin_op_rhs(0, lhs)
}

parse_prototype :: proc() -> (Prototype_AST, string) {
    if current_token != TOK_IDENTIFIER {
        return {}, "Expected function name in prototype"
    }

    function_name := strings.clone(identifier, context.temp_allocator)
    get_next_token()
    if current_token != '(' {
        return {}, "Expected '(' in prototype"
    }

    arg_names := make([dynamic]string, context.temp_allocator)
    for get_next_token() == TOK_IDENTIFIER {
        append(&arg_names, strings.clone(identifier, context.temp_allocator))
    }
    if current_token != ')' {
        return {}, "Expected ')' in prototype"
    }

    get_next_token()
    return Prototype_AST{function_name, arg_names}, ""
}

parse_definition :: proc() -> (Function_AST, string) {
    get_next_token()
    proto, err := parse_prototype()
    if err != "" {
        return {}, err
    }

    body, body_err := parse_expression()
    if body_err != "" {
        return {}, body_err
    }
    return Function_AST{proto, body}, ""
}

parse_top_level_expr :: proc() -> (Function_AST, string) {
    body, err := parse_expression()
    if err != "" {
        return {}, err
    }
    return Function_AST{Prototype_AST{name = "__anon_expr"}, body}, ""
}

parse_extern :: proc() -> (Prototype_AST, string) {
    get_next_token()
    return parse_prototype()
}

report_error :: proc(message: string) {
    fmt.eprintfln("Error: %s", message)
}

report_llvm_error :: proc(err: llvm.ErrorRef) -> bool {
    if err == nil {
        return true
    }

    process_failed = true
    message := llvm.GetErrorMessage(err)
    if message != nil {
        fmt.eprintln(string(message))
        llvm.DisposeErrorMessage(message)
    } else {
        fmt.eprintln("Unknown LLVM error")
    }
    return false
}

validate_prototype :: proc(proto: Prototype_AST, definition: bool) -> string {
    info, ok := function_prototypes[proto.name]
    if !ok {
        return ""
    }
    if info.arity != len(proto.args) {
        return "Function prototype has conflicting arity."
    }
    if definition && info.defined {
        return "Function cannot be redefined."
    }
    return ""
}

remember_prototype :: proc(proto: Prototype_AST, definition: bool) {
    if info, ok := &function_prototypes[proto.name]; ok {
        info.defined = info.defined || definition
        return
    }

    name := strings.clone(proto.name)
    function_prototypes[name] = Prototype_Info{len(proto.args), definition}
}

llvm_context: llvm.ContextRef
llvm_module: llvm.ModuleRef
llvm_builder: llvm.BuilderRef
jit: llvm.OrcLLJITRef
main_jit_dylib: llvm.OrcJITDylibRef
pass_options: llvm.PassBuilderOptionsRef
named_values: map[string]llvm.ValueRef

declare_function :: proc(name: string, arity: int) -> llvm.ValueRef {
    double_type := llvm.DoubleTypeInContext(llvm_context)
    parameter_types := make([]llvm.TypeRef, arity, context.temp_allocator)
    for &parameter_type in parameter_types {
        parameter_type = double_type
    }
    function_type := llvm.FunctionType(double_type, raw_data(parameter_types), u32(arity), llvm.Bool(0))
    return llvm.AddFunction(llvm_module, fmt.ctprint(name), function_type)
}

get_function :: proc(name: string) -> llvm.ValueRef {
    result := llvm.GetNamedFunction(llvm_module, fmt.ctprint(name))
    if result != nil {
        return result
    }

    info, ok := function_prototypes[name]
    if !ok {
        return nil
    }
    return declare_function(name, info.arity)
}

codegen_expr :: proc(expr: ^Expr) -> (llvm.ValueRef, string) {
    switch value in expr^ {
    case Number_Expr:
        return llvm.ConstReal(llvm.DoubleTypeInContext(llvm_context), value.value), ""
    case Variable_Expr:
        result, ok := named_values[value.name]
        if !ok {
            return nil, "Unknown variable name"
        }
        return result, ""
    case Binary_Expr:
        lhs, err := codegen_expr(value.lhs)
        if err != "" {
            return nil, err
        }
        rhs, rhs_err := codegen_expr(value.rhs)
        if rhs_err != "" {
            return nil, rhs_err
        }

        switch value.op {
        case '+':
            return llvm.BuildFAdd(llvm_builder, lhs, rhs, "addtmp"), ""
        case '-':
            return llvm.BuildFSub(llvm_builder, lhs, rhs, "subtmp"), ""
        case '*':
            return llvm.BuildFMul(llvm_builder, lhs, rhs, "multmp"), ""
        case '<':
            comparison := llvm.BuildFCmp(llvm_builder, .ULT, lhs, rhs, "cmptmp")
            return llvm.BuildUIToFP(llvm_builder, comparison, llvm.DoubleTypeInContext(llvm_context), "booltmp"), ""
        }
        return nil, "invalid binary operator"
    case Call_Expr:
        callee := get_function(value.callee)
        if callee == nil {
            return nil, "Unknown function referenced"
        }
        if llvm.CountParams(callee) != u32(len(value.args)) {
            return nil, "Incorrect # arguments passed"
        }

        arg_values := make([dynamic]llvm.ValueRef, context.temp_allocator)
        for arg in value.args {
            arg_value, err := codegen_expr(arg)
            if err != "" {
                return nil, err
            }
            append(&arg_values, arg_value)
        }
        return llvm.BuildCall2(
                llvm_builder,
                llvm.GlobalGetValueType(callee),
                callee,
                raw_data(arg_values[:]),
                u32(len(arg_values)),
                "calltmp",
            ),
            ""
    }
    unreachable()
}

codegen_prototype :: proc(proto: Prototype_AST) -> (llvm.ValueRef, string) {
    result := llvm.GetNamedFunction(llvm_module, fmt.ctprint(proto.name))
    if result == nil {
        result = declare_function(proto.name, len(proto.args))
    } else if llvm.CountParams(result) != u32(len(proto.args)) {
        return nil, "Function prototype has conflicting arity."
    }

    for argument_name, index in proto.args {
        argument := llvm.GetParam(result, u32(index))
        llvm.SetValueName2(argument, fmt.ctprint(argument_name), uint(len(argument_name)))
    }
    return result, ""
}

codegen_function :: proc(function_ast: Function_AST) -> (llvm.ValueRef, string) {
    function_value := get_function(function_ast.proto.name)
    if function_value == nil {
        function_value, _ = codegen_prototype(function_ast.proto)
    }
    if function_value == nil {
        return nil, "Could not create function"
    }
    if llvm.CountParams(function_value) != u32(len(function_ast.proto.args)) {
        return nil, "Function prototype has conflicting arity."
    }
    if llvm.GetFirstBasicBlock(function_value) != nil {
        return nil, "Function cannot be redefined."
    }

    for argument_name, index in function_ast.proto.args {
        argument := llvm.GetParam(function_value, u32(index))
        llvm.SetValueName2(argument, fmt.ctprint(argument_name), uint(len(argument_name)))
    }

    entry := llvm.AppendBasicBlockInContext(llvm_context, function_value, "entry")
    llvm.PositionBuilderAtEnd(llvm_builder, entry)

    clear(&named_values)
    defer clear(&named_values)
    for argument_name, index in function_ast.proto.args {
        named_values[argument_name] = llvm.GetParam(function_value, u32(index))
    }

    return_value, err := codegen_expr(function_ast.body)
    if err != "" {
        llvm.DeleteFunction(function_value)
        return nil, err
    }

    llvm.BuildRet(llvm_builder, return_value)
    if bool(llvm.VerifyFunction(function_value, .ReturnStatus)) {
        llvm.DeleteFunction(function_value)
        return nil, "invalid function"
    }

    pass_err := llvm.RunPassesOnFunction(function_value, OPTIMIZATION_PASSES, nil, pass_options)
    if pass_err != nil {
        message := llvm.GetErrorMessage(pass_err)
        error_text := strings.clone(string(message), context.temp_allocator)
        llvm.DisposeErrorMessage(message)
        llvm.DeleteFunction(function_value)
        return nil, error_text
    }
    return function_value, ""
}

print_value :: proc(prefix: string, value: llvm.ValueRef) {
    text := llvm.PrintValueToString(value)
    if text == nil {
        fmt.eprintfln("%s<unable to print LLVM value>", prefix)
        return
    }
    defer llvm.DisposeMessage(text)
    fmt.eprint(prefix)
    fmt.eprint(string(text))
    fmt.eprintln()
}

dispose_current_module :: proc() {
    if llvm_builder != nil {
        llvm.DisposeBuilder(llvm_builder)
        llvm_builder = nil
    }
    if llvm_module != nil {
        llvm.DisposeModule(llvm_module)
        llvm_module = nil
    }
    if llvm_context != nil {
        llvm.ContextDispose(llvm_context)
        llvm_context = nil
    }
}

initialize_current_module :: proc() {
    llvm_context = llvm.ContextCreate()
    llvm_module = llvm.ModuleCreateWithNameInContext("KaleidoscopeJIT", llvm_context)
    llvm.SetDataLayout(llvm_module, llvm.OrcLLJITGetDataLayoutStr(jit))
    llvm_builder = llvm.CreateBuilderInContext(llvm_context)
    clear(&named_values)
}

take_current_module :: proc() -> llvm.OrcThreadSafeModuleRef {
    llvm.DisposeBuilder(llvm_builder)
    llvm_builder = nil

    thread_safe_context := llvm.OrcCreateNewThreadSafeContextFromLLVMContext(llvm_context)
    llvm_context = nil
    thread_safe_module := llvm.OrcCreateNewThreadSafeModule(llvm_module, thread_safe_context)
    llvm_module = nil
    llvm.OrcDisposeThreadSafeContext(thread_safe_context)
    return thread_safe_module
}

submit_definition :: proc() -> bool {
    thread_safe_module := take_current_module()
    err := llvm.OrcLLJITAddLLVMIRModule(jit, main_jit_dylib, thread_safe_module)
    initialize_current_module()
    return report_llvm_error(err)
}

execute_top_level_expression :: proc() -> bool {
    tracker := llvm.OrcJITDylibCreateResourceTracker(main_jit_dylib)
    if tracker == nil {
        process_failed = true
        report_error("Could not create ORC resource tracker.")
        return false
    }
    defer {
        _ = report_llvm_error(llvm.OrcResourceTrackerRemove(tracker))
        llvm.OrcReleaseResourceTracker(tracker)
    }

    thread_safe_module := take_current_module()
    add_err := llvm.OrcLLJITAddLLVMIRModuleWithRT(jit, tracker, thread_safe_module)
    initialize_current_module()
    if !report_llvm_error(add_err) {
        return false
    }

    address: llvm.OrcExecutorAddress
    if !report_llvm_error(llvm.OrcLLJITLookup(jit, &address, "__anon_expr")) {
        return false
    }

    entry := transmute(proc "c" () -> f64)address
    fmt.eprintfln("Evaluated to %.6f", entry())
    return true
}

handle_definition :: proc() {
    function_ast, err := parse_definition()
    if err != "" {
        report_error(err)
        get_next_token()
        return
    }
    if validation_err := validate_prototype(function_ast.proto, true); validation_err != "" {
        report_error(validation_err)
        return
    }

    function_value, codegen_err := codegen_function(function_ast)
    if codegen_err != "" {
        report_error(codegen_err)
        return
    }
    print_value("Read function definition:", function_value)
    if submit_definition() {
        remember_prototype(function_ast.proto, true)
    }
}

handle_extern :: proc() {
    proto, err := parse_extern()
    if err != "" {
        report_error(err)
        get_next_token()
        return
    }
    if validation_err := validate_prototype(proto, false); validation_err != "" {
        report_error(validation_err)
        return
    }

    function_value, codegen_err := codegen_prototype(proto)
    if codegen_err != "" {
        report_error(codegen_err)
        return
    }
    print_value("Read extern: ", function_value)
    remember_prototype(proto, false)
}

handle_top_level_expression :: proc() {
    function_ast, err := parse_top_level_expr()
    if err != "" {
        report_error(err)
        get_next_token()
        return
    }

    _, codegen_err := codegen_function(function_ast)
    if codegen_err != "" {
        report_error(codegen_err)
        return
    }
    _ = execute_top_level_expression()
}

main_loop :: proc() {
    for {
        fmt.eprint("ready> ")
        switch current_token {
        case TOK_EOF:
            return
        case ';':
            get_next_token()
        case TOK_DEF:
            handle_definition()
        case TOK_EXTERN:
            handle_extern()
        case:
            handle_top_level_expression()
        }
        if process_failed {
            return
        }
        free_all(context.temp_allocator)
    }
}

@(export)
putchard :: proc "c" (value: f64) -> f64 {
    _ = libc.fputc(i32(i64(value)), libc.stderr)
    return 0
}

@(export)
printd :: proc "c" (value: f64) -> f64 {
    _ = libc.fprintf(libc.stderr, "%.6f\n", value)
    return 0
}

register_process_symbols :: proc() -> bool {
    names := [2]cstring{"putchard", "printd"}
    addresses := [2]rawptr{rawptr(putchard), rawptr(printd)}
    symbols: [2]llvm.OrcCSymbolMapPair
    flags: llvm.JITSymbolFlags = {
        Generic = {.Exported, .Weak, .Callable},
    }
    for name, index in names {
        symbols[index] = {
            Name = llvm.OrcLLJITMangleAndIntern(jit, name),
            Sym = {Address = llvm.OrcExecutorAddress(uintptr(addresses[index])), Flags = flags},
        }
        if symbols[index].Name == nil {
            for release_index in 0 ..< index {
                llvm.OrcReleaseSymbolStringPoolEntry(symbols[release_index].Name)
            }
            process_failed = true
            report_error("Could not intern process symbol.")
            return false
        }
    }

    unit := llvm.OrcAbsoluteSymbols(&symbols[0], len(symbols))
    if unit == nil {
        process_failed = true
        report_error("Could not create process symbol materialization unit.")
        return false
    }
    if err := llvm.OrcJITDylibDefine(main_jit_dylib, unit); err != nil {
        llvm.OrcDisposeMaterializationUnit(unit)
        return report_llvm_error(err)
    }

    generator: llvm.OrcDefinitionGeneratorRef
    if !report_llvm_error(
        llvm.OrcCreateDynamicLibrarySearchGeneratorForProcess(&generator, llvm.OrcLLJITGetGlobalPrefix(jit), nil, nil),
    ) {
        return false
    }
    llvm.OrcJITDylibAddGenerator(main_jit_dylib, generator)
    return true
}

dispose_function_prototypes :: proc() {
    for name in function_prototypes {
        delete(name)
    }
    delete(function_prototypes)
}

run :: proc() {
    named_values = make(map[string]llvm.ValueRef)
    function_prototypes = make(map[string]Prototype_Info)
    defer {
        dispose_current_module()
        if pass_options != nil {
            llvm.DisposePassBuilderOptions(pass_options)
        }
        if jit != nil {
            _ = report_llvm_error(llvm.OrcDisposeLLJIT(jit))
        }
        dispose_function_prototypes()
        delete(named_values)
        if identifier != "" {
            delete(identifier)
        }
        free_all(context.temp_allocator)
    }

    if bool(llvm.InitializeNativeTarget()) {
        process_failed = true
        report_error("native LLVM target unavailable")
        return
    }
    if bool(llvm.InitializeNativeAsmPrinter()) {
        process_failed = true
        report_error("native LLVM asm printer unavailable")
        return
    }
    if bool(llvm.InitializeNativeAsmParser()) {
        process_failed = true
        report_error("native LLVM asm parser unavailable")
        return
    }

    fmt.eprint("ready> ")
    get_next_token()

    builder := llvm.OrcCreateLLJITBuilder()
    if builder == nil {
        process_failed = true
        report_error("Could not create LLJIT builder.")
        return
    }
    if !report_llvm_error(llvm.OrcCreateLLJIT(&jit, builder)) {
        return
    }
    main_jit_dylib = llvm.OrcLLJITGetMainJITDylib(jit)
    if !register_process_symbols() {
        return
    }

    pass_options = llvm.CreatePassBuilderOptions()
    llvm.PassBuilderOptionsSetDebugLogging(pass_options, llvm.Bool(ODIN_DEBUG))
    initialize_current_module()
    main_loop()
}

main :: proc() {
    require_llvm_version()

    binop_precedence['<'] = 10
    binop_precedence['+'] = 20
    binop_precedence['-'] = 20
    binop_precedence['*'] = 40

    run()
    if process_failed {
        os.exit(1)
    }
}
