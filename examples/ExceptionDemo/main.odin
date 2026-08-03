package main

import "core:c/libc"
import "core:fmt"
import "core:os"

import llvm "../.."

when ODIN_OS != .Darwin && ODIN_OS != .Linux {
    #panic("ExceptionDemo requires Itanium/DWARF exception handling")
}
when size_of(uintptr) != 8 {
    #panic("ExceptionDemo requires a 64-bit Itanium/DWARF host")
}

EXCEPTION_BRIDGE_ARCHIVE :: #config(EXCEPTION_DEMO_BRIDGE_ARCHIVE, "")
when EXCEPTION_BRIDGE_ARCHIVE == "" {
    #panic("ExceptionDemo must be built through build.sh (missing EXCEPTION_DEMO_BRIDGE_ARCHIVE)")
    when ODIN_OS == .Darwin {
        foreign import exception_bridge "system:System"
    } else {
        foreign import exception_bridge "system:c"
    }
} else {
    foreign import exception_bridge {EXCEPTION_BRIDGE_ARCHIVE}
}

when ODIN_OS == .Darwin {
    @(require) foreign import unwind_runtime "system:System"
    @(require) foreign import cpp_runtime "system:c++"
} else when ODIN_OS == .Linux {
    @(require) foreign import unwind_runtime "system:gcc_s"
    @(require) foreign import cpp_runtime "system:stdc++"
}

@(default_calling_convention = "c")
foreign exception_bridge {
    throwCppException :: proc(type_to_throw: i32) ---
    runExceptionThrow :: proc(function: rawptr, type_to_throw: i32) ---
}

@(default_calling_convention = "c")
foreign unwind_runtime {
    _Unwind_GetIP :: proc(ctx: rawptr) -> uintptr ---
    _Unwind_SetIP :: proc(ctx: rawptr, value: uintptr) ---
    _Unwind_SetGR :: proc(ctx: rawptr, index: i32, value: uintptr) ---
    _Unwind_GetRegionStart :: proc(ctx: rawptr) -> uintptr ---
    _Unwind_GetLanguageSpecificData :: proc(ctx: rawptr) -> rawptr ---
    _Unwind_RaiseException :: proc(exception: rawptr) -> i32 ---
    _Unwind_Resume :: proc(exception: rawptr) ---
}

OUR_EXCEPTION_CLASS :: u64(0x6f626a0062617300)
UNWIND_HEADER_OFFSET :: uintptr(16)

URC_HANDLER_FOUND :: i32(6)
URC_INSTALL_CONTEXT :: i32(7)
URC_CONTINUE_UNWIND :: i32(8)

UA_SEARCH_PHASE :: i32(1)

DW_EH_PE_ABSPTR :: u8(0x00)
DW_EH_PE_ULEB128 :: u8(0x01)
DW_EH_PE_UDATA2 :: u8(0x02)
DW_EH_PE_UDATA4 :: u8(0x03)
DW_EH_PE_UDATA8 :: u8(0x04)
DW_EH_PE_SLEB128 :: u8(0x09)
DW_EH_PE_SDATA2 :: u8(0x0a)
DW_EH_PE_SDATA4 :: u8(0x0b)
DW_EH_PE_SDATA8 :: u8(0x0c)
DW_EH_PE_PCREL :: u8(0x10)
DW_EH_PE_INDIRECT :: u8(0x80)
DW_EH_PE_OMIT :: u8(0xff)

EXCEPTION_NOT_THROWN :: u8(0)
EXCEPTION_THROWN :: u8(1)
EXCEPTION_CAUGHT :: u8(2)

Unwind_Exception :: struct {
    exception_class:   u64,
    exception_cleanup: proc "c" (reason: i32, exception: rawptr),
    private_1:         uintptr,
    private_2:         uintptr,
}

EXCEPTION_ALLOCATION_SIZE :: UNWIND_HEADER_OFFSET + uintptr(size_of(Unwind_Exception))

read_bytes :: proc "contextless" (data: ^uintptr, destination: rawptr, size: uintptr) {
    _ = libc.memcpy(destination, rawptr(data^), uint(size))
    data^ += size
}

read_u8 :: proc "contextless" (data: ^uintptr) -> u8 {
    value: u8
    read_bytes(data, &value, size_of(value))
    return value
}

read_u16 :: proc "contextless" (data: ^uintptr) -> u16 {
    value: u16
    read_bytes(data, &value, size_of(value))
    return value
}

read_u32 :: proc "contextless" (data: ^uintptr) -> u32 {
    value: u32
    read_bytes(data, &value, size_of(value))
    return value
}

read_u64 :: proc "contextless" (data: ^uintptr) -> u64 {
    value: u64
    read_bytes(data, &value, size_of(value))
    return value
}

read_i16 :: proc "contextless" (data: ^uintptr) -> i16 {
    value: i16
    read_bytes(data, &value, size_of(value))
    return value
}

