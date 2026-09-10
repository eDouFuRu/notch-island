import Combine
import Defaults
import Foundation

enum LyricsDisplayLocation: String, CaseIterable, Defaults.Serializable {
    case off, player, notch
}

private enum LyricsLookupError: Error {
    case response(Int), oversizedResponse, rateLimited
}

/// LRCLIB supplies independent LRC files. This client neither scrapes a player's
/// desktop-lyrics window nor claims those files are the player's own lyric feed.
private actor LRCLIBClient {
    private let session: URLSession
    private var blockedUntil = Date.distantPast

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        session = URLSession(configuration: configuration)
    }

    func lookup(_ track: LyricsTrack) async throws -> LyricsDocument? {
        // Without an album, /get can silently pick another compilation with a
        // similar duration but a different LRC clock. Search must establish that
        // the closest candidate is unambiguous before any document is accepted.
        if !track.album.isEmpty, let exact = try await data(path: "get", track: track),
           let record = try? JSONDecoder().decode(LRCLIBRecord.self, from: exact),
           record.matches(track), let document = record.document,
           !OriginalLyricLanguage.isRomanizedMandarin(document, track: track) { return document }
        try Task.checkCancellation()
        // Search is a fallback, and its first result is never accepted blindly.
        try await Task.sleep(for: .milliseconds(250))
        guard let search = try await data(path: "search", track: track) else { return nil }
        let records = try JSONDecoder().decode([LRCLIBRecord].self, from: search)
        if let match = LRCLIBRecord.bestMatch(records, track: track) { return match }
        // The server does not normalize Chinese script variants. A narrow
        // search can miss JJ陸 for JJ陆; broader discovery still passes through
        // exactly the same artist/album/duration and ambiguity validation.
        guard !track.album.isEmpty, track.duration > 0,
              let broad = try await data(path: "search", track: track, titleOnly: true) else { return nil }
        return LRCLIBRecord.bestMatch(try JSONDecoder().decode([LRCLIBRecord].self, from: broad), track: track)
    }

    private func data(path: String, track: LyricsTrack, attempt: Int = 0, titleOnly: Bool = false) async throws -> Data? {
        try Task.checkCancellation()
        guard Date() >= blockedUntil else { throw LyricsLookupError.rateLimited }
        var components = URLComponents(string: "https://lrclib.net/api/\(path)")!
        components.queryItems = [URLQueryItem(name: "track_name", value: track.title)]
        if !titleOnly { components.queryItems?.append(URLQueryItem(name: "artist_name", value: track.artist)) }
        if !titleOnly && !track.album.isEmpty { components.queryItems?.append(URLQueryItem(name: "album_name", value: track.album)) }
        if path == "get", track.duration >= 1, track.duration <= 3600 {
            components.queryItems?.append(URLQueryItem(name: "duration", value: String(track.duration)))
        }
        var request = URLRequest(url: components.url!)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "local"
        request.setValue("NotchIsland/\(version) (custom boring.notch derivative; https://github.com/TheBoredTeam/boring.notch)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch let error as URLError {
            try Task.checkCancellation()
            if attempt == 0 && [.timedOut, .networkConnectionLost, .cannotConnectToHost, .secureConnectionFailed].contains(error.code) {
                try await Task.sleep(for: .milliseconds(800))
                return try await self.data(path: path, track: track, attempt: 1, titleOnly: titleOnly)
            }
            throw error
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw LyricsLookupError.response(0) }
        if http.statusCode == 404 { return nil }
        if http.statusCode == 429 {
            let wait = Self.retryDelay(http.value(forHTTPHeaderField: "Retry-After"))
            blockedUntil = Date().addingTimeInterval(wait)
            // Long server backoff is retained without holding a sleeping task.
            if attempt == 0 && wait <= 2 {
                try await Task.sleep(for: .seconds(wait))
                return try await self.data(path: path, track: track, attempt: 1, titleOnly: titleOnly)
            }
            throw LyricsLookupError.rateLimited
        }
        if (500...599).contains(http.statusCode), attempt == 0 {
            try await Task.sleep(for: .milliseconds(500))
            return try await self.data(path: path, track: track, attempt: 1, titleOnly: titleOnly)
        }
        guard http.statusCode == 200 else { throw LyricsLookupError.response(http.statusCode) }
        guard data.count <= 2_000_000 else { throw LyricsLookupError.oversizedResponse }
        return data
    }

    private static func retryDelay(_ header: String?) -> TimeInterval {
        if let header, let seconds = Double(header), seconds.isFinite { return max(0.25, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let header, let date = formatter.date(from: header) { return max(0.25, date.timeIntervalSinceNow) }
        return 60
    }
}

@MainActor
final class LyricsStore: ObservableObject {
    static let shared = LyricsStore()
    @Published private(set) var currentLine = ""
    var displayText: String {
        // A timed blank cue is an interlude, not a failed lookup.
        if let document, !document.cues.isEmpty {
            return LyricsTextPresentation.render(line: currentLine, simplifiedChinese: prefersSimplifiedChinese() && document.permitsChineseSimplification)
        }
        if isLoading { return L("Looking for synced lyrics…") }
        if lookupStatus.hasPrefix("error:") { return L("Lyrics temporarily unavailable") }
        return L("No synced lyrics available")
    }
    @Published private(set) var isLoading = false
    @Published private(set) var lookupStatus = "idle"
    @Published private(set) var location: LyricsDisplayLocation = .off
    @Published private(set) var isPlaying = false
    @Published private(set) var applicationAvailable = false
    @Published private(set) var hasTrack = false
    var isPaused: Bool { !isPlaying }
    var shouldShowNotch: Bool {
        location == .notch && applicationAvailable && hasTrack && isPlaying && !currentLine.isEmpty
    }

    private let lookup: @MainActor (LyricsTrack) async throws -> LyricsDocument?
    private let prefersSimplifiedChinese: @MainActor () -> Bool
    private var preferenceObservation: AnyCancellable?
    private var track: LyricsTrack?
    private var playback: PlaybackState?
    private var document: LyricsDocument?
    private var cache = LyricsCache()
    private var requestTask: Task<Void, Never>?
    private var tickerTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var autoRetryCount = 0
    private var retryDelay: TimeInterval = 60
    private var lastManualRetry = Date.distantPast
    private var requestGeneration: UInt64 = 0
    private var loadedTrack: LyricsTrack?
    private var nextRefreshAt = Date.distantPast
    private var notchPresentations = Set<UUID>()
    private var playerPresentations = Set<UUID>()

    private init() {
        let library = LRCLIBClient()
        let netease = NetEaseLyricsClient()
        let client = OriginalLyricsProvider(netease: { try await netease.lookup($0) }, library: { try await library.lookup($0) })
        lookup = { try await client.lookup($0) }
        // Match L(_:) and AppLanguage's explicit preference. Read on display so
        // changing language takes effect without re-fetching or rewriting lyrics.
        prefersSimplifiedChinese = { UserDefaults.standard.string(forKey: "island.language") != "en" }
        // Only migrate when the replacement key has never been saved. The old
        // key remains untouched for compatibility with a rollback installation.
        let domain = Bundle.main.bundleIdentifier.flatMap { UserDefaults.standard.persistentDomain(forName: $0) } ?? [:]
        if domain["lyricsDisplayLocation"] == nil {
            Defaults[.lyricsDisplayLocation] = Defaults[.enableLyrics] ? .player : .off
        }
        location = Defaults[.lyricsDisplayLocation]
        preferenceObservation = Defaults.publisher(.lyricsDisplayLocation).sink { [weak self] _ in
            Task { @MainActor in self?.applyLocation() }
        }
    }

    /// Offline regression harness uses the production state machine with a
    /// controlled provider. It never reads/writes the user's preferences or network.
    init(testLocation: LyricsDisplayLocation,
         prefersSimplifiedChinese: @escaping @MainActor () -> Bool = { true },
         retryDelay: TimeInterval = 60,
         lookup: @escaping @MainActor (LyricsTrack) async throws -> LyricsDocument?) {
        location = testLocation
        self.lookup = lookup
        self.retryDelay = max(0.01, retryDelay)
        self.prefersSimplifiedChinese = prefersSimplifiedChinese
    }

    deinit { requestTask?.cancel(); tickerTask?.cancel(); retryTask?.cancel() }

    func setApplicationAvailable(_ available: Bool) {
        applicationAvailable = available
        if !available { cancelRequest() }
        reconcile()
    }
    func setNotchPresentation(sourceID: UUID, visible: Bool) {
        if visible { notchPresentations.insert(sourceID) } else { notchPresentations.remove(sourceID) }
        reconcile()
    }
    func removeNotchPresentation(sourceID: UUID) { notchPresentations.remove(sourceID); reconcile() }
    func setPlayerPresentation(sourceID: UUID, visible: Bool) {
        if visible { playerPresentations.insert(sourceID) } else { playerPresentations.remove(sourceID) }
        reconcile()
    }
    func removePlayerPresentation(sourceID: UUID) { playerPresentations.remove(sourceID); reconcile() }

    /// Always receives the complete latest state, after MusicManager has applied
    /// metadata and clock updates. Controller output is the only playback clock.
    func updatePlayback(_ state: PlaybackState) {
        playback = state
        let next = LyricsTrack(source: state.bundleIdentifier, title: state.title, artist: state.artist,
                               album: state.album, duration: state.duration)
        let usable = next.canSearch && !(state.title == "I'm Handsome" && state.artist == "Me" && state.duration == 0)
        let newTrack = usable ? next : nil
        if newTrack != track {
            cancelRequest()
            track = newTrack; document = nil; loadedTrack = nil; nextRefreshAt = .distantPast
            currentLine = ""; lookupStatus = "idle"; autoRetryCount = 0
        }
        hasTrack = newTrack != nil
        isPlaying = state.isPlaying
        reconcile()
    }

    /// Technical status deliberately omits artist, title, lyric text and URLs.
    var diagnosticsSummary: String {
        "location=\(location.rawValue) available=\(applicationAvailable) playing=\(isPlaying) track=\(hasTrack) loading=\(isLoading) synchronized=\(!(document?.cues.isEmpty ?? true)) cached=\(cache.count) ticking=\(tickerTask != nil) lookup=\(lookupStatus) retry=\(retryTask != nil) retries=\(autoRetryCount)"
    }

    private func applyLocation() {
        location = Defaults[.lyricsDisplayLocation]
        if location == .off {
            cancelRequest(); document = nil; loadedTrack = nil; currentLine = ""
        }
        reconcile()
    }

    private func cancelRequest() {
        requestGeneration &+= 1
        requestTask?.cancel(); requestTask = nil; isLoading = false
        retryTask?.cancel(); retryTask = nil
    }

    private func reconcile() {
        refreshLine()
        loadIfNeeded()
        let hasVisibleTarget = location == .notch ? !notchPresentations.isEmpty : location == .player && !playerPresentations.isEmpty
        let mayRefresh = applicationAvailable && hasVisibleTarget && isPlaying
        scheduleRetry(visibleAndPlaying: mayRefresh)
        let needsTicker = mayRefresh && !(document?.cues.isEmpty ?? true)
        if !needsTicker { tickerTask?.cancel(); tickerTask = nil }
        else if tickerTask == nil {
            tickerTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                    self?.refreshLine()
                }
            }
        }
    }

    private func refreshLine() {
        let line: String
        if location != .off, let playback {
            let position = LyricsPlaybackClock.position(elapsed: playback.currentTime,
                timestamp: playback.lastUpdated.timeIntervalSinceReferenceDate,
                now: Date().timeIntervalSinceReferenceDate, duration: playback.duration,
                rate: playback.playbackRate, playing: playback.isPlaying)
            line = document?.line(at: position) ?? ""
        } else { line = "" }
        if currentLine != line { currentLine = line }
    }

    /// User-triggered retry drops only the current track's cached result. The
    /// shared HTTP client's Retry-After and this five-second debounce still apply.
    func retryCurrentTrack() {
        guard applicationAvailable, location != .off, let track, requestTask == nil,
              Date().timeIntervalSince(lastManualRetry) >= 5 else { return }
        lastManualRetry = Date()
        retryTask?.cancel(); retryTask = nil
        autoRetryCount = 0; lookupStatus = "idle"
        cache.remove(track); loadedTrack = nil; nextRefreshAt = .distantPast
        reconcile()
    }

    private func scheduleRetry(visibleAndPlaying: Bool) {
        guard visibleAndPlaying, lookupStatus.hasPrefix("error:"), autoRetryCount < 2,
              requestTask == nil, let expectedTrack = track else {
            retryTask?.cancel(); retryTask = nil
            return
        }
        guard retryTask == nil else { return }
        let generation = requestGeneration
        retryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await Task.sleep(for: .seconds(max(0.01, self.nextRefreshAt.timeIntervalSinceNow))) }
            catch { return }
            self.retryTask = nil
            guard self.applicationAvailable, self.isPlaying, self.track == expectedTrack,
                  self.requestGeneration == generation else { return }
            self.autoRetryCount += 1
            self.cache.remove(expectedTrack); self.loadedTrack = nil; self.nextRefreshAt = .distantPast
            self.loadIfNeeded()
        }
    }

    private func loadIfNeeded() {
        guard applicationAvailable, location != .off, let track, requestTask == nil else { return }
        if lookupStatus.hasPrefix("error:") && loadedTrack == track { return }
        if loadedTrack == track && Date() < nextRefreshAt { return }
        if let cached = cache.lookup(track, now: Date().timeIntervalSinceReferenceDate) {
            loadedTrack = track; document = cached.document
            lookupStatus = cached.document == nil ? "no_match_cached" : "matched_cached"
            // Cache lookup expires independently; this keeps repeated playback
            // clock updates cheap without extending a negative cache indefinitely.
            nextRefreshAt = Date(timeIntervalSinceReferenceDate: cached.expiry)
            refreshLine()
            return
        }
        requestGeneration &+= 1
        let generation = requestGeneration
        isLoading = true
        requestTask = Task { @MainActor [weak self, lookup] in
            let result: LyricsDocument?
            let lifetime: TimeInterval
            let status: String
            do {
                result = try await lookup(track); lifetime = result == nil ? 600 : 86_400
                status = result == nil ? "no_match" : "matched"
            }
            catch is CancellationError { return }
            catch {
                result = nil; lifetime = self?.retryDelay ?? 60
                if let error = error as? LyricsLookupError {
                    switch error {
                    case .response(let code): status = "error:http_\(code)"
                    case .rateLimited: status = "error:rate_limited"
                    case .oversizedResponse: status = "error:response_too_large"
                    }
                } else if let error = error as? NetEaseLyricsError {
                    switch error {
                    case .response(let code): status = "error:netease_http_\(code)"
                    case .service(let code): status = "error:netease_service_\(code)"
                    case .rateLimited: status = "error:netease_rate_limited"
                    case .oversizedResponse: status = "error:response_too_large"
                    case .insecureRedirect: status = "error:lyric_redirect"
                    }
                } else if let error = error as? URLError {
                    status = "error:network_\(error.code.rawValue)"
                } else { status = "error:lookup_failed" }
            }
            guard let self, !Task.isCancelled, self.requestGeneration == generation,
                  self.track == track, self.location != .off, self.applicationAvailable else { return }
            self.requestTask = nil; self.isLoading = false
            self.loadedTrack = track; self.document = result; self.lookupStatus = status
            self.nextRefreshAt = Date().addingTimeInterval(lifetime)
            self.cache.insert(result, for: track, now: Date().timeIntervalSinceReferenceDate, lifetime: lifetime)
            self.reconcile()
        }
    }
}
