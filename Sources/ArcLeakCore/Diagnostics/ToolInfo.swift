/// Single source of truth for tool identity (CLI version string, SARIF driver,
/// baseline headers).
public enum ToolInfo {
    public static let name = "arcleak"
    // 0.5.0: experimental embedding-rank can now run a code-trained Core ML model
    // plus its HuggingFace tokenizer (`--embedding-bundle`) instead of the
    // English NLContextual default — new user-facing capability, new dependency.
    // The version also gates the on-disk FactsCache: any cache written by an
    // older build is discarded, so a schema/coder change can never deserialize
    // into wrong shapes — the current coder only ever reads caches it wrote.
    public static let version = "0.9.0"
    public static let informationURI = "https://github.com/g-cqd/arcleak"
}
