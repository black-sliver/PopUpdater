const std = @import("std");
const BOOL = std.os.windows.BOOL;
const DWORD = std.os.windows.DWORD;
const HANDLE = std.os.windows.HANDLE;
const HINSTANCE = std.os.windows.HINSTANCE;
const HMODULE = std.os.windows.HMODULE;
const HWND = std.os.windows.HWND;

pub const PROCESS_TERMINATE: DWORD = 0x0001;

pub extern "kernel32" fn OpenProcess(
    dwDesiredAccess: DWORD,
    bInheritHandle: BOOL,
    dwProcessId: DWORD,
) callconv(.winapi) HANDLE;

pub extern "shell32" fn ShellExecuteW(
    hwnd: ?HWND,
    lpOperation: ?[*:0]const u16,
    lpFile: [*:0]const u16,
    lpParameters: ?[*:0]const u16,
    lpDirectory: ?[*:0]const u16,
    nShowCmd: c_int,
) callconv(.winapi) HINSTANCE;

pub extern "kernel32" fn GetModuleFileNameW(
    hmodule: ?HMODULE,
    lpFile: [*:0]u16,
    nSize: DWORD,
) callconv(.winapi) DWORD;

pub extern "kernel32" fn GetCurrentDirectoryW(
    nBufferLength: DWORD,
    lpBuffer: [*:0]u16,
) callconv(.winapi) DWORD;