read_i32 :: proc "contextless" (data: ^uintptr) -> i32 {
    value: i32
    read_bytes(data, &value, size_of(value))
    return value
}

read_i64 :: proc "contextless" (data: ^uintptr) -> i64 {
    value: i64
    read_bytes(data, &value, size_of(value))
    return value
}

read_uleb128 :: proc "contextless" (data: ^uintptr) -> uintptr {
    result: uintptr
    shift: uintptr

    for {
        byte := read_u8(data)
        result |= uintptr(byte & 0x7f) << shift
        if byte & 0x80 == 0 {
            return result
        }
        shift += 7
    }
}

read_sleb128 :: proc "contextless" (data: ^uintptr) -> i64 {
    result: u64
    shift: u64
    byte: u8

    for {
        byte = read_u8(data)
        result |= u64(byte & 0x7f) << shift
        shift += 7
        if byte & 0x80 == 0 {
            break
        }
    }

    if byte & 0x40 != 0 && shift < 64 {
        result |= ~u64(0) << shift
    }
    return transmute(i64)result
}

encoding_size :: proc "contextless" (encoding: u8) -> (uintptr, bool) {
    switch encoding & 0x0f {
    case DW_EH_PE_ABSPTR:
        return size_of(uintptr), true
    case DW_EH_PE_UDATA2, DW_EH_PE_SDATA2:
        return 2, true
    case DW_EH_PE_UDATA4, DW_EH_PE_SDATA4:
        return 4, true
    case DW_EH_PE_UDATA8, DW_EH_PE_SDATA8:
        return 8, true
    }
    return 0, false
}

read_encoded_pointer :: proc "contextless" (data: ^uintptr, encoding: u8) -> (uintptr, bool) {
    if encoding == DW_EH_PE_OMIT {
        return 0, true
    }

    original := data^
    result: uintptr
    switch encoding & 0x0f {
    case DW_EH_PE_ABSPTR:
        result = uintptr(read_u64(data))
    case DW_EH_PE_ULEB128:
        result = read_uleb128(data)
    case DW_EH_PE_SLEB128:
        result = transmute(uintptr)read_sleb128(data)
    case DW_EH_PE_UDATA2:
        result = uintptr(read_u16(data))
    case DW_EH_PE_UDATA4:
        result = uintptr(read_u32(data))
    case DW_EH_PE_UDATA8:
        result = uintptr(read_u64(data))
    case DW_EH_PE_SDATA2:
        result = transmute(uintptr)i64(read_i16(data))
    case DW_EH_PE_SDATA4:
        result = transmute(uintptr)i64(read_i32(data))
    case DW_EH_PE_SDATA8:
        result = transmute(uintptr)read_i64(data)
    case:
        return 0, false
    }

    switch encoding & 0x70 {
    case DW_EH_PE_ABSPTR:
    case DW_EH_PE_PCREL:
        result += original
    case:
        return 0, false
    }

    if encoding & DW_EH_PE_INDIRECT != 0 {
        result = (^uintptr)(rawptr(result))^
    }
    return result, true
}

handle_action_value :: proc "contextless" (
    type_encoding: u8,
    class_info: uintptr,
    action_entry: uintptr,
    exception_class: u64,
    exception_object: rawptr,
) -> (
    bool,
    i32,
) {
    if exception_object == nil || exception_class != OUR_EXCEPTION_CLASS {
        return false, 0
    }

    exception_base := rawptr(uintptr(exception_object) - UNWIND_HEADER_OFFSET)
    exception_type := (^i32)(exception_base)^
    action_position := action_entry

    for action_index := i32(0);; action_index += 1 {
        type_offset := read_sleb128(&action_position)
        next_position := action_position
        action_offset := read_sleb128(&next_position)

        if type_offset < 0 {
            return false, 0
        }
        if type_offset > 0 {
            size, supported := encoding_size(type_encoding)
            if !supported {
                return false, 0
            }
            entry_position := class_info - uintptr(type_offset) * size
            type_info_address, decoded := read_encoded_pointer(&entry_position, type_encoding)
            if !decoded || type_info_address == 0 {
                return false, 0
            }
            if (^i32)(rawptr(type_info_address))^ == exception_type {
                return true, action_index + 1
            }
        }

        if action_offset == 0 {
            break
        }
        action_position = uintptr(i64(action_position) + action_offset)
    }
    return false, 0
}

