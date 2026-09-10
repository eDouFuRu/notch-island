import AppKit
import Combine
import CoreGraphics
import Darwin
import ImageIO
import AVFoundation

/// System capture tools. Only explicit user actions start a capture. The optional
/// observer imports new, metadata-tagged system screenshots without changing the
/// user's system screenshot location or deleting the original files.
@MainActor
final class CaptureTools: ObservableObject {
    static let shared = CaptureTools()
    static let automaticImportKey = "tools.capture.importSystemScreenshots"

    enum Status: Equatable {
        case idle, preparing, selecting, selectingRecordingRegion, recording, finishing, cancelled
        case choosingRecordingSource, startingNativeRecording
        case recordingCancelledPickerUnconfirmed
        case saved(Int), permissionRequired, clipboardEmpty, captureUnconfirmed, failed
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var isBusy = false
    @Published private(set) var isRecording = false
    @Published private(set) var lastImportedCount = 0
    @Published private(set) var externalImportAvailable = true
    @Published private(set) var processDiagnostic = CaptureProcessDiagnostic()
    @Published private(set) var importDiagnostic = CaptureImportDiagnostic()
    @Published var automaticallyImportSystemScreenshots: Bool {
        didSet {
            UserDefaults.standard.set(automaticallyImportSystemScreenshots, forKey: Self.automaticImportKey)
            updateExternalObserver()
        }
    }

    /// The app delegate hides its panels before capture and restores normal
    /// visibility afterwards. The user's persisted hide preference is untouched.
    var prepareForCapture: (() -> Void)?
    var onCaptureFinished: (() -> Void)?

    private var process: Process?
    private var regionSelector: CaptureRegionSelector?
    private var nativeRecorder: CaptureNativeRecorder?
    private var launchTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?
    private var visibilitySubscription: AnyCancellable?
    private var operationID: UUID?
    private var stoppedByUser = false
    private var importPolicy: CaptureFilePolicy?
    private var observationState = CaptureObservationState()
    private var watchGeneration = UUID()
    private struct RecoveryStart {
        let directory: URL
        let startedAt: Date
        let existing: [CaptureFileCandidate]?
        var interrupted = false
    }
    private var recoveryStart: RecoveryStart?
    private var importLedger = CaptureImportLedger()

    var diagnosticsSummary: String { processDiagnostic.summary + "\n\n" + importDiagnostic.summary }

    private init() {
        automaticallyImportSystemScreenshots = UserDefaults.standard.object(forKey: Self.automaticImportKey) as? Bool ?? true
        visibilitySubscription = Publishers.CombineLatest3(IslandVisibility.shared.$isHidden,
                                                           IslandVisibility.shared.$screenUnavailable,
                                                           IslandVisibility.shared.$captureInProgress)
            .sink { [weak self] hidden, unavailable, _ in
                // Latch interruption from the emitted values, even if a later
                // resume occurs before queued observer work gets CPU time.
                if hidden || unavailable {
                    self?.recoveryStart?.interrupted = true
                    self?.regionSelector?.cancel()
                    if self?.isBusy == true, self?.process == nil {
                        self?.cancelCapture()
                    }
                }
                Task { @MainActor in self?.updateExternalObserver() }
            }
        updateExternalObserver()
    }

    var statusText: String {
        switch status {
        case .idle: return L("Captures are saved temporarily in the file shelf.")
        case .preparing: return L("Preparing system capture…")
        case .selecting: return L("Use the system capture controls. Press Escape to cancel.")
        case .selectingRecordingRegion: return L("Drag to select an area. Release to start recording. Press Escape to cancel.")
        case .choosingRecordingSource: return L("Choose a screen or window in the system picker. Video only; system audio and microphone are off.")
        case .startingNativeRecording: return L("Starting recording of the selected content…")
        case .recordingCancelledPickerUnconfirmed: return L("This recording was cancelled. If the system picker is still visible, press Escape to close it.")
        case .recording: return L("Recording. Stop here or from the system recording control.")
        case .finishing: return L("Finishing recording…")
        case .cancelled: return L("Capture cancelled. No file was added.")
        case .saved(let count): return String(format: L("Added %d capture(s) to the file shelf."), count)
        case .permissionRequired: return L("Allow screen recording for this app in System Settings, then try again.")
        case .clipboardEmpty: return L("No image in the clipboard. Copy a screenshot first.")
        case .captureUnconfirmed: return L("The system capture finished, but its file could not be confirmed. Check the system save location.")
        case .failed: return L("Capture could not be saved. Check screen recording permission and try again.")
        }
    }

