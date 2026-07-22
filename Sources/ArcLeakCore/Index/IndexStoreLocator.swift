public import Foundation

/// Discovers an index store on disk and enforces the staleness contract:
/// a store older than the newest analyzed source must downgrade the analysis
/// to corpus-only facts, with an explicit notice — never silently wrong.
///
/// Store locations are non-contractual (SourceKit-LSP's background index
/// commonly lives at `.build/index-build`; Xcode's under DerivedData), so an
/// explicit `--index-store-path` always wins and every default is a probe.
public enum IndexStoreLocator {
    public struct DiscoveredStore: Sendable, Equatable {
        public let url: URL
        public let modificationDate: Date

        /// True when any analyzed source is newer than the store.
        public func isStale(comparedTo newestSource: Date) -> Bool {
            modificationDate < newestSource
        }
    }

    public static func discover(projectRoot: URL, explicitPath: String? = nil) -> DiscoveredStore? {
        var candidates: [URL] = []
        if let explicitPath {
            candidates.append(URL(fileURLWithPath: explicitPath))
        }
        candidates.append(projectRoot.appending(path: ".build/index-build/index/store"))
        candidates.append(projectRoot.appending(path: ".build/index-build"))
        candidates.append(projectRoot.appending(path: ".build/debug/index/store"))

        for candidate in candidates {
            guard
                let values = try? candidate.resourceValues(
                    forKeys: [.isDirectoryKey, .contentModificationDateKey]
                ),
                values.isDirectory == true
            else { continue }
            return DiscoveredStore(
                url: candidate,
                modificationDate: values.contentModificationDate ?? .distantPast
            )
        }
        return nil
    }

    /// Newest modification date across the analyzed files (staleness input).
    public static func newestModification(of files: [String]) -> Date {
        let manager = FileManager.default
        var newest = Date.distantPast
        for file in files {
            if let date = try? manager.attributesOfItem(atPath: file)[.modificationDate] as? Date,
                date > newest
            {
                newest = date
            }
        }
        return newest
    }
}
