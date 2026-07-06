import Testing
import Foundation
@testable import RocketChatSDK

private let serverURL = URL(string: "https://chat.example.com")!

private func makeClient(_ transport: MockHTTPTransport) async -> RocketChatClient {
    let client = RocketChatClient(
        serverURL: serverURL, transport: transport, clock: TestClock())
    await client.adopt(credentials: AuthCredentials(authToken: "tok", userId: "uid-9"))
    return client
}

@Suite struct MultipartFormTests {
    @Test func encodesSingleFilePart() {
        let file = UploadableFile(
            data: Data("PNGBYTES".utf8), filename: "shot.png", mimeType: "image/png")
        let body = MultipartForm.encode(file: file, boundary: "BOUND")
        let text = String(data: body, encoding: .utf8)!

        #expect(text.hasPrefix("--BOUND\r\n"))
        #expect(text.contains(
            "Content-Disposition: form-data; name=\"file\"; filename=\"shot.png\""))
        #expect(text.contains("Content-Type: image/png\r\n\r\nPNGBYTES"))
        #expect(text.hasSuffix("\r\n--BOUND--\r\n"))
    }

    @Test func sanitizesHostileFilenames() {
        let file = UploadableFile(
            data: Data(), filename: "a\"b\r\nc.txt", mimeType: "text/plain")
        let body = MultipartForm.encode(file: file, boundary: "B")
        let text = String(data: body, encoding: .utf8)!
        #expect(text.contains("filename=\"a'b  c.txt\""))
    }
}

@Suite struct UploadFlowTests {
    @Test func uploadThenConfirmThenCatchUp() async throws {
        let transport = MockHTTPTransport()
        transport.respond(path: "channels.messages", json:
            #"{"messages": [], "count": 0, "offset": 0, "total": 0, "success": true}"#)
        transport.expect(path: "rooms.media/r1") { request in
            let contentType = request.value(forHTTPHeaderField: "Content-Type") ?? ""
            #expect(contentType.hasPrefix("multipart/form-data; boundary="))
            let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            #expect(body.contains("filename=\"notes.txt\""))
            #expect(body.contains("hello upload"))
            return (Data(#"{"file": {"_id": "file-1", "url": "/x"}, "success": true}"#.utf8),
                    MockHTTPTransport.httpResponse(url: request.url!, status: 200))
        }
        transport.expect(path: "rooms.mediaConfirm/r1/file-1") { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody!)
                as? [String: Any]
            #expect(body?["msg"] as? String == "here you go")
            return (Data("""
                {"message": {"_id": "m-up", "rid": "r1", "msg": "here you go",
                 "ts": "2024-01-02T10:00:00.000Z",
                 "u": {"_id": "uid-9", "username": "felipe"}}, "success": true}
                """.utf8),
                MockHTTPTransport.httpResponse(url: request.url!, status: 200))
        }
        transport.respond(path: "chat.syncMessages", json:
            #"{"result": {"updated": [], "deleted": []}, "success": true}"#)

        let client = await makeClient(transport)
        try await client.engine.openRoom("r1", startPolling: false)
        let handle = RoomHandle(roomId: "r1", engine: client.engine, client: client)

        let file = UploadableFile(
            data: Data("hello upload".utf8), filename: "notes.txt",
            mimeType: "text/plain")
        let message = try await handle.upload(file, text: "here you go")

        #expect(message?._id == "m-up")
        // Catch-up tick fired after the confirm.
        #expect(transport.requests.last?.url?.path()
            .hasSuffix("chat.syncMessages") == true)
    }

    @Test func threadUploadCarriesTmid() async throws {
        let transport = MockHTTPTransport()
        transport.respond(path: "rooms.media/r1", json:
            #"{"file": {"_id": "file-2"}, "success": true}"#)
        transport.expect(path: "rooms.mediaConfirm/r1/file-2") { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody!)
                as? [String: Any]
            #expect(body?["tmid"] as? String == "t1")
            return (Data(#"{"message": null, "success": true}"#.utf8),
                    MockHTTPTransport.httpResponse(url: request.url!, status: 200))
        }

        let client = await makeClient(transport)
        _ = try await client.uploadFile(
            UploadableFile(data: Data([1]), filename: "a.bin",
                           mimeType: "application/octet-stream"),
            roomId: "r1", threadId: "t1")
    }
}
