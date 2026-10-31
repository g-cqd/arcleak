// swift-format-ignore-file
import AVFoundation

// A continuation must be resumed exactly once. Storing the new one over the
// member, with nothing that checks or resumes the old one first, drops the old
// one when a second call arrives before the first resumes: that caller stays
// suspended forever, and the next resume reaches the wrong caller.

// maintastic's Camera.getCurrentFrameInHD(): five call sites can overlap.
@MainActor final class Camera: NSObject {
    private var photoContinuation: CheckedContinuation<Data, Error>?
    private let output = AVCapturePhotoOutput()

    func capture() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            photoContinuation = continuation // #al:expect continuation-overwrite
            output.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
        }
    }

    func finished(_ data: Data) {
        defer { photoContinuation = nil }
        photoContinuation?.resume(returning: data)
    }
}

// Through `self.`, a non-throwing continuation.
actor Gate {
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            self.waiter = continuation // #al:expect continuation-overwrite
        }
    }

    func open() {
        waiter?.resume()
        waiter = nil
    }
}

// The shorthand parameter, and an unsafe continuation.
final class Prompt {
    private var answer: UnsafeContinuation<String, Never>?

    func ask() async -> String {
        await withUnsafeContinuation {
            answer = $0 // #al:expect continuation-overwrite
        }
    }

    func reply(_ text: String) {
        answer?.resume(returning: text)
        answer = nil
    }
}

// An unsafe throwing one, after statements that do not decide anything.
final class Download {
    private var completion: UnsafeContinuation<URL, Error>?
    private var started = 0

    func start() async throws -> URL {
        started += 1
        return try await withUnsafeThrowingContinuation { continuation in
            started += 1
            completion = continuation // #al:expect continuation-overwrite
        }
    }

    func finish(_ url: URL) {
        completion?.resume(returning: url)
        completion = nil
    }
}
