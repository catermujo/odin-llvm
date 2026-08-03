// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
package main

import "base:runtime"
import "core:c"
import "core:c/libc"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"

import llvm "../../../.."

Token :: enum rune {
    eof        = -1,
    def        = -2,
    extern     = -3,
    identifier = -4,
    number     = -5,
    if_kw      = -6,
    then_kw    = -7,
    else_kw    = -8,
    for_kw     = -9,
    in_kw      = -10,
    binary     = -11,
    unary      = -12,
    var_kw     = -13,
}

EOF_RUNE :: rune(Token.eof)

identifier: string
number_value: f64
current_token: Token
process_failed: bool

read_rune :: proc() -> rune {
    return rune(libc.getchar())
}

is_space :: proc(value: rune) -> bool {
    return bool(libc.isspace(c.int(value)))
}

is_alpha :: proc(value: rune) -> bool {
    return bool(libc.isalpha(c.int(value)))
}

is_alnum :: proc(value: rune) -> bool {
    return bool(libc.isalnum(c.int(value)))
}

is_digit :: proc(value: rune) -> bool {
    return bool(libc.isdigit(c.int(value)))
}

get_token :: proc() -> Token {
    @(static) last_char: rune = ' '
    for is_space(last_char) {
        last_char = read_rune()
    }

    if is_alpha(last_char) {
        builder := strings.builder_make(context.temp_allocator)
        for is_alnum(last_char) {
            strings.write_rune(&builder, last_char)
            last_char = read_rune()
        }
        if identifier != "" {
            delete(identifier)
        }
        identifier = strings.clone(strings.to_string(builder))
        switch identifier {
        case "def":
            return .def
        case "extern":
            return .extern
        case "if":
            return .if_kw
        case "then":
            return .then_kw
        case "else":
            return .else_kw
        case "for":
            return .for_kw
        case "in":
            return .in_kw
        case "binary":
            return .binary
        case "unary":
            return .unary
        case "var":
            return .var_kw
        }
        return .identifier
    }

    if is_digit(last_char) || last_char == '.' {
        builder := strings.builder_make(context.temp_allocator)
        for is_digit(last_char) || last_char == '.' {
            strings.write_rune(&builder, last_char)
            last_char = read_rune()
        }
        number_value, _ = strconv.parse_f64(strings.to_string(builder))
        return .number
    }

    if last_char == '#' {
        for last_char != EOF_RUNE && last_char != '\n' && last_char != '\r' {
            last_char = read_rune()
        }
        if last_char != EOF_RUNE {
            return get_token()
        }
    }

    if last_char == EOF_RUNE {
        return .eof
    }
    this_char := last_char
    last_char = read_rune()
    return Token(this_char)
}

get_next_token :: proc() -> Token {
    current_token = get_token()
    return current_token
}

Expr_Kind :: enum {
    Number,
    Variable,
    Unary,
    Binary,
    Call,
    If,
    For,
    Var,
}

Var_Binding :: struct {
    name: string,
    init: ^Expr,
}

Expr :: struct {
    kind:      Expr_Kind,
    number:    f64,
    name:      string,
    op:        rune,
    operand:   ^Expr,
    lhs:       ^Expr,
    rhs:       ^Expr,
    args:      [dynamic]^Expr,
    condition: ^Expr,
    then_expr: ^Expr,
    else_expr: ^Expr,
    start:     ^Expr,
    end:       ^Expr,
    step:      ^Expr,
    body:      ^Expr,
    bindings:  [dynamic]Var_Binding,
}

Prototype :: struct {
    name:        string,
    args:        [dynamic]string,
    is_operator: bool,
    op:          rune,
    precedence:  int,
}

Function_AST :: struct {
    proto: Prototype,
    body:  ^Expr,
}

Frontend_Error :: Maybe(string)

new_expr :: proc(kind: Expr_Kind) -> ^Expr {
    expr := new(Expr, context.temp_allocator)
    expr.kind = kind
    return expr
}

