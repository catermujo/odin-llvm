// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
package main

import "core:fmt"
import "core:os"
import "core:strings"

Arguments :: struct {
    help:        bool,
    version:     bool,
    uppercase:   bool,
    lowercase:   bool,
    subcommands: [dynamic]string,
    positionals: [dynamic]string,
    unknown:     [dynamic]string,
}

// LLVM's OptTable has no C API, so this keeps the canonical table's parsing rules in native Odin.
parse_arguments :: proc() -> Arguments {
    arguments: Arguments
    arguments.subcommands = make([dynamic]string, context.temp_allocator)
    arguments.positionals = make([dynamic]string, context.temp_allocator)
    arguments.unknown = make([dynamic]string, context.temp_allocator)

    for arg in os.args[1:] {
        if arg == "" {
            continue
        }
        switch arg {
        case "--help":
            arguments.help = true
        case "-version":
            arguments.version = true
        case "-uppercase":
            arguments.uppercase = true
        case "-lowercase":
            arguments.lowercase = true
        case "foo", "bar":
            append(&arguments.subcommands, arg)
        case:
            if strings.has_prefix(arg, "-") && arg != "-" {
                append(&arguments.unknown, arg)
            } else {
                append(&arguments.positionals, arg)
            }
        }
    }
    return arguments
}

print_help :: proc(subcommand: string) {
    switch subcommand {
    case "foo":
        fmt.print(
            "OVERVIEW: LLVM Hello SubCommand Example\n\n" +
            "HelpText for SubCommand foo.\n\n" +
            "OPTIONS:\n" +
            "  -lowercase Print in lowercase\n" +
            "  -uppercase Print in uppercase\n",
        )
    case "bar":
        fmt.print(
            "OVERVIEW: LLVM Hello SubCommand Example\n\n" +
            "HelpText for SubCommand bar.\n\n" +
            "USAGE: OptSubcommand bar <options>\n\n" +
            "OPTIONS:\n" +
            "  -uppercase Print in uppercase\n",
        )
    case:
        fmt.print(
            "OVERVIEW: LLVM Hello SubCommand Example\n\n" +
            "USAGE: llvm-hello-sub [subcommand] [options]\n\n" +
            "SUBCOMMANDS:\n\n" +
            "bar - HelpText for SubCommand bar.\n" +
            "foo - HelpText for SubCommand foo.\n\n" +
            "OPTIONS:\n" +
            "  --help   OptSubcommand <subcommand> <options>\n" +
            "  -version Toplevel Display the version number\n",
        )
    }
}

print_multiple_subcommands :: proc(subcommands: []string) {
    fmt.eprintln("error: more than one subcommand passed [")
    for subcommand in subcommands {
        fmt.eprintf(" `%s`\n", subcommand)
    }
    fmt.eprintln("]")
    fmt.eprintln("See --help.")
}

print_unknown_positionals :: proc(positionals: []string) {
    fmt.eprintln("error: unknown positional argument(s) [")
    for positional in positionals {
        fmt.eprintf(" `%s`\n", positional)
    }
    fmt.eprintln("]")
    fmt.eprintln("See --help.")
}

valid_for_subcommand :: proc(present: bool, option, subcommand: string, valid: bool) -> bool {
    if !present {
        return false
    }
    if !valid {
        fmt.eprintf("Option [%s] is not valid for SubCommand [%s]\n", option, subcommand)
        return false
    }
    return true
}

run :: proc() -> int {
    arguments := parse_arguments()

    if len(arguments.subcommands) > 1 {
        print_multiple_subcommands(arguments.subcommands[:])
        return 1
    }
    if len(arguments.positionals) != 0 {
        print_unknown_positionals(arguments.positionals[:])
        return 1
    }

    subcommand := ""
    if len(arguments.subcommands) == 1 {
        subcommand = arguments.subcommands[0]
    }

    if arguments.help {
        print_help(subcommand)
        return 0
    }

    if len(arguments.unknown) != 0 {
        for option in arguments.unknown {
            fmt.eprintf("Unknown option `%s'\n", option)
        }
        fmt.eprintln("See `OptSubcommand --help`.")
        return 1
    }

    switch subcommand {
    case "":
        if arguments.version {
            fmt.println("LLVM Hello SubCommand Example 1.0")
        }
    case "foo":
        if valid_for_subcommand(arguments.uppercase, "uppercase", subcommand, true) {
            fmt.println("FOO")
        } else if valid_for_subcommand(arguments.lowercase, "lowercase", subcommand, true) {
            fmt.println("foo")
        }
        if valid_for_subcommand(arguments.version, "version", subcommand, false) {
            fmt.println("LLVM Hello SubCommand foo Example 1.0")
        }
    case "bar":
        if valid_for_subcommand(arguments.lowercase, "lowercase", subcommand, false) {
            fmt.println("bar")
        } else if valid_for_subcommand(arguments.uppercase, "uppercase", subcommand, true) {
            fmt.println("BAR")
        }
        if valid_for_subcommand(arguments.version, "version", subcommand, false) {
            fmt.println("LLVM Hello SubCommand bar Example 1.0")
        }
    }
    return 0
}

main :: proc() {
    status := run()
    if status != 0 {
        os.exit(status)
    }
}