handle_lsda :: proc "contextless" (
    lsda_pointer: rawptr,
    actions: i32,
    exception_class: u64,
    exception_object: rawptr,
    unwind_context: rawptr,
) -> i32 {
    if lsda_pointer == nil {
        return URC_CONTINUE_UNWIND
    }

    instruction_pointer := _Unwind_GetIP(unwind_context) - 1
    function_start := _Unwind_GetRegionStart(unwind_context)
    instruction_offset := instruction_pointer - function_start
    lsda := uintptr(lsda_pointer)
    class_info: uintptr

    landing_pad_encoding := read_u8(&lsda)
    if landing_pad_encoding != DW_EH_PE_OMIT {
        _, decoded := read_encoded_pointer(&lsda, landing_pad_encoding)
        if !decoded {
            return URC_CONTINUE_UNWIND
        }
    }

    type_encoding := read_u8(&lsda)
    if type_encoding != DW_EH_PE_OMIT {
        class_info_offset := read_uleb128(&lsda)
        class_info = lsda + class_info_offset
    }

    call_site_encoding := read_u8(&lsda)
    call_site_length := read_uleb128(&lsda)
    call_site_position := lsda
    call_site_end := call_site_position + call_site_length
    action_table_start := call_site_end

    for call_site_position < call_site_end {
        start, start_ok := read_encoded_pointer(&call_site_position, call_site_encoding)
        length, length_ok := read_encoded_pointer(&call_site_position, call_site_encoding)
        landing_pad, landing_pad_ok := read_encoded_pointer(&call_site_position, call_site_encoding)
        action_entry := read_uleb128(&call_site_position)
        if !start_ok || !length_ok || !landing_pad_ok {
            return URC_CONTINUE_UNWIND
        }

        if exception_class != OUR_EXCEPTION_CLASS {
            action_entry = 0
        }
        if landing_pad == 0 || instruction_offset < start || instruction_offset >= start + length {
            continue
        }

        absolute_action: uintptr
        if action_entry != 0 {
            absolute_action = action_table_start + action_entry - 1
        }

        exception_matched := false
        action_value: i32
        if absolute_action != 0 {
            exception_matched, action_value = handle_action_value(
                type_encoding,
                class_info,
                absolute_action,
                exception_class,
                exception_object,
            )
        }

        if actions & UA_SEARCH_PHASE != 0 {
            if exception_matched {
                return URC_HANDLER_FOUND
            }
            return URC_CONTINUE_UNWIND
        }

        // LLVM's Itanium targets pass landingpad values in unwind data regs 0/1.
        _Unwind_SetGR(unwind_context, 0, uintptr(exception_object))
        _Unwind_SetGR(unwind_context, 1, uintptr(action_value) if exception_matched else 0)
        _Unwind_SetIP(unwind_context, function_start + landing_pad)
        return URC_INSTALL_CONTEXT
    }

    return URC_CONTINUE_UNWIND
}

our_personality :: proc "c" (
    _: i32,
    actions: i32,
    exception_class: u64,
    exception_object: rawptr,
    unwind_context: rawptr,
) -> i32 {
    return handle_lsda(
        _Unwind_GetLanguageSpecificData(unwind_context),
        actions,
        exception_class,
        exception_object,
        unwind_context,
    )
}

print_32_int :: proc "c" (value: i32, format: cstring) {
    if format == nil {
        _ = libc.fprintf(libc.stderr, "::print32Int(...):NULL arg.\n")
        return
    }
    _ = libc.fprintf(libc.stderr, format, value)
}

print_string :: proc "c" (value: cstring) {
    if value == nil {
        _ = libc.fprintf(libc.stderr, "::printStr(...):NULL arg.\n")
        return
    }
    _ = libc.fprintf(libc.stderr, "%s", value)
}

delete_our_exception :: proc "c" (exception: rawptr) {
    if exception == nil {
        return
    }
    unwind := (^Unwind_Exception)(exception)
    if unwind.exception_class == OUR_EXCEPTION_CLASS {
        libc.free(rawptr(uintptr(exception) - UNWIND_HEADER_OFFSET))
    }
}

cleanup_our_exception :: proc "c" (_: i32, exception: rawptr) {
    delete_our_exception(exception)
}

create_our_exception :: proc "c" (exception_type: i32) -> rawptr {
    allocation := libc.calloc(1, uint(EXCEPTION_ALLOCATION_SIZE))
    if allocation == nil {
        return nil
    }

    (^i32)(allocation)^ = exception_type
    unwind := (^Unwind_Exception)(rawptr(uintptr(allocation) + UNWIND_HEADER_OFFSET))
    unwind.exception_class = OUR_EXCEPTION_CLASS
    unwind.exception_cleanup = cleanup_our_exception
    return rawptr(unwind)
}

IR_Generator :: struct {
    ctx:                 llvm.ContextRef,
    module:              llvm.ModuleRef,
    builder:             llvm.BuilderRef,
    void_type:           llvm.TypeRef,
    i8_type:             llvm.TypeRef,
    i32_type:            llvm.TypeRef,
    i64_type:            llvm.TypeRef,
    ptr_type:            llvm.TypeRef,
    type_info_type:      llvm.TypeRef,
    caught_result_type:  llvm.TypeRef,
    exception_type:      llvm.TypeRef,
    unwind_type:         llvm.TypeRef,
    type_infos:          [7]llvm.ValueRef,
    print_32:            llvm.ValueRef,
    print_str:           llvm.ValueRef,
    delete_exception:    llvm.ValueRef,
    create_exception:    llvm.ValueRef,
    raise_exception:     llvm.ValueRef,
    unwind_resume:       llvm.ValueRef,
    personality:         llvm.ValueRef,
    throw_cpp_exception: llvm.ValueRef,
}