operator_name :: proc(prefix: string, op: rune, allocator: mem.Allocator) -> string {
    builder := strings.builder_make(allocator)
    strings.write_string(&builder, prefix)
    strings.write_rune(&builder, op)
    return strings.to_string(builder)
}

parse_number_expr :: proc() -> (^Expr, Frontend_Error) {
    result := new_expr(.Number)
    result.number = number_value
    get_next_token()
    return result, nil
}

parse_paren_expr :: proc() -> (result: ^Expr, err: Frontend_Error) {
    get_next_token()
    result = parse_expression() or_return
    if rune(current_token) != ')' {
        return nil, "expected ')'"
    }
    get_next_token()
    return
}

parse_identifier_expr :: proc() -> (result: ^Expr, err: Frontend_Error) {
    name := strings.clone(identifier, context.temp_allocator)
    get_next_token()
    if rune(current_token) != '(' {
        result = new_expr(.Variable)
        result.name = name
        return
    }

    get_next_token()
    args := make([dynamic]^Expr, context.temp_allocator)
    if rune(current_token) != ')' {
        for {
            arg := parse_expression() or_return
            append(&args, arg)
            if rune(current_token) == ')' {
                break
            }
            if rune(current_token) != ',' {
                return nil, "expected ')' or ',' in argument list"
            }
            get_next_token()
        }
    }
    get_next_token()
    result = new_expr(.Call)
    result.name = name
    result.args = args
    return
}

parse_if_expr :: proc() -> (result: ^Expr, err: Frontend_Error) {
    get_next_token()
    condition := parse_expression() or_return
    if current_token != .then_kw {
        return nil, "expected then"
    }
    get_next_token()
    then_expr := parse_expression() or_return
    if current_token != .else_kw {
        return nil, "expected else"
    }
    get_next_token()
    else_expr := parse_expression() or_return

    result = new_expr(.If)
    result.condition = condition
    result.then_expr = then_expr
    result.else_expr = else_expr
    return
}

parse_for_expr :: proc() -> (result: ^Expr, err: Frontend_Error) {
    get_next_token()
    if current_token != .identifier {
        return nil, "expected identifier after for"
    }
    name := strings.clone(identifier, context.temp_allocator)
    get_next_token()
    if rune(current_token) != '=' {
        return nil, "expected '=' after for"
    }
    get_next_token()
    start := parse_expression() or_return
    if rune(current_token) != ',' {
        return nil, "expected ',' after for start value"
    }
    get_next_token()
    end := parse_expression() or_return

    step: ^Expr
    if rune(current_token) == ',' {
        get_next_token()
        step = parse_expression() or_return
    }
    if current_token != .in_kw {
        return nil, "expected 'in' after for"
    }
    get_next_token()
    body := parse_expression() or_return

    result = new_expr(.For)
    result.name = name
    result.start = start
    result.end = end
    result.step = step
    result.body = body
    return
}

parse_var_expr :: proc() -> (result: ^Expr, err: Frontend_Error) {
    get_next_token()
    if current_token != .identifier {
        return nil, "expected identifier after var"
    }

    bindings := make([dynamic]Var_Binding, context.temp_allocator)
    for {
        binding := Var_Binding {
            name = strings.clone(identifier, context.temp_allocator),
        }
        get_next_token()
        if rune(current_token) == '=' {
            get_next_token()
            binding.init = parse_expression() or_return
        }
        append(&bindings, binding)
        if rune(current_token) != ',' {
            break
        }
        get_next_token()
        if current_token != .identifier {
            return nil, "expected identifier list after var"
        }
    }

    if current_token != .in_kw {
        return nil, "expected 'in' keyword after 'var'"
    }
    get_next_token()
    body := parse_expression() or_return

    result = new_expr(.Var)
    result.bindings = bindings
    result.body = body
    return
}

parse_primary :: proc() -> (^Expr, Frontend_Error) {
    #partial switch current_token {
    case .identifier:
        return parse_identifier_expr()
    case .number:
        return parse_number_expr()
    case .if_kw:
        return parse_if_expr()
    case .for_kw:
        return parse_for_expr()
    case .var_kw:
        return parse_var_expr()
    case:
        if rune(current_token) == '(' {
            return parse_paren_expr()
        }
    }
    return nil, "unknown token when expecting an expression"
}

