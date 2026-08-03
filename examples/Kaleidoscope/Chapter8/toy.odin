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
TOK_IF :: i32(-6)
TOK_THEN :: i32(-7)
TOK_ELSE :: i32(-8)
TOK_FOR :: i32(-9)
TOK_IN :: i32(-10)
TOK_BINARY :: i32(-11)
TOK_UNARY :: i32(-12)
TOK_VAR :: i32(-13)

identifier: string
number_value: f64
last_char: i32 = ' '
current_token: i32
binop_precedence: [128]int
process_failed: bool
source_error: bool

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

Unary_Expr :: struct {
    opcode:  i32,
    operand: ^Expr,
}

Binary_Expr :: struct {
    op:       i32,
    lhs, rhs: ^Expr,
}

Call_Expr :: struct {
    callee: string,
    args:   [dynamic]^Expr,
}

If_Expr :: struct {
    condition, then_expr, else_expr: ^Expr,
}

For_Expr :: struct {
    var_name:               string,
    start, end, step, body: ^Expr,
}

Var_Binding :: struct {
    name: string,
    init: ^Expr,
}

Var_Expr :: struct {
    bindings: [dynamic]Var_Binding,
    body:     ^Expr,
}

Expr :: union #no_nil {
    Number_Expr,
    Variable_Expr,
    Unary_Expr,
    Binary_Expr,
    Call_Expr,
    If_Expr,
    For_Expr,
    Var_Expr,
}

Prototype_AST :: struct {
    name:        string,
    args:        [dynamic]string,
    is_operator: bool,
    precedence:  int,
}

Function_AST :: struct {
    proto: Prototype_AST,
    body:  ^Expr,
}

prototype_is_unary :: proc(proto: Prototype_AST) -> bool {
    return proto.is_operator && len(proto.args) == 1
}

prototype_is_binary :: proc(proto: Prototype_AST) -> bool {
    return proto.is_operator && len(proto.args) == 2
}

prototype_operator :: proc(proto: Prototype_AST) -> i32 {
    assert(prototype_is_unary(proto) || prototype_is_binary(proto))
    return i32(proto.name[len(proto.name) - 1])
}

