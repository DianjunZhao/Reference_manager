import CryptoKit
import Foundation

enum StableHash {
    static func sha256(_ text: String) -> String {
        sha256(Data(text.utf8))
    }

    /// Use this overload for downloaded documents and image bytes.  Hashing a
    /// base64 representation would be deterministic but would not be the
    /// SHA-256 integrity value of the original file.
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

protocol Clock: Sendable {
    func now() -> Date
}

struct SystemClock: Clock {
    func now() -> Date { Date() }
}

enum LatticeLensError: LocalizedError, Equatable, Sendable {
    case invalidResponse
    case httpStatus(Int)
    case malformedPayload
    case endpointChanged
    case paginationLimitExceeded
    case insecureExternalURL
    case missingCredential
    case schemaViolation(String)
    case cancelled
    case persistenceUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "服务返回了无法识别的响应。"
        case .httpStatus(let status): "服务请求失败（HTTP \(status)）。"
        case .malformedPayload: "服务返回的资料格式不完整或已变化。"
        case .endpointChanged: "分页链接不属于受信任的 INSPIRE 服务。"
        case .paginationLimitExceeded: "分页超过安全上限，已停止以避免重复请求。"
        case .insecureExternalURL: "外部链接必须使用 HTTPS。"
        case .missingCredential: "请先在设置中保存 API Key 和模型。"
        case .schemaViolation(let reason): "模型返回未通过资料边界验证：\(reason)"
        case .cancelled: "操作已取消。"
        case .persistenceUnavailable(let reason): "本地资料库不可安全写入：\(reason)"
        }
    }
}

extension DateFormatter {
    static let inspireDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