function_type :: proc(return_type: llvm.TypeRef, parameters: []llvm.TypeRef) -> llvm.TypeRef {
    if len(parameters) == 0 {
        return llvm.FunctionType(return_type, nil, 0, llvm.Bool(0))
    }
    return llvm.FunctionType(return_type, raw_data(parameters), u32(len(parameters)), llvm.Bool(0))
}

declare_function :: proc(
    ir: ^IR_Generator,
    name: cstring,
    return_type: llvm.TypeRef,
    parameters: []llvm.TypeRef,
) -> llvm.ValueRef {
    return llvm.AddFunction(ir.module, name, function_type(return_type, parameters))
}

const_i8 :: proc(ir: ^IR_Generator, value: u8) -> llvm.ValueRef {
    return llvm.ConstInt(ir.i8_type, u64(value), llvm.Bool(0))
}

const_i32 :: proc(ir: ^IR_Generator, value: i32) -> llvm.ValueRef {
    return llvm.ConstInt(ir.i32_type, u64(transmute(u32)value), llvm.Bool(0))
}

const_i64 :: proc(ir: ^IR_Generator, value: i64) -> llvm.ValueRef {
    return llvm.ConstInt(ir.i64_type, transmute(u64)value, llvm.Bool(0))
}

add_global_string :: proc(ir: ^IR_Generator, text: string) -> llvm.ValueRef {
    constant := llvm.ConstStringInContext2(ir.ctx, cstring(raw_data(text)), len(text), llvm.Bool(0))
    global := llvm.AddGlobal(ir.module, llvm.TypeOf(constant), ".str")
    llvm.SetInitializer(global, constant)
    llvm.SetGlobalConstant(global, llvm.Bool(1))
    llvm.SetLinkage(global, .PrivateLinkage)
    llvm.SetUnnamedAddress(global, .GlobalUnnamedAddr)
    return global
}

emit_print :: proc(ir: ^IR_Generator, text: string) {
    arguments := [1]llvm.ValueRef{add_global_string(ir, text)}
    llvm.BuildCall2(ir.builder, llvm.GlobalGetValueType(ir.print_str), ir.print_str, &arguments[0], 1, "")
}

emit_integer_print :: proc(ir: ^IR_Generator, value: llvm.ValueRef, format: string) {
    arguments := [2]llvm.ValueRef{value, add_global_string(ir, format)}
    llvm.BuildCall2(ir.builder, llvm.GlobalGetValueType(ir.print_32), ir.print_32, &arguments[0], 2, "")
}

initialize_ir :: proc(ir: ^IR_Generator) {
    ir.void_type = llvm.VoidTypeInContext(ir.ctx)
    ir.i8_type = llvm.Int8TypeInContext(ir.ctx)
    ir.i32_type = llvm.Int32TypeInContext(ir.ctx)
    ir.i64_type = llvm.Int64TypeInContext(ir.ctx)
    ir.ptr_type = llvm.PointerTypeInContext(ir.ctx, 0)

    ir.type_info_type = llvm.StructCreateNamed(ir.ctx, "OurExceptionType")
    type_info_fields := [1]llvm.TypeRef{ir.i32_type}
    llvm.StructSetBody(ir.type_info_type, &type_info_fields[0], 1, llvm.Bool(0))

    ir.caught_result_type = llvm.StructCreateNamed(ir.ctx, "CaughtResult")
    caught_fields := [2]llvm.TypeRef{ir.ptr_type, ir.i32_type}
    llvm.StructSetBody(ir.caught_result_type, &caught_fields[0], 2, llvm.Bool(0))

    ir.exception_type = llvm.StructCreateNamed(ir.ctx, "OurException")
    exception_fields := [1]llvm.TypeRef{ir.type_info_type}
    llvm.StructSetBody(ir.exception_type, &exception_fields[0], 1, llvm.Bool(0))

    ir.unwind_type = llvm.StructCreateNamed(ir.ctx, "UnwindExceptionPrefix")
    unwind_fields := [1]llvm.TypeRef{ir.i64_type}
    llvm.StructSetBody(ir.unwind_type, &unwind_fields[0], 1, llvm.Bool(0))

    for index in 0 ..< len(ir.type_infos) {
        field_values := [1]llvm.ValueRef{const_i32(ir, i32(index))}
        initializer := llvm.ConstNamedStruct(ir.type_info_type, &field_values[0], 1)
        name := fmt.ctprintf("typeInfo%d", index)
        ir.type_infos[index] = llvm.AddGlobal(ir.module, ir.type_info_type, name)
        llvm.SetInitializer(ir.type_infos[index], initializer)
        llvm.SetGlobalConstant(ir.type_infos[index], llvm.Bool(1))
    }

    print_32_parameters := [2]llvm.TypeRef{ir.i32_type, ir.ptr_type}
    ir.print_32 = declare_function(ir, "print32Int", ir.void_type, print_32_parameters[:])

    pointer_parameter := [1]llvm.TypeRef{ir.ptr_type}
    ir.print_str = declare_function(ir, "printStr", ir.void_type, pointer_parameter[:])
    ir.delete_exception = declare_function(ir, "deleteOurException", ir.void_type, pointer_parameter[:])

    i32_parameter := [1]llvm.TypeRef{ir.i32_type}
    ir.create_exception = declare_function(ir, "createOurException", ir.ptr_type, i32_parameter[:])
    ir.raise_exception = declare_function(ir, "_Unwind_RaiseException", ir.i32_type, pointer_parameter[:])
    ir.unwind_resume = declare_function(ir, "_Unwind_Resume", ir.void_type, pointer_parameter[:])
    ir.throw_cpp_exception = declare_function(ir, "throwCppException", ir.void_type, i32_parameter[:])

    personality_parameters := [5]llvm.TypeRef{ir.i32_type, ir.i32_type, ir.i64_type, ir.ptr_type, ir.ptr_type}
    ir.personality = declare_function(ir, "ourPersonality", ir.i32_type, personality_parameters[:])
}

