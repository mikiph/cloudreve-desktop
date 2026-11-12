import Foundation

/// Which transport a Cloudreve upload session requires.
enum UploadTargetKind: Equatable {
    /// Local policy, relay, or any same-origin upload URL.
    case cloudreve
    /// Remote (slave node) policy with a session credential.
    case slave
    /// "s3", "ks3", "cos", "oss" or "obs".
    case s3Like(String)
    case oneDrive
    case qiniu
    case upyun
    case unsupported(String)
}

/// Pure, network-free helpers for uploading directly to storage providers.
enum ObjectStorageUpload {
    /// Decide the transport. `firstURLIsSameOrigin` is nil when there are no upload URLs.
    static func target(
        policyType: String?, uploadURLCount: Int, firstURLIsSameOrigin: Bool?,
        hasSlaveCredential: Bool
    ) -> UploadTargetKind {
        if uploadURLCount == 0 { return .cloudreve }
        if firstURLIsSameOrigin == true { return .cloudreve }
        if policyType == "remote" && hasSlaveCredential { return .slave }
        switch policyType {
        case "s3", "ks3", "cos", "oss", "obs": return .s3Like(policyType!)
        case "onedrive": return .oneDrive
        case "qiniu": return .qiniu
        case "upyun": return .upyun
        default: return .unsupported(policyType ?? "unknown")
        }
    }

    static func chunkCount(size: Int64, chunkSize: Int64) -> Int {
        let chunk = max(chunkSize, 1)
        guard size > 0 else { return 1 }
        return Int((size + chunk - 1) / chunk)
    }

    static func trimmedETag(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"")) else { return nil }
        return value.isEmpty ? nil : value
    }

    private static func xmlEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func completeMultipartXML(etags: [String]) -> Data {
        var xml = "<CompleteMultipartUpload>"
        for (index, etag) in etags.enumerated() {
            xml += "<Part><PartNumber>\(index + 1)</PartNumber><ETag>\(xmlEscaped(etag))</ETag></Part>"
        }
        xml += "</CompleteMultipartUpload>"
        return Data(xml.utf8)
    }

    static func oneDriveContentRange(offset: Int64, length: Int, total: Int64) -> String {
        "bytes \(offset)-\(offset + Int64(length) - 1)/\(total)"
    }

    static func qiniuPartURL(base: String, index: Int) -> URL? {
        URL(string: "\(base)/\(index + 1)")
    }

    static func qiniuCompleteBody(etags: [String], mimeType: String?) -> Data {
        let parts: [[String: Any]] = etags.enumerated().map {
            ["etag": $0.element, "partNumber": $0.offset + 1]
        }
        var object: [String: Any] = ["parts": parts]
        if let mimeType { object["mimeType"] = mimeType }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    static func upyunMultipartBody(
        policy: String, authorization: String, mimeType: String?, fileData: Data, boundary: String
    ) -> Data {
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("policy", policy)
        field("authorization", authorization)
        if let mimeType { field("content-type", mimeType) }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"file\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(fileData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    static func callbackPath(policyType: String, sessionID: String, secret: String) -> String {
        "/callback/\(policyType)/\(sessionID)/\(secret)"
    }
}
