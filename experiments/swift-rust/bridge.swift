import Foundation

let args = CommandLine.arguments
let started = DispatchTime.now().uptimeNanoseconds
var result = RustStats()
let status = args[1].withCString { rust_scan($0, Int(args[2])!, &result) }
guard status == 0 else { fatalError("Rust scan failed") }
let seconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
print("{\"files\":\(result.files),\"dirs\":\(result.dirs),\"links\":\(result.links),\"bytes\":\(result.bytes),\"selected\":\(result.selected),\"selected_bytes\":\(result.selected_bytes),\"errors\":\(result.errors),\"scan_seconds\":\(seconds)}")
