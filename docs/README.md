# Using arcleak

arcleak finds retain cycles, anchor leaks and premature releases in Swift source, without a build.

- [Getting started](getting-started.md): install, run, adopt on existing code, accept a finding.
- [Rules](rules.md): what it finds, what it leaves alone, how sure each rule is.
- [Configuration](configuration.md): rules, exclusions, and contracts for your own wrappers.
- [Using it in builds and CI](integration.md): the build plugin, pull-request gates, code scanning.
- [Command line and reports](reports.md): options, the JSON report, stability.
- [Cross-module types](index-store.md): resolving classes from other modules with the index (macOS).
- [Grouping findings by similarity](embeddings.md): the experimental ranking (macOS).

How arcleak is built and released is in [`development/`](../development/).
