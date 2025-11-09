const std = @import("std");
const BOOL = std.os.windows.BOOL;
const DWORD = std.os.windows.DWORD;
const HANDLE = std.os.windows.HANDLE;

pub const PROCESS_TERMINATE: DWORD = 0x0001;

pub extern "kernel32" fn OpenProcess(
    dwDesiredAccess: DWORD,
    bInheritHandle: BOOL,
    dwProcessId: DWORD,
) callconv(.winapi) HANDLE;
