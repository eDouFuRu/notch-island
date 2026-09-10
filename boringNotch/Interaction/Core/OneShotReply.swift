import Foundation

/// XPC can report an error, a late reply, and a timeout. Only one may resume the caller.
public final class OneShotReply<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: ((Value) -> Void)?
    public init(_ completion: @escaping (Value) -> Void) { self.completion = completion }

    @discardableResult
    public func finish(_ value: Value) -> Bool {
        lock.lock()
        let callback = completion
        completion = nil
        lock.unlock()
        guard let callback else { return false }
        callback(value)
        return true
    }
}