is_ascii_token :: proc(token: Token) -> bool {
    value := rune(token)
    return value >= 0 && value <= 127
}

parse_unary :: proc() -> (result: ^Expr, err: Frontend_Error) {
    token := rune(current_token)
    if !is_ascii_token(current_token) || token == '(' || token == ')' || token == ',' || token == ';' {
        return parse_primary()
    }
    op := token
    get_next_token()
    operand := parse_unary() or_return
    result = new_expr(.Unary)
    result.op = op
    result.operand = operand
    return
}

binary_precedence: map[rune]int

get_token_precedence :: proc() -> int {
    if !is_ascii_token(current_token) {
        return -1
    }
    precedence, ok := binary_precedence[rune(current_token)]
    if !ok || precedence <= 0 {
        return -1
    }
    return precedence
}

parse_binary_rhs :: proc(expression_precedence: int, lhs: ^Expr) -> (result: ^Expr, err: Frontend_Error) {
    lhs := lhs
    for {
        token_precedence := get_token_precedence()
        if token_precedence < expression_precedence {
            return lhs, nil
        }

        op := rune(current_token)
        get_next_token()
        rhs := parse_unary() or_return
        next_precedence := get_token_precedence()
        if token_precedence < next_precedence || op == '=' && token_precedence == next_precedence {
            rhs_precedence := token_precedence + 1
            if op == '=' {
                rhs_precedence = token_precedence
            }
            rhs = parse_binary_rhs(rhs_precedence, rhs) or_return
        }

        parent := new_expr(.Binary)
        parent.op = op
        parent.lhs = lhs
        parent.rhs = rhs
        lhs = parent
    }
}

parse_expression :: proc() -> (result: ^Expr, err: Frontend_Error) {
    lhs := parse_unary() or_return
    return parse_binary_rhs(0, lhs)
}

parse_prototype :: proc() -> (result: Prototype, err: Frontend_Error) {
    kind := 0
    precedence := 30
    op: rune

    #partial switch current_token {
    case .identifier:
        result.name = strings.clone(identifier, context.temp_allocator)
        get_next_token()
    case .unary:
        kind = 1
        get_next_token()
        if !is_ascii_token(current_token) {
            return {}, "expected unary operator"
        }
        op = rune(current_token)
        result.name = operator_name("unary", op, context.temp_allocator)
        get_next_token()
    case .binary:
        kind = 2
        get_next_token()
        if !is_ascii_token(current_token) {
            return {}, "expected binary operator"
        }
        op = rune(current_token)
        result.name = operator_name("binary", op, context.temp_allocator)
        get_next_token()
        if current_token == .number {
            if number_value < 1 || number_value > 100 {
                return {}, "invalid precedence: must be 1..100"
            }
            precedence = int(number_value)
            get_next_token()
        }
    case:
        return {}, "expected function name in prototype"
    }

    if rune(current_token) != '(' {
        return {}, "expected '(' in prototype"
    }
    result.args = make([dynamic]string, context.temp_allocator)
    for get_next_token() == .identifier {
        append(&result.args, strings.clone(identifier, context.temp_allocator))
    }
    if rune(current_token) != ')' {
        return {}, "expected ')' in prototype"
    }
    get_next_token()

    if kind != 0 && len(result.args) != kind {
        return {}, "invalid number of operands for operator"
    }
    result.is_operator = kind != 0
    result.op = op
    result.precedence = precedence
    return result, nil
}

parse_definition :: proc() -> (result: ^Function_AST, err: Frontend_Error) {
    get_next_token()
    proto := parse_prototype() or_return
    body := parse_expression() or_return
    result = new(Function_AST, context.temp_allocator)
    result.proto = proto
    result.body = body
    return
}

parse_extern :: proc() -> (Prototype, Frontend_Error) {
    get_next_token()
    return parse_prototype()
}

