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
/// Membership spans the anchor and every related location. A
/// `mutual-strong-properties` finding anchors at the alphabetically-first type
/// in its strongly-connected component, which is arbitrary with respect to a
/// diff, so it also carries the remaining links as structured
/// `RelatedLocation`s — the way dolly carries clone-group members. A pull
/// request that closes a cycle therefore sees it whichever file the anchor
/// landed in.
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
        // Across the anchor *and* every related location: a cross-type cycle
        // anchors at whichever link the graph walk started from, which is
        // arbitrary with respect to a diff. Matching the anchor alone would
        // hide a cycle from the very pull request that closed it.
        files.contains(finding.path) || finding.related.contains { files.contains($0.path) }
    }

    /// Splits findings into (inScope, outOfScope), mirroring `Baseline.filter`.
    public func filter(_ findings: [Finding]) -> (inScope: [Finding], outOfScope: [Finding]) {
        let (outOfScope, inScope) = findings.partitioned(by: contains)
        return (inScope, outOfScope)
    }
}
