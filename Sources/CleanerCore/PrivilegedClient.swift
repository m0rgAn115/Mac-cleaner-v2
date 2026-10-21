import Foundation
import ServiceManagement
import Security
import PrivilegedProtocol

public enum PrivilegedAvailability: String, Sendable {
    case unavailable, notRegistered, requiresApproval, enabled, notFound
}
public struct PrivilegedStatus: Sendable {
    public let availability: PrivilegedAvailability
    public let message: String
    public let removalSupported: Bool
    public var canRegister: Bool { availability == .notRegistered }
    public var canScan: Bool { availability == .enabled }
}

/// Activation is an explicit UI action; construction and status inspection do not register a daemon.
@MainActor public final class PrivilegedClient {
    private let service = SMAppService.daemon(plistName: HelperConfiguration.plistName)
    private var connection: NSXPCConnection?
    public init() {}

    public func status() -> PrivilegedStatus {
        do { _ = try signingPreflight() }
        catch { return PrivilegedStatus(availability: .unavailable, message: error.localizedDescription, removalSupported: false) }
        switch service.status {
        case .notRegistered:
            return PrivilegedStatus(availability: .notRegistered, message: "El helper no está registrado. Activarlo requiere aprobación de macOS.", removalSupported: false)
        case .requiresApproval:
            return PrivilegedStatus(availability: .requiresApproval, message: "Autoriza CleanMyMacLocal en Ajustes del Sistema → General → Ítems de inicio y extensiones.", removalSupported: false)
        case .enabled:
            return PrivilegedStatus(availability: .enabled, message: "Helper autorizado por macOS. La limpieza del sistema es definitiva y requiere confirmación por selección.", removalSupported: true)
        case .notFound:
            return PrivilegedStatus(availability: .notFound, message: "macOS no encuentra el helper empaquetado; vuelve a instalar la aplicación firmada.", removalSupported: false)
        @unknown default:
            return PrivilegedStatus(availability: .unavailable, message: "Estado de autorización desconocido.", removalSupported: false)
        }
    }

    public func register() throws {
        _ = try signingPreflight()
        try service.register()
    }
    public func unregister() async throws {
        connection?.invalidate(); connection = nil
        try await service.unregister()
    }
    public func openApprovalSettings() { SMAppService.openSystemSettingsLoginItems() }
    public func disconnect() { connection?.invalidate(); connection = nil }

    public func scan(exclusions: HelperExclusions = HelperExclusions()) async throws -> HelperScanResponse {
        let result = try await send(HelperRequest(operation: .scanSystem, exclusions: exclusions))
        guard let scan = result.scan else { throw HelperSecurityError.message("Respuesta de escaneo incompleta.") }
        return scan
    }
    public func validate(scanID: String, token: String, exclusions: HelperExclusions = HelperExclusions()) async throws -> HelperValidation {
        let result = try await send(HelperRequest(operation: .validate, scanID: scanID, tokens: [token], exclusions: exclusions))
        guard let validation = result.validations?.first, validation.token == token else {
            throw HelperSecurityError.message("Respuesta de validación incompleta.")
        }
        return validation
    }
    public func remove(scanID: String, tokens: [String], confirmed: Bool, exclusions: HelperExclusions = HelperExclusions()) async throws -> HelperRemovalResponse {
        guard confirmed else { throw HelperSecurityError.message("Debes confirmar expresamente la eliminación definitiva de los elementos seleccionados.") }
        let result = try await send(HelperRequest(operation: .remove, scanID: scanID, tokens: tokens, confirmed: true, exclusions: exclusions))
        guard let removal = result.removal else { throw HelperSecurityError.message("Respuesta de limpieza incompleta.") }
        return removal
    }

    private func signingPreflight() throws -> HelperSigningIdentity {
        let identity = try HelperSigning.currentIdentity(expectedIdentifier: HelperConfiguration.appIdentifier)
        let bundle = Bundle.main.bundleURL
        let plist = bundle.appendingPathComponent("Contents/Library/LaunchDaemons/" + HelperConfiguration.plistName)
        let binary = bundle.appendingPathComponent(HelperConfiguration.executablePath)
        guard FileManager.default.fileExists(atPath: plist.path), FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw HelperSecurityError.message("Este paquete no incluye el LaunchDaemon y el ejecutable privilegiado.")
        }
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let text = HelperSigning.requirementString(identifier: HelperConfiguration.serviceName, teamID: identity.teamID)
        guard SecStaticCodeCreateWithPath(binary as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else {
            throw HelperSecurityError.message("La firma del helper no coincide con la identidad de la aplicación.")
        }
        var signingInfo: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &signingInfo) == errSecSuccess,
              let dictionary = signingInfo as? [String: Any], let flags = dictionary[kSecCodeInfoFlags as String] as? NSNumber,
              flags.uint32Value & SecCodeSignatureFlags.runtime.rawValue != 0 else {
            throw HelperSecurityError.message("El helper debe estar firmado con hardened runtime.")
        }
        return identity
    }

    private func liveConnection() throws -> NSXPCConnection {
        let identity = try signingPreflight()
        guard service.status == .enabled else { throw HelperSecurityError.message(status().message) }
        if let connection { return connection }
        let connection = NSXPCConnection(machServiceName: HelperConfiguration.serviceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: CleanerHelperProtocol.self)
        connection.setCodeSigningRequirement(HelperSigning.requirementString(identifier: HelperConfiguration.serviceName, teamID: identity.teamID))
        connection.invalidationHandler = { [weak self] in Task { @MainActor in self?.connection = nil } }
        connection.interruptionHandler = { [weak self] in Task { @MainActor in self?.disconnect() } }
        connection.activate()
        self.connection = connection
        return connection
    }

    private func send(_ request: HelperRequest) async throws -> HelperReply {
        guard request.tokens.count <= 1_000 else { throw HelperSecurityError.message("El lote excede 1 000 elementos; divide la selección.") }
        let connection = try liveConnection()
        let encoded = try JSONEncoder().encode(request)
        let reply: HelperReply = try await withCheckedThrowingContinuation { continuation in
            let waiter = HelperReplyWaiter(continuation)
            DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
                waiter.finish(.failure(HelperSecurityError.message("El helper no respondió en 60 segundos. El resultado es desconocido; vuelve a escanear antes de reintentar.")))
            }
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in waiter.finish(.failure(error)) }) as? CleanerHelperProtocol else {
                waiter.finish(.failure(HelperSecurityError.message("No se pudo conectar al helper autorizado."))); return
            }
            proxy.perform(encoded as NSData) { data in
                do { waiter.finish(.success(try JSONDecoder().decode(HelperReply.self, from: data as Data))) }
                catch { waiter.finish(.failure(error)) }
            }
        }
        guard reply.version == HelperConfiguration.version else { throw HelperSecurityError.message("Versión del helper incompatible.") }
        if let error = reply.error { throw HelperSecurityError.message(error) }
        return reply
    }
}

private final class HelperReplyWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<HelperReply, any Error>?
    init(_ continuation: CheckedContinuation<HelperReply, any Error>) { self.continuation = continuation }
    func finish(_ result: Result<HelperReply, any Error>) {
        lock.lock()
        let continuation = self.continuation; self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
