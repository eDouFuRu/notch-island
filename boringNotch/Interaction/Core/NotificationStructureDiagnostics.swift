import Foundation

/// A diagnostic schema with no notification-text fields. Identifier values and arbitrary
/// attribute names are deliberately not accepted, even when a caller has access to them.
struct NotificationStructureDiagnostics: Equatable {
    private(set) var nodes = 0
    private(set) var roles: [String: Int] = [:]
    private(set) var subroles: [String: Int] = [:]
    private(set) var attributes: [String: Int] = [:]
    private(set) var identifierAttributeNodes = 0
    private(set) var otherAttributeCount = 0
    private(set) var sizes: [String] = []
    private(set) var errors: [Int: Int] = [:]
    private(set) var bannerWindows: [String] = []
    private var recordedBannerNodes = 0
    var truncated = false

    struct BannerNode {
        let number: Int
        let parent: Int?
        let depth: Int
        let role: String?
        let subrole: String?
        let width: Double?
        let height: Double?
        let onScreen: Bool?
        let attributeNames: [String]
    }

    private static let permittedAttributes: Set<String> = [
        "AXRole", "AXSubrole", "AXIdentifier", "AXAttributedDescription", "AXDescription",
        "AXValue", "AXChildren", "AXWindows", "AXSize", "AXPosition", "AXTitle", "AXParent",
        "AXFocused", "AXFocusedWindow", "AXMain", "AXEnabled", "AXHelp", "AXSelected",
        "AXCloseButton", "AXContents", "AXURL", "AXWindow", "AXRoleDescription"
    ]

    mutating func recordNode(role: String?, subrole: String?, attributeNames: [String]) {
        nodes += 1
        Self.increment(role, in: &roles)
        Self.increment(subrole, in: &subroles)
        if attributeNames.contains("AXIdentifier") { identifierAttributeNodes += 1 }
        for name in Set(attributeNames) {
            if Self.permittedAttributes.contains(name) { attributes[name, default: 0] += 1 }
            else { otherAttributeCount += 1 }
        }
    }

    mutating func recordWindowSize(width: Double, height: Double) {
        guard sizes.count < 16, width.isFinite, height.isFinite,
              (0...100_000).contains(width), (0...100_000).contains(height) else { return }
        sizes.append("\(Int(width.rounded()))x\(Int(height.rounded()))")
    }

    mutating func recordError(_ code: Int) {
        guard code != 0 else { return }
        errors[code, default: 0] += 1
    }

    /// Only windows containing an actual banner/alert are described. Numbers are ephemeral
    /// traversal ordinals, never AXIdentifier values or hashes of an accessibility element.
    mutating func recordBannerWindow(number: Int, window: BannerNode, focused: Bool?,
                                     bannerCount: Int, stackCount: Int, cards: [BannerNode]) {
        guard bannerCount > 0, (0..<16).contains(number), bannerWindows.count < 16 else { return }
        func flag(_ value: Bool?) -> String { value.map(String.init) ?? "unknown" }
        func dimension(_ width: Double?, _ height: Double?) -> String {
            guard let width, let height, width.isFinite, height.isFinite,
                  (0...100_000).contains(width), (0...100_000).contains(height) else { return "unknown" }
            return "\(Int(width.rounded()))x\(Int(height.rounded()))"
        }
        func describe(_ node: BannerNode) -> String {
            let role = Self.safeAXName(node.role) ?? "unknown"
            let subrole = Self.safeAXName(node.subrole) ?? "unknown"
            let known = ["AXAttributedDescription", "AXDescription", "AXTitle", "AXIdentifier", "AXValue", "AXChildren", "AXSize", "AXPosition"]
            let present = Set(node.attributeNames)
            let bits = known.map { "\($0)=\(present.contains($0) ? 1 : 0)" }.joined(separator: ",")
            return "node=\(node.number) parent=\(node.parent.map(String.init) ?? "none") depth=\(node.depth) role=\(role) subrole=\(subrole) size=\(dimension(node.width, node.height)) onScreen=\(flag(node.onScreen)) attributes=[\(bits)]"
        }
        let validCards = cards.filter { (0..<160).contains($0.number) && (0...10).contains($0.depth) }
        let kept = Array(validCards.prefix(max(0, 32 - recordedBannerNodes)))
        if kept.count < validCards.count { truncated = true }
        recordedBannerNodes += kept.count
        let text = "Window \(number): \(describe(window)) focusedWindow=\(flag(focused)) banners=\(bannerCount) stacks=\(stackCount) {\(kept.map(describe).joined(separator: "; "))}"
        guard bannerWindows.reduce(0, { $0 + $1.count }) + text.count <= 8_000 else { truncated = true; return }
        bannerWindows.append(text)
    }

    var summary: String {
        func counts(_ values: [String: Int]) -> String {
            values.keys.sorted().map { "\($0)=\(values[$0] ?? 0)" }.joined(separator: ",")
        }
        let errorText = errors.keys.sorted().map { "\($0)=\(errors[$0] ?? 0)" }.joined(separator: ",")
        return "Structure only · Nodes: \(nodes) · Roles: [\(counts(roles))] · Subroles: [\(counts(subroles))] · Attributes present: [\(counts(attributes))] · Identifier attribute nodes: \(identifierAttributeNodes) (values not read) · Other attributes: \(otherAttributeCount) · Window sizes: [\(sizes.joined(separator: ","))] · AX errors: [\(errorText)] · Truncated: \(truncated) · Banner geometry: [\(bannerWindows.joined(separator: " | "))] · Description/value/title/identifier text: not read"
    }

    private static func safeAXName(_ name: String?) -> String? {
        guard let name, name.hasPrefix("AX"), (3...72).contains(name.utf8.count),
              name.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }) else { return nil }
        return name
    }

    private static func increment(_ name: String?, in counts: inout [String: Int]) {
        guard let name = safeAXName(name),
              counts[name] != nil || counts.count < 24 else { return }
        counts[name, default: 0] += 1
    }
}
