import Foundation

enum FullscreenMediaPolicy {
    enum Mode { case never, allApps, currentMediaApp }
    struct Space: Equatable {
        let screenID: String
        let applicationIDs: Set<String>
    }

    static func status(spaces: [Space], mode: Mode, mediaSource: String?) -> [String: Bool] {
        let source = mediaSource?.trimmingCharacters(in: .whitespacesAndNewlines)
        var result: [String: Bool] = [:]
        for space in spaces {
            let hidden: Bool
            switch mode {
            case .never: hidden = false
            case .allApps: hidden = true
            case .currentMediaApp:
                hidden = source.map { !$0.isEmpty && space.applicationIDs.contains($0) } ?? false
            }
            result[space.screenID] = result[space.screenID, default: false] || hidden
        }
        return result
    }
}
