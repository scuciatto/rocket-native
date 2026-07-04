import Foundation

/// JSON coding tuned for Rocket.Chat payloads.
///
/// Dates arrive in three shapes depending on endpoint and record age:
/// ISO-8601 with fractional seconds ("2024-01-02T13:06:42.408Z"),
/// ISO-8601 without them, and Meteor-style `{"$date": <epoch ms>}`.
enum RCJSON {
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let string = try? container.decode(String.self) {
                if let date = (try? isoFractional.parse(string)) ?? (try? iso.parse(string)) {
                    return date
                }
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "Unrecognized date string: \(string)")
            }
            if let millis = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: millis / 1000)
            }
            let wrapper = try decoder.container(keyedBy: DollarDateKey.self)
            let millis = try wrapper.decode(Double.self, forKey: .date)
            return Date(timeIntervalSince1970: millis / 1000)
        }
        return decoder
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(isoFractional.format(date))
        }
        return encoder
    }

    /// Formats a date the way delta-sync params (`updatedSince`, `lastUpdate`) expect.
    static func syncTimestamp(_ date: Date) -> String {
        isoFractional.format(date)
    }

    private enum DollarDateKey: String, CodingKey {
        case date = "$date"
    }

    private static let isoFractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let iso = Date.ISO8601FormatStyle()
}
