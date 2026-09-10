// Main-process authorization and media-key interception lifecycle for 工位充电岛.
import AppKit
import ApplicationServices
import Combine
import Defaults
import Security

enum HUDStatus: Equatable {
    case disabled
    case permissionRequired
    case running
    case temporarilySuspended
    case failed
}

struct HUDMediaEventRecord {
    let timestamp: Date
    let event: SystemMediaKeyEvent
    let consumed: Bool
    let modifierFlags: UInt
}

struct HUDControlResult {
    let timestamp: Date
    let kind: SystemHUDKind
    /// The reading returned for this operation, never a cached value or the requested target.
    let actualValue: Double?
    let isMuted: Bool?
    let error: String?
    var succeeded: Bool { error == nil && actualValue != nil }
}

@MainActor
final class HUDStateManager: ObservableObject {
    static let shared = HUDStateManager()

    @Published private(set) var accessibilityAuthorized = false
    @Published private(set) var status: HUDStatus = .disabled
    @Published private(set) var eventTapEnabled = false
    @Published private(set) var lastMediaEventAt: Date?
    @Published private(set) var lastMediaEventDescription = "None"
    /// In-memory only. The parser admits exactly the five supported system media keys.
    @Published private(set) var recentMediaEvents: [HUDMediaEventRecord] = []
    @Published private(set) var lastControlResult: HUDControlResult?
    @Published private(set) var lastControlError: String?
    /// Localization key. A tap failure is deliberately distinct from denied AX access.
    @Published private(set) var errorMessage: String?
    var isRunning: Bool { status == .running }

    private var preferenceObservation: AnyCancellable?
    private var activationObservation: AnyCancellable?
    private var permissionRefreshTask: Task<Void, Never>?
    private var started = false
    // Availability must be supplied by the app's hidden/locked state before intercepting keys.
    private var applicationAvailable = false
    private let interceptor = MediaKeyInterceptor.shared
    private let processIdentity = HUDStateManager.readProcessIdentity()
    private var presentationAvailable = false
    private(set) var controlGeneration: UInt64 = 0
    private let diagnosticDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    var diagnosticsSummary: String {
        let resultDescription: String
        if let result = lastControlResult {
            let actual = result.actualValue.map { String(format: "%.4f", $0) } ?? "Unavailable"
            let mute = result.isMuted.map { " muted=\($0)" } ?? ""
            resultDescription = "\(diagnosticDateFormatter.string(from: result.timestamp)) kind=\(result.kind) actual=\(actual)\(mute) outcome=\(result.succeeded ? "success" : "failure") error=\(result.error ?? "None")"
        } else {
            resultDescription = "None"
        }
        let events = recentMediaEvents.map {
            "\(diagnosticDateFormatter.string(from: $0.timestamp)) \(describeMediaEvent($0))"
        }.joined(separator: "\n")
        return "\(processIdentity)\nAX: \(accessibilityAuthorized)\nEvent tap: \(eventTapEnabled)\nRecent media event: \(lastMediaEventDescription)\nEvent time: \(lastMediaEventAt?.description ?? "None")\nControl error: \(lastControlError ?? "None")\nLast control result: \(resultDescription)\nRecent system media events (last 20, oldest first):\n\(events.isEmpty ? "None" : events)"
    }

    private init() {}

