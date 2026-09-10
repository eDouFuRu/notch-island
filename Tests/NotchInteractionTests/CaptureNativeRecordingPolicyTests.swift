import XCTest
@testable import NotchInteractionCore

final class CaptureNativeRecordingPolicyTests: XCTestCase {
    func testSystemPickerCancellationIsConfirmedByCallbackOnly() {
        var cancellation = CapturePickerCancellationPolicy()
        XCTAssertEqual(cancellation.systemDidCancel(), .systemPicker)
        XCTAssertNil(cancellation.systemDidCancel())
        cancellation.requestFromApplication()
        XCTAssertNil(cancellation.confirmationDeadlineReached())
    }

    func testApplicationCancellationHasBoundedUnconfirmedResult() {
        var cancellation = CapturePickerCancellationPolicy()
        cancellation.requestFromApplication()
        XCTAssertTrue(cancellation.awaitsSystemConfirmation)
        XCTAssertLessThanOrEqual(CapturePickerCancellationPolicy.confirmationWaitNanoseconds, 1_000_000_000)
        XCTAssertEqual(cancellation.confirmationDeadlineReached(), .applicationUnconfirmed)
        XCTAssertFalse(cancellation.awaitsSystemConfirmation)
        XCTAssertNil(cancellation.systemDidCancel(), "Late callbacks must not overwrite a completed operation")
    }

    func testSystemConfirmationDuringBoundedWaitRecordsBothOrigins() {
        var cancellation = CapturePickerCancellationPolicy()
        cancellation.requestFromApplication()
        XCTAssertEqual(cancellation.systemDidCancel(), .applicationConfirmed)
        XCTAssertNil(cancellation.confirmationDeadlineReached())
        XCTAssertNil(cancellation.systemDidCancel())
    }

    func testCancellationRejectsLateSelectionBeforePickerHasDismissed() {
        var recording = CaptureNativeRecordingPolicy()
        var cancellation = CapturePickerCancellationPolicy()
        XCTAssertEqual(recording.requestStop(), .cancelSelection)
        cancellation.requestFromApplication()
        XCTAssertTrue(cancellation.awaitsSystemConfirmation)
        XCTAssertFalse(recording.acceptSelection())
        XCTAssertFalse(recording.recordingStarted())
        XCTAssertEqual(recording.requestStop(), .none, "Repeated Cancel cannot extend the bounded wait")
        XCTAssertNil(recording.recordingFinished())
    }

    func testNoCancellationOutcomeBeforeAnyRequestOrNativeCallback() {
        var cancellation = CapturePickerCancellationPolicy()
        XCTAssertNil(cancellation.confirmationDeadlineReached())
        XCTAssertFalse(cancellation.awaitsSystemConfirmation)
    }

    func testStreamStartAloneDoesNotConfirmRecordingOrFile() {
        var policy = CaptureNativeRecordingPolicy()
        XCTAssertTrue(policy.acceptSelection())
        XCTAssertEqual(policy.streamStarted(), .none)
        XCTAssertEqual(policy.phase, .starting)
        XCTAssertFalse(policy.recordingHasStarted)
        XCTAssertTrue(policy.recordingStarted())
        XCTAssertEqual(policy.phase, .recording)
        XCTAssertEqual(policy.requestStop(), .stopStream)
        XCTAssertEqual(policy.phase, .stopping)
        XCTAssertEqual(policy.recordingFinished(), .saved)
    }

    func testOutputStartMayPrecedeStreamStartCallback() {
        var policy = CaptureNativeRecordingPolicy()
        XCTAssertTrue(policy.acceptSelection())
        XCTAssertTrue(policy.recordingStarted())
        XCTAssertEqual(policy.streamStarted(), .none)
        XCTAssertEqual(policy.requestStop(), .stopStream)
        XCTAssertEqual(policy.recordingFinished(), .saved)
    }

    func testStopDuringStartupWaitsForStreamAndIssuesStopOnce() {
        var policy = CaptureNativeRecordingPolicy()
        XCTAssertTrue(policy.acceptSelection())
        XCTAssertEqual(policy.requestStop(), .waitForStart)
        XCTAssertFalse(policy.recordingStarted(), "A late start must not flash a recording UI after Stop")
        XCTAssertEqual(policy.streamStarted(), .stopStream)
        XCTAssertEqual(policy.streamStarted(), .none)
        XCTAssertEqual(policy.requestStop(), .none)
        XCTAssertEqual(policy.recordingFinished(), .saved)
    }

