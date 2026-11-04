import Foundation

enum ItemIdentity {
    static let remotePrefix = "cloudreve-item:/"

    static func remoteID(_ fileID: String, fallbackURI: String) -> String {
        fileID.isEmpty ? fallbackURI : "\(remotePrefix)\(fileID)"
    }
}
