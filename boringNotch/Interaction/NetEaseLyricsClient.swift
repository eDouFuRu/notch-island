import Foundation

enum NetEaseLyricsError: Error {
    case response(Int), service(Int), oversizedResponse, rateLimited, insecureRedirect
}

private final class NetEaseLyricsRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(NetEaseLyricsClient.isAllowedURL(request.url) ? request : nil)
    }
}

/// Anonymous discovery of the current recording followed by its original timed
/// lyrics. No player files, login cookies, translated lyrics or romanized lyrics
/// are used. Metadata must identify one recording before a lyric is requested.
actor NetEaseLyricsClient {
    private let session: URLSession
    private let retryDelay: TimeInterval
    private var blockedUntil = Date.distantPast
    private var nextRequestAt = Date.distantPast

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: NetEaseLyricsRedirectPolicy(), delegateQueue: nil)
        retryDelay = 0.8
    }

    /// The offline harness supplies a URLProtocol-backed session. Production
    /// always uses the anonymous, HTTPS-only configuration above.
    init(session: URLSession, retryDelay: TimeInterval = 0.8) {
        self.session = session
        self.retryDelay = max(0.01, retryDelay)
    }

    func lookup(_ track: LyricsTrack) async throws -> LyricsDocument? {
        guard track.canSearch else { return nil }
        let searchURL = makeURL(path: "search/get", items: [
            URLQueryItem(name: "s", value: track.title + " " + track.artist),
            URLQueryItem(name: "type", value: "1"),
            URLQueryItem(name: "limit", value: "30"),
            URLQueryItem(name: "offset", value: "0")
        ])
        guard let searchData = try await data(from: searchURL) else { return nil }
        let search = try JSONDecoder().decode(NetEaseSearchResponse.self, from: searchData)
        try validateServiceCode(search.code)
        guard let match = NetEaseSongRecord.bestMatch(search.result?.songs ?? [], track: track, searchCount: 30) else { return nil }
        try Task.checkCancellation()
        let lyricURL = makeURL(path: "song/lyric", items: [
            URLQueryItem(name: "id", value: String(match.id)),
            URLQueryItem(name: "lv", value: "-1"),
            URLQueryItem(name: "tv", value: "-1"),
            URLQueryItem(name: "rv", value: "-1")
        ])
        guard let lyricData = try await data(from: lyricURL) else { return nil }
        let response = try JSONDecoder().decode(NetEaseLyricResponse.self, from: lyricData)
        try validateServiceCode(response.code)
        try Task.checkCancellation()
        return response.document
    }

    nonisolated fileprivate static func isAllowedURL(_ url: URL?) -> Bool {
        url?.scheme == "https" && url?.host == "music.163.com" && (url?.port == nil || url?.port == 443)
    }

    private func makeURL(path: String, items: [URLQueryItem]) -> URL {
        var components = URLComponents(string: "https://music.163.com/api/" + path)!
        components.queryItems = items
        return components.url!
    }

    private func validateServiceCode(_ code: Int) throws {
        // A successful HTTP response can still be a service error; never cache
        // that as a genuine lack of lyrics. Respect throttling at either layer.
        if code == 429 {
            blockedUntil = Date().addingTimeInterval(60)
            throw NetEaseLyricsError.rateLimited
        }
        guard code == 200 else { throw NetEaseLyricsError.service(code) }
    }

    private func data(from url: URL, attempt: Int = 0) async throws -> Data? {
        try Task.checkCancellation()
        guard Date() >= blockedUntil else { throw NetEaseLyricsError.rateLimited }
        // Reserve a slot before awaiting, so actor reentrancy cannot turn a
        // quick track change into simultaneous discovery/lyric request bursts.
        let slot = max(Date(), nextRequestAt)
        nextRequestAt = slot.addingTimeInterval(0.2)
        let wait = slot.timeIntervalSinceNow
        if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
        try Task.checkCancellation()
        guard Date() >= blockedUntil else { throw NetEaseLyricsError.rateLimited }
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("NotchIsland/271 (anonymous original synchronized lyric lookup)", forHTTPHeaderField: "User-Agent")
        let body: Data
        let response: URLResponse
        do { (body, response) = try await session.data(for: request) }
        catch let error as URLError {
            try Task.checkCancellation()
            if attempt == 0 && [.timedOut, .networkConnectionLost, .cannotConnectToHost, .secureConnectionFailed].contains(error.code) {
                try await Task.sleep(for: .seconds(retryDelay))
                return try await data(from: url, attempt: 1)
            }
            throw error
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw NetEaseLyricsError.response(0) }
        guard Self.isAllowedURL(http.url) else { throw NetEaseLyricsError.insecureRedirect }
        if http.statusCode == 404 { return nil }
        if http.statusCode == 429 {
            let wait = Self.retryAfter(http.value(forHTTPHeaderField: "Retry-After"))
            blockedUntil = Date().addingTimeInterval(wait)
            if attempt == 0 && wait <= 2 {
                try await Task.sleep(for: .seconds(wait))
                return try await data(from: url, attempt: 1)
            }
            throw NetEaseLyricsError.rateLimited
        }
        if (500...599).contains(http.statusCode), attempt == 0 {
            try await Task.sleep(for: .seconds(retryDelay))
            return try await data(from: url, attempt: 1)
        }
        guard http.statusCode == 200 else { throw NetEaseLyricsError.response(http.statusCode) }
        guard body.count <= 2_000_000 else { throw NetEaseLyricsError.oversizedResponse }
        return body
    }

    private static func retryAfter(_ header: String?) -> TimeInterval {
        if let header, let seconds = Double(header), seconds.isFinite { return max(0.25, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let header, let date = formatter.date(from: header) { return max(0.25, date.timeIntervalSinceNow) }
        return 60
    }
}
