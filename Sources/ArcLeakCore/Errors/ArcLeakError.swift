/// Typed failure surface for the core library. The CLI is the only layer that
/// erases these into exit codes and stderr text.
public enum ArcLeakError: Error, Sendable, CustomStringConvertible {
    case fileUnreadable(path: String, underlying: String)
    case configurationUnreadable(path: String, underlying: String)
    case configurationInvalid(path: String, detail: String)
    case noInputs

    public var description: String {
        switch self {
        case let .fileUnreadable(path, underlying):
            "cannot read \(path): \(underlying)"
        case let .configurationUnreadable(path, underlying):
            "cannot read configuration \(path): \(underlying)"
        case let .configurationInvalid(path, detail):
            "invalid configuration \(path): \(detail)"
        case .noInputs:
            "no Swift files to analyze"
        }
    }
}
