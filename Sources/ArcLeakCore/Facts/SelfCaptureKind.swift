/// How a closure captures `self`, resolved from its capture list and body.
///
/// Resolution order: an explicit capture-list entry for `self` decides alone
/// (`[weak self]` ⇒ `.weak` even when the body uses `self` after `guard let
/// self` — SE-0365). Without an entry, any lexical reference to `self` in the
/// body — including inside nested closures, whose weak rebinding still forces
/// the *outer* closure to capture `self` strongly — is a strong capture.
/// `implicit` marks Task-style bodies where a bare member reference captured
/// `self` with no `self` token in source (`@_implicitSelfCapture`).
public enum SelfCaptureKind: Sendable, Equatable, Codable {
    case none
    case strong(implicit: Bool)
    case weak
    case unowned

    public var isStrong: Bool {
        if case .strong = self { return true }
        return false
    }
}
