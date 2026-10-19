import Foundation

enum CredentialStore {
    private static let fileManager = FileManager.default
    private static var secretsDirectory: URL {
        fileManager.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
            .appendingPathComponent("XueScribe/Secrets",isDirectory:true)
    }
    private static var assemblyAIKeyURL: URL { secretsDirectory.appendingPathComponent("assemblyai.key",isDirectory:false) }
    private static var geminiKeyURL: URL { secretsDirectory.appendingPathComponent("gemini.key",isDirectory:false) }

    static var hasAssemblyAIKey: Bool { assemblyAIKey() != nil }
    static func assemblyAIKey() -> String? { read(assemblyAIKeyURL) }
    static func saveAssemblyAIKey(_ rawKey: String) throws { try save(rawKey,to:assemblyAIKeyURL) }
    static func deleteAssemblyAIKey() throws { try delete(assemblyAIKeyURL) }

    static var hasGeminiKey: Bool { geminiKey() != nil }
    static func geminiKey() -> String? { read(geminiKeyURL) }
    static func saveGeminiKey(_ rawKey: String) throws { try save(rawKey,to:geminiKeyURL) }
    static func deleteGeminiKey() throws { try delete(geminiKeyURL) }

    private static func read(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf:url),
              let key = String(data:data,encoding:.utf8)?.trimmingCharacters(in:.whitespacesAndNewlines),
              !key.isEmpty else { return nil }
        return key
    }

    private static func save(_ rawKey: String, to url: URL) throws {
        let key = rawKey.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !key.isEmpty else { try delete(url); return }
        try fileManager.createDirectory(at:secretsDirectory,withIntermediateDirectories:true,
                                        attributes:[.posixPermissions:0o700])
        try fileManager.setAttributes([.posixPermissions:0o700],ofItemAtPath:secretsDirectory.path)
        try Data(key.utf8).write(to:url,options:.atomic)
        try fileManager.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }

    private static func delete(_ url: URL) throws {
        guard fileManager.fileExists(atPath:url.path) else { return }
        try fileManager.removeItem(at:url)
    }
}
