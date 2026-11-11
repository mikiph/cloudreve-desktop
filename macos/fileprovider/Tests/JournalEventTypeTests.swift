import Foundation

@main
enum JournalEventTypeTests {
    static func main() throws {
        let path = CommandLine.arguments[1]
        let text = try String(contentsOfFile: path, encoding: .utf8)
        var host: Set<String> = []
        var extensionTypes: Set<String> = []
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let parts = line.split(separator: " ")
            guard parts.count == 2 else { continue }
            switch parts[1] {
            case "host": host.insert(String(parts[0]))
            case "extension": extensionTypes.insert(String(parts[0]))
            default: preconditionFailure("unknown writer in fixture: \(line)")
            }
        }
        precondition(host == JournalEventType.hostWritten,
            "host types differ from fixture: \(host.symmetricDifference(JournalEventType.hostWritten))")
        precondition(extensionTypes == JournalEventType.extensionWritten,
            "extension types differ from fixture")
        print("JournalEventTypeTests: all tests passed")
    }
}
