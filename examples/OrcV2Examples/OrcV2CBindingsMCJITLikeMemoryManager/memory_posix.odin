#+build darwin, linux

package main

import "core:c"
import sys_llvm "core:sys/llvm"
import "core:sys/posix"

memory_page_size :: proc() -> uintptr {
    size := posix.sysconf(._PAGESIZE)
    if size <= 0 {
        return 0
    }
    return uintptr(size)
}

allocate_section_memory :: proc(size: uintptr) -> rawptr {
    pointer := posix.mmap(nil, c.size_t(size), {.READ, .WRITE}, {.PRIVATE, .ANONYMOUS})
    if pointer == posix.MAP_FAILED {
        return nil
    }
    return pointer
}

protect_section_memory :: proc(pointer: rawptr, size: uintptr, kind: Section_Kind) -> bool {
    protection: posix.Prot_Flags
    switch kind {
    case .Code:
        protection = {.READ, .EXEC}
    case .Read_Only_Data:
        protection = {.READ}
    case .Writable_Data:
        protection = {.READ, .WRITE}
    }
    return posix.mprotect(pointer, c.size_t(size), protection) == .OK
}

flush_instruction_cache :: proc(pointer: rawptr, size: uintptr) -> bool {
    if size != 0 {
        sys_llvm.clear_cache(pointer, rawptr(uintptr(pointer) + size))
    }
    return true
}

release_section_memory :: proc(pointer: rawptr, size: uintptr) -> bool {
    return posix.munmap(pointer, c.size_t(size)) == .OK
}
