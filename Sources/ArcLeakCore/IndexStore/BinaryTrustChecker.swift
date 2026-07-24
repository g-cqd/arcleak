import Foundation

/// Defence-in-depth check that a dylib path is safe to hand to
/// `IndexStoreLibrary.init` (which `dlopen`s it). Refuses any path whose target
/// is not a regular file, is world- or group-writable, or is owned by some
/// *other* user.
///
/// Lifted from SwiftStaticAnalysis, with a deliberate policy relaxation for a
/// developer CLI. SSA's checker required uid 0 (root) ownership — correct for
/// its MCP server, which resolves attacker-influenced paths in a possibly
/// shared/multi-user context. arcleak instead reads `libIndexStore.dylib` out
/// of the *user's own* active Swift toolchain (swiftly snapshots and
/// `~/Library/Developer/Toolchains` are user-owned by construction), so
/// root-only ownership would reject exactly the toolchain the user builds with.
/// The retained gate — regular file, not world/group-writable, owned by root OR
/// the current user — still blocks a dylib planted by another account or in a
/// world-writable directory, which is the realistic local threat.
///
/// The candidate should already be symlink-resolved by the caller; `lstat`
/// rejects symlinks outright.
public enum BinaryTrustChecker {
    /// Returns `true` if `path` exists, is a regular file owned by root or the
    /// current user, and is not writable by group or other.
    public static func isTrusted(at path: String) -> Bool {
        guard !path.isEmpty else { return false }
        var info = stat()
        // `lstat` takes raw C pointers; under strict memory safety the call is
        // explicitly marked `unsafe`. It is bounded — `info` is a fixed-size
        // stack struct and `path` a valid NUL-terminated String.
        let status = unsafe lstat(path, &info)
        guard status == 0 else { return false }
        guard (info.st_mode & S_IFMT) == S_IFREG else { return false }
        let owner = info.st_uid
        guard owner == 0 || owner == getuid() else { return false }
        // Group- or world-writable binaries are tampering targets even when
        // nominally owned by a trusted principal.
        if (info.st_mode & UInt16(S_IWGRP | S_IWOTH)) != 0 { return false }
        return true
    }
}
