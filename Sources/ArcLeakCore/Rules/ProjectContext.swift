import ProjectModel

/// How a finding's place in the project changes what it means. The rules
/// judge one type's retention; where that type lives decides how much a
/// leak costs:
/// - preview code never ships, and nobody edits a generated file: their
///   findings are withheld, as suppressions with the reason;
/// - `#if DEBUG` code only runs in debug builds, and test code only in a test
///   run: their findings say so;
/// - a class a project file tells the system to create lives for the whole
///   process or extension, so a cycle through it leaks once at most: its
///   findings become notes.
enum ProjectContext {
    static let previewReason = "preview code: previews never ship"
    static let generatedReason = "generated file: fix the generator's input or template"
    static let debugNote = "only debug builds compile this code (#if DEBUG)"
    static let testNote =
        "test code: the object lives for the test run at most; if the retention is deliberate assertion plumbing, accept it with // @al:accept"

    /// The reason to withhold a finding, or nil to report it.
    static func withholdingReason(for finding: Finding, in facts: FileFacts?) -> String? {
        guard let facts else { return nil }
        let region = facts.region(ofLine: finding.line)
        if region.contains(.generated) {
            return generatedReason
        }
        if region.contains(.preview) {
            return previewReason
        }
        return nil
    }

    /// The finding with the notes its region calls for.
    static func annotated(_ finding: Finding, in facts: FileFacts?) -> Finding {
        guard let facts else { return finding }
        let region = facts.region(ofLine: finding.line)
        var result = finding
        if region.contains(.debugOnly) {
            result = result.adding(note: debugNote)
        }
        // The Combine rules already explain XCTest's lifetime.
        if region.contains(.test), finding.note?.contains("XCTest holds") != true {
            result = result.adding(note: testNote)
        }
        return result
    }

    /// A finding on a type the system creates from a project file: a note.
    static func systemEntryPoint(_ finding: Finding, typeName: String) -> Finding {
        finding.adding(
            note: "the system creates \(typeName) from a project file and keeps it for the whole process "
                + "or extension, so this leaks once at most",
            severity: .note
        )
    }
}

extension Finding {
    /// This finding with `note` appended and, when given, a new severity.
    func adding(note extra: String, severity newSeverity: Severity? = nil) -> Finding {
        Finding(
            rule: rule,
            severity: newSeverity ?? severity,
            path: path,
            line: line,
            column: column,
            message: message,
            note: note.map { "\($0) — \(extra)" } ?? extra,
            related: related,
            fingerprintPath: fingerprintPath
        )
    }
}
