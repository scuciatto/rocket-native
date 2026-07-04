import Testing
import Foundation
@testable import RocketChatSDK

@Suite struct RocketChatClientTests {
    @Test func clientKeepsServerURL() {
        let url = URL(string: "https://open.rocket.chat")!
        let client = RocketChatClient(serverURL: url)
        #expect(client.serverURL == url)
    }
}
