import Foundation

/// The source token belongs to this running app only and is never persisted. A drag
/// from another app or a previous launch cannot edit the user's tool configuration.
struct ToolGridDragPayload: Codable, Equatable, Sendable {
    let version: Int
    let toolID: String
    let sourceID: String

    init(toolID: String, sourceID: String, version: Int = 1) {
        self.version = version
        self.toolID = toolID
        self.sourceID = sourceID
    }
}

struct ToolGridConfiguration: Codable, Equatable {
    private(set) var orderedIDs: [String]
    private(set) var visibleIDs: Set<String>
    init(allIDs: [String], defaultVisible: [String]) {
        orderedIDs = Self.unique(allIDs)
        visibleIDs = Set(defaultVisible).intersection(orderedIDs)
    }
    mutating func reconcile(allIDs: [String]) {
        let allowed = Set(allIDs)
        orderedIDs = Self.unique(orderedIDs.filter { allowed.contains($0) } + allIDs)
        visibleIDs.formIntersection(allowed)
    }
    var selectedIDs: [String] { orderedIDs.filter { visibleIDs.contains($0) } }
    mutating func setVisible(_ visible: Bool, id: String) {
        guard orderedIDs.contains(id) else { return }
        if visible { visibleIDs.insert(id) } else { visibleIDs.remove(id) }
    }
    mutating func move(_ id: String, by offset: Int) {
        let selected = selectedIDs
        guard let index = selected.firstIndex(of: id), offset == -1 || offset == 1 else { return }
        let target = index + offset
        guard selected.indices.contains(target), let sourceIndex = orderedIDs.firstIndex(of: id),
              let targetIndex = orderedIDs.firstIndex(of: selected[target]) else { return }
        orderedIDs.swapAt(sourceIndex, targetIndex)
    }

    /// Replace only visible slots, leaving hidden tools in their original slots.
    /// All validation and mutation happen at drop time; drag previews do not call this.
    func canDrop(_ payload: ToolGridDragPayload, on targetID: String, sourceID: String) -> Bool {
        payload.version == 1 && !sourceID.isEmpty && payload.sourceID == sourceID &&
            payload.toolID != targetID && visibleIDs.contains(payload.toolID) && visibleIDs.contains(targetID) &&
            orderedIDs.contains(payload.toolID) && orderedIDs.contains(targetID)
    }

    @discardableResult
    mutating func drop(_ payload: ToolGridDragPayload, on targetID: String, sourceID: String) -> Bool {
        guard canDrop(payload, on: targetID, sourceID: sourceID) else { return false }
        var selected = selectedIDs
        guard let sourceIndex = selected.firstIndex(of: payload.toolID),
              let targetIndex = selected.firstIndex(of: targetID), sourceIndex != targetIndex else { return false }
        let source = selected.remove(at: sourceIndex)
        selected.insert(source, at: targetIndex)
        var iterator = selected.makeIterator()
        orderedIDs = orderedIDs.map { visibleIDs.contains($0) ? iterator.next()! : $0 }
        return true
    }
    private static func unique(_ ids: [String]) -> [String] {
        var seen = Set<String>(); return ids.filter { seen.insert($0).inserted }
    }
}