build_throw_function :: proc(ir: ^IR_Generator) -> llvm.ValueRef {
    parameters := [1]llvm.TypeRef{ir.i32_type}
    function := llvm.AddFunction(ir.module, "throwFunct", function_type(ir.void_type, parameters[:]))
    exception_type := llvm.GetParam(function, 0)
    llvm.SetValueName2(exception_type, "exceptTypeToThrow", len("exceptTypeToThrow"))

    entry := llvm.AppendBasicBlockInContext(ir.ctx, function, "entry")
    native_throw := llvm.AppendBasicBlockInContext(ir.ctx, function, "nativeThrow")
    generated_throw := llvm.AppendBasicBlockInContext(ir.ctx, function, "generatedThrow")

    llvm.PositionBuilderAtEnd(ir.builder, entry)
    emit_integer_print(ir, exception_type, "\nGen: About to throw exception type <%d> in throwFunct.\n")
    dispatch := llvm.BuildSwitch(ir.builder, exception_type, generated_throw, 1)
    llvm.AddCase(dispatch, const_i32(ir, -1), native_throw)

    llvm.PositionBuilderAtEnd(ir.builder, native_throw)
    native_arguments := [1]llvm.ValueRef{exception_type}
    llvm.BuildCall2(
        ir.builder,
        llvm.GlobalGetValueType(ir.throw_cpp_exception),
        ir.throw_cpp_exception,
        &native_arguments[0],
        1,
        "",
    )
    llvm.BuildUnreachable(ir.builder)

    llvm.PositionBuilderAtEnd(ir.builder, generated_throw)
    create_arguments := [1]llvm.ValueRef{exception_type}
    exception := llvm.BuildCall2(
        ir.builder,
        llvm.GlobalGetValueType(ir.create_exception),
        ir.create_exception,
        &create_arguments[0],
        1,
        "exception",
    )
    raise_arguments := [1]llvm.ValueRef{exception}
    llvm.BuildCall2(
        ir.builder,
        llvm.GlobalGetValueType(ir.raise_exception),
        ir.raise_exception,
        &raise_arguments[0],
        1,
        "",
    )
    llvm.BuildUnreachable(ir.builder)
    return function
}