parse_top_level_expr :: proc() -> (result: ^Function_AST, err: Frontend_Error) {
    body := parse_expression() or_return
    result = new(Function_AST, context.temp_allocator)
    result.proto.name = "__anon_expr"
    result.proto.args = make([dynamic]string, context.temp_allocator)
    result.body = body
    return
}

clone_prototype :: proc(source: Prototype, allocator: mem.Allocator) -> Prototype {
    result := source
    result.name = strings.clone(source.name, allocator)
    result.args = make([dynamic]string, 0, len(source.args), allocator)
    for arg in source.args {
        append(&result.args, strings.clone(arg, allocator))
    }
    return result
}

destroy_prototype :: proc(proto: ^Prototype, allocator: mem.Allocator) {
    delete(proto.name, allocator)
    for arg in proto.args {
        delete(arg, allocator)
    }
    delete(proto.args)
    proto^ = {}
}

Prototype_Record :: struct {
    proto:   Prototype,
    defined: bool,
}

function_prototypes: map[string]Prototype_Record
named_values: map[string]llvm.ValueRef

the_jit: ^Kaleidoscope_JIT
the_context: llvm.ContextRef
the_module: llvm.ModuleRef
builder: llvm.BuilderRef

validate_prototype :: proc(proto: Prototype, definition: bool) -> Frontend_Error {
    record, ok := function_prototypes[proto.name]
    if !ok {
        return nil
    }
    if len(record.proto.args) != len(proto.args) {
        return "function prototype has conflicting arity"
    }
    if definition && record.defined {
        return "function cannot be redefined"
    }
    return nil
}

remember_prototype :: proc(proto: Prototype, definition: bool) {
    if record, ok := &function_prototypes[proto.name]; ok {
        record.defined = record.defined || definition
    } else {
        owned := clone_prototype(proto, context.allocator)
        function_prototypes[owned.name] = {
            proto   = owned,
            defined = definition,
        }
    }
    if definition && proto.is_operator && len(proto.args) == 2 {
        binary_precedence[proto.op] = proto.precedence
    }
}

dispose_prototypes :: proc() {
    for _, record in function_prototypes {
        proto := record.proto
        destroy_prototype(&proto, context.allocator)
    }
    delete(function_prototypes)
}

declare_function :: proc(proto: Prototype) -> llvm.ValueRef {
    double_type := llvm.DoubleTypeInContext(the_context)
    parameter_types := make([]llvm.TypeRef, len(proto.args), context.temp_allocator)
    for &parameter_type in parameter_types {
        parameter_type = double_type
    }
    function_type := llvm.FunctionType(double_type, raw_data(parameter_types), u32(len(parameter_types)), llvm.Bool(0))
    return llvm.AddFunction(the_module, fmt.ctprint(proto.name), function_type)
}

codegen_prototype :: proc(proto: Prototype) -> (result: llvm.ValueRef, err: Frontend_Error) {
    result = llvm.GetNamedFunction(the_module, fmt.ctprint(proto.name))
    if result == nil {
        result = declare_function(proto)
    } else if llvm.CountParams(result) != u32(len(proto.args)) {
        return nil, "function prototype has conflicting arity"
    }
    for arg_name, index in proto.args {
        arg := llvm.GetParam(result, u32(index))
        name := fmt.ctprint(arg_name)
        llvm.SetValueName2(arg, name, c.size_t(len(arg_name)))
    }
    return result, nil
}

get_function :: proc(name: string) -> llvm.ValueRef {
    if fn := llvm.GetNamedFunction(the_module, fmt.ctprint(name)); fn != nil {
        return fn
    }
    record, ok := function_prototypes[name]
    if !ok {
        return nil
    }
    fn, _ := codegen_prototype(record.proto)
    return fn
}

create_entry_block_alloca :: proc(fn: llvm.ValueRef, name: string) -> llvm.ValueRef {
    temporary_builder := llvm.CreateBuilderInContext(the_context)
    defer llvm.DisposeBuilder(temporary_builder)
    entry := llvm.GetEntryBasicBlock(fn)
    if first_instruction := llvm.GetFirstInstruction(entry); first_instruction != nil {
        llvm.PositionBuilderBefore(temporary_builder, first_instruction)
    } else {
        llvm.PositionBuilderAtEnd(temporary_builder, entry)
    }
    return llvm.BuildAlloca(temporary_builder, llvm.DoubleTypeInContext(the_context), fmt.ctprint(name))
}

