//
//  FullscreenMediaDetection.swift
//  boringNotch
//
//  Created by Richard Kunkli on 06/09/2024.
//

import Foundation
import Combine
import Defaults
import MacroVisionKit

@MainActor
final class FullscreenMediaDetector: ObservableObject {
    static let shared = FullscreenMediaDetector()
    
    @Published var fullscreenStatus: [String: Bool] = [:]
    
    private var monitorTask: Task<Void, Never>?
    private var latestSpaces: [FullscreenMediaPolicy.Space] = []
    private var mode: FullscreenMediaPolicy.Mode = .never
    private var mediaSource: String?
    private var subscriptions = Set<AnyCancellable>()
    
    private init() {
        observePolicyInputs()
        startMonitoring()
    }
    
    deinit {
        monitorTask?.cancel()
    }
    
    private func startMonitoring() {
        monitorTask = Task { @MainActor in
            let stream = await FullScreenMonitor.shared.spaceChanges()
            for await spaces in stream {
                updateStatus(with: spaces)
            }
        }
    }
    
    private func updateStatus(with spaces: [MacroVisionKit.FullScreenMonitor.SpaceInfo]) {
        latestSpaces = spaces.compactMap { space in
            space.screenUUID.map { FullscreenMediaPolicy.Space(screenID: $0, applicationIDs: Set(space.runningApps)) }
        }
        recompute()
    }

    private func observePolicyInputs() {
        let music = MusicManager.shared
        Publishers.CombineLatest4(
            Defaults.publisher(.hideNotchOption).map(\.newValue).removeDuplicates(),
            music.$bundleIdentifier.removeDuplicates(),
            music.$isPlaying.removeDuplicates(),
            music.$isPlayerIdle.removeDuplicates()
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] option, bundle, playing, idle in
            guard let self else { return }
            switch option {
            case .never: self.mode = .never
            case .always: self.mode = .allApps
            case .nowPlayingOnly: self.mode = .currentMediaApp
            }
            self.mediaSource = (playing || !idle) ? bundle : nil
            self.recompute()
        }
        .store(in: &subscriptions)
    }

    private func recompute() {
        // Settings/player changes must take effect even if the user stays in the same Space.
        let status = FullscreenMediaPolicy.status(spaces: latestSpaces, mode: mode, mediaSource: mediaSource)
        if fullscreenStatus != status { fullscreenStatus = status }
    }
}