build_catch_wrapper :: proc(
    ir: ^IR_Generator,
    to_invoke: llvm.ValueRef,
    function_id: string,
    catch_types: [3]i32,
) -> llvm.ValueRef {
    parameters := [1]llvm.TypeRef{ir.i32_type}
    function := llvm.AddFunction(ir.module, fmt.ctprint(function_id), function_type(ir.void_type, parameters[:]))
    argument := llvm.GetParam(function, 0)
    llvm.SetValueName2(argument, "exceptTypeToThrow", len("exceptTypeToThrow"))
    llvm.SetPersonalityFn(function, ir.personality)

    entry := llvm.AppendBasicBlockInContext(ir.ctx, function, "entry")
    normal := llvm.AppendBasicBlockInContext(ir.ctx, function, "normal")
    exception_block := llvm.AppendBasicBlockInContext(ir.ctx, function, "exception")
    exception_route := llvm.AppendBasicBlockInContext(ir.ctx, function, "exceptionRoute")
    external_exception := llvm.AppendBasicBlockInContext(ir.ctx, function, "externalException")
    unwind_resume := llvm.AppendBasicBlockInContext(ir.ctx, function, "unwindResume")
    finally := llvm.AppendBasicBlockInContext(ir.ctx, function, "finally")
    end := llvm.AppendBasicBlockInContext(ir.ctx, function, "end")
    catch_blocks: [3]llvm.BasicBlockRef
    for catch_type, index in catch_types {
        catch_blocks[index] = llvm.AppendBasicBlockInContext(ir.ctx, function, fmt.ctprintf("typeInfo%d", catch_type))
    }

    llvm.PositionBuilderAtEnd(ir.builder, entry)
    exception_state := llvm.BuildAlloca(ir.builder, ir.i8_type, "exceptionCaught")
    exception_storage := llvm.BuildAlloca(ir.builder, ir.ptr_type, "exceptionStorage")
    caught_storage := llvm.BuildAlloca(ir.builder, ir.caught_result_type, "caughtResultStorage")
    llvm.BuildStore(ir.builder, const_i8(ir, EXCEPTION_NOT_THROWN), exception_state)
    llvm.BuildStore(ir.builder, llvm.ConstPointerNull(ir.ptr_type), exception_storage)
    llvm.BuildStore(ir.builder, llvm.ConstNull(ir.caught_result_type), caught_storage)
    invoke_arguments := [1]llvm.ValueRef{argument}
    llvm.BuildInvoke2(
        ir.builder,
        llvm.GlobalGetValueType(to_invoke),
        to_invoke,
        &invoke_arguments[0],
        1,
        normal,
        exception_block,
        "",
    )

    llvm.PositionBuilderAtEnd(ir.builder, normal)
    emit_print(ir, string(fmt.ctprintf("Gen: No exception in %s!\n", function_id)))
    llvm.BuildBr(ir.builder, finally)

    llvm.PositionBuilderAtEnd(ir.builder, exception_block)
    caught_result := llvm.BuildLandingPad(ir.builder, ir.caught_result_type, ir.personality, 3, "landingPad")
    llvm.SetCleanup(caught_result, llvm.Bool(1))
    for catch_type in catch_types {
        llvm.AddClause(caught_result, ir.type_infos[catch_type])
    }
    unwind_exception := llvm.BuildExtractValue(ir.builder, caught_result, 0, "unwindException")
    type_info_index := llvm.BuildExtractValue(ir.builder, caught_result, 1, "typeInfoIndex")
    llvm.BuildStore(ir.builder, caught_result, caught_storage)
    llvm.BuildStore(ir.builder, unwind_exception, exception_storage)
    llvm.BuildStore(ir.builder, const_i8(ir, EXCEPTION_THROWN), exception_state)
    class_pointer := llvm.BuildStructGEP2(ir.builder, ir.unwind_type, unwind_exception, 0, "exceptionClassPtr")
    exception_class := llvm.BuildLoad2(ir.builder, ir.i64_type, class_pointer, "exceptionClass")
    is_ours := llvm.BuildICmp(
        ir.builder,
        .EQ,
        exception_class,
        llvm.ConstInt(ir.i64_type, OUR_EXCEPTION_CLASS, llvm.Bool(0)),
        "isOurException",
    )
    llvm.BuildCondBr(ir.builder, is_ours, exception_route, external_exception)

    llvm.PositionBuilderAtEnd(ir.builder, external_exception)
    emit_print(ir, "Gen: Foreign exception received.\n")
    llvm.BuildBr(ir.builder, finally)

    llvm.PositionBuilderAtEnd(ir.builder, exception_route)
    offset_indices := [1]llvm.ValueRef{const_i64(ir, -i64(UNWIND_HEADER_OFFSET))}
    exception_base := llvm.BuildGEP2(ir.builder, ir.i8_type, unwind_exception, &offset_indices[0], 1, "exceptionBase")
    type_info_pointer := llvm.BuildStructGEP2(ir.builder, ir.exception_type, exception_base, 0, "typeInfo")
    type_value_pointer := llvm.BuildStructGEP2(ir.builder, ir.type_info_type, type_info_pointer, 0, "typeValuePtr")
    type_value := llvm.BuildLoad2(ir.builder, ir.i32_type, type_value_pointer, "typeValue")
    emit_integer_print(
        ir,
        type_value,
        string(fmt.ctprintf("Gen: Exception type <%%d> received (stack unwound) in %s.\n", function_id)),
    )
    route := llvm.BuildSwitch(ir.builder, type_info_index, finally, 3)
    for _, index in catch_types {
        llvm.AddCase(route, const_i32(ir, i32(index + 1)), catch_blocks[index])
    }

    for catch_type, index in catch_types {
        llvm.PositionBuilderAtEnd(ir.builder, catch_blocks[index])
        emit_print(ir, string(fmt.ctprintf("Gen: Executing catch block typeInfo%d in %s\n", catch_type, function_id)))
        llvm.BuildStore(ir.builder, const_i8(ir, EXCEPTION_CAUGHT), exception_state)
        llvm.BuildBr(ir.builder, finally)
    }

    llvm.PositionBuilderAtEnd(ir.builder, finally)
    emit_print(ir, string(fmt.ctprintf("Gen: Executing finally block finally in %s\n", function_id)))
    state := llvm.BuildLoad2(ir.builder, ir.i8_type, exception_state, "exceptionState")
    finally_route := llvm.BuildSwitch(ir.builder, state, end, 2)
    llvm.AddCase(finally_route, const_i8(ir, EXCEPTION_CAUGHT), end)
    llvm.AddCase(finally_route, const_i8(ir, EXCEPTION_THROWN), unwind_resume)

    llvm.PositionBuilderAtEnd(ir.builder, unwind_resume)
    resumed_exception := llvm.BuildLoad2(ir.builder, ir.caught_result_type, caught_storage, "resumedException")
    llvm.BuildResume(ir.builder, resumed_exception)

    llvm.PositionBuilderAtEnd(ir.builder, end)
    emit_print(ir, string(fmt.ctprintf("Gen: In end block: exiting in %s.\n", function_id)))
    exception_to_delete := llvm.BuildLoad2(ir.builder, ir.ptr_type, exception_storage, "exceptionToDelete")
    delete_arguments := [1]llvm.ValueRef{exception_to_delete}
    llvm.BuildCall2(
        ir.builder,
        llvm.GlobalGetValueType(ir.delete_exception),
        ir.delete_exception,
        &delete_arguments[0],
        1,
        "",
    )
    llvm.BuildRetVoid(ir.builder)
    return function
}

