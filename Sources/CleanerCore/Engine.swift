import Foundation
import CleanerBridge

// Only cancel may run concurrently with actor calls; Rust implements it with an atomic.
private final class SessionHandle: @unchecked Sendable {
    let pointer: OpaquePointer
    init(_ pointer: OpaquePointer) { self.pointer = pointer }
    deinit { cm_session_free(pointer) }
}
// The actor serializes polling and validation; Rust owns its independent scan workers.
public actor Engine {
    private let handle: SessionHandle
    private var session: OpaquePointer { handle.pointer }
    public init(home: URL, rules: Rules, installedBundleIDs: Set<String> = [], containerOwners: [String: String] = [:], targets: [ScanTarget] = [], runningBundleIDs: Set<String> = [], cacheOwners: [String: String] = [:], includeDefaultCategories: Bool = true) throws {
        try rules.validate()
        struct Request: Encodable {
            let version = 1
            let home: String
            let rules: Rules
            let installed_bundle_ids: Set<String>
            let container_owners: [String: String]
            let cache_owners: [String: String]
            let targets: [ScanTarget]
            let running_bundle_ids: Set<String>
            let include_default_categories: Bool
        }
        let request = Request(home: home.resolvingSymlinksInPath().path, rules: rules,
                              installed_bundle_ids: installedBundleIDs, container_owners: containerOwners, cache_owners: cacheOwners, targets: targets, running_bundle_ids: runningBundleIDs, include_default_categories: includeDefaultCategories)
        let data = try JSONEncoder().encode(request)
        guard let pointer = data.withUnsafeBytes({ cm_session_new($0.bindMemory(to: UInt8.self).baseAddress, $0.count) }) else {
            throw CleanerError.message("No se pudo iniciar el motor. Comprueba HOME y el formato de reglas.")
        }
        handle = SessionHandle(pointer)
    }
    private func decode<T: Decodable>(_ buffer: CMBuffer, as type: T.Type) throws -> T {
        defer { cm_buffer_free(buffer) }
        guard let data = buffer.data, buffer.len > 0 else { throw CleanerError.message("El motor devolvió una respuesta vacía.") }
        return try JSONDecoder().decode(type, from: Data(bytes: data, count: buffer.len))
    }
    public func poll() throws -> ScanBatch {
        let batch = try decode(cm_session_poll(session), as: ScanBatch.self)
        guard batch.version == 1 else { throw CleanerError.message("Versión del motor incompatible.") }
        return batch
    }
    public nonisolated func cancel() { cm_session_cancel(handle.pointer) }
    public func validate(id: String, rules: Rules, runningBundleIDs: Set<String>) throws -> Validation {
        try rules.validate()
        struct Request: Encodable {
            let version = 1
            let id: String
            let rules: Rules
            let running_bundle_ids: Set<String>
        }
        let data = try JSONEncoder().encode(Request(id: id, rules: rules, running_bundle_ids: runningBundleIDs))
        let result = try data.withUnsafeBytes {
            try decode(cm_session_validate(session, $0.bindMemory(to: UInt8.self).baseAddress, $0.count), as: Validation.self)
        }
        guard result.version == 1 else { throw CleanerError.message("Versión del motor incompatible.") }
        return result
    }
}
