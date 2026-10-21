#[path = "scanner.rs"]
mod scanner;
use std::{ffi::{CStr, c_char}, os::unix::ffi::OsStrExt, path::Path};

// Caller owns a valid NUL-terminated path and a writable Stats for the duration of this call.
#[no_mangle]
pub unsafe extern "C" fn rust_scan(path: *const c_char, workers: usize, output: *mut scanner::Stats) -> i32 {
    if path.is_null() || output.is_null() { return -1 }
    let result = std::panic::catch_unwind(|| {
        let bytes = unsafe { CStr::from_ptr(path) }.to_bytes();
        scanner::scan_categories(Path::new(std::ffi::OsStr::from_bytes(bytes)), workers)
    });
    match result {
        Ok(Ok(stats)) => { unsafe { output.write(stats) }; 0 }
        _ => -1,
    }
}
