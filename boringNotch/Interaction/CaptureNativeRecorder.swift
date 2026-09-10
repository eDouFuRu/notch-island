import AppKit
import AVFoundation
import ScreenCaptureKit

/// Owns exactly one picker/stream/output. ScreenCaptureKit writes the movie
/// directly; no captured frames or audio buffers are delivered to application
/// code. The default is video only, including neither system audio nor mic.
@available(macOS 15.0, *)
@MainActor
final class CaptureNativeRecorder: NSObject {
    enum State { case selecting, starting, recording, stopping }
    enum Outcome { case saved(URL), cancelled(CaptureNativeCancellation), failed(Int?) }
    var onState: ((State) -> Void)?
    var onFinish: ((Outcome) -> Void)?

    private let outputURL: URL
    private var policy = CaptureNativeRecordingPolicy()
    private var pickerCancellation = CapturePickerCancellationPolicy()
    private var pickerCancellationTask: Task<Void, Never>?
    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var watchdog: Task<Void, Never>?
    private var didDeliverCompletion = false
    private var pickerRegistered = false
    private var previousConfiguration: SCContentSharingPickerConfiguration?
    private var previousMaximumStreamCount: Int?

    init(outputURL: URL) { self.outputURL = outputURL; super.init() }

    func present() {
        guard !pickerRegistered, policy.phase == .selecting else { return }
        let picker = SCContentSharingPicker.shared
        previousConfiguration = picker.defaultConfiguration
        previousMaximumStreamCount = picker.maximumStreamCount
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = [.singleDisplay, .singleWindow]
        configuration.allowsChangingSelectedContent = false
        if let bundle = Bundle.main.bundleIdentifier { configuration.excludedBundleIDs = [bundle] }
        picker.defaultConfiguration = configuration
        picker.maximumStreamCount = 1
        picker.add(self)
        pickerRegistered = true
        picker.isActive = true
        onState?(.selecting)
        picker.present()
    }

    func stop() {
        let action = policy.requestStop()
        switch action {
        case .cancelSelection: cancelSelectionFromApplication()
        case .stopStream: onState?(.stopping); stopStream()
        case .waitForStart: onState?(.stopping); armWatchdog()
        case .none: break
        }
    }

