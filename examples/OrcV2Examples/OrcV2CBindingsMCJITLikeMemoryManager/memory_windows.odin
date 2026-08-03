#+build windows

package main

import windows "core:sys/windows"

foreign import kernel32 "system:Kernel32.lib"

@(default_calling_convention = "system")
foreign kernel32 {
    FlushInstructionCache :: proc(process: windows.HANDLE, base_address: rawptr, size: windows.SIZE_T) -> windows.BOOL ---
}

memory_page_size :: proc() -> uintptr {
    system_info: windows.SYSTEM_INFO
    windows.GetSystemInfo(&system_info)
    return uintptr(system_info.dwPageSize)
}

allocate_section_memory :: proc(size: uintptr) -> rawptr {
    return windows.VirtualAlloc(
        nil,
        windows.SIZE_T(size),
        windows.MEM_RESERVE | windows.MEM_COMMIT,
        windows.PAGE_READWRITE,
    )
}

protect_section_memory :: proc(pointer: rawptr, size: uintptr, kind: Section_Kind) -> bool {
    protection: windows.DWORD
    switch kind {
    case .Code:
        protection = windows.PAGE_EXECUTE_READ
    case .Read_Only_Data:
        protection = windows.PAGE_READONLY
    case .Writable_Data:
        protection = windows.PAGE_READWRITE
    }
    old_protection: windows.DWORD
    return bool(windows.VirtualProtect(pointer, windows.SIZE_T(size), protection, &old_protection))
}

flush_instruction_cache :: proc(pointer: rawptr, size: uintptr) -> bool {
    if size == 0 {
        return true
    }
    return bool(FlushInstructionCache(windows.GetCurrentProcess(), pointer, windows.SIZE_T(size)))
}

release_section_memory :: proc(pointer: rawptr, _: uintptr) -> bool {
    return bool(windows.VirtualFree(pointer, 0, windows.MEM_RELEASE))
}
