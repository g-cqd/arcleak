// swift-format-ignore-file
import Foundation

// Docs: "The session object keeps a strong reference to the delegate until
// your app exits or explicitly invalidates the session. If you do not
// invalidate the session … your app leaks memory until it exits."
// Invalidation only in deinit is unreachable while the session holds self.
final class Api: NSObject, URLSessionDelegate {
    var session: URLSession?

    func start() {
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil) // #al:expect urlsession-delegate-leak
    }

    deinit {
        session?.invalidateAndCancel()
    }
}