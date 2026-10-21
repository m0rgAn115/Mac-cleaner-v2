import Foundation
import Darwin

struct Stats {
    var files: UInt64 = 0, dirs: UInt64 = 0, links: UInt64 = 0, bytes: UInt64 = 0
    var selected: UInt64 = 0, selectedBytes: UInt64 = 0, errors: UInt64 = 0
    mutating func add(_ s: Stats) {
        files += s.files; dirs += s.dirs; links += s.links; bytes += s.bytes
        selected += s.selected; selectedBytes += s.selectedBytes; errors += s.errors
    }
    mutating func file(_ name: String, _ size: UInt64) {
        files += 1; bytes += size
        if (name.hasSuffix(".log") && size > 10240) || (name.hasSuffix(".cache") && size > 0) {
            selected += 1; selectedBytes += size
        }
    }
}

func foundationScan(_ root: String) -> Stats {
    let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey]
    var s = Stats()
    var pending = [URL(fileURLWithPath: root, isDirectory: true)]
    let fm = FileManager()
    while let dir = pending.popLast() {
        s.dirs += 1
        autoreleasepool {
            do {
                for url in try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: Array(keys)) {
                    let name = url.lastPathComponent
                    if name == ".DS_Store" || name == ".protected" { continue }
                    do {
                        let values = try url.resourceValues(forKeys: keys)
                        if values.isSymbolicLink == true { s.links += 1 }
                        else if values.isDirectory == true { pending.append(url) }
                        else if values.isRegularFile == true {
                            guard let size = values.fileSize else { s.errors += 1; continue }
                            s.file(name, UInt64(size))
                        }
                    } catch { s.errors += 1 }
                }
            } catch { s.errors += 1 }
        }
    }
    return s
}

func posixScan(_ root: String) -> Stats {
    var s = Stats()
    var pending = [root]
    while let dir = pending.popLast() {
        s.dirs += 1
        guard let stream = opendir(dir) else { s.errors += 1; continue }
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { s.errors += 1 }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." || name == ".DS_Store" || name == ".protected" { continue }
            let path = dir + "/" + name
            var kind = entry.pointee.d_type
            var info = stat()
            var hasInfo = false
            if kind == UInt8(DT_UNKNOWN) {
                if lstat(path, &info) != 0 { s.errors += 1; continue }
                hasInfo = true
                switch info.st_mode & S_IFMT {
                case S_IFDIR: kind = UInt8(DT_DIR)
                case S_IFREG: kind = UInt8(DT_REG)
                case S_IFLNK: kind = UInt8(DT_LNK)
                default: break
                }
            }
            if kind == UInt8(DT_LNK) { s.links += 1 }
            else if kind == UInt8(DT_DIR) { pending.append(path) }
            else if kind == UInt8(DT_REG) {
                if !hasInfo && lstat(path, &info) != 0 { s.errors += 1; continue }
                s.file(name, UInt64(info.st_size))
            }
        }
        closedir(stream)
    }
    return s
}

final class Work: @unchecked Sendable {
    // Only the index and aggregate are shared; both are protected by this lock.
    let lock = NSLock()
    var next = 0
    var total = Stats()
    let roots: [String]
    let mode: String
    init(roots: [String], mode: String) { self.roots = roots; self.mode = mode }
    func run() {
        var local = Stats()
        while true {
            lock.lock()
            let i = next; next += 1
            lock.unlock()
            if i >= roots.count { break }
            local.add(mode == "foundation" ? foundationScan(roots[i]) : posixScan(roots[i]))
        }
        lock.lock(); total.add(local); lock.unlock()
    }
}

let args = CommandLine.arguments
let started = DispatchTime.now().uptimeNanoseconds
let root = args[1], workers = Int(args[2])!, mode = args[3]
let roots = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isDirectoryKey])
    .filter { try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true }
    .map(\.path).sorted()
let work = Work(roots: roots, mode: mode)
let queue = OperationQueue()
queue.maxConcurrentOperationCount = workers
for _ in 0..<workers { queue.addOperation { work.run() } }
queue.waitUntilAllOperationsAreFinished()
let seconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
let s = work.total
print("{\"files\":\(s.files),\"dirs\":\(s.dirs),\"links\":\(s.links),\"bytes\":\(s.bytes),\"selected\":\(s.selected),\"selected_bytes\":\(s.selectedBytes),\"errors\":\(s.errors),\"scan_seconds\":\(seconds)}")
