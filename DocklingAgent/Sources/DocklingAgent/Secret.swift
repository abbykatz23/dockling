import Foundation
import Security

/// Per-install shared secret so only real Claude Code hook events (and the
/// dispatcher's own forwards to session children) are accepted on the local
/// HTTP ports — otherwise any other local process could POST a fake event.
/// See DOCKLING_SPEC.md's Security & Privacy section ("local channel auth").
/// Self-bootstrapping: generated on first use if not already present, so
/// this works even without running install.sh.
enum DocklingSecret {
    private static let directory = (NSHomeDirectory() as NSString).appendingPathComponent(".dockling")
    static let path = (directory as NSString).appendingPathComponent("secret")

    static func load() -> String {
        let fileManager = FileManager.default
        if let existing = try? String(contentsOfFile: path, encoding: .utf8) {
            let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }

        let token = generateToken()
        try? fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        fileManager.createFile(atPath: path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600])
        return token
    }

    private static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let result = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(result == errSecSuccess, "unable to generate a random Dockling secret")
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