    private func cancelSelectionFromApplication() {
        // requestStop has already made policy terminal, so a late selection
        // cannot start a stream, even while awaiting dismissal confirmation.
        pickerCancellation.requestFromApplication()
        SCContentSharingPicker.shared.isActive = false
        pickerCancellationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: CapturePickerCancellationPolicy.confirmationWaitNanoseconds)
            guard !Task.isCancelled, let self,
                  let source = self.pickerCancellation.confirmationDeadlineReached() else { return }
            self.finish(.cancelled(source))
        }
    }

    private func begin(with filter: SCContentFilter) {
        guard policy.acceptSelection() else { return }
        guard let size = CaptureNativeVideoDimensions.size(content: filter.contentRect.size,
                                                           pointPixelScale: CGFloat(filter.pointPixelScale)) else {
            fail(code: -3812)
            return
        }
        let configuration = SCStreamConfiguration()
        configuration.width = Int(size.width)
        configuration.height = Int(size.height)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.showsCursor = true
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.capturesAudio = false
        configuration.captureMicrophone = false
        configuration.captureDynamicRange = .SDR
        configuration.streamName = "工位充电岛"
        let outputConfiguration = SCRecordingOutputConfiguration()
        outputConfiguration.outputURL = outputURL
        outputConfiguration.videoCodecType = .h264
        outputConfiguration.outputFileType = .mp4
        let output = SCRecordingOutput(configuration: outputConfiguration, delegate: self)
        let captureStream = SCStream(filter: filter, configuration: configuration, delegate: self)
        recordingOutput = output
        stream = captureStream
        do { try captureStream.addRecordingOutput(output) }
        catch { fail(code: (error as NSError).code); return }
        onState?(.starting)
        armWatchdog()
        Task { [weak self, captureStream] in
            do {
                try await captureStream.startCapture()
                guard let self, self.stream === captureStream, self.policy.phase != .finished else {
                    // Cancellation can finish while the framework is still
                    // starting; a late success must immediately stop its stream.
                    try? await captureStream.stopCapture()
                    return
                }
                if self.policy.streamStarted() == .stopStream { self.stopStream() }
            } catch {
                guard let self, self.stream === captureStream else { return }
                self.fail(code: (error as NSError).code)
            }
        }
    }

    private func stopStream() {
        guard let stream else { fail(code: nil); return }
        armWatchdog()
        Task { [weak self, stream] in
            do { try await stream.stopCapture() }
            catch {
                guard let self, self.stream === stream, self.policy.phase != .finished else { return }
                let error = error as NSError
                // A simultaneous native Stop can make our stop request report
                // already-stopped. Continue waiting for the recording callback.
                if error.domain == SCStreamErrorDomain, [-3808, -3817, -3821].contains(error.code) { return }
                self.fail(code: error.code)
            }
            // stopCapture completion never publishes the file. The output's
            // didFinish callback is the authoritative file-finalization event.
        }
    }

    private func armWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled, let self, self.policy.phase != .finished else { return }
            self.fail(code: nil)
        }
    }

    private func fail(code: Int?) {
        guard policy.fail() else { return }
        // Keep the stream alive until the stop request completes, even when
        // a recording-output failure arrives before stream termination.
        if let stream {
            if let recordingOutput { try? stream.removeRecordingOutput(recordingOutput) }
            Task { try? await stream.stopCapture() }
        }
        finish(.failed(code))
    }

    private func finish(_ outcome: Outcome) {
        guard !didDeliverCompletion else { return }
        didDeliverCompletion = true
        watchdog?.cancel()
        watchdog = nil
        pickerCancellationTask?.cancel()
        pickerCancellationTask = nil
        if pickerRegistered {
            let picker = SCContentSharingPicker.shared
            picker.remove(self)
            picker.isActive = false
            if let previousConfiguration { picker.defaultConfiguration = previousConfiguration }
            picker.maximumStreamCount = previousMaximumStreamCount
            pickerRegistered = false
        }
        // Releasing our strong reference is safe after output finish/failure;
        // in-flight start/stop Tasks independently retain their exact stream.
        if let stream, policy.streamHasStarted { Task { try? await stream.stopCapture() } }
        stream = nil
        recordingOutput = nil
        let callback = onFinish
        onFinish = nil
        onState = nil
        callback?(outcome)
    }
}

@available(macOS 15.0, *)
extension CaptureNativeRecorder: SCContentSharingPickerObserver, SCStreamDelegate, SCRecordingOutputDelegate {
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor [weak self] in
            guard let self, stream == nil,
                  self.policy.phase == .selecting || self.pickerCancellation.awaitsSystemConfirmation else { return }
            if self.policy.phase == .selecting { _ = self.policy.requestStop() }
            guard let source = self.pickerCancellation.systemDidCancel() else { return }
            self.finish(.cancelled(source))
        }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker,
                                         didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor [weak self] in
            guard stream == nil else { return }
            self?.begin(with: filter)
        }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        let code = (error as NSError).code
        Task { @MainActor [weak self] in self?.fail(code: code) }
    }

    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor [weak self] in
            guard let self, self.recordingOutput === recordingOutput else { return }
            if self.policy.recordingStarted() {
                self.watchdog?.cancel()
                self.onState?(.recording)
            }
        }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor [weak self] in
            guard let self, self.recordingOutput === recordingOutput,
                  let completion = self.policy.recordingFinished() else { return }
            switch completion {
            case .saved: self.finish(.saved(self.outputURL))
            case .cancelled: self.finish(.cancelled(.beforeRecordingOutput))
            case .failed: self.finish(.failed(nil))
            }
        }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        let code = (error as NSError).code
        Task { @MainActor [weak self] in
            guard let self, self.recordingOutput === recordingOutput else { return }
            self.fail(code: code)
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        let code = (error as NSError).code
        let systemStop = (error as NSError).domain == SCStreamErrorDomain && [-3817, -3821].contains(code)
        Task { @MainActor [weak self] in
            guard let self, self.stream === stream else { return }
            if systemStop {
                guard self.policy.streamStoppedExternally() else { return }
                self.onState?(.stopping)
                self.armWatchdog()
            } else { self.fail(code: code) }
        }
    }

    @available(macOS 15.2, *)
    nonisolated func streamDidBecomeInactive(_ stream: SCStream) {
        Task { @MainActor [weak self] in
            guard let self, self.stream === stream else { return }
            self.stop()
        }
    }
}
