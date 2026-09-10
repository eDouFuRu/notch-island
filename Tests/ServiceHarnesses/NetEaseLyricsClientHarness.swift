import Foundation

// Synthetic text only: this executable never makes a real network request or
// embeds a copyrighted song's lyrics. It compiles the production client/core.
private struct HTTPReply {
    var status = 200
    var body = Data()
    var headers: [String: String] = [:]
    var error: URLError?
    var responseURL: URL?
}

private final class StubState: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [HTTPReply] = []
    private var captured: [URLRequest] = []
    func reset(_ replies: [HTTPReply]) { lock.withLock { self.replies = replies; captured = [] } }
    var requests: [URLRequest] { lock.withLock { captured } }
    func next(_ request: URLRequest) -> HTTPReply {
        lock.withLock {
            captured.append(request)
            return replies.isEmpty ? HTTPReply(error: URLError(.badServerResponse)) : replies.removeFirst()
        }
    }
}

private final class LyricsHTTPStub: URLProtocol {
    static let state = StubState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply = Self.state.next(request)
        if let error = reply.error { client?.urlProtocol(self, didFailWithError: error); return }
        let response = HTTPURLResponse(url: reply.responseURL ?? request.url!, statusCode: reply.status,
                                       httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct NetEaseLyricsClientHarness {
    static func main() async throws {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            guard condition() else { fatalError("FAIL: \(label)") }
            count += 1; print("PASS: \(label)")
        }
        func json(_ value: Any) -> Data { try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
        func search(album: String = "小岛日记", duration: Double = 180_000, count: Int = 1) -> Data {
            json(["code": 200, "result": ["songs": (0..<count).map { index in
                ["id": 101 + index, "name": "红薯之歌", "artists": [["name": "薯队长"]],
                 "album": ["name": album], "duration": duration] as [String: Any]
            }]])
        }
        let original = "[00:01.20]种一颗红薯\n[00:05.00]A little sunshine"
        let lyric = json(["code": 200, "lrc": ["lyric": original],
                          "romalrc": ["lyric": "[00:01.20]zhong yi ke hong shu"],
                          "tlyric": ["lyric": "[00:01.20]A translated line"]])
        let track = LyricsTrack(source: "com.netease.163music", title: "红薯之歌", artist: "薯队长", album: "小岛日记", duration: 180)
        func client(retryDelay: TimeInterval = 0.01) -> NetEaseLyricsClient {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [LyricsHTTPStub.self]
            configuration.httpCookieStorage = nil; configuration.urlCache = nil
            return NetEaseLyricsClient(session: URLSession(configuration: configuration), retryDelay: retryDelay)
        }
        func query(_ request: URLRequest) -> [String: String] {
            Dictionary(uniqueKeysWithValues: URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
        }
        let state = LyricsHTTPStub.state
        state.reset([HTTPReply(body: search()), HTTPReply(body: lyric)])
        let document = try await client().lookup(track)
        check(state.requests.count == 2, "Discovery completes before a single selected lyric request")
        check(state.requests[0].url!.path == "/api/search/get" && query(state.requests[0])["s"] == "红薯之歌 薯队长",
              "Search sends Unicode title/artist through encoded query parameters")
        check(query(state.requests[0])["type"] == "1" && query(state.requests[0])["limit"] == "30" && query(state.requests[0])["offset"] == "0",
              "Search is limited to the first 30 song records")
        check(state.requests[1].url!.path == "/api/song/lyric" && query(state.requests[1])["id"] == "101",
              "Lyric request uses the strictly matched recording identifier")
        check(state.requests.allSatisfy { !$0.httpShouldHandleCookies && $0.value(forHTTPHeaderField: "Cookie") == nil && $0.value(forHTTPHeaderField: "Authorization") == nil },
              "Requests contain no login cookie or authorization credential")
        check(document?.line(at: 1.2) == "种一颗红薯", "Original Chinese LRC wins over romanized and translated fields")
        check(document?.line(at: 5) == "A little sunshine", "Original English text remains English")

        state.reset([HTTPReply(body: search(album: "另一张专辑"))])
        let wrongAlbum = try await client().lookup(track)
        check(wrongAlbum == nil && state.requests.count == 1, "Different album never starts a lyric request")
        state.reset([HTTPReply(body: search(duration: 182_000))])
        let wrongDuration = try await client().lookup(track)
        check(wrongDuration == nil && state.requests.count == 1, "Different recording duration never starts a lyric request")
        state.reset([HTTPReply(body: search(count: 2))])
        let unknownAlbum = LyricsTrack(source: track.source, title: track.title, artist: track.artist, album: "", duration: 180)
        let ambiguous = try await client().lookup(unknownAlbum)
        check(ambiguous == nil && state.requests.count == 1, "Unknown album with multiple matches does not guess a recording")
        state.reset([HTTPReply(body: search()), HTTPReply(body: json(["code": 200, "romalrc": ["lyric": "[00:01]zhong yi ke hong shu"]]))])
        let romanizedOnly = try await client().lookup(track)
        check(romanizedOnly == nil, "A romanized-only payload is not substituted for the missing original lyric")

        state.reset([HTTPReply(body: json(["code": 403]))])
        do { _ = try await client().lookup(track); fatalError("Service error was cached as no match") }
        catch NetEaseLyricsError.service(403) { check(true, "HTTP 200 with failed service code is an explicit error") }
        state.reset([HTTPReply(status: 503), HTTPReply(body: search()), HTTPReply(body: lyric)])
        let recovered = try await client().lookup(track)
        check(recovered != nil && state.requests.count == 3, "One bounded server-error retry recovers normally")
        state.reset([HTTPReply(status: 503), HTTPReply(status: 503)])
        do { _ = try await client().lookup(track); fatalError("Repeated server error unexpectedly passed") }
        catch NetEaseLyricsError.response(503) { check(state.requests.count == 2, "Persistent server error stops after one retry") }
        state.reset([HTTPReply(error: URLError(.timedOut)), HTTPReply(body: search()), HTTPReply(body: lyric)])
        let timeoutRecovery = try await client().lookup(track)
        check(timeoutRecovery != nil && state.requests.count == 3, "Transient transport timeout retries once")
        state.reset([HTTPReply(error: URLError(.notConnectedToInternet))])
        do { _ = try await client().lookup(track); fatalError("Offline lookup unexpectedly passed") }
        catch let error as URLError { check(error.code == .notConnectedToInternet && state.requests.count == 1, "Offline failure does not busy-retry") }

        state.reset([HTTPReply(status: 429, headers: ["Retry-After": "30"])])
        let throttled = client()
        do { _ = try await throttled.lookup(track); fatalError("Rate limit unexpectedly passed") }
        catch NetEaseLyricsError.rateLimited { check(true, "Long Retry-After is retained without sleeping the caller") }
        do { _ = try await throttled.lookup(track); fatalError("Retry-After was bypassed") }
        catch NetEaseLyricsError.rateLimited { check(state.requests.count == 1, "A subsequent lookup cannot bypass server backoff") }
        state.reset([HTTPReply(status: 429, headers: ["Retry-After": "0.25"]), HTTPReply(body: search()), HTTPReply(body: lyric)])
        let shortBackoff = try await client().lookup(track)
        check(shortBackoff != nil && state.requests.count == 3, "Short Retry-After allows one sequential retry")
        state.reset([HTTPReply(body: json(["code": 429]))])
        let serviceThrottled = client()
        do { _ = try await serviceThrottled.lookup(track); fatalError("Service throttle unexpectedly passed") }
        catch NetEaseLyricsError.rateLimited { }
        do { _ = try await serviceThrottled.lookup(track); fatalError("Service throttle was bypassed") }
        catch NetEaseLyricsError.rateLimited { check(state.requests.count == 1, "Service-level throttling also retains backoff") }

        state.reset([HTTPReply(body: Data(repeating: 32, count: 2_000_001))])
        do { _ = try await client().lookup(track); fatalError("Oversized payload unexpectedly passed") }
        catch NetEaseLyricsError.oversizedResponse { check(true, "Oversized response is rejected before decoding") }
        state.reset([HTTPReply(body: search(), responseURL: URL(string: "http://music.163.com/api/search/get"))])
        do { _ = try await client().lookup(track); fatalError("HTTP downgrade unexpectedly passed") }
        catch NetEaseLyricsError.insecureRedirect { check(true, "Insecure response destination is rejected") }
        state.reset([HTTPReply(status: 404)])
        let missing = try await client().lookup(track)
        check(missing == nil && state.requests.count == 1, "HTTP 404 is a genuine unavailable recording result")

        state.reset([HTTPReply(status: 503), HTTPReply(body: search()), HTTPReply(body: lyric)])
        let cancelClient = client(retryDelay: 0.4)
        let task = Task { try await cancelClient.lookup(track) }
        try await Task.sleep(for: .milliseconds(80)); task.cancel()
        do { _ = try await task.value; fatalError("Cancelled lookup unexpectedly passed") }
        catch is CancellationError { check(state.requests.count == 1, "Cancellation during retry prevents follow-up search and lyric requests") }
        print("\(count) NetEase client checks passed")
        let providerCount = try await OriginalLyricsProviderHarness.run()
        print("\(providerCount) original-language provider checks passed")
        print("\(count + providerCount) total lyric source checks passed")
    }
}
