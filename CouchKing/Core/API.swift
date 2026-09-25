import Foundation

// Thin URLSession client for the CouchKing backend. NOTHING is hardcoded:
// serviceBase is user-entered (or arrives via account sync) exactly like the
// Android store flavor — the binary ships clean for App Store review.
struct API {
    static var serviceBase: String {
        get { UserDefaults.standard.string(forKey: "serviceBase") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "serviceBase") }
    }

    static func get(_ path: String, base: String? = nil) async throws -> Data {
        let b = base ?? serviceBase
        guard !b.isEmpty, let url = URL(string: b + path) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
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
}
