import Foundation

// Thin URLSession client for the CouchKing backend. NOTHING is hardcoded:
// serviceBase is user-entered (or arrives via account sync) exactly like the
// Android store flavor — the binary ships clean for App Store review.
struct API {
    static var serviceBase: String {
        get { UserDefaults.standard.string(forKey: "serviceBase") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "serviceBase") }
    }

    /// Raw fetch that keeps the HTTP status (the stream gate answers 429/503/403 with a reason).
    static func fetch(_ path: String, base: String? = nil, timeout: TimeInterval = 20) async throws -> (Data, Int) {
        let b = base ?? serviceBase
        guard !b.isEmpty, let url = URL(string: b + path) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        let (data, resp) = try await URLSession.shared.data(for: req)
        return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }

    static func get(_ path: String, base: String? = nil) async throws -> Data {
        let (data, code) = try await fetch(path, base: base)
        guard code == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    static func postJSON(_ path: String, body: [String: Any]) async throws -> [String: Any] {
        guard let url = URL(string: serviceBase + path) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 20
        let (data, _) = try await URLSession.shared.data(for: req)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    static func json(_ path: String, base: String? = nil) async throws -> [String: Any] {
        let d = try await get(path, base: base)
        return (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
    }

    /// Status-preserving JSON fetch: (body, status). Body is empty on non-JSON.
    static func jsonStatus(_ path: String, base: String? = nil) async throws -> ([String: Any], Int) {
        let (d, code) = try await fetch(path, base: base)
        return ((try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:], code)
    }

    /// Access-gate probe on a stream URL (Android liveTune gate): a 1-byte ranged GET that
    /// surfaces 429 (device cap) / 503 (capacity) / 403 (not on plan) BEFORE the player spins.
    static func probe(_ url: URL, timeout: TimeInterval = 8) async -> Int {
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        req.httpMethod = "HEAD"
        guard let r = try? await URLSession.shared.data(for: req) else { return 0 }
        return (r.1 as? HTTPURLResponse)?.statusCode ?? 0
    }

    /// base64url (IOS_CONTRACTS §4): standard base64 with + → -, / → _, padding stripped.
    static func b64url(_ s: String) -> String {
        Data(s.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The centered CouchKing modal copy for a gate status (Android showTopBanner reasons).
    static func gateReason(_ code: Int) -> String? {
        switch code {
        case 429: return "You're already watching on another device. Stop playback there to watch here."
        case 503: return "CouchKing is at full capacity right now — try again in a few minutes."
        case 403: return "This isn't part of your plan. Upgrade to watch it."
        default: return nil
        }
    }
}
