import Foundation

/// Client-side check for names Cloudreve refuses. macOS cannot block a rename
/// in Finder, so the extension fails the operation before it reaches the server.
enum NameValidation {
    /// Characters Cloudreve forbids in file names (only `?` verified live).
    static let forbidden: Set<Character> = ["\\", "/", ":", "*", "?", "\"", "<", ">", "|"]

    static func validate(_ name: String) throws {
        if name.isEmpty {
            throw CloudreveError.invalidName("empty name")
        }
        if name == "." || name == ".." {
            throw CloudreveError.invalidName(name)
        }
        let bad = name.filter { forbidden.contains($0) }
        if !bad.isEmpty {
            throw CloudreveError.invalidName(bad)
        }
    }
}
