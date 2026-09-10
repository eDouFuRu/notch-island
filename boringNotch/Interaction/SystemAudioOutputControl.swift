import Combine
import CoreAudio
import Foundation

protocol AudioOutputControlling: Sendable {
    func read() async -> AudioOutputDeviceResponse
    func select(id: String) async -> AudioOutputDeviceResponse
    func startObserving(_ onChange: @escaping @Sendable () -> Void)
}
extension AudioOutputControlling {
    func startObserving(_ onChange: @escaping @Sendable () -> Void) {}
}

private final class AudioOutputCompletion: @unchecked Sendable {
    let gate = AudioOutputRequestGate()
    private let lock = NSLock()
    private var continuation: CheckedContinuation<AudioOutputDeviceResponse, Never>?
    private var pending: AudioOutputDeviceResponse?
    func attach(_ continuation: CheckedContinuation<AudioOutputDeviceResponse, Never>) {
        lock.lock()
        if let pending { lock.unlock(); continuation.resume(returning: pending) }
        else { self.continuation = continuation; lock.unlock() }
    }
    func resolve(_ value: AudioOutputDeviceResponse) {
        guard gate.finish() else { return }
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        if continuation == nil { pending = value }
        lock.unlock()
        continuation?.resume(returning: value)
    }
}

