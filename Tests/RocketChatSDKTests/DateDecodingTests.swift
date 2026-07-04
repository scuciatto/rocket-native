import Testing
import Foundation
@testable import RocketChatSDK

@Suite struct DateDecodingTests {
    private struct Wrapper: Decodable {
        var ts: Date
    }

    private func decode(_ json: String) throws -> Date {
        try RCJSON.decoder().decode(Wrapper.self, from: Data(json.utf8)).ts
    }

    @Test func decodesISO8601WithFractionalSeconds() throws {
        let date = try decode(#"{"ts": "2024-01-02T13:06:42.408Z"}"#)
        #expect(abs(date.timeIntervalSince1970 - 1704200802.408) < 0.001)
    }

    @Test func decodesISO8601WithoutFractionalSeconds() throws {
        let date = try decode(#"{"ts": "2024-01-02T13:06:42Z"}"#)
        #expect(abs(date.timeIntervalSince1970 - 1704200802) < 0.001)
    }

    @Test func decodesMeteorDollarDate() throws {
        let date = try decode(#"{"ts": {"$date": 1704200802408}}"#)
        #expect(abs(date.timeIntervalSince1970 - 1704200802.408) < 0.001)
    }

    @Test func decodesEpochMilliseconds() throws {
        let date = try decode(#"{"ts": 1704200802408}"#)
        #expect(abs(date.timeIntervalSince1970 - 1704200802.408) < 0.001)
    }

    @Test func syncTimestampRoundTrips() throws {
        let date = Date(timeIntervalSince1970: 1704200802.408)
        let formatted = RCJSON.syncTimestamp(date)
        #expect(formatted.hasPrefix("2024-01-02T13:06:42."))
        #expect(formatted.hasSuffix("Z"))
        let reparsed = try decode(#"{"ts": "\#(formatted)"}"#)
        #expect(abs(reparsed.timeIntervalSince(date)) < 0.002)
    }
}
