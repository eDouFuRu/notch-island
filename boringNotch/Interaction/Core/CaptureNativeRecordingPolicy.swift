import Foundation

enum CaptureNativeCancellation: String, Sendable {
    case systemPicker = "system picker didCancelFor"
    case applicationUnconfirmed = "application cancellation; picker dismissal unconfirmed"
    case applicationConfirmed = "application cancellation; system didCancelFor confirmed"
    case beforeRecordingOutput = "recording stopped before output start"
}

/// Deactivating the public picker does not document synchronous dismissal of
/// an already presented UI. Keep callback confirmation separate from intent.
struct CapturePickerCancellationPolicy: Sendable {
    static let confirmationWaitNanoseconds: UInt64 = 400_000_000
    private var applicationRequested = false
    private var completed = false
    var awaitsSystemConfirmation: Bool { applicationRequested && !completed }

    mutating func requestFromApplication() {
        guard !completed else { return }
        applicationRequested = true
    }

    mutating func systemDidCancel() -> CaptureNativeCancellation? {
        guard !completed else { return nil }
        completed = true
        return applicationRequested ? .applicationConfirmed : .systemPicker
    }

    mutating func confirmationDeadlineReached() -> CaptureNativeCancellation? {
        guard applicationRequested, !completed else { return nil }
        completed = true
        return .applicationUnconfirmed
    }
}

/// The stream-start callback and recording-output callbacks may arrive in
/// either order. A file is publishable only after recording output finishes.
struct CaptureNativeRecordingPolicy: Sendable {
    enum Phase: String, Sendable { case selecting, starting, recording, stopping, finished }
    enum StopAction: Equatable { case cancelSelection, waitForStart, stopStream, none }
    enum Completion: Equatable { case saved, cancelled, failed }
    private(set) var phase: Phase = .selecting
    private(set) var streamHasStarted = false
    private(set) var recordingHasStarted = false
    private(set) var stopRequested = false
    private var stopIssued = false

    mutating func acceptSelection() -> Bool {
        guard phase == .selecting else { return false }
        phase = .starting
        return true
    }

    mutating func streamStarted() -> StopAction {
        guard phase != .finished else { return .none }
        streamHasStarted = true
        if stopRequested, !stopIssued { stopIssued = true; return .stopStream }
        return .none
    }

    /// Returns whether the UI may now claim it is recording.
    mutating func recordingStarted() -> Bool {
        guard phase == .starting || phase == .stopping else { return false }
        recordingHasStarted = true
        guard !stopRequested else { return false }
        phase = .recording
        return true
    }

    mutating func requestStop() -> StopAction {
        guard phase != .finished else { return .none }
        stopRequested = true
        if phase == .selecting { phase = .finished; return .cancelSelection }
        phase = .stopping
        guard streamHasStarted else { return .waitForStart }
        guard !stopIssued else { return .none }
        stopIssued = true
        return .stopStream
    }

    /// System UI and session shutdown can stop the stream before its file's
    /// final callback arrives. This is not itself a file failure or success.
    mutating func streamStoppedExternally() -> Bool {
        guard phase != .finished else { return false }
        stopRequested = true
        stopIssued = true
        phase = .stopping
        return true
    }

    mutating func recordingFinished() -> Completion? {
        guard phase != .finished else { return nil }
        phase = .finished
        if recordingHasStarted { return .saved }
        return stopRequested ? .cancelled : .failed
    }

    mutating func fail() -> Bool {
        guard phase != .finished else { return false }
        phase = .finished
        return true
    }
}

enum CaptureNativeVideoDimensions {
    /// H.264-compatible, even output dimensions, bounded to 4K. The selected
    /// content is scaled uniformly; its capture region is never expanded.
    static func size(content: CGSize, pointPixelScale: CGFloat) -> CGSize? {
        guard content.width.isFinite, content.height.isFinite, pointPixelScale.isFinite,
              content.width > 0, content.height > 0, pointPixelScale > 0 else { return nil }
        let width = content.width * pointPixelScale
        let height = content.height * pointPixelScale
        guard width.isFinite, height.isFinite else { return nil }
        let scale = min(1, 3840 / width, 2160 / height)
        return CGSize(width: max(2, floor(width * scale / 2) * 2),
                      height: max(2, floor(height * scale / 2) * 2))
    }
}
