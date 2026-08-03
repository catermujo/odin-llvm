package main

import "core:c/libc"
import "core:fmt"
import "core:strconv"
import "core:strings"

TOK_EOF :: i32(-1)
TOK_DEF :: i32(-2)
TOK_EXTERN :: i32(-3)
TOK_IDENTIFIER :: i32(-4)
TOK_NUMBER :: i32(-5)

identifier: string
number_value: f64
last_char: i32 = ' '
current_token: i32
binop_precedence: [128]int

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

handle_definition :: proc() {
    _, err := parse_definition()
    if err != "" {
        report_error(err)
        get_next_token()
        return
    }
    fmt.eprintln("Parsed a function definition.")
}

handle_extern :: proc() {
    _, err := parse_extern()
    if err != "" {
        report_error(err)
        get_next_token()
        return
    }
    fmt.eprintln("Parsed an extern")
}

handle_top_level_expression :: proc() {
    _, err := parse_top_level_expr()
    if err != "" {
        report_error(err)
        get_next_token()
        return
    }
    fmt.eprintln("Parsed a top-level expr")
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
        free_all(context.temp_allocator)
    }
}

main :: proc() {
    binop_precedence['<'] = 10
    binop_precedence['+'] = 20
    binop_precedence['-'] = 20
    binop_precedence['*'] = 40

    defer {
        free_all(context.temp_allocator)
        if identifier != "" {
            delete(identifier)
        }
    }

    fmt.eprint("ready> ")
    get_next_token()
    main_loop()
}
