import Foundation
import Security

public enum HelperConfiguration {
    public static let appIdentifier = "local.cleanmymac.CleanMyMacLocal"
    public static let serviceName = "local.cleanmymac.CleanMyMacLocal.helper"
    public static let plistName = serviceName + ".plist"
    public static let executablePath = "Contents/Library/HelperTools/CleanerHelper"
    public static let quarantineName = serviceName + ".quarantine"
    public static let version = 1
}

public enum HelperOperation: String, Codable, Sendable { case scanSystem, validate, remove }

public struct HelperExclusions: Codable, Sendable {
    public let paths: [String]
    public let names: [String]
    public init(paths: [String] = [], names: [String] = []) { self.paths = paths; self.names = names }
}

/// There is intentionally no path, shell, executable or arbitrary root in requests.
public struct HelperRequest: Codable, Sendable {
    public let version: Int
    public let operation: HelperOperation
    public let scanID: String?
    public let tokens: [String]
    public let confirmed: Bool
    public let exclusions: HelperExclusions
    public init(operation: HelperOperation, scanID: String? = nil, tokens: [String] = [], confirmed: Bool = false, exclusions: HelperExclusions = HelperExclusions()) {
        version = HelperConfiguration.version; self.operation = operation
        self.scanID = scanID; self.tokens = tokens; self.confirmed = confirmed; self.exclusions = exclusions
    }
}

public struct HelperItem: Codable, Sendable, Identifiable {
    public let token: String
    public var id: String { token }
    public let path: String
    public let category: String
    public let logicalBytes: UInt64
    public let allocatedBytes: UInt64
    public let blockedReason: String?
    public let autoselected: Bool
    public init(token: String, path: String, category: String, logicalBytes: UInt64, allocatedBytes: UInt64,
                blockedReason: String? = nil, autoselected: Bool = false) {
        self.token = token; self.path = path; self.category = category
        self.logicalBytes = logicalBytes; self.allocatedBytes = allocatedBytes
        self.blockedReason = blockedReason; self.autoselected = autoselected
    }
}

public struct HelperIssue: Codable, Sendable {
    public let path: String
    public let message: String
    public init(path: String, message: String) { self.path = path; self.message = message }
}

public struct HelperScanResponse: Codable, Sendable {
    public let scanID: String
    public let items: [HelperItem]
    public let issues: [HelperIssue]
    public let removalSupported: Bool
    public init(scanID: String, items: [HelperItem], issues: [HelperIssue], removalSupported: Bool) {
        self.scanID = scanID; self.items = items; self.issues = issues; self.removalSupported = removalSupported
    }
}

public struct HelperValidation: Codable, Sendable {
    public let token: String
    public let valid: Bool
    public let reason: String?
    public init(token: String, valid: Bool, reason: String? = nil) { self.token = token; self.valid = valid; self.reason = reason }
}

public struct HelperOutcome: Codable, Sendable {
    public let token: String
    public let path: String?
    public let status: String
    public let message: String?
    public let quarantinePath: String?
    public init(token: String, path: String?, status: String, message: String? = nil, quarantinePath: String? = nil) {
        self.token = token; self.path = path; self.status = status; self.message = message; self.quarantinePath = quarantinePath
    }
}

public struct HelperRemovalResponse: Codable, Sendable {
    public let outcomes: [HelperOutcome]
    public init(outcomes: [HelperOutcome]) { self.outcomes = outcomes }
}

public struct HelperReply: Codable, Sendable {
    public let version: Int
    public let scan: HelperScanResponse?
    public let validations: [HelperValidation]?
    public let removal: HelperRemovalResponse?
    public let error: String?
    public init(scan: HelperScanResponse? = nil, validations: [HelperValidation]? = nil,
                removal: HelperRemovalResponse? = nil, error: String? = nil) {
        version = HelperConfiguration.version; self.scan = scan
        self.validations = validations; self.removal = removal; self.error = error
    }
}

@objc public protocol CleanerHelperProtocol {
    func perform(_ request: NSData, withReply reply: @escaping @Sendable (NSData) -> Void)
}

public struct HelperSigningIdentity: Sendable {
    public let teamID: String
    public let identifier: String
}

public enum HelperSecurityError: Error, LocalizedError {
    case message(String)
    public var errorDescription: String? { if case let .message(message) = self { message } else { nil } }
}

/// Shared policy: Apple-anchored Team ID plus hardened runtime; no ad-hoc identity fallback.
public enum HelperSigning {
    public static func identity(of code: SecCode) throws -> HelperSigningIdentity {
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            throw HelperSecurityError.message("No se pudo comprobar la firma estática del proceso.")
        }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any],
              let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String,
              team.count == 10, team.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }),
              let identifier = dictionary[kSecCodeInfoIdentifier as String] as? String,
              identifier.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ".-_".contains($0)) }),
              let flags = dictionary[kSecCodeInfoFlags as String] as? NSNumber,
              flags.uint32Value & SecCodeSignatureFlags.adhoc.rawValue == 0 else {
            throw HelperSecurityError.message("El helper requiere firma Apple con Team ID; la firma ad hoc local no permite autenticar esta función privilegiada.")
        }
        guard flags.uint32Value & SecCodeSignatureFlags.runtime.rawValue != 0 else {
            throw HelperSecurityError.message("La aplicación y el helper deben firmarse con hardened runtime.")
        }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementString(identifier: identifier, teamID: team) as CFString,
                                              [], &requirement) == errSecSuccess,
              SecCodeCheckValidity(code, [], requirement) == errSecSuccess else {
            throw HelperSecurityError.message("La firma no satisface la identidad Apple esperada o permite depuración.")
        }
        return HelperSigningIdentity(teamID: team, identifier: identifier)
    }
    public static func currentIdentity(expectedIdentifier: String) throws -> HelperSigningIdentity {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
            throw HelperSecurityError.message("No se pudo verificar la firma del proceso.")
        }
        let identity = try identity(of: code)
        guard identity.identifier == expectedIdentifier else {
            throw HelperSecurityError.message("El identificador firmado no corresponde a este componente.")
        }
        return identity
    }
    public static func requirementString(identifier: String, teamID: String) -> String {
        // Only these fixed identifiers and a validated Team ID reach the requirement parser.
        "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(teamID)\" and entitlement[\"com.apple.security.get-task-allow\"] != true"
    }
}