codegen_expr :: proc(expr: ^Expr) -> (llvm.ValueRef, Frontend_Error) {
    switch expr.kind {
    case .Number:
        return llvm.ConstReal(llvm.DoubleTypeInContext(the_context), expr.number), nil
    case .Variable:
        value, ok := named_values[expr.name]
        if !ok {
            return nil, "unknown variable name"
        }
        return llvm.BuildLoad2(builder, llvm.DoubleTypeInContext(the_context), value, fmt.ctprint(expr.name)), nil
    case .Unary:
        return codegen_unary(expr)
    case .Binary:
        return codegen_binary(expr)
    case .Call:
        return codegen_call(expr)
    case .If:
        return codegen_if(expr)
    case .For:
        return codegen_for(expr)
    case .Var:
        return codegen_var(expr)
    }
    unreachable()
}

codegen_unary :: proc(expr: ^Expr) -> (result: llvm.ValueRef, err: Frontend_Error) {
    operand := codegen_expr(expr.operand) or_return
    name := operator_name("unary", expr.op, context.temp_allocator)
    fn := get_function(name)
    if fn == nil {
        return nil, "unknown unary operator"
    }
    args := [1]llvm.ValueRef{operand}
    return llvm.BuildCall2(builder, llvm.GlobalGetValueType(fn), fn, &args[0], 1, "unop"), nil
}

codegen_binary :: proc(expr: ^Expr) -> (result: llvm.ValueRef, err: Frontend_Error) {
    if expr.op == '=' {
        if expr.lhs.kind != .Variable {
            return nil, "destination of '=' must be a variable"
        }
        value := codegen_expr(expr.rhs) or_return
        variable, ok := named_values[expr.lhs.name]
        if !ok {
            return nil, "unknown variable name"
        }
        llvm.BuildStore(builder, value, variable)
        return value, nil
    }

    lhs := codegen_expr(expr.lhs) or_return
    rhs := codegen_expr(expr.rhs) or_return
    switch expr.op {
    case '+':
        return llvm.BuildFAdd(builder, lhs, rhs, "addtmp"), nil
    case '-':
        return llvm.BuildFSub(builder, lhs, rhs, "subtmp"), nil
    case '*':
        return llvm.BuildFMul(builder, lhs, rhs, "multmp"), nil
    case '<':
        comparison := llvm.BuildFCmp(builder, .ULT, lhs, rhs, "cmptmp")
        return llvm.BuildUIToFP(builder, comparison, llvm.DoubleTypeInContext(the_context), "booltmp"), nil
    }

    name := operator_name("binary", expr.op, context.temp_allocator)
    fn := get_function(name)
    if fn == nil {
        return nil, "unknown binary operator"
    }
    args := [2]llvm.ValueRef{lhs, rhs}
    return llvm.BuildCall2(builder, llvm.GlobalGetValueType(fn), fn, &args[0], 2, "binop"), nil
}

codegen_call :: proc(expr: ^Expr) -> (result: llvm.ValueRef, err: Frontend_Error) {
    fn := get_function(expr.name)
    if fn == nil {
        return nil, "unknown function referenced"
    }
    if llvm.CountParams(fn) != u32(len(expr.args)) {
        return nil, "incorrect number of arguments passed"
    }
    args := make([dynamic]llvm.ValueRef, 0, len(expr.args), context.temp_allocator)
    for arg in expr.args {
        append(&args, codegen_expr(arg) or_return)
    }
    return llvm.BuildCall2(builder, llvm.GlobalGetValueType(fn), fn, raw_data(args[:]), u32(len(args)), "calltmp"), nil
}

