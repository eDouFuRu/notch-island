import AppKit
import Carbon
import Combine

@MainActor protocol KeyboardInputSourceControlling {
    func read() -> InputSourceReading?
    /// Called only for an explicit user choice, never by refresh or observers.
    func select(id: String) -> (failure: InputSourceFailure?, statusCode: Int32?)
}

/// Public HIToolbox metadata/selection only. Retained Copy/Create results and
/// unretained Get properties follow the ownership rules in TextInputSources.h.
/// Every opaque CF pointer is type-checked before use with its documented type.
@MainActor final class TISKeyboardInputSourceDevice: KeyboardInputSourceControlling {
    private struct Source {
        let reference: TISInputSource
        let record: KeyboardInputSourceRecord
    }

    func read() -> InputSourceReading? {
        guard let sources = enabledKeyboardSources() else { return nil }
        return reading(sources)
    }

    func select(id: String) -> (failure: InputSourceFailure?, statusCode: Int32?) {
        // Re-enumerate at the moment of the click: menu entries may become stale
        // if the user removes a source in System Settings while the menu is open.
        guard let sources = enabledKeyboardSources() else { return (.unavailable, nil) }
        let current = reading(sources)
        guard current.containsSelectableSource(id),
              let source = sources.first(where: { $0.record.id == id }) else { return (.sourceUnavailable, nil) }
        if current.selectedID == id { return (nil, noErr) }
        let status = TISSelectInputSource(source.reference)
        return status == noErr ? (nil, status) : (.selectionFailed, status)
    }

    private func reading(_ sources: [Source]) -> InputSourceReading {
        let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
        return InputSourceReading(records: sources.map(\.record),
            selectedID: current.flatMap { string($0, kTISPropertyInputSourceID) },
            currentName: current.flatMap { string($0, kTISPropertyLocalizedName) })
    }

    private func enabledKeyboardSources() -> [Source]? {
        let filter = [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource] as CFDictionary
        // false excludes disabled installed sources; no installation/enabling API
        // is used. Parent records remain available for child-mode validation.
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() else { return nil }
        let count = CFArrayGetCount(list)
        guard count <= 256 else { return nil }
        var result: [Source] = []
        for index in 0..<count {
            guard let pointer = CFArrayGetValueAtIndex(list, index) else { continue }
            let object = Unmanaged<CFTypeRef>.fromOpaque(pointer).takeUnretainedValue()
            guard CFGetTypeID(object) == TISInputSourceGetTypeID() else { continue }
            let source = Unmanaged<TISInputSource>.fromOpaque(pointer).takeUnretainedValue()
            guard string(source, kTISPropertyInputSourceCategory) == kTISCategoryKeyboardInputSource as String,
                  let id = string(source, kTISPropertyInputSourceID), !id.isEmpty,
                  let name = string(source, kTISPropertyLocalizedName), !name.isEmpty else { continue }
            let kind: KeyboardInputSourceKind
            let type = string(source, kTISPropertyInputSourceType)
            if type == (kTISTypeKeyboardLayout as String) { kind = .layout }
            else if type == (kTISTypeKeyboardInputMethodWithoutModes as String) { kind = .inputMethod }
            else if type == (kTISTypeKeyboardInputMethodModeEnabled as String) { kind = .inputMethodParent }
            else if type == (kTISTypeKeyboardInputMode as String) { kind = .inputMode }
            else { kind = .other }
            result.append(Source(reference: source, record: KeyboardInputSourceRecord(
                id: id, displayName: name, bundleID: string(source, kTISPropertyBundleID), kind: kind,
                enabled: boolean(source, kTISPropertyInputSourceIsEnabled) == true,
                selectable: boolean(source, kTISPropertyInputSourceIsSelectCapable) == true)))
        }
        return result
    }

