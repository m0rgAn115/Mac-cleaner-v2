import Foundation
import Darwin
import Security
import PrivilegedProtocol

private final class HelperSession: NSObject, CleanerHelperProtocol {
    private weak var connection: NSXPCConnection?
    private let pid: pid_t
    private let uid: uid_t
    private let requirement: SecRequirement
    private let scanner = SystemScanner()

    init(connection: NSXPCConnection, requirement: SecRequirement) {
        self.connection = connection; pid = connection.processIdentifier
        uid = connection.effectiveUserIdentifier; self.requirement = requirement
    }
    func perform(_ request: NSData, withReply reply: @escaping @Sendable (NSData) -> Void) {
        let result: HelperReply
        do {
            // NSXPC's requirement also authenticates every message against its kernel-backed peer identity.
            guard let connection, NSXPCConnection.current() === connection,
                  connection.processIdentifier == pid, connection.effectiveUserIdentifier == uid, uid != 0 else {
                throw HelperSecurityError.message("La identidad auditada de la conexión no coincide con la sesión.")
            }
            var guest: SecCode?
            let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
            guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest) == errSecSuccess, let guest,
                  SecCodeCheckValidity(guest, [], requirement) == errSecSuccess else {
                throw HelperSecurityError.message("La firma del cliente ya no satisface la identidad de la sesión.")
            }
            guard request.length <= 65_536 else { throw HelperSecurityError.message("Petición demasiado grande.") }
            let request = try JSONDecoder().decode(HelperRequest.self, from: request as Data)
            guard request.version == HelperConfiguration.version, request.tokens.count <= 1_000,
                  Set(request.tokens).count == request.tokens.count,
                  request.tokens.allSatisfy({ UUID(uuidString: $0) != nil }),
                  request.exclusions.paths.count <= 2_000, request.exclusions.names.count <= 2_000,
                  request.exclusions.paths.allSatisfy({ $0.hasPrefix("/") && !$0.split(separator: "/").contains("..") }),
                  request.exclusions.names.allSatisfy({ !$0.isEmpty && !$0.contains("/") }) else {
                throw HelperSecurityError.message("Versión, tokens o tamaño de lote no válidos.")
            }
            switch request.operation {
            case .scanSystem:
                guard request.tokens.isEmpty, request.scanID == nil, !request.confirmed else {
                    throw HelperSecurityError.message("Petición de escaneo no válida.")
                }
                result = HelperReply(scan: scanner.scan(exclusions: request.exclusions))
            case .validate:
                result = HelperReply(validations: request.tokens.map { scanner.validate(scanID: request.scanID, token: $0, exclusions: request.exclusions) })
            case .remove:
                result = HelperReply(removal: scanner.remove(scanID: request.scanID, tokens: request.tokens, confirmed: request.confirmed, exclusions: request.exclusions))
            }
        } catch { result = HelperReply(error: error.localizedDescription) }
        do { reply(try JSONEncoder().encode(result) as NSData) }
        catch { reply(Data("{\"version\":1,\"error\":\"No se pudo codificar la respuesta del helper.\"}".utf8) as NSData) }
    }
}

private final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    let requirement: SecRequirement
    let requirementText: String
    init(teamID: String) throws {
        requirementText = HelperSigning.requirementString(identifier: HelperConfiguration.appIdentifier, teamID: teamID)
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess, let requirement else {
            throw HelperSecurityError.message("No se pudo construir la política de autenticación XPC.")
        }
        self.requirement = requirement
    }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier != 0 else { return false }
        var guest: SecCode?
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: connection.processIdentifier)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest) == errSecSuccess, let guest,
              SecCodeCheckValidity(guest, [], requirement) == errSecSuccess,
              (try? HelperSigning.identity(of: guest)) != nil else { return false }
        // The listener and each accepted connection enforce the requirement before any operation is dispatched.
        connection.setCodeSigningRequirement(requirementText)
        connection.exportedInterface = NSXPCInterface(with: CleanerHelperProtocol.self)
        connection.exportedObject = HelperSession(connection: connection, requirement: requirement)
        connection.activate()
        return true
    }
}

if CommandLine.arguments == [CommandLine.arguments[0], "--self-test"] {
    do { print(try SystemScanner.selfTest()); exit(EXIT_SUCCESS) }
    catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(EXIT_FAILURE) }
}

do {
    guard CommandLine.arguments.count == 1 else { throw HelperSecurityError.message("El helper no admite comandos ni rutas arbitrarias.") }
    guard geteuid() == 0 else { throw HelperSecurityError.message("CleanerHelper solo puede iniciarse mediante el LaunchDaemon autorizado por macOS.") }
    let identity = try HelperSigning.currentIdentity(expectedIdentifier: HelperConfiguration.serviceName)
    let delegate = try HelperListenerDelegate(teamID: identity.teamID)
    let listener = NSXPCListener(machServiceName: HelperConfiguration.serviceName)
    listener.setConnectionCodeSigningRequirement(delegate.requirementText)
    listener.delegate = delegate
    listener.activate()
    withExtendedLifetime((listener, delegate)) { RunLoop.current.run() }
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(EXIT_FAILURE)
}