codegen_if :: proc(expr: ^Expr) -> (result: llvm.ValueRef, err: Frontend_Error) {
    condition := codegen_expr(expr.condition) or_return
    condition = llvm.BuildFCmp(
        builder,
        .ONE,
        condition,
        llvm.ConstReal(llvm.DoubleTypeInContext(the_context), 0),
        "ifcond",
    )

    fn := llvm.GetBasicBlockParent(llvm.GetInsertBlock(builder))
    then_block := llvm.AppendBasicBlockInContext(the_context, fn, "then")
    else_block := llvm.AppendBasicBlockInContext(the_context, fn, "else")
    merge_block := llvm.AppendBasicBlockInContext(the_context, fn, "ifcont")
    llvm.BuildCondBr(builder, condition, then_block, else_block)

    llvm.PositionBuilderAtEnd(builder, then_block)
    then_value := codegen_expr(expr.then_expr) or_return
    llvm.BuildBr(builder, merge_block)
    then_block = llvm.GetInsertBlock(builder)

    llvm.PositionBuilderAtEnd(builder, else_block)
    else_value := codegen_expr(expr.else_expr) or_return
    llvm.BuildBr(builder, merge_block)
    else_block = llvm.GetInsertBlock(builder)

    llvm.PositionBuilderAtEnd(builder, merge_block)
    phi := llvm.BuildPhi(builder, llvm.DoubleTypeInContext(the_context), "iftmp")
    values := [2]llvm.ValueRef{then_value, else_value}
    blocks := [2]llvm.BasicBlockRef{then_block, else_block}
    llvm.AddIncoming(phi, &values[0], &blocks[0], 2)
    return phi, nil
}

codegen_for :: proc(expr: ^Expr) -> (result: llvm.ValueRef, err: Frontend_Error) {
    fn := llvm.GetBasicBlockParent(llvm.GetInsertBlock(builder))
    variable := create_entry_block_alloca(fn, expr.name)
    start := codegen_expr(expr.start) or_return
    llvm.BuildStore(builder, start, variable)

    loop_block := llvm.AppendBasicBlockInContext(the_context, fn, "loop")
    llvm.BuildBr(builder, loop_block)
    llvm.PositionBuilderAtEnd(builder, loop_block)

    old_value, had_old_value := named_values[expr.name]
    named_values[expr.name] = variable
    if _, body_err := codegen_expr(expr.body); body_err != nil {
        return nil, body_err
    }

    step := llvm.ConstReal(llvm.DoubleTypeInContext(the_context), 1)
    if expr.step != nil {
        step = codegen_expr(expr.step) or_return
    }
    end_condition := codegen_expr(expr.end) or_return
    current_value := llvm.BuildLoad2(builder, llvm.DoubleTypeInContext(the_context), variable, fmt.ctprint(expr.name))
    next_value := llvm.BuildFAdd(builder, current_value, step, "nextvar")
    llvm.BuildStore(builder, next_value, variable)

    end_condition = llvm.BuildFCmp(
        builder,
        .ONE,
        end_condition,
        llvm.ConstReal(llvm.DoubleTypeInContext(the_context), 0),
        "loopcond",
    )
    after_block := llvm.AppendBasicBlockInContext(the_context, fn, "afterloop")
    llvm.BuildCondBr(builder, end_condition, loop_block, after_block)
    llvm.PositionBuilderAtEnd(builder, after_block)

    if had_old_value {
        named_values[expr.name] = old_value
    } else {
        delete_key(&named_values, expr.name)
    }
    return llvm.ConstNull(llvm.DoubleTypeInContext(the_context)), nil
}

Old_Binding :: struct {
    value:   llvm.ValueRef,
    existed: bool,
}

codegen_var :: proc(expr: ^Expr) -> (result: llvm.ValueRef, err: Frontend_Error) {
    old_bindings := make([dynamic]Old_Binding, 0, len(expr.bindings), context.temp_allocator)
    fn := llvm.GetBasicBlockParent(llvm.GetInsertBlock(builder))
    processed := 0
    defer {
        for offset in 0 ..< processed {
            index := processed - offset - 1
            binding := expr.bindings[index]
            old := old_bindings[index]
            if old.existed {
                named_values[binding.name] = old.value
            } else {
                delete_key(&named_values, binding.name)
            }
        }
    }

    for binding in expr.bindings {
        initial_value := llvm.ConstReal(llvm.DoubleTypeInContext(the_context), 0)
        if binding.init != nil {
            initial_value = codegen_expr(binding.init) or_return
        }
        variable := create_entry_block_alloca(fn, binding.name)
        llvm.BuildStore(builder, initial_value, variable)
        old_value, existed := named_values[binding.name]
        append(&old_bindings, Old_Binding{old_value, existed})
        named_values[binding.name] = variable
        processed += 1
    }

    result = codegen_expr(expr.body) or_return
    return result, nil
}