    private func string(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        let object = Unmanaged<CFTypeRef>.fromOpaque(pointer).takeUnretainedValue()
        guard CFGetTypeID(object) == CFStringGetTypeID() else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }
    private func boolean(_ source: TISInputSource, _ key: CFString) -> Bool? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        let object = Unmanaged<CFTypeRef>.fromOpaque(pointer).takeUnretainedValue()
        guard CFGetTypeID(object) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(pointer).takeUnretainedValue())
    }
}

@MainActor final class SystemInputSourceControl: ObservableObject {
    static let shared = SystemInputSourceControl()
    @Published private(set) var sources: [InputSourceMenuItem] = []
    @Published private(set) var selectedID: String?
    @Published private(set) var currentName: String?
    @Published private(set) var isBusy = false
    @Published private(set) var errorKey: String?
    @Published private(set) var lastStatusCode: Int32?
    private let device: any KeyboardInputSourceControlling
    private var observers: [NSObjectProtocol] = []
    private var refreshPending = false

    init(device: (any KeyboardInputSourceControlling)? = nil) {
        self.device = device ?? TISKeyboardInputSourceDevice()
        let center = DistributedNotificationCenter.default()
        for name in [kTISNotifySelectedKeyboardInputSourceChanged, kTISNotifyEnabledKeyboardInputSourcesChanged] {
            guard let name else { continue }
            observers.append(center.addObserver(forName: Notification.Name(name as String), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.refresh(preservingError: true) }
            })
        }
        // Constructor performs no selection and does not create keyboard/event
        // monitors. UI opens/activations can explicitly call refresh().
    }
    deinit {
        for observer in observers { DistributedNotificationCenter.default().removeObserver(observer) }
    }

    func refresh() async { await refresh(preservingError: false) }

    private func refresh(preservingError: Bool) async {
        guard !isBusy else { refreshPending = true; return }
        guard let reading = device.read() else {
            sources = []; selectedID = nil; currentName = nil
            errorKey = InputSourceFailure.unavailable.messageKey
            return
        }
        publish(reading)
        if reading.sources.isEmpty { errorKey = InputSourceFailure.noSources.messageKey }
        else if !preservingError { errorKey = nil }
    }

    /// Explicit menu action only. The current-ID checkmark is updated only from
    /// TIS readback; a successful OSStatus alone is never presented as success.
    @discardableResult func select(id: String) async -> Bool {
        guard !isBusy, !Task.isCancelled else { return false }
        isBusy = true
        errorKey = nil
        lastStatusCode = nil
        defer {
            isBusy = false
            if refreshPending {
                refreshPending = false
                Task { @MainActor [weak self] in await self?.refresh(preservingError: true) }
            }
        }
        guard let initial = device.read() else {
            errorKey = InputSourceFailure.unavailable.messageKey
            return false
        }
        publish(initial)
        switch InputSourceSelectionDecision.evaluate(id: id, reading: initial) {
        case .unavailable:
            errorKey = InputSourceFailure.sourceUnavailable.messageKey
            return false
        case .alreadySelected: return true
        case .select: break
        }
        let written = device.select(id: id)
        lastStatusCode = written.statusCode
        if let failure = written.failure {
            if let actual = device.read() { publish(actual) }
            errorKey = failure.messageKey
            return false
        }
        var actual = device.read()
        // Some IMEs report the newly selected mode on the next main run-loop
        // turn. Bounded read-only confirmation never retries the write itself.
        for delay in [80_000_000, 160_000_000] as [UInt64] {
            if actual?.selectedID == id { break }
            do { try await Task.sleep(nanoseconds: delay) }
            catch {
                if let latest = device.read() { publish(latest) }
                errorKey = InputSourceFailure.cancelled.messageKey
                return false
            }
            actual = device.read()
        }
        if let actual { publish(actual) }
        let failure = InputSourceSelectionVerification.failure(requestedID: id, writeSucceeded: true, actual: actual)
        errorKey = failure?.messageKey
        return failure == nil
    }

    private func publish(_ reading: InputSourceReading) {
        sources = reading.sources
        selectedID = reading.selectedID
        currentName = reading.currentName
    }
}