    func start() {
        guard !started else { refresh(); return }
        started = true
        interceptor.onRuntimeStateChange = { [weak self] result in
            guard let self, self.started else { return }
            if self.applicationAvailable && Defaults[.hudReplacement] {
                self.apply(result)
            } else {
                self.reconcile()
            }
        }
        interceptor.onMediaEvent = { [weak self] event, consumed, flags in
            guard let self else { return }
            let record = HUDMediaEventRecord(timestamp: Date(), event: event, consumed: consumed, modifierFlags: flags)
            self.recentMediaEvents.append(record)
            if self.recentMediaEvents.count > 20 {
                self.recentMediaEvents.removeFirst(self.recentMediaEvents.count - 20)
            }
            self.lastMediaEventAt = record.timestamp
            self.lastMediaEventDescription = self.describeMediaEvent(record)
            self.eventTapEnabled = self.interceptor.isTapEnabled
        }
        preferenceObservation = Defaults.publisher(.hudReplacement)
            .sink { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        // Leaving System Settings can grant access without activating this nonactivating app.
        activationObservation = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] _ in Task { @MainActor in self?.refresh() } }
        refresh()
    }

    /// Passive: never prompts and never changes the user's requested preference.
    func refresh() {
        accessibilityAuthorized = AXIsProcessTrusted()
        reconcile()
    }

    /// Call only from the user's explicit permission button.
    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refresh()

        // System Settings may stay foreground; provide a bounded live recheck without restarting.
        permissionRefreshTask?.cancel()
        permissionRefreshTask = Task { @MainActor [weak self] in
            for _ in 0..<60 {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, self.started else { return }
                self.refresh()
                if self.accessibilityAuthorized { return }
            }
        }
    }

    func setApplicationAvailable(_ available: Bool) {
        applicationAvailable = available
        refresh()
    }

    func recordControlError(_ error: String?) { lastControlError = error }

    func recordControlResult(kind: SystemHUDKind, actualValue: Double?, isMuted: Bool? = nil, error: String?) {
        lastControlResult = HUDControlResult(timestamp: Date(), kind: kind, actualValue: actualValue,
                                             isMuted: isMuted, error: error)
        lastControlError = error
    }

    private func describeMediaEvent(_ record: HUDMediaEventRecord) -> String {
        let direction: String
        switch record.event.key {
        case .volumeUp: direction = "volume.increase"
        case .volumeDown: direction = "volume.decrease"
        case .brightnessUp: direction = "brightness.increase"
        case .brightnessDown: direction = "brightness.decrease"
        case .mute: direction = "volume.mute"
        }
        return "key=\(record.event.key.rawValue) \(direction) \(record.event.isKeyDown ? "down" : "up") repeat=\(record.event.isRepeat) consumed=\(record.consumed) flags=0x\(String(record.modifierFlags, radix: 16))"
    }

    func stop() {
        started = false
        permissionRefreshTask?.cancel()
        permissionRefreshTask = nil
        preferenceObservation?.cancel()
        preferenceObservation = nil
        activationObservation?.cancel()
        activationObservation = nil
        interceptor.onRuntimeStateChange = nil
        interceptor.onMediaEvent = nil
        interceptor.stop()
        eventTapEnabled = false
        setPresentationAvailable(false)
        errorMessage = nil
        status = .disabled
    }

    private func reconcile() {
        defer { updatePresentationAvailability() }
        errorMessage = nil
        guard started, Defaults[.hudReplacement] else {
            interceptor.stop()
            status = .disabled
            return
        }
        guard applicationAvailable else {
            interceptor.stop()
            status = .temporarilySuspended
            return
        }
        guard accessibilityAuthorized else {
            interceptor.stop()
            status = .permissionRequired
            return
        }
        apply(interceptor.start())
    }

    private func apply(_ result: MediaKeyInterceptor.StartResult) {
        defer { updatePresentationAvailability() }
        switch result {
        case .running:
            accessibilityAuthorized = true
            status = .running
            errorMessage = nil
        case .permissionRequired:
            accessibilityAuthorized = false
            status = .permissionRequired
            errorMessage = nil
        case .failed(let message):
            status = .failed
            errorMessage = message
        }
    }

    private func updatePresentationAvailability() {
        eventTapEnabled = interceptor.isTapEnabled
        setPresentationAvailable(status == .running && eventTapEnabled)
    }

    private func setPresentationAvailable(_ available: Bool) {
        if presentationAvailable != available { controlGeneration &+= 1 }
        presentationAvailable = available
        SystemHUDPresentation.shared.setApplicationAvailable(available)
    }

    private static func readProcessIdentity() -> String {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        var signature = "Unavailable"
        if SecCodeCopySelf([], &code) == errSecSuccess, let code,
           SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
           SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
           let info = information as? [String: Any] {
            let identifier = info[kSecCodeInfoIdentifier as String] as? String ?? "Unknown"
            let team = info[kSecCodeInfoTeamIdentifier as String] as? String ?? "None"
            let hash = (info[kSecCodeInfoUnique as String] as? Data)?.map { String(format: "%02x", $0) }.joined() ?? "Unknown"
            let authorities = (info[kSecCodeInfoCertificates as String] as? [SecCertificate])?.compactMap {
                SecCertificateCopySubjectSummary($0) as String?
            }.joined(separator: " → ") ?? "Ad hoc or unsigned"
            signature = "\(identifier); Team=\(team); CDHash=\(hash); \(authorities)"
        }
        return "Process: \(Bundle.main.bundleURL.path)\nBundle ID: \(Bundle.main.bundleIdentifier ?? "Unknown")\nSignature: \(signature)"
    }
}