/// HAL access is serialized off the main thread. Only output-scope stream
/// metadata is queried; stream buffer pointers/audio samples are never read.
final class CoreAudioOutputDevice: AudioOutputControlling, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.dongfengrui.NotchIsland.audio-output", qos: .userInitiated)
    private struct Listener {
        let object: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }
    private var listeners: [Listener] = []
    private var observedOutputs: Set<AudioObjectID> = []
    private var onChange: (@Sendable () -> Void)?
    private var observing = false

    deinit {
        let entries = listeners
        let listenerQueue = queue
        listenerQueue.async {
            for var entry in entries {
                AudioObjectRemovePropertyListenerBlock(entry.object, &entry.address, listenerQueue, entry.block)
            }
        }
    }

    func startObserving(_ onChange: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            self.onChange = onChange
            guard !observing else { return }
            observing = true
            addListener(object: AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDevices)
            addListener(object: AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDefaultOutputDevice)
        }
    }

    func read() async -> AudioOutputDeviceResponse { await perform { _ in self.readOnQueue().response } }

    func select(id: String) async -> AudioOutputDeviceResponse {
        await perform { gate in
            let snapshot = self.readOnQueue()
            guard let reading = snapshot.response.reading else { return snapshot.response }
            switch AudioOutputSelectionDecision.evaluate(id: id, reading: reading) {
            case .unavailable: return .init(reading: reading, failure: .deviceUnavailable)
            case .readOnly: return .init(reading: reading, failure: .readOnly)
            case .alreadySelected: return .init(reading: reading, statusCode: noErr)
            case .select: break
            }
            let matches = snapshot.records.filter { $0.uid == id && $0.isAlive && $0.canBeDefault && $0.outputChannels > 0 }
            guard matches.count == 1, let record = matches.first else {
                return .init(reading: reading, failure: .deviceUnavailable)
            }
            var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
            var objectID = AudioObjectID(record.objectID)
            guard !gate.isFinished else { return .init(failure: .cancelled) }
            // This is the only write in the service. In particular, it never
            // writes volume, mute or kAudioHardwarePropertyDefaultSystemOutputDevice.
            let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &objectID)
            let after = self.readOnQueue().response
            let failure: AudioOutputFailure? = status != noErr ? .writeFailed :
                (after.reading?.selectedID == id ? nil : after.failure)
            return .init(reading: after.reading, failure: failure, statusCode: status)
        }
    }

    private func perform(_ operation: @escaping @Sendable (AudioOutputRequestGate) -> AudioOutputDeviceResponse) async -> AudioOutputDeviceResponse {
        let completion = AudioOutputCompletion()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                completion.attach(continuation)
                queue.async {
                    guard completion.gate.begin() else { return }
                    completion.resolve(operation(completion.gate))
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
                    completion.resolve(.init(failure: .timedOut))
                }
            }
        } onCancel: { completion.resolve(.init(failure: .cancelled)) }
    }

    private func readOnQueue() -> (response: AudioOutputDeviceResponse, records: [AudioOutputDeviceRecord]) {
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard let ids = deviceIDs() else { return (.init(failure: .unavailable), []) }
        var records: [AudioOutputDeviceRecord] = []
        var outputs = Set<AudioObjectID>()
        var incomplete = false
        for id in ids {
            // Determine output capability before reading UID or display name.
            guard let channels = outputChannels(id) else { incomplete = true; continue }
            guard channels > 0 else { continue }
            outputs.insert(id)
            guard let uid = string(id, selector: kAudioDevicePropertyDeviceUID),
                  let name = string(id, selector: kAudioObjectPropertyName),
                  let alive = uint32(id, selector: kAudioDevicePropertyDeviceIsAlive),
                  let eligible = uint32(id, selector: kAudioDevicePropertyDeviceCanBeDefaultDevice,
                                        scope: kAudioObjectPropertyScopeOutput) else { incomplete = true; continue }
            records.append(.init(objectID: id, uid: uid, displayName: name, outputChannels: channels,
                                 isAlive: alive == 1, canBeDefault: eligible == 1))
        }
        updateOutputListeners(outputs)
        let selected = uint32(system, selector: kAudioHardwarePropertyDefaultOutputDevice)
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        var settable: DarwinBoolean = false
        let settableStatus = AudioObjectIsPropertySettable(system, &address, &settable)
        let reading = AudioOutputReading(records: records, selectedObjectID: selected,
                                        defaultIsSettable: settableStatus == noErr && settable.boolValue)
        let failure: AudioOutputFailure?
        if reading.devices.isEmpty { failure = incomplete ? .unavailable : .noDevices }
        else if selected == nil || selected == 0 || reading.selectedID == nil { failure = .unavailable }
        else if !reading.canSelect { failure = .readOnly }
        else { failure = nil }
        return (.init(reading: reading, failure: failure), records)
    }

    private func deviceIDs() -> [AudioObjectID]? {
        var address = Self.address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr,
              size % UInt32(MemoryLayout<AudioObjectID>.size) == 0, size <= 2_048 else { return nil }
        if size == 0 { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let capacity = size
        let status = ids.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(system, &address, 0, nil, &size, bytes.baseAddress!)
        }
        guard status == noErr, size <= capacity, size % UInt32(MemoryLayout<AudioObjectID>.size) == 0 else { return nil }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private func outputChannels(_ id: AudioObjectID) -> Int? {
        var address = Self.address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeOutput)
        guard AudioObjectHasProperty(id, &address) else { return 0 }
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr,
              size >= MemoryLayout<AudioBufferList>.offset(of: \.mBuffers)!, size <= 65_536 else { return nil }
        let capacity = Int(size)
        let allocated = max(capacity, MemoryLayout<AudioBufferList>.size)
        let storage = UnsafeMutableRawPointer.allocate(byteCount: allocated, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        storage.initializeMemory(as: UInt8.self, repeating: 0, count: allocated)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, storage) == noErr, Int(size) <= capacity else { return nil }
        let list = storage.assumingMemoryBound(to: AudioBufferList.self)
        let offset = MemoryLayout<AudioBufferList>.offset(of: \.mBuffers)!
        guard Int(size) >= offset,
              Int(list.pointee.mNumberBuffers) <= (Int(size) - offset) / MemoryLayout<AudioBuffer>.size else { return nil }
        return UnsafeMutableAudioBufferListPointer(list).reduce(0) { sum, buffer in
            sum + Int(buffer.mNumberChannels) // mData is never dereferenced
        }
    }

    private func uint32(_ object: AudioObjectID, selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var address = Self.address(selector, scope: scope)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
              size == MemoryLayout<UInt32>.size else { return nil }
        return value
    }
    private func string(_ object: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = Self.address(selector)
        var value: Unmanaged<CFTypeRef>?
        var size = UInt32(MemoryLayout<Unmanaged<CFTypeRef>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        // The CoreAudio headers explicitly transfer ownership for Name and UID.
        let object = value.takeRetainedValue()
        guard CFGetTypeID(object) == CFStringGetTypeID() else { return nil }
        return object as? String
    }
    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        .init(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    private func updateOutputListeners(_ outputs: Set<AudioObjectID>) {
        guard observing, outputs != observedOutputs else { return }
        for var entry in listeners where entry.object != AudioObjectID(kAudioObjectSystemObject) {
            AudioObjectRemovePropertyListenerBlock(entry.object, &entry.address, queue, entry.block)
        }
        listeners.removeAll { $0.object != AudioObjectID(kAudioObjectSystemObject) }
        observedOutputs = outputs
        for id in outputs {
            addListener(object: id, selector: kAudioDevicePropertyDeviceIsAlive)
            addListener(object: id, selector: kAudioObjectPropertyName)
            addListener(object: id, selector: kAudioDevicePropertyDeviceCanBeDefaultDevice, scope: kAudioObjectPropertyScopeOutput)
            addListener(object: id, selector: kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeOutput)
        }
    }
    private func addListener(object: AudioObjectID, selector: AudioObjectPropertySelector,
                             scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) {
        var address = Self.address(selector, scope: scope)
        guard AudioObjectHasProperty(object, &address) else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.onChange?() }
        if AudioObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr {
            listeners.append(.init(object: object, address: address, block: block))
        }
    }
}