    func testSelectingCancelNeverStartsStreamOrImportsFile() {
        var policy = CaptureNativeRecordingPolicy()
        XCTAssertEqual(policy.requestStop(), .cancelSelection)
        XCTAssertFalse(policy.acceptSelection())
        XCTAssertFalse(policy.recordingStarted())
        XCTAssertEqual(policy.streamStarted(), .none)
        XCTAssertNil(policy.recordingFinished())
    }

    func testSystemStopWaitsForOutputFinalization() {
        var policy = CaptureNativeRecordingPolicy()
        _ = policy.acceptSelection()
        _ = policy.streamStarted()
        _ = policy.recordingStarted()
        XCTAssertTrue(policy.streamStoppedExternally())
        XCTAssertEqual(policy.phase, .stopping)
        XCTAssertEqual(policy.requestStop(), .none)
        XCTAssertEqual(policy.recordingFinished(), .saved)
    }

    func testStopWithoutConfirmedOutputProducesNoSuccessfulFile() {
        var policy = CaptureNativeRecordingPolicy()
        _ = policy.acceptSelection()
        _ = policy.streamStarted()
        _ = policy.requestStop()
        XCTAssertEqual(policy.recordingFinished(), .cancelled)
        var unexpectedlyFinished = CaptureNativeRecordingPolicy()
        _ = unexpectedlyFinished.acceptSelection()
        _ = unexpectedlyFinished.streamStarted()
        XCTAssertEqual(unexpectedlyFinished.recordingFinished(), .failed)
    }

    func testLateRepeatedCallbacksCannotCompleteTwice() {
        var policy = CaptureNativeRecordingPolicy()
        _ = policy.acceptSelection()
        _ = policy.streamStarted()
        _ = policy.recordingStarted()
        XCTAssertEqual(policy.recordingFinished(), .saved)
        XCTAssertNil(policy.recordingFinished())
        XCTAssertFalse(policy.fail())
        XCTAssertFalse(policy.recordingStarted())
        XCTAssertFalse(policy.streamStoppedExternally())
        XCTAssertEqual(policy.requestStop(), .none)
    }

    func testFailureOrTimeoutCannotLaterBecomeSuccess() {
        var policy = CaptureNativeRecordingPolicy()
        _ = policy.acceptSelection()
        XCTAssertTrue(policy.fail())
        XCTAssertFalse(policy.fail())
        XCTAssertEqual(policy.streamStarted(), .none)
        XCTAssertFalse(policy.recordingStarted())
        XCTAssertNil(policy.recordingFinished())
    }

    func testDuplicatePickerUpdatesCannotRestartRecording() {
        var policy = CaptureNativeRecordingPolicy()
        XCTAssertTrue(policy.acceptSelection())
        XCTAssertFalse(policy.acceptSelection())
        _ = policy.streamStarted()
        _ = policy.recordingStarted()
        XCTAssertFalse(policy.acceptSelection())
    }

    func testRetinaSizeUsesPixelScaleAndEvenEncoderDimensions() {
        XCTAssertEqual(CaptureNativeVideoDimensions.size(content: CGSize(width: 1000, height: 700), pointPixelScale: 2),
                       CGSize(width: 2000, height: 1400))
        XCTAssertEqual(CaptureNativeVideoDimensions.size(content: CGSize(width: 101, height: 99), pointPixelScale: 1),
                       CGSize(width: 100, height: 98))
    }

    func testLargeDisplayFits4KWithoutExpandingAspectRatio() throws {
        let size = try XCTUnwrap(CaptureNativeVideoDimensions.size(content: CGSize(width: 3000, height: 2000),
                                                                 pointPixelScale: 2))
        XCTAssertEqual(size, CGSize(width: 3240, height: 2160))
        XCTAssertLessThanOrEqual(size.width, 3840)
        XCTAssertLessThanOrEqual(size.height, 2160)
        XCTAssertEqual(size.width / size.height, 1.5, accuracy: 0.001)
    }

    func testInvalidFilterGeometryCannotAllocateEncoder() {
        for size in [CGSize.zero, CGSize(width: -1, height: 20), CGSize(width: CGFloat.infinity, height: 20)] {
            XCTAssertNil(CaptureNativeVideoDimensions.size(content: size, pointPixelScale: 2))
        }
        XCTAssertNil(CaptureNativeVideoDimensions.size(content: CGSize(width: 20, height: 20), pointPixelScale: 0))
        XCTAssertNil(CaptureNativeVideoDimensions.size(content: CGSize(width: 20, height: 20), pointPixelScale: .nan))
    }
}
