//
//  MusicVisualizer.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 02/08/24.
//
import AppKit
import Cocoa
import SwiftUI

class AudioSpectrum: NSView {
    private var barLayers: [CAShapeLayer] = []
    private var barScales: [CGFloat] = []
    private var isPlaying: Bool = true
    private var animationTimer: Timer?
    private var windowOcclusionObserver: NSObjectProtocol?
    override var intrinsicContentSize: NSSize { ClosedMediaLayout.spectrumSize }

    deinit {
        animationTimer?.invalidate()
        if let windowOcclusionObserver { NotificationCenter.default.removeObserver(windowOcclusionObserver) }
    }
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setupBars()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        setupBars()
    }

    private func setupBars() {
        for _ in 0 ..< 4 {
            let barLayer = CAShapeLayer()
            barLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            barLayer.fillColor = NSColor.white.cgColor
            barLayer.allowsGroupOpacity = false
            barLayer.masksToBounds = true
            barLayers.append(barLayer)
            barScales.append(0.35)
            layer?.addSublayer(barLayer)
        }
    }

    override func layout() {
        super.layout()
        let barWidth = min(2, max(0, bounds.width / 7))
        let totalWidth = 7 * barWidth
        let leading = (bounds.width - totalWidth) / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, bar) in barLayers.enumerated() {
            bar.bounds = CGRect(x: 0, y: 0, width: barWidth, height: bounds.height)
            bar.position = CGPoint(x: leading + CGFloat(index) * 2 * barWidth + barWidth / 2,
                                   y: bounds.height / 2)
            bar.path = CGPath(roundedRect: bar.bounds, cornerWidth: barWidth / 2,
                              cornerHeight: barWidth / 2, transform: nil)
        }
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let windowOcclusionObserver { NotificationCenter.default.removeObserver(windowOcclusionObserver) }
        windowOcclusionObserver = nil
        if let window {
            windowOcclusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateAnimationState() }
            }
        }
        updateAnimationState()
    }

    private var canAnimate: Bool {
        isPlaying && window?.isVisible == true && window?.occlusionState.contains(.visible) == true
    }

    private func updateAnimationState() {
        if canAnimate { startAnimating() } else { stopAnimating() }
    }
    
    private func startAnimating() {
        guard animationTimer == nil, canAnimate else { return }
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.updateBars()
        }
        animationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    
    private func stopAnimating() {
        animationTimer?.invalidate()
        animationTimer = nil
        resetBars()
    }
    
    private func updateBars() {
        guard canAnimate else { stopAnimating(); return }
        for (i, barLayer) in barLayers.enumerated() {
            let currentScale = barScales[i]
            let targetScale = CGFloat.random(in: 0.35 ... 1.0)
            barScales[i] = targetScale
            let animation = CABasicAnimation(keyPath: "transform.scale.y")
            animation.fromValue = currentScale
            animation.toValue = targetScale
            animation.duration = 0.3
            animation.autoreverses = true
            animation.fillMode = .forwards
            animation.isRemovedOnCompletion = false
            if #available(macOS 13.0, *) {
                animation.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 24, preferred: 24)
            }
            barLayer.add(animation, forKey: "scaleY")
        }
    }
    
    private func resetBars() {
        for (i, barLayer) in barLayers.enumerated() {
            barLayer.removeAllAnimations()
            barLayer.transform = CATransform3DMakeScale(1, 0.35, 1)
            barScales[i] = 0.35
        }
    }
    
    func setPlaying(_ playing: Bool) {
        isPlaying = playing
        updateAnimationState()
    }
}

struct AudioSpectrumView: NSViewRepresentable {
    @Binding var isPlaying: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    
    func makeNSView(context: Context) -> AudioSpectrum {
        let spectrum = AudioSpectrum()
        spectrum.setPlaying(isPlaying && !reduceMotion)
        return spectrum
    }
    
    func updateNSView(_ nsView: AudioSpectrum, context: Context) {
        nsView.setPlaying(isPlaying && !reduceMotion)
    }

    static func dismantleNSView(_ nsView: AudioSpectrum, coordinator: ()) { nsView.setPlaying(false) }
}

#Preview {
    AudioSpectrumView(isPlaying: .constant(true))
        .frame(width: 16, height: 20)
        .padding()
}
