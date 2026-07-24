/// Single source of truth for tool identity (CLI version string, SARIF driver,
/// baseline headers).
public enum ToolInfo {
    public static let name = "arcleak"
    // 0.4.0: the FactsCache coder moved Foundation -> ADJSON fast path. The
    // version gate discards any older on-disk cache, so a schema/coder change
    // can never deserialize into wrong shapes — the new coder only ever reads
    // caches it wrote.
    public static let version = "0.4.0"
    public static let informationURI = "https://github.com/g-cqd/arcleak"
}
