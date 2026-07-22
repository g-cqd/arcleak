/// Declared strength of a stored property reference.
public enum ReferenceStrength: String, Sendable, Equatable, Codable {
    case strong
    case weak
    case unowned
}