codegen_function :: proc(fn_ast: ^Function_AST) -> (result: llvm.ValueRef, err: Frontend_Error) {
    result = codegen_prototype(fn_ast.proto) or_return
    if llvm.GetFirstBasicBlock(result) != nil {
        return nil, "function cannot be redefined"
    }

    entry := llvm.AppendBasicBlockInContext(the_context, result, "entry")
    llvm.PositionBuilderAtEnd(builder, entry)
    clear(&named_values)
    for arg_name, index in fn_ast.proto.args {
        arg := llvm.GetParam(result, u32(index))
        variable := create_entry_block_alloca(result, arg_name)
        llvm.BuildStore(builder, arg, variable)
        named_values[arg_name] = variable
    }

    return_value, body_err := codegen_expr(fn_ast.body)
    if body_err != nil {
        llvm.DeleteFunction(result)
        return nil, body_err
    }
    llvm.BuildRet(builder, return_value)
    if bool(llvm.VerifyFunction(result, .ReturnStatus)) {
        llvm.DeleteFunction(result)
        return nil, "generated invalid function"
    }
    return result, nil
}

dispose_current_module :: proc() {
    if builder != nil {
        llvm.DisposeBuilder(builder)
        builder = nil
    }
    if the_module != nil {
        llvm.DisposeModule(the_module)
        the_module = nil
    }
    if the_context != nil {
        llvm.ContextDispose(the_context)
        the_context = nil
    }
}

take_current_module :: proc() -> llvm.OrcThreadSafeModuleRef {
    llvm.DisposeBuilder(builder)
    builder = nil
    thread_safe_context := llvm.OrcCreateNewThreadSafeContextFromLLVMContext(the_context)
    the_context = nil
    thread_safe_module := llvm.OrcCreateNewThreadSafeModule(the_module, thread_safe_context)
    the_module = nil
    llvm.OrcDisposeThreadSafeContext(thread_safe_context)
    return thread_safe_module
}

initialize_module :: proc() {
    the_context = llvm.ContextCreate()
    the_module = llvm.ModuleCreateWithNameInContext("KaleidoscopeJIT", the_context)
    llvm.SetDataLayout(the_module, jit_data_layout(the_jit))
    builder = llvm.CreateBuilderInContext(the_context)
    clear(&named_values)
}

report_frontend_error :: proc(err: Frontend_Error) -> bool {
    if message, failed := err.?; failed {
        fmt.eprintf("Error: %s\n", message)
        return false
    }
    return true
}

report_parse_error :: proc(err: Frontend_Error) -> bool {
    if report_frontend_error(err) {
        return true
    }
    get_next_token()
    return false
}

report_llvm_error :: proc(err: llvm.ErrorRef) -> bool {
    if err == nil {
        return true
    }
    process_failed = true
    message := llvm.GetErrorMessage(err)
    defer llvm.DisposeErrorMessage(message)
    fmt.eprintf("Error: %s\n", message)
    return false
}

handle_definition :: proc() {
    fn_ast, parse_err := parse_definition()
    if !report_parse_error(parse_err) {
        return
    }
    if !report_frontend_error(validate_prototype(fn_ast.proto, true)) {
        return
    }
    fn, codegen_err := codegen_function(fn_ast)
    if !report_frontend_error(codegen_err) {
        return
    }
    fmt.eprint("Read function definition:")
    llvm.DumpValue(fn)
    tsm := take_current_module()
    err := jit_add_module(the_jit, tsm)
    initialize_module()
    if report_llvm_error(err) {
        remember_prototype(fn_ast.proto, true)
    }
}

