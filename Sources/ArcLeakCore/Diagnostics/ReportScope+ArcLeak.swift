import ProjectModel

extension ReportScope {
    /// A scope over `files`, canonicalized the way arcleak canonicalizes findings' paths.
    package init(files: some Sequence<String>) {
        self.init(files: files, canonicalize: SourcePath.canonical)
    }
}
