public import AemiJSON
import ProjectModel

/// Lines of one file that only debug builds or previews compile, in the
/// cacheable form of `ProjectModel.RegionSpan`.
@JSONCodable
public struct RegionSpanFact: Sendable, Equatable, Codable {
    public let startLine: Int
    public let endLine: Int
    /// `CodeRegion.rawValue`.
    public let region: UInt8

    public init(startLine: Int, endLine: Int, region: UInt8) {
        self.startLine = startLine
        self.endLine = endLine
        self.region = region
    }

    init(_ span: RegionSpan) {
        self.init(startLine: span.startLine, endLine: span.endLine, region: span.region.rawValue)
    }
}

extension FileFacts {
    /// The region of one line of this file: production, debug-only, preview,
    /// or both, plus `test` and `generated` when the whole file is.
    /// - Complexity: O(s) in the number of region spans.
    func region(ofLine line: Int) -> CodeRegion {
        var region = CodeRegion.production
        if isTestCode { region.formUnion(.test) }
        if isGenerated { region.formUnion(.generated) }
        for span in regionSpans where span.startLine <= line && line <= span.endLine {
            region.formUnion(CodeRegion(rawValue: span.region))
        }
        return region
    }
}
