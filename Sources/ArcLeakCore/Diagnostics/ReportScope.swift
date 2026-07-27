/// The set of files a report is narrowed to — typically a pull request's
/// changed files.
///
/// Scoping applies to the *report*, never to the corpus. Twelve of thirteen
/// rules are per-file and would survive a shrunken corpus, but
/// `mutual-strong-properties` walks an ownership graph built from every type
/// in the corpus: drop the files a cycle passes through and the cycle stops
/// existing. Shrinking the input also prunes the shared facts cache down to
/// the subset, so the next whole-corpus run starts cold. Analyze everything,
/// report a slice.
///
/// A `mutual-strong-properties` finding anchors at the alphabetically-first
/// type in its strongly-connected component and names the rest of the cycle in
/// its note as free text, so a cross-file cycle is matched only when the file
/// it happens to anchor at is in scope. Adding structured related locations to
/// `Finding` — the way dolly carries clone-group members — would let scope
/// match any participating file; until then this is a known and documented
/// narrowing, not an accident.
public struct ReportScope: Sendable, Equatable {
    /// Canonical absolute paths, matching `Finding.path`.
    public let files: Set<String>

    public var isEmpty: Bool { files.isEmpty }

    /// Paths are canonicalized on the way in, so callers can pass whatever
    /// `git diff --name-only` produced without worrying about spelling.
    public init(files: some Sequence<String>) {
        self.files = Set(files.lazy.map(SourcePath.canonical))
    }

    public func contains(_ finding: Finding) -> Bool {
        files.contains(finding.path)
    }

    /// Splits findings into (inScope, outOfScope), mirroring `Baseline.filter`.
    public func filter(_ findings: [Finding]) -> (inScope: [Finding], outOfScope: [Finding]) {
        let (outOfScope, inScope) = findings.partitioned(by: contains)
        return (inScope, outOfScope)
    }
}