    func start(_ kind: CaptureToolKind) {
        guard !isBusy, IslandVisibility.shared.isAvailable else { return }
        processDiagnostic = CaptureProcessDiagnostic(kind: kind, phase: "checking permission", startedAt: Date())
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            processDiagnostic.phase = "finished"
            processDiagnostic.error = .permission
            processDiagnostic.endedAt = Date()
            status = .permissionRequired
            return
        }
        let id = UUID()
        operationID = id
        stoppedByUser = false
        lastImportedCount = 0
        isBusy = true
        status = .preparing
        processDiagnostic.phase = "preparing"
        prepareForCapture?()
        launchTask = Task { [weak self] in
            // Allow the shell's closing spring/window disappearance to settle.
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled, let self, self.operationID == id else { return }
            if kind == .areaRecording { self.selectRecordingRegion(operation: id) }
            else if kind == .customRecording { self.startNativeRecording(operation: id) }
            else { self.launch(kind, operation: id) }
        }
    }

    func stopRecording() {
        if let nativeRecorder {
            stoppedByUser = true
            processDiagnostic.userRequestedStop = true
            nativeRecorder.stop()
            return
        }
        guard isRecording, let process, process.isRunning else { return }
        stoppedByUser = true
        processDiagnostic.userRequestedStop = true
        processDiagnostic.phase = "stop requested"
        status = .finishing
        // SIGINT is screencapture's graceful recording stop, allowing the movie
        // container to be finalized. Never SIGKILL a recording.
        process.interrupt()
    }

    func cancelCapture() {
        if nativeRecorder != nil { stopRecording(); return }
        if let selector = regionSelector { selector.cancel(); return }
        if isRecording { stopRecording(); return }
        launchTask?.cancel()
        if let process, process.isRunning {
            stoppedByUser = true
            processDiagnostic.userRequestedStop = true
            processDiagnostic.phase = "cancel requested"
            process.terminate()
        } else if isBusy {
            processDiagnostic.phase = "cancelled before launch"
            processDiagnostic.endedAt = Date()
            resetOperation()
            status = .cancelled
        }
    }

    func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    /// An explicit bridge for hi/WeChat and other capture apps, driven by a user click.
    ///
    /// Declared files are handled first and copied byte for byte. Copying a document in
    /// Finder also leaves an icon bitmap on the pasteboard, so reading an image first turned
    /// every `.md` and `.swift` into a PNG of its own icon.
    @discardableResult
    func importClipboardFiles() -> Int {
        let staged = stageClipboardFileURLs()
        if staged > 0 { return staged }
        guard let image = NSImage(pasteboard: .general) else {
            status = .clipboardEmpty
            return 0
        }
        guard saveToShelf(image: image) else {
            status = .failed
            return 0
        }
        return 1
    }