@MainActor final class SystemAudioOutputControl: ObservableObject {
    static let shared = SystemAudioOutputControl()
    @Published private(set) var devices: [AudioOutputMenuItem] = []
    @Published private(set) var selectedID: String?
    @Published private(set) var currentName: String?
    @Published private(set) var isBusy = false
    @Published private(set) var canSelect = false
    @Published private(set) var errorKey: String?
    @Published private(set) var lastStatusCode: Int32?
    private let device: any AudioOutputControlling
    private var refreshPending = false

    init(device: any AudioOutputControlling = CoreAudioOutputDevice()) {
        self.device = device
        device.startObserving { [weak self] in Task { @MainActor in await self?.refresh(preservingError: true) } }
    }
    func refresh() async { await refresh(preservingError: false) }
    private func refresh(preservingError: Bool) async {
        guard !isBusy else { refreshPending = true; return }
        isBusy = true
        let response = await device.read()
        publish(response.reading)
        if response.failure != nil || !preservingError { errorKey = response.failure?.messageKey }
        lastStatusCode = response.statusCode
        finishBusy()
    }
    @discardableResult func select(id: String) async -> Bool {
        guard !isBusy, !Task.isCancelled else { return false }
        isBusy = true
        errorKey = nil
        lastStatusCode = nil
        defer { finishBusy() }
        let initial = await device.read()
        publish(initial.reading)
        guard !Task.isCancelled else { errorKey = AudioOutputFailure.cancelled.messageKey; return false }
        guard let reading = initial.reading else { errorKey = (initial.failure ?? .unavailable).messageKey; return false }
        switch AudioOutputSelectionDecision.evaluate(id: id, reading: reading) {
        case .unavailable: errorKey = AudioOutputFailure.deviceUnavailable.messageKey; return false
        case .readOnly: errorKey = AudioOutputFailure.readOnly.messageKey; return false
        case .alreadySelected: return true
        case .select: break
        }
        let written = await device.select(id: id)
        publish(written.reading)
        lastStatusCode = written.statusCode
        if let failure = written.failure { errorKey = failure.messageKey; return false }
        var actual = written.reading
        for delay in [80_000_000, 160_000_000] as [UInt64] {
            if actual?.selectedID == id { break }
            do { try await Task.sleep(nanoseconds: delay) }
            catch { errorKey = AudioOutputFailure.cancelled.messageKey; return false }
            let response = await device.read()
            actual = response.reading
            publish(actual)
            if let failure = response.failure { errorKey = failure.messageKey; return false }
        }
        let failure = AudioOutputVerification.failure(requestedID: id, actual: actual)
        errorKey = failure?.messageKey
        return failure == nil
    }
    private func publish(_ reading: AudioOutputReading?) {
        devices = reading?.devices ?? []
        selectedID = reading?.selectedID
        currentName = reading?.currentName
        canSelect = reading?.canSelect ?? false
    }
    private func finishBusy() {
        isBusy = false
        if refreshPending {
            refreshPending = false
            Task { @MainActor [weak self] in await self?.refresh(preservingError: true) }
        }
    }
}
