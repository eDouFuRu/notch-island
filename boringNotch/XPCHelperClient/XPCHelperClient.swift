import Foundation
import Cocoa
import AsyncXPCConnection

final class XPCHelperClient {
    nonisolated static let shared = XPCHelperClient()
    
    private let serviceName = "com.dongfengrui.NotchIsland.XPCHelper"
    
    private var remoteService: RemoteXPCService<BoringNotchXPCHelperProtocol>?
    private var connection: NSXPCConnection?
    private var lastKnownAuthorization: Bool?
    
    nonisolated private init() {}
    
    deinit {
        connection?.invalidate()
    }
    
    // MARK: - Connection Management (Main Actor Isolated)
    
    @MainActor
    private func ensureRemoteService() -> RemoteXPCService<BoringNotchXPCHelperProtocol> {
        if let existing = remoteService {
            return existing
        }
        
        let conn = NSXPCConnection(serviceName: serviceName)
        
        conn.interruptionHandler = { [weak self, weak conn] in
            Task { @MainActor in
                guard let self, self.connection === conn else { return }
                self.connection = nil
                self.remoteService = nil
            }
        }
        
        conn.invalidationHandler = { [weak self, weak conn] in
            Task { @MainActor in
                guard let self, self.connection === conn else { return }
                self.connection = nil
                self.remoteService = nil
            }
        }
        
        conn.resume()
        
        let service = RemoteXPCService<BoringNotchXPCHelperProtocol>(
            connection: conn,
            remoteInterface: BoringNotchXPCHelperProtocol.self
        )
        
        connection = conn
        remoteService = service
        return service
    }
    
    @MainActor
    private func getRemoteService() -> RemoteXPCService<BoringNotchXPCHelperProtocol>? {
        remoteService
    }
    
    @MainActor
    private func notifyAuthorizationChange(_ granted: Bool) {
        guard lastKnownAuthorization != granted else { return }
        lastKnownAuthorization = granted
        NotificationCenter.default.post(
            name: .accessibilityAuthorizationChanged,
            object: nil,
            userInfo: ["granted": granted]
        )
    }
    
    // MARK: - Accessibility
    
    nonisolated func requestAccessibilityAuthorization() {
        Task {
            let service = await MainActor.run {
                ensureRemoteService()
            }
            try? await service.withService { service in
                service.requestAccessibilityAuthorization()
            }
        }
    }
    
    nonisolated func isAccessibilityAuthorized() async -> Bool {
        do {
            let service = await MainActor.run {
                ensureRemoteService()
            }
            let result: Bool = try await service.withContinuation { service, continuation in
                service.isAccessibilityAuthorized { authorized in
                    continuation.resume(returning: authorized)
                }
            }
            await MainActor.run {
                notifyAuthorizationChange(result)
            }
            return result
        } catch {
            return false
        }
    }
    
    nonisolated func ensureAccessibilityAuthorization(promptIfNeeded: Bool) async -> Bool {
        do {
            let service = await MainActor.run {
                ensureRemoteService()
            }
            let result: Bool = try await service.withContinuation { service, continuation in
                service.ensureAccessibilityAuthorization(promptIfNeeded) { authorized in
                    continuation.resume(returning: authorized)
                }
            }
            await MainActor.run {
                notifyAuthorizationChange(result)
            }
            return result
        } catch {
            return false
        }
    }
    
    // MARK: - Bounded brightness RPCs

    @MainActor
    private func brightnessRequest<Value>(
        fallback: Value,
        _ invoke: (BoringNotchXPCHelperProtocol, @escaping (Value) -> Void) -> Void
    ) async -> Value {
        _ = ensureRemoteService()
        guard let activeConnection = connection else { return fallback }
        return await withCheckedContinuation { continuation in
            let reply = OneShotReply<Value> { continuation.resume(returning: $0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self, weak activeConnection] in
                guard reply.finish(fallback) else { return }
                activeConnection?.invalidate()
                if self?.connection === activeConnection {
                    self?.connection = nil
                    self?.remoteService = nil
                }
            }
            let proxy = activeConnection.remoteObjectProxyWithErrorHandler { _ in reply.finish(fallback) }
            guard let service = proxy as? BoringNotchXPCHelperProtocol else {
                reply.finish(fallback)
                return
            }
            invoke(service) { reply.finish($0) }
        }
    }

    nonisolated func isKeyboardBrightnessAvailable() async -> Bool {
        await brightnessRequest(fallback: false) { service, reply in service.isKeyboardBrightnessAvailable(with: reply) }
    }

    nonisolated func currentKeyboardBrightness() async -> Float? {
        let value: NSNumber? = await brightnessRequest(fallback: nil) { service, reply in service.currentKeyboardBrightness(with: reply) }
        return value?.floatValue
    }

    nonisolated func setKeyboardBrightness(_ value: Float) async -> Bool {
        guard value.isFinite else { return false }
        return await brightnessRequest(fallback: false) { service, reply in service.setKeyboardBrightness(value, with: reply) }
    }

    nonisolated func isScreenBrightnessAvailable() async -> Bool {
        await brightnessRequest(fallback: false) { service, reply in service.isScreenBrightnessAvailable(with: reply) }
    }

    nonisolated func currentScreenBrightness() async -> Float? {
        let value: NSNumber? = await brightnessRequest(fallback: nil) { service, reply in service.currentScreenBrightness(with: reply) }
        return value?.floatValue
    }

    nonisolated func setScreenBrightness(_ value: Float) async -> Bool {
        guard value.isFinite else { return false }
        return await brightnessRequest(fallback: false) { service, reply in service.setScreenBrightness(value, with: reply) }
    }

}

extension Notification.Name {
    static let accessibilityAuthorizationChanged = Notification.Name("accessibilityAuthorizationChanged")
}

