//
//  MediaKeyInterceptor.swift
//  boringNotch
//
//  Created by JeanLouis on 21/08/2025.

import Foundation
import AppKit
import os.log
import ApplicationServices
import IOKit
import Defaults

private let kSystemDefinedEventType = CGEventType(rawValue: 14)!

@MainActor
final class MediaKeyInterceptor {
    static let shared = MediaKeyInterceptor()


    private var eventTap: CFMachPort? = nil
    private var runLoopSource: CFRunLoopSource? = nil
    private let brightnessStep: Float = 1.0 / 16.0

    private init() {}

    enum StartResult: Equatable, Sendable {
        case running
        case permissionRequired
        case failed(String)
    }

    /// Called on the main run loop when the system disables the active tap.
    var onRuntimeStateChange: ((StartResult) -> Void)?
    private var wantsToRun = false
    private var routing = MediaKeyRoutingState()
    var onMediaEvent: ((SystemMediaKeyEvent, Bool, UInt) -> Void)?
    var isTapEnabled: Bool { eventTap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    func isAccessibilityAuthorized() -> Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    func start() -> StartResult {
        wantsToRun = true
        guard isAccessibilityAuthorized() else {
            stop()
            return .permissionRequired
        }

        if let eventTap {
            if !CGEvent.tapIsEnabled(tap: eventTap) {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            if CGEvent.tapIsEnabled(tap: eventTap) { return .running }
            stop()
            wantsToRun = true
        }

        let mask = CGEventMask(1 << kSystemDefinedEventType.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, cgEvent, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(cgEvent) }
                // This source is attached exclusively to CFRunLoopGetMain().
                return MainActor.assumeIsolated {
                    let interceptor = Unmanaged<MediaKeyInterceptor>.fromOpaque(userInfo).takeUnretainedValue()
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        interceptor.recoverDisabledTap()
                        return Unmanaged.passUnretained(cgEvent)
                    }
                    guard interceptor.isAccessibilityAuthorized() else {
                        interceptor.stop()
                        interceptor.onRuntimeStateChange?(.permissionRequired)
                        return Unmanaged.passUnretained(cgEvent)
                    }
                    return interceptor.handleSystemDefined(event: cgEvent)
                }
            },
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        ) else {
            return .failed("Unable to start media key interception.")
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return .failed("Unable to attach media key interception to the main run loop.")
        }
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        guard CGEvent.tapIsEnabled(tap: tap) else {
            stop()
            return .failed("Media key interception was not enabled by macOS.")
        }
        return .running
    }

    func stop() {
        wantsToRun = false
        routing.reset()
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            CFRunLoopSourceInvalidate(runLoopSource)
        }
        runLoopSource = nil
        eventTap = nil
    }

    private func recoverDisabledTap() {
        guard wantsToRun else { return }
        // A release may have happened while delivery was disabled; discard stale ownership.
        routing.reset()
        let result = start()
        onRuntimeStateChange?(result)
    }

    private func handleSystemDefined(event cgEvent: CGEvent) -> Unmanaged<CGEvent>? {
        guard let event = NSEvent(cgEvent: cgEvent), event.type == .systemDefined,
              let media = SystemMediaKeyEvent(subtype: Int(event.subtype.rawValue), data1: event.data1) else {
            return Unmanaged.passUnretained(cgEvent)
        }
        let disposition = routing.process(media, canHandle: wantsToRun && isTapEnabled)
        let consumed = disposition != .passThrough
        onMediaEvent?(media, consumed, event.modifierFlags.rawValue)
        guard case .consume(let performAction) = disposition else { return Unmanaged.passUnretained(cgEvent) }
        if performAction {
            let key = media.key
            let flags = event.modifierFlags
            let generation = routing.generation
            // Return from the C event-tap callback before potentially slow hardware IPC.
            // Main-queue FIFO preserves the order of physical presses and their repeats.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.wantsToRun, self.isTapEnabled,
                      self.routing.generation == generation else { return }
                self.perform(key, flags: flags)
            }
        }
        return nil
    }

    private func perform(_ key: SystemMediaKey, flags: NSEvent.ModifierFlags) {
        let option = flags.contains(.option)
        let shift = flags.contains(.shift)
        let keyboardBacklight = flags.contains(.command)
        if option && !shift {
            switch Defaults[.optionKeyAction] {
            case .none: return
            case .openSettings:
                let pane = key == .brightnessUp || key == .brightnessDown
                    ? (keyboardBacklight ? "keyboard" : "displays") : "sound"
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference." + pane) {
                    NSWorkspace.shared.open(url)
                }
            case .showHUD:
                switch key {
                case .volumeUp, .volumeDown, .mute: VolumeManager.shared.showCurrent()
                case .brightnessUp, .brightnessDown:
                    if keyboardBacklight { KeyboardBacklightManager.shared.showCurrent() }
                    else { BrightnessManager.shared.showCurrent() }
                }
            }
            return
        }
        let divisor: Float = option && shift ? 4 : 1
        switch key {
        case .volumeUp: VolumeManager.shared.increase(stepDivisor: divisor)
        case .volumeDown: VolumeManager.shared.decrease(stepDivisor: divisor)
        case .mute: VolumeManager.shared.toggleMuteAction()
        case .brightnessUp, .brightnessDown:
            let delta = (key == .brightnessUp ? brightnessStep : -brightnessStep) / divisor
            if keyboardBacklight { KeyboardBacklightManager.shared.setRelative(delta: delta) }
            else { BrightnessManager.shared.setRelative(delta: delta) }
        }
    }
}
