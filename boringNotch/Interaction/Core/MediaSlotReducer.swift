import Foundation

struct MediaControlDragPayload: Codable, Equatable {
    let controlID: String
    let sourceSlot: Int?
}

/// Pure operations shared by settings gestures and runtime configuration normalization.
enum MediaSlotReducer {
    static let slotCount = 5

    static func normalize<Control: Hashable>(_ input: [Control], empty: Control) -> [Control] {
        var seen = Set<Control>()
        let padded = Array(input.prefix(slotCount)) + Array(repeating: empty, count: max(0, slotCount - input.count))
        return padded.map { value in
            guard value != empty else { return empty }
            return seen.insert(value).inserted ? value : empty
        }
    }

    static func drop<Control: Hashable>(_ control: Control, from source: Int?, to target: Int?,
                                        in input: [Control], empty: Control) -> [Control] {
        var slots = normalize(input, empty: empty)
        guard control != empty else { return slots }
        if let source {
            guard slots.indices.contains(source), slots[source] == control else { return slots }
        }
        guard let target else {
            // Only a slot drag can be removed by returning it to the palette/trash.
            if let source { slots[source] = empty }
            return slots
        }
        guard slots.indices.contains(target) else { return slots }
        if let existing = source ?? slots.firstIndex(of: control) {
            slots.swapAt(existing, target)
        } else {
            slots[target] = control
        }
        return slots
    }
}
