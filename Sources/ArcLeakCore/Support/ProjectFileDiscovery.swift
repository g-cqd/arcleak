import ProjectModel
import SourceCorpus

/// Finds the project files that tell the system which classes to create and which platforms the code builds
/// for: Xcode projects, package manifests, property lists, storyboards and xibs. The walk is
/// ``SourceDiscovery``'s; only what counts as a project file is arcleak's.
public enum ProjectFileDiscovery {
    /// The project files under `directory` that `isExcluded` keeps, sorted.
    public static func projectFiles(
        under directory: String, isExcluded: @escaping @Sendable (String) -> Bool
    ) -> [String] {
        SourceDiscovery.files(under: directory, isExcluded: isExcluded, where: isProjectFile)
    }

    /// Whether `path` names a project file ``projectFiles(under:isExcluded:)`` would list.
    public static func isProjectFile(_ path: String) -> Bool {
        SystemEntryPoints.isProjectFile(path) || ProjectPlatforms.isPlatformSource(path)
    }
}
