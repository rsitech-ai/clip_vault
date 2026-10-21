import Dispatch
import Foundation

/// Bounds the caller's OCR wait without accumulating workers if Vision stalls.
/// The outstanding operation retains admission until it actually returns.
final class BoundedTextRecognition: Sendable {
    private let admission = DispatchSemaphore(value: 1)
    private let queue = DispatchQueue(label: "com.andrzej.ClipVault.image-ocr", qos: .utility)
    private let timeout: DispatchTimeInterval

    init(timeout: DispatchTimeInterval = .seconds(2)) { self.timeout = timeout }

    func recognize(_ data: Data, operation: @escaping @Sendable (Data) -> String?) -> String? {
        guard admission.wait(timeout: .now()) == .success else { return nil }
        let result = RecognitionResult()
        let completed = DispatchSemaphore(value: 0)
        queue.async { [admission] in
            defer { admission.signal(); completed.signal() }
            result.set(operation(data))
        }
        guard completed.wait(timeout: .now() + timeout) == .success else { return nil }
        return result.get()
    }
}

private final class RecognitionResult: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    func set(_ value: String?) {
        lock.lock()
        defer { lock.unlock() }
        self.value = value
    }
    func get() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