handle_extern :: proc() {
    proto, parse_err := parse_extern()
    if !report_parse_error(parse_err) {
        return
    }
    if !report_frontend_error(validate_prototype(proto, false)) {
        return
    }
    fn, codegen_err := codegen_prototype(proto)
    if !report_frontend_error(codegen_err) {
        return
    }
    fmt.eprint("Read extern: ")
    llvm.DumpValue(fn)
    remember_prototype(proto, false)
}

handle_top_level_expression :: proc() {
    fn_ast, parse_err := parse_top_level_expr()
    if !report_parse_error(parse_err) {
        return
    }
    if _, codegen_err := codegen_function(fn_ast); !report_frontend_error(codegen_err) {
        return
    }

    tracker := jit_create_resource_tracker(the_jit)
    if tracker == nil {
        process_failed = true
        fmt.eprintln("Error: could not create ORC resource tracker")
        return
    }
    defer {
        _ = report_llvm_error(llvm.OrcResourceTrackerRemove(tracker))
        llvm.OrcReleaseResourceTracker(tracker)
    }

    tsm := take_current_module()
    err := jit_add_module(the_jit, tsm, tracker)
    initialize_module()
    if !report_llvm_error(err) {
        return
    }

    address: llvm.OrcExecutorAddress
    if !report_llvm_error(jit_lookup(the_jit, "__anon_expr", &address)) {
        return
    }
    entry := transmute(proc "c" () -> f64)address
    fmt.eprintf("Evaluated to %.6f\n", entry())
}

@(export)
putchard :: proc "c" (value: f64) -> f64 {
    context = runtime.default_context()
    buffer := [1]byte{byte(value)}
    _, _ = os.write(os.stderr, buffer[:])
    return 0
}

@(export)
printd :: proc "c" (value: f64) -> f64 {
    context = runtime.default_context()
    fmt.eprintf("%.6f\n", value)
    return 0
}

run :: proc() {
    binary_precedence = make(map[rune]int)
    function_prototypes = make(map[string]Prototype_Record)
    named_values = make(map[string]llvm.ValueRef)
    binary_precedence['='] = 2
    binary_precedence['<'] = 10
    binary_precedence['+'] = 20
    binary_precedence['-'] = 20
    binary_precedence['*'] = 40

    defer {
        dispose_current_module()
        dispose_prototypes()
        delete(named_values)
        delete(binary_precedence)
        if identifier != "" {
            delete(identifier)
        }
        if the_jit != nil {
            _ = report_llvm_error(jit_dispose(the_jit))
        }
        llvm.Shutdown()
    }

    major, minor, patch: u32
    llvm.GetVersion(&major, &minor, &patch)
    if major != 22 {
        process_failed = true
        fmt.eprintf("Kaleidoscope requires LLVM 22.x, found %d.%d.%d\n", major, minor, patch)
        return
    }
    if bool(llvm.InitializeNativeTarget()) {
        process_failed = true
        fmt.eprintln("native LLVM target unavailable")
        return
    }
    if bool(llvm.InitializeNativeAsmPrinter()) {
        process_failed = true
        fmt.eprintln("native LLVM asm printer unavailable")
        return
    }
    if bool(llvm.InitializeNativeAsmParser()) {
        process_failed = true
        fmt.eprintln("native LLVM asm parser unavailable")
        return
    }

    jit_err: llvm.ErrorRef
    the_jit, jit_err = jit_create()
    if !report_llvm_error(jit_err) {
        return
    }
    initialize_module()

    fmt.eprint("ready> ")
    get_next_token()
    for current_token != .eof {
        #partial switch current_token {
        case .def:
            handle_definition()
        case .extern:
            handle_extern()
        case:
            if rune(current_token) == ';' {
                get_next_token()
            } else {
                handle_top_level_expression()
            }
        }
        free_all(context.temp_allocator)
        fmt.eprint("ready> ")
    }
}

main :: proc() {
    run()
    if process_failed {
        os.exit(1)
    }
}
