import Foundation

public enum RocketChatError: Error, Sendable {
    case network(underlying: URLError)
    case httpError(status: Int, errorType: String?, message: String?)
    case twoFactorRequired(TwoFactorChallenge)
    case twoFactorInvalid(TwoFactorChallenge)
    case rateLimited(retryAfter: Date?)
    case notAuthenticated
    case decoding(description: String, endpoint: String)
    case invalidServerURL
    /// The call was abandoned before completing — including a 2FA prompt the
    /// user dismissed (`TwoFactorCodeProvider` returned nil). Callers should
    /// treat it as a silent no-op, not an error to display.
    case cancelled
}

/// Body shape of Rocket.Chat API errors. Two envelopes exist in the wild:
/// `{"success": false, "error": "...", "errorType": "..."}` (most endpoints)
/// and `{"status": "error", "error": ..., "message": "..."}` (login, where a
/// 2FA challenge arrives as HTTP 401 with the code in `error`).
struct APIErrorBody: Decodable {
    var error: String?
    var errorType: String?
    var message: String?
    var details: TwoFactorDetails?

    struct TwoFactorDetails: Decodable {
        var method: String?
        var availableMethods: [String]?
        var codeGenerated: Bool?
        var emailOrUsername: String?
    }

    // `error` is sometimes a string, sometimes a number (login envelope).
    private enum CodingKeys: String, CodingKey {
        case error, errorType, message, details
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let string = try? container.decode(String.self, forKey: .error) {
            error = string
        } else if let number = try? container.decode(Double.self, forKey: .error) {
            error = String(number)
        }
        errorType = try container.decodeIfPresent(String.self, forKey: .errorType)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        details = try? container.decodeIfPresent(TwoFactorDetails.self, forKey: .details)
    }
}