    /// Copies the clipboard's files into the shelf's temporary store, each keeping its own
    /// name and extension. Every file gets its own directory, so names never collide.
    private func stageClipboardFileURLs() -> Int {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let hasFileURLs = NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: options)
        guard ClipboardStagingDecision.decide(hasFileURLs: hasFileURLs, hasBitmap: false) == .files,
              let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self],
                                                          options: options) as? [URL],
              !urls.isEmpty else { return 0 }
        let staged = urls.reduce(0) { $0 + (copyFileToShelf($1) ? 1 : 0) }
        if staged > 0 {
            lastImportedCount = staged
            if !isBusy { status = .saved(staged) }
        } else {
            status = .failed
        }
        return staged
    }

    private func copyFileToShelf(_ source: URL) -> Bool {
        do {
            let folder = try Self.makeCaptureDirectory()
            let name = ClipboardStagingDecision.stagedFileName(
                source: source.lastPathComponent,
                fallback: "Clipboard-\(Self.filenameDate())")
            let file = folder.appendingPathComponent(name)
            try FileManager.default.copyItem(at: source, to: file)
            guard addTemporaryFile(file) else {
                try? FileManager.default.removeItem(at: folder)
                return false
            }
            return true
        } catch { return false }
    }

    /// Shared by the toolbar button and the clipboard watcher. Reports status only when the
    /// app is otherwise idle, so a background import cannot overwrite the message a capture
    /// in progress is showing.
    @discardableResult
    func saveToShelf(image: NSImage) -> Bool {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:]) else { return false }
        do {
            let folder = try Self.makeCaptureDirectory()
            let file = folder.appendingPathComponent("Clipboard-\(Self.filenameDate()).png")
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            guard addTemporaryFile(file) else {
                try? FileManager.default.removeItem(at: folder)
                return false
            }
            lastImportedCount = 1
            if !isBusy { status = .saved(1) }
            return true
        } catch { return false }
    }

    private func startNativeRecording(operation: UUID) {
        guard operationID == operation else { return }
        guard !IslandVisibility.shared.isHidden, !IslandVisibility.shared.screenUnavailable else {
            cancelCapture()
            return
        }
        processDiagnostic.backend = "ScreenCaptureKit"
        do {
            let folder = try Self.makeCaptureDirectory()
            let output = folder.appendingPathComponent("Recording-\(Self.filenameDate()).mp4")
            let recorder = CaptureNativeRecorder(outputURL: output)
            nativeRecorder = recorder
            recorder.onState = { [weak self] state in
                guard let self, self.operationID == operation else { return }
                switch state {
                case .selecting:
                    self.processDiagnostic.phase = "selecting native recording source"
                    self.status = .choosingRecordingSource
                case .starting:
                    self.processDiagnostic.phase = "starting native recording"
                    self.status = .startingNativeRecording
                case .recording:
                    self.processDiagnostic.phase = "recording output confirmed started"
                    self.isRecording = true
                    self.status = .recording
                case .stopping:
                    self.processDiagnostic.phase = "waiting for recording output to finish"
                    self.isRecording = false
                    self.status = .finishing
                }
            }
            recorder.onFinish = { [weak self] outcome in
                Task { @MainActor in
                    await self?.finishNativeRecording(operation: operation, output: output, outcome: outcome)
                }
            }
            recorder.present()
        } catch {
            processDiagnostic.phase = "native recording setup failed"
            processDiagnostic.error = .launchFailure
            processDiagnostic.endedAt = Date()
            resetOperation()
            status = .failed
        }
    }

    private func finishNativeRecording(operation: UUID, output: URL,
                                       outcome: CaptureNativeRecorder.Outcome) async {
        guard operationID == operation else { return }
        isRecording = false
        let exists = FileManager.default.fileExists(atPath: output.path)
        let bytes = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        processDiagnostic.output = exists ? (bytes > 0 ? .invalid : .empty) : .absent
        var imported = false
        let result: Status
        switch outcome {
        case .saved(let url):
            processDiagnostic.phase = "validating finalized native recording"
            if url == output, await Self.isValidMovie(url) {
                guard operationID == operation else { return }
                processDiagnostic.output = .video
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                imported = addTemporaryFile(url)
                if imported { processDiagnostic.importMethod = "ScreenCaptureKit finalized output" }
            }
            result = imported ? .saved(1) : .failed
        case .cancelled(let source):
            // Picker cancellation never launched a stream or produced a movie.
            if !exists { try? FileManager.default.removeItem(at: output.deletingLastPathComponent()) }
            processDiagnostic.cancellation = source.rawValue
            result = source == .applicationUnconfirmed ? .recordingCancelledPickerUnconfirmed : .cancelled
        case .failed(let code):
            processDiagnostic.nativeErrorCode = code
            let denied = code == -3801 || !CGPreflightScreenCaptureAccess()
            processDiagnostic.error = denied ? .permission : .captureFailure
            result = denied ? .permissionRequired : .failed
            // Preserve any partial private output on failure: a stop request may
            // still be finishing in the framework. It is never published as saved.
        }
        guard operationID == operation else { return }
        processDiagnostic.imported = imported
        processDiagnostic.phase = "finished"
        processDiagnostic.endedAt = Date()
        if imported { lastImportedCount = 1 }
        resetOperation()
        status = result
    }

    private func selectRecordingRegion(operation: UUID) {
        guard operationID == operation else { return }
        guard !IslandVisibility.shared.isHidden, !IslandVisibility.shared.screenUnavailable else {
            processDiagnostic.phase = "region selection interrupted"
            processDiagnostic.endedAt = Date()
            resetOperation()
            status = .cancelled
            return
        }
        status = .selectingRecordingRegion
        processDiagnostic.phase = "selecting recording region"
        let selector = CaptureRegionSelector()
        regionSelector = selector
        selector.select { [weak self] region in
            guard let self, self.operationID == operation else { return }
            self.regionSelector = nil
            guard let region else {
                self.processDiagnostic.phase = "region selection cancelled"
                self.processDiagnostic.endedAt = Date()
                self.resetOperation()
                self.status = .cancelled
                return
            }
            self.status = .preparing
            self.processDiagnostic.phase = "preparing selected region"
            self.launchTask = Task { [weak self] in
                // The selector and its instructional overlay must disappear
                // before the first recorded frame can be generated.
                try? await Task.sleep(nanoseconds: 450_000_000)
                guard !Task.isCancelled, let self, self.operationID == operation else { return }
                self.launch(.areaRecording, operation: operation, region: region)
            }
        }
    }

    private func launch(_ kind: CaptureToolKind, operation: UUID, region: CaptureRegion? = nil) {
        guard operationID == operation else { return }
        guard !IslandVisibility.shared.isHidden, !IslandVisibility.shared.screenUnavailable else {
            processDiagnostic.phase = "interrupted before recording"
            processDiagnostic.endedAt = Date()
            resetOperation()
            status = .cancelled
            return
        }
        var workingFolder: URL?
        var errorWriter: FileHandle?
        do {
            let folder = try Self.makeCaptureDirectory()
            workingFolder = folder
            let output = folder.appendingPathComponent("\(kind.recordsVideo ? "Recording" : "Screenshot")-\(Self.filenameDate()).\(kind.recordsVideo ? "mov" : "png")")
            let errorURL = folder.appendingPathComponent(".capture-error")
            FileManager.default.createFile(atPath: errorURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            let errorHandle = try FileHandle(forWritingTo: errorURL)
            errorWriter = errorHandle
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            let arguments = kind.arguments(output: output, region: region)
            guard !arguments.isEmpty else { throw CocoaError(.fileWriteUnknown) }
            child.arguments = arguments
            child.standardOutput = FileHandle.nullDevice
            child.standardError = errorHandle
            if kind.usesSystemToolbar {
                let directory = Self.systemScreenshotDirectory()
                let baseline = Self.readCandidates(in: directory)
                recoveryStart = RecoveryStart(directory: directory, startedAt: Date(), existing: baseline)
            }
            child.terminationHandler = { [weak self] finished in
                try? errorHandle.close()
                Task { @MainActor in
                    await self?.finish(operation: operation, kind: kind, output: output,
                                       errorURL: errorURL, exitCode: finished.terminationStatus)
                }
            }
            process = child
            try child.run()
            processDiagnostic.phase = "process running"
            isRecording = kind.recordsVideo
            status = kind.recordsVideo ? .recording : (kind.isInteractive ? .selecting : .preparing)
        } catch {
            processDiagnostic.phase = "launch failed"
            processDiagnostic.error = .launchFailure
            processDiagnostic.endedAt = Date()
            try? errorWriter?.close()
            if let workingFolder { try? FileManager.default.removeItem(at: workingFolder) }
            resetOperation()
            status = .failed
        }
    }

    private func finish(operation: UUID, kind: CaptureToolKind, output: URL,
                        errorURL: URL, exitCode: Int32) async {
        guard operationID == operation else { return }
        let processFinishedAt = Date()
        isRecording = false // The native process has stopped; recovery is file I/O only.
        let wasStopped = stoppedByUser
        // screencapture error output contains tool diagnostics, not screen data.
        let errorData = (try? Data(contentsOf: errorURL)) ?? Data()
        let diagnostic = String(decoding: errorData.prefix(8_192), as: UTF8.self).lowercased()
        processDiagnostic.exitCode = exitCode
        processDiagnostic.error = CaptureErrorCategory.classify(diagnostic)
        processDiagnostic.phase = "checking output"
        try? FileManager.default.removeItem(at: errorURL)
        let exists = FileManager.default.fileExists(atPath: output.path)
        let bytes = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        processDiagnostic.output = exists ? (bytes > 0 ? .invalid : .empty) : .absent
        var valid = false
        if exists {
            if kind.recordsVideo { valid = await Self.isValidMovie(output) }
            else { valid = Self.isValidImage(output) }
        }
        if valid { processDiagnostic.output = kind.recordsVideo ? .video : .image }
        guard operationID == operation else { return }
        var imported = false
        if valid, exitCode == 0 || (kind.recordsVideo && wasStopped) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
            imported = addTemporaryFile(output)
            if imported {
                processDiagnostic.importMethod = "direct output"
                copyStillToClipboardIfEnabled(output, kind: kind)
            }
        }
        if !exists, exitCode == 0, !wasStopped, kind.usesSystemToolbar {
            imported = await recoverToolbarScreenshot(operation: operation, finishedAt: processFinishedAt)
        }
        guard operationID == operation else {
            // Only the app-owned, unsuccessful direct-output folder is disposable.
            if !exists { try? FileManager.default.removeItem(at: output.deletingLastPathComponent()) }
            return
        }
        if !imported || !exists { try? FileManager.default.removeItem(at: output.deletingLastPathComponent()) }
        processDiagnostic.imported = imported
        processDiagnostic.phase = "finished"
        processDiagnostic.endedAt = Date()
        resetOperation()
        if imported {
            lastImportedCount = 1
            status = .saved(1)
        } else if !CGPreflightScreenCaptureAccess() || diagnostic.contains("permission") || diagnostic.contains("not authorized") {
            status = .permissionRequired
        } else if !exists, exitCode == 0, kind.usesSystemToolbar {
            status = .captureUnconfirmed
        } else if !exists && ((!kind.recordsVideo && wasStopped) || (!wasStopped && exitCode != 0 && kind.isInteractive && (diagnostic.isEmpty || diagnostic.contains("cancel")))) {
            status = .cancelled
        } else { status = .failed }
    }

    private func resetOperation() {
        operationID = nil
        launchTask = nil
        process = nil
        regionSelector = nil
        nativeRecorder = nil
        recoveryStart = nil
        isBusy = false
        isRecording = false
        onCaptureFinished?()
    }

    private func addTemporaryFile(_ url: URL) -> Bool {
        guard let bookmark = try? Bookmark(url: url) else { return false }
        ShelfStateViewModel.shared.add([ShelfItem(kind: .file(bookmark: bookmark.data), isTemporary: true)])
        return true
    }

    /// Every capture reaches the shelf through `addTemporaryFile`, but only stills belong on
    /// the clipboard — a recording would put a single poster frame there and read as the
    /// wrong thing when pasted.
    private func copyStillToClipboardIfEnabled(_ url: URL, kind: CaptureToolKind) {
        guard !kind.recordsVideo else { return }
        ClipboardShelfBridge.shared.copyCaptureToClipboard(contentsOf: url)
    }

    private func recoverToolbarScreenshot(operation: UUID, finishedAt: Date) async -> Bool {
        guard let start = recoveryStart, let baseline = start.existing else {
            processDiagnostic.recovery = "initial folder unavailable"
            return false
        }
        var policy = CaptureRecoveryPolicy(directory: start.directory, startedAt: start.startedAt,
                                           finishedAt: finishedAt, existing: baseline)
        let deadline = finishedAt.addingTimeInterval(CaptureRecoveryPolicy.maximumDelay)
        processDiagnostic.phase = "recovering toolbar output"
        processDiagnostic.recovery = "waiting for a unique stable screenshot"
        while Date() <= deadline {
            guard operationID == operation else { return false }
            let permitted = recoveryStart?.interrupted == false &&
                !IslandVisibility.shared.isHidden && !IslandVisibility.shared.screenUnavailable
            guard permitted else { processDiagnostic.recovery = "interrupted by hide or lock"; return false }
            let currentDirectory = Self.systemScreenshotDirectory()
            guard currentDirectory == start.directory else {
                processDiagnostic.recovery = "save directory changed; not scanned"
                return false
            }
            let candidates = await Task.detached(priority: .utility) {
                Self.readCandidates(in: start.directory)
            }.value
            guard operationID == operation else { return false }
            let stillPermitted = recoveryStart?.interrupted == false &&
                !IslandVisibility.shared.isHidden && !IslandVisibility.shared.screenUnavailable
            let decision = policy.evaluate(candidates, currentDirectory: Self.systemScreenshotDirectory(),
                                           permitted: stillPermitted, now: Date())
            switch decision {
            case .unique(let candidate):
                let alreadyImported = importLedger.contains(candidate)
                guard copyExternalScreenshot(candidate) else {
                    processDiagnostic.recovery = "copy or validation failed"
                    return false
                }
                processDiagnostic.recovery = alreadyImported ? "matched an already imported screenshot" : "copied unique screenshot"
                processDiagnostic.importMethod = alreadyImported ? "system folder; existing import" : "system folder recovery"
                return true
            case .waiting: try? await Task.sleep(nanoseconds: 500_000_000)
            case .ambiguous: processDiagnostic.recovery = "multiple matching screenshots"; return false
            case .directoryChanged: processDiagnostic.recovery = "save directory changed; not scanned"; return false
            case .interrupted: processDiagnostic.recovery = "interrupted by hide or lock"; return false
            case .unreadable: processDiagnostic.recovery = "save directory unavailable"; return false
            case .timedOut: processDiagnostic.recovery = "no unique stable screenshot within 15 seconds"; return false
            }
        }
        processDiagnostic.recovery = "no unique stable screenshot within 15 seconds"
        return false
    }

    private static func makeCaptureDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NotchIsland-Captures", isDirectory: true)
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        return folder
    }

    private static func filenameDate() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: Date())
    }

    private nonisolated static func isValidImage(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return false }
        return width > 0 && height > 0
    }

    private static func isValidMovie(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .video), !tracks.isEmpty,
              let duration = try? await asset.load(.duration) else { return false }
        return duration.seconds.isFinite && duration.seconds > 0
    }

    // MARK: External system screenshots

    private func updateExternalObserver() {
        let visibility = IslandVisibility.shared
        let changed = observationState.update(enabled: automaticallyImportSystemScreenshots,
                                              manuallyHidden: visibility.isHidden,
                                              screenUnavailable: visibility.screenUnavailable,
                                              captureInProgress: visibility.captureInProgress,
                                              at: Date())
        // Keep both the original time boundary and successful-import identities
        // while our capture temporarily hides the shell. Otherwise a toolbar's
        // image saved during that interval is permanently excluded as history.
        guard changed || importDiagnostic.gate != observationState.gate.rawValue ||
                (observationState.gate == .observing && watchTask == nil) else { return }
        watchTask?.cancel()
        watchTask = nil
        importPolicy = nil
        watchGeneration = UUID()
        importDiagnostic = CaptureImportDiagnostic(gate: observationState.gate.rawValue)
        guard observationState.gate == .observing else { return }
        let generation = watchGeneration
        let directory = Self.systemScreenshotDirectory()
        importPolicy = CaptureFilePolicy(directory: directory, startedAt: observationState.beganAt ?? Date())
        importDiagnostic.startedAt = importPolicy?.startedAt
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled, let self, self.watchGeneration == generation else { return }
                // Respect changes made in Screenshot.app's Options menu without
                // importing an existing folder's historical screenshots.
                let currentDirectory = Self.systemScreenshotDirectory()
                if self.importPolicy?.directory != currentDirectory {
                    self.importPolicy = CaptureFilePolicy(directory: currentDirectory, startedAt: Date())
                    self.importDiagnostic.startedAt = self.importPolicy?.startedAt
                }
                let result = await Task.detached(priority: .utility) {
                    Self.readCandidates(in: currentDirectory)
                }.value
                guard !Task.isCancelled, self.watchGeneration == generation else { return }
                // A visibility publication reaches the observer asynchronously.
                // Recheck committed privacy gates before importing a completed
                // scan so lock/manual-hide cannot lose a race with disk I/O.
                guard self.automaticallyImportSystemScreenshots,
                      !IslandVisibility.shared.isHidden,
                      !IslandVisibility.shared.screenUnavailable else {
                    self.updateExternalObserver()
                    return
                }
                self.externalImportAvailable = result != nil
                self.importDiagnostic.lastScanAt = Date()
                self.importDiagnostic.directoryReadable = result != nil
                self.importDiagnostic.candidates = result?.count ?? 0
                self.importDiagnostic.stableCandidates = 0
                self.importDiagnostic.importedThisScan = 0
                for candidate in result ?? [] {
                    guard self.importPolicy?.readyToImport(candidate, now: Date()) == true else { continue }
                    self.importDiagnostic.stableCandidates += 1
                    if self.copyExternalScreenshot(candidate) {
                        self.importPolicy?.markImported(candidate)
                        self.importDiagnostic.importedThisScan += 1
                    }
                }
            }
        }
    }

    private static func systemScreenshotDirectory() -> URL {
        let location = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
        let fallback = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
        guard let location, !location.isEmpty else { return fallback }
        let path = (location as NSString).expandingTildeInPath
        guard path.hasPrefix("/") else { return fallback }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    private nonisolated static func readCandidates(in directory: URL) -> [CaptureFileCandidate]? {
        let keys: Set<URLResourceKey> = [.creationDateKey, .contentModificationDateKey, .fileSizeKey,
                                         .isRegularFileKey, .isSymbolicLinkKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else { return nil }
        return urls.compactMap { url in
            guard CaptureFilePolicy.imageExtensions.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: keys),
                  let creation = values.creationDate, let modification = values.contentModificationDate else { return nil }
            return CaptureFileCandidate(url: url, creationDate: creation, modificationDate: modification,
                                        byteCount: Int64(values.fileSize ?? 0), isRegularFile: values.isRegularFile == true,
                                        isSymbolicLink: values.isSymbolicLink == true,
                                        isSystemScreenshot: Self.hasSystemScreenshotMetadata(url))
        }
    }

    private nonisolated static func hasSystemScreenshotMetadata(_ url: URL) -> Bool {
        let name = "com.apple.metadata:kMDItemIsScreenCapture"
        let size = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0, size <= 4_096 else { return false }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
        guard read == size, let value = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return false }
        if let number = value as? NSNumber { return number.boolValue }
        if let text = value as? String { return text == "1" || text.lowercased() == "true" }
        return false
    }

    private func copyExternalScreenshot(_ candidate: CaptureFileCandidate) -> Bool {
        if importLedger.contains(candidate) { return true }
        let source = candidate.url
        guard Self.isValidImage(source) else { return false }
        do {
            let folder = try Self.makeCaptureDirectory()
            let destination = folder.appendingPathComponent(source.lastPathComponent)
            try FileManager.default.copyItem(at: source, to: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            guard addTemporaryFile(destination) else {
                try? FileManager.default.removeItem(at: folder)
                return false
            }
            importLedger.recordSuccessfulImport(candidate)
            ClipboardShelfBridge.shared.copyCaptureToClipboard(contentsOf: destination)
            lastImportedCount = 1
            if !isBusy { status = .saved(1) }
            return true
        } catch { return false }
    }
}
