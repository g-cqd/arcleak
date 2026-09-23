#if canImport(FoundationEssentials)
    internal import FoundationEssentials
#else
    internal import Foundation
#endif

/// Finds the Swift sources under a directory argument.
public enum SourceDiscovery {
    /// Directory names never walked into: build products, VCS internals and
    /// dependency checkouts.
    static let skippedNames: Set<String> = [".build", ".git", "DerivedData", ".swiftpm", "checkouts"]

    /// Every `.swift` file under `directory` that `isExcluded` keeps, sorted.
    ///
    /// Explicit worklist rather than FileManager.enumerator, which is
    /// corelibs-only. Skips hidden entries and ``skippedNames``, resolves
    /// symlinks, and seeds absolute, because finding paths are part of the
    /// output contract.
    ///
    /// Symlinked directories are followed, but each directory is walked once,
    /// under the first spelling that reaches it. A link back up the tree
    /// (`ln -s .. Loop`) used to re-walk it under every longer spelling until
    /// the kernel refused the path (ELOOP), and two such links multiplied at
    /// every level and never finished. Entries are visited in sorted order, so
    /// which spelling comes first does not depend on the file system.
    public static func swiftFiles(under directory: String, isExcluded: (String) -> Bool) -> [String] {
        let manager = FileManager.default
        var files: [String] = []
        let start = URL(fileURLWithPath: directory).resolvingSymlinksInPath().path
        var visited: Set<String> = []
        if let attributes = try? manager.attributesOfItem(atPath: start) {
            visited.insert(identity(of: start, attributes: attributes))
        }
        var stack = [start]
        while let current = stack.popLast() {
            guard let entries = try? manager.contentsOfDirectory(atPath: current) else {
                continue
            }
            for entry in entries.sorted() {
                if entry.hasPrefix(".") { continue }
                if skippedNames.contains(entry) { continue }
                let full = current + "/" + entry
                // Resolved first — attributesOfItem does not traverse a final
                // symlink.
                let resolved = URL(fileURLWithPath: full).resolvingSymlinksInPath().path
                guard let attributes = try? manager.attributesOfItem(atPath: resolved) else { continue }
                if attributes[.type] as? FileAttributeType == .typeDirectory {
                    if visited.insert(identity(of: resolved, attributes: attributes)).inserted {
                        stack.append(full)
                    }
                } else if full.hasSuffix(".swift"), !isExcluded(full) {
                    files.append(full)
                }
            }
        }
        return files.sorted()
    }

    /// What makes a directory the same directory under any spelling: its
    /// device and inode, or its resolved path where the file system reports
    /// neither.
    private static func identity(of resolvedPath: String, attributes: [FileAttributeKey: Any]) -> String {
        guard let device = attributes[.systemNumber], let inode = attributes[.systemFileNumber] else {
            return resolvedPath
        }
        return "\(device):\(inode)"
    }
}
