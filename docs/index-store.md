# Cross-module types

By default arcleak reasons only about types declared in the files it analyzes; a stored property whose type lives in another
module or the SDK is skipped as unknown. `--index-store` asks the compiler's index (the one SourceKit-LSP and `swift build`
already write) whether such a type is a class, so a cycle that closes across modules can be found.

```sh
arcleak analyze Sources --index-store                  # find the store (.build, DerivedData)
arcleak analyze Sources --index-store-path .build/debug  # a store, or a build directory above it
arcleak analyze Sources --index-store-build            # run swift build first if there is none
arcleak analyze Sources --index-store --verbose        # explain which libIndexStore was chosen
```

It is opt-in, macOS-only, and **fails open**. With no index, on Linux, or when the store covers none of the files, arcleak says so
in one line and runs the default analysis unchanged. Otherwise the note says how far the index reaches
(`index active for 2809 of 2838 files; 11 not in the index, 18 changed since the build`), and the JSON report lists the rest
under `skippedFiles`.

## How it decides

An edge is added only when the index **confirms** a type is a class or actor, never on a guess.

- A type the files declare is never looked up.
- A name the index defines several ways that disagree answers nothing.
- A definition whose file changed since the build, or no longer declares the type, is not used.

## Finding the store

SwiftPM's store under `.build` is tried first (the background index, each configuration, `.build/out`), then Xcode's DerivedData,
matched to the project through `info.plist`, so separate worktrees do not borrow each other's stores. `--index-store-path` takes
a store, a `vN` directory, `Index.noindex`, a DerivedData build root or a SwiftPM build directory; anything else is refused
before it is opened. The database is kept under the cache root, never beside the store.

`libIndexStore.dylib` comes from the first trusted toolchain: `DEVELOPER_DIR`, `xcode-select -p`, `xcrun`, toolchains in
`~/Library/Developer/Toolchains`, then the Command Line Tools. A trusted library is a regular file owned by root or you, neither it
nor its folder writable by group or others.