generate_exception_test :: proc(ir: ^IR_Generator) -> llvm.ValueRef {
    initialize_ir(ir)
    throw_function := build_throw_function(ir)
    inner := build_catch_wrapper(ir, throw_function, "innerCatchFunct", {6, 2, 4})
    return build_catch_wrapper(ir, inner, "outerCatchFunct", {3, 1, 5})
}

report_llvm_error :: proc(error: llvm.ErrorRef) -> bool {
    if error == nil {
        return true
    }
    message := llvm.GetErrorMessage(error)
    _ = libc.fprintf(libc.stderr, "LLVM error: %s\n", message)
    llvm.DisposeErrorMessage(message)
    return false
}

register_host_symbols :: proc(jit: llvm.OrcLLJITRef, dylib: llvm.OrcJITDylibRef) -> bool {
    names := [8]cstring {
        "print32Int",
        "printStr",
        "deleteOurException",
        "createOurException",
        "ourPersonality",
        "throwCppException",
        "_Unwind_RaiseException",
        "_Unwind_Resume",
    }
    addresses := [8]rawptr {
        rawptr(print_32_int),
        rawptr(print_string),
        rawptr(delete_our_exception),
        rawptr(create_our_exception),
        rawptr(our_personality),
        rawptr(throwCppException),
        rawptr(_Unwind_RaiseException),
        rawptr(_Unwind_Resume),
    }
    symbols: [8]llvm.OrcCSymbolMapPair
    flags: llvm.JITSymbolFlags = {
        Generic = {.Exported, .Callable},
    }

    for name, index in names {
        symbols[index].Name = llvm.OrcLLJITMangleAndIntern(jit, name)
        if symbols[index].Name == nil {
            for release_index in 0 ..< index {
                llvm.OrcReleaseSymbolStringPoolEntry(symbols[release_index].Name)
            }
            _ = libc.fprintf(libc.stderr, "Could not intern host symbol %s.\n", name)
            return false
        }
        symbols[index].Sym = {
            Address = llvm.OrcExecutorAddress(uintptr(addresses[index])),
            Flags   = flags,
        }
    }

    unit := llvm.OrcAbsoluteSymbols(&symbols[0], len(symbols))
    if unit == nil {
        _ = libc.fprintf(libc.stderr, "Could not create host symbol materialization unit.\n")
        return false
    }

    error := llvm.OrcJITDylibDefine(dylib, unit)
    if error != nil {
        llvm.OrcDisposeMaterializationUnit(unit)
        return report_llvm_error(error)
    }
    return true
}

verify_module :: proc(module: llvm.ModuleRef) -> bool {
    message: cstring
    if bool(llvm.VerifyModule(module, .ReturnStatus, &message)) {
        _ = libc.fprintf(libc.stderr, "LLVM module verification failed:\n%s", message)
        llvm.DisposeMessage(message)
        return false
    }
    if message != nil {
        llvm.DisposeMessage(message)
    }
    return true
}

