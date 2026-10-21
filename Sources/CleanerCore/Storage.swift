import Foundation

public struct Storage: Sendable {
    public let directory: URL
    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CleanMyMacLocal", isDirectory: true)
    }
    public static func bundledRules() throws -> Rules {
        guard let url = Bundle.module.url(forResource: "rules", withExtension: "json") else {
            throw CleanerError.message("Falta el archivo de reglas de la aplicación.")
        }
        let rules = try JSONDecoder().decode(Rules.self, from: Data(contentsOf: url))
        try rules.validate()
        return rules
    }
    public func loadRules() throws -> Rules {
        let url = directory.appendingPathComponent("exclusions.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return Rules() }
        let rules = try JSONDecoder().decode(Rules.self, from: Data(contentsOf: url))
        try rules.validate()
        return rules
    }
    public func saveRules(_ rules: Rules) throws {
        try rules.validate()
        try write(rules, to: directory.appendingPathComponent("exclusions.json"))
    }
    @discardableResult public func saveReport(_ report: CleaningReport) throws -> URL {
        let url = directory.appendingPathComponent("Reports", isDirectory: true).appendingPathComponent("\(UUID().uuidString).json")
        try write(report, to: url)
        return url
    }
    private func write(_ value: some Encodable, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
