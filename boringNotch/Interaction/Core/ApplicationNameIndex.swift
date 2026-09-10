import Foundation

/// macOS renders every banner description as "<Application> <title>, <subtitle>, <body>".
/// The application name is separated from the title by a plain space, so the boundary cannot be
/// recovered from the string alone — it is only knowable by testing known application names
/// against the prefix.
public enum BannerNamePrefix {
    public static let separators: Set<Character> = [" ", ",", "，", "\u{00A0}", "\u{3000}", "\n"]
    public static let maximumNameLength = 80

    /// How many characters `name` occupies at the start of `text`, or nil when `name` is not a
    /// prefix that ends on a name boundary. Comparison is case-insensitive; both sides are trimmed.
    public static func matchLength(of name: String, in text: String) -> Int? {
        let candidate = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let subject = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, candidate.count <= maximumNameLength,
              subject.count >= candidate.count else { return nil }
        let boundary = subject.index(subject.startIndex, offsetBy: candidate.count)
        guard subject[..<boundary].caseInsensitiveCompare(candidate) == .orderedSame else { return nil }
        guard boundary == subject.endIndex || separators.contains(subject[boundary]) else { return nil }
        return candidate.count
    }

    /// The part of the description that follows the application name.
    public static func remainder(of text: String, afterNameOfLength length: Int) -> String {
        let subject = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard length <= subject.count else { return "" }
        let start = subject.index(subject.startIndex, offsetBy: length)
        return subject[start...]
            .drop { separators.contains($0) }
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Resolves a banner description to the application that posted it, without any hard-coded
/// allow list: the index is built from what is actually installed and running on this Mac.
public struct ApplicationNameIndex: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let bundleID: String
        public let bundlePath: String
        public let displayNames: Set<String>
        public let isRunning: Bool

        public init(bundleID: String, bundlePath: String, displayNames: Set<String>, isRunning: Bool) {
            self.bundleID = bundleID
            self.bundlePath = bundlePath
            self.displayNames = displayNames
            self.isRunning = isRunning
        }
    }

    public struct Resolution: Equatable, Sendable {
        public let bundleID: String
        public let displayName: String
        public let remainder: String

        public init(bundleID: String, displayName: String, remainder: String) {
            self.bundleID = bundleID
            self.displayName = displayName
            self.remainder = remainder
        }
    }

    public var entries: [Entry]

    public init(entries: [Entry] = []) { self.entries = entries }

    /// Returns nil when no installed application claims the prefix, or when the claim stays
    /// ambiguous after every tie-break. Callers must keep showing such a banner verbatim rather
    /// than dropping it — an unidentified sender is still a real notification.
    public func resolve(bannerDescription: String) -> Resolution? {
        var best: [(entry: Entry, name: String, length: Int)] = []
        var bestLength = 0
        for entry in entries {
            var entryMatch: (String, Int)?
            for name in entry.displayNames {
                guard let length = BannerNamePrefix.matchLength(of: name, in: bannerDescription) else { continue }
                if length > (entryMatch?.1 ?? 0) { entryMatch = (name, length) }
            }
            guard let (name, length) = entryMatch, length >= bestLength else { continue }
            if length > bestLength { bestLength = length; best.removeAll() }
            best.append((entry, name, length))
        }
        guard bestLength > 0 else { return nil }

        var candidates = deduplicatedByBundleID(best)
        if candidates.count > 1 { candidates = droppingNestedBundles(candidates) }
        if candidates.count > 1 {
            let running = candidates.filter { $0.entry.isRunning }
            if running.count == 1 { candidates = running }
        }
        guard candidates.count == 1, let winner = candidates.first else { return nil }
        return Resolution(bundleID: winner.entry.bundleID, displayName: winner.name,
                          remainder: BannerNamePrefix.remainder(of: bannerDescription, afterNameOfLength: bestLength))
    }

    private typealias Candidate = (entry: Entry, name: String, length: Int)

    private func deduplicatedByBundleID(_ candidates: [Candidate]) -> [Candidate] {
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.entry.bundleID).inserted }
    }

    /// A helper living inside another application's bundle is that application, not a rival —
    /// WeChat ships `com.tencent.flue.WeChatAppEx` inside `WeChat.app` under the same name "微信".
    private func droppingNestedBundles(_ candidates: [Candidate]) -> [Candidate] {
        candidates.filter { candidate in
            candidates.contains { other in
                other.entry.bundleID != candidate.entry.bundleID
                && AppNotificationNameFilter.isBundlePath(candidate.entry.bundlePath, containedIn: other.entry.bundlePath)
            } == false
        }
    }
}