parse_exception_type :: proc(argument: string) -> (i32, bool) {
    if len(argument) == 0 {
        return 0, false
    }

    negative := false
    index := 0
    switch argument[0] {
    case '-':
        negative = true
        index = 1
    case '+':
        index = 1
    }
    if index == len(argument) {
        return 0, false
    }

    limit := u64(max(i32))
    if negative {
        limit += 1
    }
    magnitude: u64
    for ; index < len(argument); index += 1 {
        byte := argument[index]
        if byte < '0' || byte > '9' {
            return 0, false
        }
        digit := u64(byte - '0')
        if magnitude > (limit - digit) / 10 {
            return 0, false
        }
        magnitude = magnitude * 10 + digit
    }

    value: i32
    if negative {
        value = i32(-i64(magnitude))
    } else {
        value = i32(magnitude)
    }
    if value != -1 && value < 1 {
        return 0, false
    }
    return value, true
}

run_demo :: proc(arguments: []i32) -> bool {
    if bool(llvm.InitializeNativeTarget()) {
        _ = libc.fprintf(libc.stderr, "native LLVM target unavailable\n")
        return false
    }
    if bool(llvm.InitializeNativeAsmPrinter()) {
        _ = libc.fprintf(libc.stderr, "native LLVM asm printer unavailable\n")
        return false
    }

    jit_builder := llvm.OrcCreateLLJITBuilder()
    if jit_builder == nil {
        _ = libc.fprintf(libc.stderr, "Could not create LLJIT builder.\n")
        return false
    }

    jit: llvm.OrcLLJITRef
    if !report_llvm_error(llvm.OrcCreateLLJIT(&jit, jit_builder)) {
        return false
    }
    defer if jit != nil {
        _ = report_llvm_error(llvm.OrcDisposeLLJIT(jit))
    }

    dylib := llvm.OrcLLJITGetMainJITDylib(jit)
    if !register_host_symbols(jit, dylib) {
        return false
    }

    context_ref := llvm.ContextCreate()
    module := llvm.ModuleCreateWithNameInContext("my cool jit", context_ref)
    builder := llvm.CreateBuilderInContext(context_ref)
    defer {
        if builder != nil {
            llvm.DisposeBuilder(builder)
        }
        if module != nil {
            llvm.DisposeModule(module)
        }
        if context_ref != nil {
            llvm.ContextDispose(context_ref)
        }
    }

    llvm.SetDataLayout(module, llvm.OrcLLJITGetDataLayoutStr(jit))
    llvm.SetTarget(module, llvm.OrcLLJITGetTripleString(jit))
    ir := IR_Generator {
        ctx     = context_ref,
        module  = module,
        builder = builder,
    }
    _ = generate_exception_test(&ir)
    if !verify_module(module) {
        return false
    }

    llvm.DisposeBuilder(builder)
    builder = nil
    thread_safe_context := llvm.OrcCreateNewThreadSafeContextFromLLVMContext(context_ref)
    context_ref = nil
    if thread_safe_context == nil {
        _ = libc.fprintf(libc.stderr, "Could not create thread-safe LLVM context.\n")
        return false
    }
    thread_safe_module := llvm.OrcCreateNewThreadSafeModule(module, thread_safe_context)
    module = nil
    llvm.OrcDisposeThreadSafeContext(thread_safe_context)
    if thread_safe_module == nil {
        _ = libc.fprintf(libc.stderr, "Could not create thread-safe LLVM module.\n")
        return false
    }
    if !report_llvm_error(llvm.OrcLLJITAddLLVMIRModule(jit, dylib, thread_safe_module)) {
        return false
    }

    address: llvm.OrcExecutorAddress
    if !report_llvm_error(llvm.OrcLLJITLookup(jit, &address, "outerCatchFunct")) {
        return false
    }

    _ = libc.fprintf(libc.stderr, "\n\nBegin Test:\n")
    for type_to_throw in arguments {
        runExceptionThrow(rawptr(uintptr(address)), type_to_throw)
    }
    _ = libc.fprintf(libc.stderr, "\nEnd Test:\n\n")
    return true
}

print_usage :: proc() {
    _ = libc.fprintf(
        libc.stderr,
        "\nUsage: ExceptionDemo <exception type to throw> " +
        "[<type 2>...<type n>].\n" +
        "   Each type must have the value of 1 - 6 for " +
        "generated exceptions to be caught;\n" +
        "   the value -1 for foreign C++ exceptions to be " +
        "generated and thrown;\n" +
        "   or the values > 6 for exceptions to be ignored.\n" +
        "\nTry: ExceptionDemo 2 3 7 -1\n" +
        "   for a full test.\n\n",
    )
}

main :: proc() {
    if len(os.args) == 1 {
        print_usage()
        return
    }

    arguments := make([]i32, len(os.args) - 1, context.temp_allocator)
    for argument, index in os.args[1:] {
        value, ok := parse_exception_type(argument)
        if !ok {
            fmt.eprintf(
                "ExceptionDemo: invalid exception type `%s'; expected -1 or an integer from 1 through %d.\n",
                argument,
                max(i32),
            )
            libc.exit(1)
        }
        arguments[index] = value
    }

    if !run_demo(arguments) {
        libc.exit(1)
    }
}
