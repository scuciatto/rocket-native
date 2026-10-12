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

private let listJSON = """
{
  "emojis": {
    "update": [
      {"_id": "e1", "name": "party_parrot", "aliases": ["pp", "parrot"],
       "extension": "gif", "etag": "a1b2c3", "_updatedAt": "2026-01-02T00:00:00.000Z"},
      {"_id": "e2", "name": "shipit", "aliases": [], "extension": "png",
       "_updatedAt": "2026-01-01T00:00:00.000Z"},
      {"_id": "bad", "aliases": []}
    ],
    "remove": [
      {"_id": "e0", "name": "gone", "_deletedAt": "2026-01-01T00:00:00.000Z",
       "__collection__": "custom_emoji"}
    ]
  },
  "success": true
}
"""

@Suite struct CustomEmojiTests {
    @Test func listOmitsUpdatedSinceWhenNil() async throws {
        let transport = MockHTTPTransport()
        transport.expect { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems ?? []
            #expect(request.url!.path().hasSuffix("emoji-custom.list"))
            #expect(!query.contains { $0.name == "updatedSince" })
            return (Data(listJSON.utf8),
                    MockHTTPTransport.httpResponse(url: request.url!, status: 200))
        }
        let client = await makeClient(transport)
        _ = try await client.customEmojis()
    }

    @Test func listSendsUpdatedSinceAndDropsMalformedRecords() async throws {
        let transport = MockHTTPTransport()
        transport.expect { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems ?? []
            #expect(query.first { $0.name == "updatedSince" }?.value?.hasSuffix("Z") == true)
            return (Data(listJSON.utf8),
                    MockHTTPTransport.httpResponse(url: request.url!, status: 200))
        }
        let client = await makeClient(transport)
        let delta = try await client.customEmojis(
            updatedSince: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(delta.update.map(\._id) == ["e1", "e2"])
        #expect(delta.update[0].aliases == ["pp", "parrot"])
        #expect(delta.update[0].etag == "a1b2c3")
        #expect(delta.remove == ["e0"])
    }

    @Test func indexResolvesNamesAndAliases() {
        let index = CustomEmojiIndex([
            CustomEmoji(_id: "e1", name: "party_parrot", aliases: ["pp"], extension: "gif"),
        ])
        #expect(index.emoji(forShortCode: "party_parrot")?._id == "e1")
        #expect(index.emoji(forShortCode: ":pp:")?.name == "party_parrot")
        #expect(index.emoji(forShortCode: "nope") == nil)
    }

    @Test func indexAppliesRemovalsAndRenames() {
        let old = Date(timeIntervalSince1970: 1_000)
        let new = Date(timeIntervalSince1970: 2_000)
        var index = CustomEmojiIndex([
            CustomEmoji(_id: "e1", name: "old_name", aliases: ["alias"],
                        extension: "png", _updatedAt: old),
            CustomEmoji(_id: "e2", name: "doomed", extension: "png", _updatedAt: old),
        ])
        index.apply(CustomEmojiDelta(
            update: [CustomEmoji(_id: "e1", name: "new_name", extension: "png",
                                 _updatedAt: new)],
            remove: ["e2"]))
        #expect(index.emoji(forShortCode: "old_name") == nil)
        #expect(index.emoji(forShortCode: "alias") == nil)
        #expect(index.emoji(forShortCode: "new_name")?._id == "e1")
        #expect(index.emoji(forShortCode: "doomed") == nil)
        #expect(index.watermark == new)
    }

    @Test func imageURLEncodesNameAndCarriesEtag() {
        let client = RocketChatClient(serverURL: serverURL)
        let plain = client.customEmojiURL(
            CustomEmoji(_id: "e", name: "shipit", extension: "png"))
        #expect(plain.absoluteString == "https://chat.example.com/emoji-custom/shipit.png")
        let tagged = client.customEmojiURL(
            CustomEmoji(_id: "e", name: "a b", extension: "gif", etag: "x1"))
        #expect(tagged.absoluteString
            == "https://chat.example.com/emoji-custom/a%20b.gif?etag=x1")
    }
}
