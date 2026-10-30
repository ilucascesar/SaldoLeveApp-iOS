import Foundation

/// One HTTPS origin keeps PHP sessions, relative URLs and CSRF checks intact.
struct SiteAddress: Equatable {
    let home: URL

    init?(_ text: String) {
        guard var parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.path.hasSuffix("/sistema.php") else { return nil }
        parts.scheme = "https"
        parts.host = host.lowercased()
        if parts.port == 443 { parts.port = nil }
        guard let url = parts.url else { return nil }
        home = url
    }

    func contains(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.host?.lowercased() == home.host?.lowercased()
            && (url.port ?? 443) == (home.port ?? 443)
            && url.user == nil && url.password == nil
    }

    var origin: String {
        var parts = URLComponents(url: home, resolvingAgainstBaseURL: false)!
        parts.path = ""
        return parts.string!
    }
}
