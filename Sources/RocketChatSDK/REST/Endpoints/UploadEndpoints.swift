import Foundation

/// A file to send into a room.
public struct UploadableFile: Sendable {
    public var data: Data
    public var filename: String
    public var mimeType: String

    public init(data: Data, filename: String, mimeType: String) {
        self.data = data
        self.filename = filename
        self.mimeType = mimeType
    }
}

/// `rooms.media` response: the file is uploaded but not yet posted.
struct MediaUploadResponse: Decodable, Sendable {
    var file: UploadedFile

    struct UploadedFile: Decodable, Sendable {
        var _id: String
        var url: String?
    }
}

/// `rooms.mediaConfirm` posts the uploaded file as a message.
struct MediaConfirmResponse: Decodable, Sendable {
    var message: Message?
}

enum MultipartForm {
    /// Encodes a single file part the way `rooms.media` expects.
    static func encode(file: UploadableFile, boundary: String) -> Data {
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data(
            "Content-Disposition: form-data; name=\"file\"; filename=\"\(sanitize(file.filename))\"\r\n"
                .utf8))
        body.append(Data("Content-Type: \(file.mimeType)\r\n\r\n".utf8))
        body.append(file.data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    /// Header-safe filename: strip quotes and CR/LF.
    private static func sanitize(_ filename: String) -> String {
        filename.replacingOccurrences(of: "\"", with: "'")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }
}

extension API.Rooms {
    /// Step 1: upload the bytes (not visible in the room yet).
    /// Uses `rooms.media` — `rooms.upload` was removed in Rocket.Chat 8.0.
    static func media(roomId: String, file: UploadableFile) -> Endpoint<MediaUploadResponse> {
        let boundary = "rc-sdk-\(MessageID.generate())"
        return Endpoint(
            path: "rooms.media/\(roomId)",
            method: .post,
            body: MultipartForm.encode(file: file, boundary: boundary),
            contentType: "multipart/form-data; boundary=\(boundary)")
    }

    /// Step 2: post the uploaded file as a message.
    static func mediaConfirm(
        roomId: String, fileId: String,
        text: String?, description: String?, threadId: String?
    ) -> Endpoint<MediaConfirmResponse> {
        struct Body: Encodable {
            var msg: String?
            var description: String?
            var tmid: String?
        }
        return .post(
            "rooms.mediaConfirm/\(roomId)/\(fileId)",
            body: Body(msg: text, description: description, tmid: threadId))
    }
}
