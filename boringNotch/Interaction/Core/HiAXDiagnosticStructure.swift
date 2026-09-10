import Foundation

/// Bounded structural metadata only. This type never accepts notification field values,
/// identifiers, app names, or accessibility descriptions.
struct HiAXDiagnosticStructure: Equatable, Sendable {
    enum Source { case hi, other, unparsed }
    private(set) var roles: [String: Int] = [:]
    private(set) var subroles: [String: Int] = [:]
    private(set) var hi = 0
    private(set) var other = 0
    private(set) var unparsed = 0
    static let nameLimit = 24

    mutating func record(role: String?, subrole: String?) {
        Self.add(role, to: &roles)
        Self.add(subrole, to: &subroles)
    }

    mutating func recordSource(_ source: Source) {
        switch source {
        case .hi: hi += 1
        case .other: other += 1
        case .unparsed: unparsed += 1
        }
    }

    var summary: String {
        func describe(_ counts: [String: Int]) -> String {
            counts.keys.sorted().map { "\($0)=\(counts[$0] ?? 0)" }.joined(separator: ",")
        }
        return "Roles: [\(describe(roles))] · Subroles: [\(describe(subroles))] · Source: hi=\(hi),other=\(other),unparsed=\(unparsed)"
    }

    private static func add(_ name: String?, to counts: inout [String: Int]) {
        guard let name, name.hasPrefix("AX"), name.count > 2, name.utf8.count <= 72,
              name.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }) else { return }
        guard counts[name] != nil || counts.count < nameLimit else { return }
        counts[name, default: 0] += 1
    }
}
