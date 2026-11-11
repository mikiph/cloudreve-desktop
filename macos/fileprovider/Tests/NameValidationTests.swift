import FileProvider
import Foundation

@main
enum NameValidationTests {
    static func rejected(_ name: String) -> Bool {
        do { try NameValidation.validate(name); return false } catch CloudreveError.invalidName { return true } catch { return false }
    }

    static func main() {
        for ch in NameValidation.forbidden {
            precondition(rejected("a\(ch)b.txt"), "should reject \(ch)")
        }
        for ch in ["\\", "/", ":", "*", "?", "\"", "<", ">", "|"] {
            precondition(rejected("a\(ch)b.txt"), "should reject literal \(ch)")
        }
        for ok in ["a b.txt", "a#b.txt", "a+b.txt", "100%.txt", "é.txt", ".hidden"] {
            precondition(!rejected(ok), "should accept \(ok)")
        }
        for bad in ["", ".", ".."] {
            precondition(rejected(bad), "should reject '\(bad)'")
        }
        let mapped = FileProviderEnumerator.mapError(CloudreveError.invalidName("?")) as NSError
        precondition(mapped.domain == NSFileProviderErrorDomain)
        precondition(mapped.code == NSFileProviderError.Code.cannotSynchronize.rawValue)
        precondition(mapped.localizedDescription.contains("Rename the item"))
        precondition(ReplayFailure.classify(CloudreveError.invalidName("?")) == .permanent)
        precondition(
            CloudreveError.invalidName("?").localizedDescription
                .hasPrefix("Cloudreve does not allow these characters in names"),
            "Rust INVALID_NAME_MESSAGE_PREFIX must match this message"
        )
        print("NameValidationTests passed")
    }
}