operator_name :: proc(prefix: string, op: i32) -> string {
    return fmt.tprintf("%s%c", prefix, rune(op))
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
            if identifier == "if" {
                return TOK_IF
            }
            if identifier == "then" {
                return TOK_THEN
            }
            if identifier == "else" {
                return TOK_ELSE
            }
            if identifier == "for" {
                return TOK_FOR
            }
            if identifier == "in" {
                return TOK_IN
            }
            if identifier == "binary" {
                return TOK_BINARY
            }
            if identifier == "unary" {
                return TOK_UNARY
            }
            if identifier == "var" {
                return TOK_VAR
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

parse_if_expr :: proc() -> (^Expr, string) {
    get_next_token()
    condition, err := parse_expression()
    if err != "" {
        return nil, err
    }

    if current_token != TOK_THEN {
        return nil, "expected then"
    }
    get_next_token()
    then_expr, then_err := parse_expression()
    if then_err != "" {
        return nil, then_err
    }

    if current_token != TOK_ELSE {
        return nil, "expected else"
    }
    get_next_token()
    else_expr, else_err := parse_expression()
    if else_err != "" {
        return nil, else_err
    }

    result := new(Expr, context.temp_allocator)
    result^ = If_Expr{condition, then_expr, else_expr}
    return result, ""
}

parse_for_expr :: proc() -> (^Expr, string) {
    get_next_token()
    if current_token != TOK_IDENTIFIER {
        return nil, "expected identifier after for"
    }

    var_name := strings.clone(identifier, context.temp_allocator)
    get_next_token()
    if current_token != '=' {
        return nil, "expected '=' after for"
    }
    get_next_token()

    start, err := parse_expression()
    if err != "" {
        return nil, err
    }
    if current_token != ',' {
        return nil, "expected ',' after for start value"
    }
    get_next_token()

    end, end_err := parse_expression()
    if end_err != "" {
        return nil, end_err
    }

    step: ^Expr
    if current_token == ',' {
        get_next_token()
        step, err = parse_expression()
        if err != "" {
            return nil, err
        }
    }

    if current_token != TOK_IN {
        return nil, "expected 'in' after for"
    }
    get_next_token()
    body, body_err := parse_expression()
    if body_err != "" {
        return nil, body_err
    }

    result := new(Expr, context.temp_allocator)
    result^ = For_Expr{var_name, start, end, step, body}
    return result, ""
}

parse_var_expr :: proc() -> (^Expr, string) {
    get_next_token()
    if current_token != TOK_IDENTIFIER {
        return nil, "expected identifier after var"
    }

    bindings := make([dynamic]Var_Binding, context.temp_allocator)
    for {
        name := strings.clone(identifier, context.temp_allocator)
        get_next_token()

        init: ^Expr
        if current_token == '=' {
            get_next_token()
            parsed_init, init_err := parse_expression()
            if init_err != "" {
                return nil, init_err
            }
            init = parsed_init
        }
        append(&bindings, Var_Binding{name, init})

        if current_token != ',' {
            break
        }
        get_next_token()
        if current_token != TOK_IDENTIFIER {
            return nil, "expected identifier list after var"
        }
    }

    if current_token != TOK_IN {
        return nil, "expected 'in' keyword after 'var'"
    }
    get_next_token()
    body, body_err := parse_expression()
    if body_err != "" {
        return nil, body_err
    }

    result := new(Expr, context.temp_allocator)
    result^ = Var_Expr{bindings, body}
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
    case TOK_IF:
        return parse_if_expr()
    case TOK_FOR:
        return parse_for_expr()
    case TOK_VAR:
        return parse_var_expr()
    }
    return nil, "unknown token when expecting an expression"
}

parse_unary :: proc() -> (^Expr, string) {
    if current_token < 0 ||
       current_token >= len(binop_precedence) ||
       current_token == '(' ||
       current_token == ')' ||
       current_token == ',' ||
       current_token == ';' {
        return parse_primary()
    }

    opcode := current_token
    get_next_token()
    operand, err := parse_unary()
    if err != "" {
        return nil, err
    }

    result := new(Expr, context.temp_allocator)
    result^ = Unary_Expr{opcode, operand}
    return result, ""
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

        rhs, err := parse_unary()
        if err != "" {
            return nil, err
        }

        next_precedence := get_token_precedence()
        if token_precedence < next_precedence || binary_op == '=' && token_precedence == next_precedence {
            rhs_precedence := token_precedence + 1
            if binary_op == '=' {
                rhs_precedence = token_precedence
            }
            rhs, err = parse_bin_op_rhs(rhs_precedence, rhs)
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
    lhs, err := parse_unary()
    if err != "" {
        return nil, err
    }
    return parse_bin_op_rhs(0, lhs)
}

parse_prototype :: proc() -> (Prototype_AST, string) {
    function_name: string
    kind := 0
    binary_precedence := 30

    switch current_token {
    case TOK_IDENTIFIER:
        function_name = strings.clone(identifier, context.temp_allocator)
        get_next_token()
    case TOK_UNARY:
        get_next_token()
        if current_token < 0 || current_token >= len(binop_precedence) {
            return {}, "Expected unary operator"
        }
        function_name = operator_name("unary", current_token)
        kind = 1
        get_next_token()
    case TOK_BINARY:
        get_next_token()
        if current_token < 0 || current_token >= len(binop_precedence) {
            return {}, "Expected binary operator"
        }
        function_name = operator_name("binary", current_token)
        kind = 2
        get_next_token()

        if current_token == TOK_NUMBER {
            if number_value < 1 || number_value > 100 {
                return {}, "Invalid precedence: must be 1..100"
            }
            binary_precedence = int(number_value)
            get_next_token()
        }
    case:
        return {}, "Expected function name in prototype"
    }

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
    if kind != 0 && len(arg_names) != kind {
        return {}, "Invalid number of operands for operator"
    }
    return Prototype_AST{function_name, arg_names, kind != 0, binary_precedence}, ""
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
    source_error = true
    fmt.eprintfln("Error: %s", message)
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
target_machine: llvm.TargetMachineRef
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

restore_named_value :: proc(name: string, old_value: llvm.ValueRef, existed: bool) {
    if existed {
        named_values[name] = old_value
    } else {
        delete_key(&named_values, name)
    }
}

create_entry_block_alloca :: proc(function_value: llvm.ValueRef, name: string) -> llvm.ValueRef {
    temporary_builder := llvm.CreateBuilderInContext(llvm_context)
    defer llvm.DisposeBuilder(temporary_builder)

    entry := llvm.GetEntryBasicBlock(function_value)
    llvm.PositionBuilderBeforeDbgRecords(temporary_builder, entry, llvm.GetFirstInstruction(entry))
    return llvm.BuildAlloca(temporary_builder, llvm.DoubleTypeInContext(llvm_context), fmt.ctprint(name))
}

codegen_expr :: proc(expr: ^Expr) -> (llvm.ValueRef, string) {
    switch value in expr^ {
    case Number_Expr:
        return llvm.ConstReal(llvm.DoubleTypeInContext(llvm_context), value.value), ""
    case Variable_Expr:
        variable, ok := named_values[value.name]
        if !ok {
            return nil, "Unknown variable name"
        }
        return llvm.BuildLoad2(
                llvm_builder,
                llvm.DoubleTypeInContext(llvm_context),
                variable,
                fmt.ctprint(value.name),
            ),
            ""
    case Unary_Expr:
        operand, err := codegen_expr(value.operand)
        if err != "" {
            return nil, err
        }

        callee := get_function(operator_name("unary", value.opcode))
        if callee == nil {
            return nil, "Unknown unary operator"
        }
        args := [1]llvm.ValueRef{operand}
        return llvm.BuildCall2(llvm_builder, llvm.GlobalGetValueType(callee), callee, &args[0], 1, "unop"), ""
    case Binary_Expr:
        if value.op == '=' {
            variable_name: string
            #partial switch lhs in value.lhs^ {
            case Variable_Expr:
                variable_name = lhs.name
            case:
                return nil, "destination of '=' must be a variable"
            }

            assigned_value, err := codegen_expr(value.rhs)
            if err != "" {
                return nil, err
            }
            variable, ok := named_values[variable_name]
            if !ok {
                return nil, "Unknown variable name"
            }
            llvm.BuildStore(llvm_builder, assigned_value, variable)
            return assigned_value, ""
        }

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

        callee := get_function(operator_name("binary", value.op))
        if callee == nil {
            return nil, "Unknown binary operator"
        }
        args := [2]llvm.ValueRef{lhs, rhs}
        return llvm.BuildCall2(llvm_builder, llvm.GlobalGetValueType(callee), callee, &args[0], 2, "binop"), ""
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
    case If_Expr:
        condition, err := codegen_expr(value.condition)
        if err != "" {
            return nil, err
        }
        condition = llvm.BuildFCmp(
            llvm_builder,
            .ONE,
            condition,
            llvm.ConstReal(llvm.DoubleTypeInContext(llvm_context), 0),
            "ifcond",
        )

        function_value := llvm.GetBasicBlockParent(llvm.GetInsertBlock(llvm_builder))
        then_block := llvm.AppendBasicBlockInContext(llvm_context, function_value, "then")
        else_block := llvm.AppendBasicBlockInContext(llvm_context, function_value, "else")
        merge_block := llvm.AppendBasicBlockInContext(llvm_context, function_value, "ifcont")
        llvm.BuildCondBr(llvm_builder, condition, then_block, else_block)

        llvm.PositionBuilderAtEnd(llvm_builder, then_block)
        then_value, then_err := codegen_expr(value.then_expr)
        if then_err != "" {
            return nil, then_err
        }
        llvm.BuildBr(llvm_builder, merge_block)
        then_block = llvm.GetInsertBlock(llvm_builder)

        llvm.PositionBuilderAtEnd(llvm_builder, else_block)
        else_value, else_err := codegen_expr(value.else_expr)
        if else_err != "" {
            return nil, else_err
        }
        llvm.BuildBr(llvm_builder, merge_block)
        else_block = llvm.GetInsertBlock(llvm_builder)

        llvm.PositionBuilderAtEnd(llvm_builder, merge_block)
        phi := llvm.BuildPhi(llvm_builder, llvm.DoubleTypeInContext(llvm_context), "iftmp")
        incoming_values := [2]llvm.ValueRef{then_value, else_value}
        incoming_blocks := [2]llvm.BasicBlockRef{then_block, else_block}
        llvm.AddIncoming(phi, &incoming_values[0], &incoming_blocks[0], 2)
        return phi, ""
    case For_Expr:
        function_value := llvm.GetBasicBlockParent(llvm.GetInsertBlock(llvm_builder))
        variable := create_entry_block_alloca(function_value, value.var_name)

        start_value, err := codegen_expr(value.start)
        if err != "" {
            return nil, err
        }
        llvm.BuildStore(llvm_builder, start_value, variable)

        loop_block := llvm.AppendBasicBlockInContext(llvm_context, function_value, "loop")
        llvm.BuildBr(llvm_builder, loop_block)
        llvm.PositionBuilderAtEnd(llvm_builder, loop_block)

        old_value, existed := named_values[value.var_name]
        named_values[value.var_name] = variable
        defer restore_named_value(value.var_name, old_value, existed)

        _, body_err := codegen_expr(value.body)
        if body_err != "" {
            return nil, body_err
        }

        step_value := llvm.ConstReal(llvm.DoubleTypeInContext(llvm_context), 1)
        if value.step != nil {
            step_value, err = codegen_expr(value.step)
            if err != "" {
                return nil, err
            }
        }

        end_condition, end_err := codegen_expr(value.end)
        if end_err != "" {
            return nil, end_err
        }
        current_value := llvm.BuildLoad2(
            llvm_builder,
            llvm.DoubleTypeInContext(llvm_context),
            variable,
            fmt.ctprint(value.var_name),
        )
        next_variable := llvm.BuildFAdd(llvm_builder, current_value, step_value, "nextvar")
        llvm.BuildStore(llvm_builder, next_variable, variable)

        end_condition = llvm.BuildFCmp(
            llvm_builder,
            .ONE,
            end_condition,
            llvm.ConstReal(llvm.DoubleTypeInContext(llvm_context), 0),
            "loopcond",
        )

        after_block := llvm.AppendBasicBlockInContext(llvm_context, function_value, "afterloop")
        llvm.BuildCondBr(llvm_builder, end_condition, loop_block, after_block)
        llvm.PositionBuilderAtEnd(llvm_builder, after_block)
        return llvm.ConstNull(llvm.DoubleTypeInContext(llvm_context)), ""
    case Var_Expr:
        Binding_Backup :: struct {
            value:   llvm.ValueRef,
            existed: bool,
        }

        backups := make([]Binding_Backup, len(value.bindings), context.temp_allocator)
        processed := 0
        defer {
            for offset in 0 ..< processed {
                index := processed - offset - 1
                restore_named_value(value.bindings[index].name, backups[index].value, backups[index].existed)
            }
        }

        function_value := llvm.GetBasicBlockParent(llvm.GetInsertBlock(llvm_builder))
        for binding, index in value.bindings {
            initial_value := llvm.ConstReal(llvm.DoubleTypeInContext(llvm_context), 0)
            if binding.init != nil {
                generated_value, init_err := codegen_expr(binding.init)
                if init_err != "" {
                    return nil, init_err
                }
                initial_value = generated_value
            }

            variable := create_entry_block_alloca(function_value, binding.name)
            llvm.BuildStore(llvm_builder, initial_value, variable)
            backups[index].value, backups[index].existed = named_values[binding.name]
            named_values[binding.name] = variable
            processed += 1
        }

        return codegen_expr(value.body)
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

    is_binary := prototype_is_binary(function_ast.proto)
    operator := i32(0)
    old_precedence := 0
    codegen_succeeded := false
    if is_binary {
        operator = prototype_operator(function_ast.proto)
        old_precedence = binop_precedence[operator]
        binop_precedence[operator] = function_ast.proto.precedence
    }
    defer {
        if is_binary && !codegen_succeeded {
            binop_precedence[operator] = old_precedence
        }
    }

    entry := llvm.AppendBasicBlockInContext(llvm_context, function_value, "entry")
    llvm.PositionBuilderAtEnd(llvm_builder, entry)

    clear(&named_values)
    defer clear(&named_values)
    for argument_name, index in function_ast.proto.args {
        argument := llvm.GetParam(function_value, u32(index))
        variable := create_entry_block_alloca(function_value, argument_name)
        llvm.BuildStore(llvm_builder, argument, variable)
        named_values[argument_name] = variable
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

    codegen_succeeded = true
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
    llvm_module = llvm.ModuleCreateWithNameInContext("Kaleidoscope", llvm_context)
    llvm_builder = llvm.CreateBuilderInContext(llvm_context)
    clear(&named_values)
}

initialize_native_target_machine :: proc() -> bool {
    if bool(llvm.InitializeNativeTarget()) {
        process_failed = true
        fmt.eprintln("native LLVM target unavailable")
        return false
    }
    if bool(llvm.InitializeNativeAsmPrinter()) {
        process_failed = true
        fmt.eprintln("native LLVM asm printer unavailable")
        return false
    }
    if bool(llvm.InitializeNativeAsmParser()) {
        process_failed = true
        fmt.eprintln("native LLVM asm parser unavailable")
        return false
    }

    target_triple := llvm.GetDefaultTargetTriple()
    if target_triple == nil {
        process_failed = true
        fmt.eprintln("Could not determine native target triple")
        return false
    }
    defer llvm.DisposeMessage(target_triple)
    llvm.SetTarget(llvm_module, target_triple)

    target: llvm.TargetRef
    message: cstring
    if bool(llvm.GetTargetFromTriple(target_triple, &target, &message)) {
        process_failed = true
        if message != nil {
            defer llvm.DisposeMessage(message)
            fmt.eprintln(string(message))
        }
        return false
    }

    target_machine = llvm.CreateTargetMachine(target, target_triple, "generic", "", .Default, .PIC, .Default)
    if target_machine == nil {
        process_failed = true
        fmt.eprintln("Could not create native target machine")
        return false
    }

    data_layout := llvm.CreateTargetDataLayout(target_machine)
    if data_layout == nil {
        process_failed = true
        fmt.eprintln("Could not create native data layout")
        return false
    }
    llvm.SetModuleDataLayout(llvm_module, data_layout)
    llvm.DisposeTargetData(data_layout)
    return true
}

verify_module :: proc() -> bool {
    message: cstring
    if bool(llvm.VerifyModule(llvm_module, .ReturnStatus, &message)) {
        process_failed = true
        if message != nil {
            defer llvm.DisposeMessage(message)
            fmt.eprintln(string(message))
        }
        return false
    }
    return true
}

emit_object :: proc() -> bool {
    message: cstring
    if bool(llvm.TargetMachineEmitToFile(target_machine, llvm_module, "output.o", .ObjectFile, &message)) {
        process_failed = true
        if message != nil {
            defer llvm.DisposeMessage(message)
            fmt.eprintln(string(message))
        }
        return false
    }
    fmt.println("Wrote output.o")
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
    remember_prototype(function_ast.proto, true)
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
}

main_loop :: proc() {
    for {
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
        if target_machine != nil {
            llvm.DisposeTargetMachine(target_machine)
        }
        dispose_function_prototypes()
        delete(named_values)
        if identifier != "" {
            delete(identifier)
        }
        free_all(context.temp_allocator)
    }

    fmt.eprint("ready> ")
    get_next_token()
    initialize_current_module()
    main_loop()

    if source_error {
        process_failed = true
        return
    }
    if !initialize_native_target_machine() {
        return
    }
    if !verify_module() {
        return
    }
    _ = emit_object()
}

main :: proc() {
    require_llvm_version()

    binop_precedence['='] = 2
    binop_precedence['<'] = 10
    binop_precedence['+'] = 20
    binop_precedence['-'] = 20
    binop_precedence['*'] = 40

    run()
    if process_failed {
        os.exit(1)
    }
}
