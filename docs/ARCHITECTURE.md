# Architecture

SlackResolve 0.4.0 has four entry paths and one shared dependency engine.

## Entry paths

1. `check-program` starts from one installed ELF object.
2. `search-file` finds an exact basename or package path, selects its provider package, and then enters the shared dependency engine.
3. `check-system` starts from every dynamic ELF object owned by an installed Slackware package.
4. `install` starts from a local package archive or an exact package selected from official slackpkg indexes.

The engine reads the target's pkgtools records, loader paths, `ld.so.cache`, RPATH, RUNPATH, ELF class, machine, SONAME, required version definitions, and required versioned symbols.

The target package architecture is inferred from the installed pkgtools
records. `noarch` packages are always eligible. Members of the 32-bit x86
package family (`i386` through `i686`) are mutually eligible; other package
architectures must match the target exactly. An explicit `--arch` override is
available for incomplete alternate roots. ELF providers are still required to
match each consumer's class, machine, and endianness.

For official repositories, SlackResolve builds a persistent basename-to-package
index from Slackware's `MANIFEST` and cross-references it with the current
`pkglist`. Its cache key includes the release, architecture, and repository
metadata state. A generic file that is not represented in the fast library
map falls back to `slackpkg file-search`; that result is also cached under the
same repository signature.

Candidates are downloaded with `slackpkg download`, verified, unpacked into
the content-addressed analysis cache, and inspected. Generic searches require
an exact basename or exact package path after download. Provider packages
enter the same graph, so their ELF requirements are resolved recursively. A
package with no dynamic ELF objects has no inferable ELF edges and remains a
valid package operation.

Each graph pass collects all unresolved requirements. Providers that are
unambiguous are deduplicated and added as one dependency round, avoiding a
complete graph restart for every individual library. Ambiguous alternatives
continue through the bounded backtracking search.

Missing ELF requirements are prioritized independently from conservative
package-script warnings. Therefore, a script that still requires review cannot
truncate the recursive provider search. Fixed post-install commands explicitly
modeled by the restricted parser, including the official gdk-pixbuf loader-cache
update, do not create a pending issue; arbitrary script execution remains
blocked and is never performed during analysis.

## Planned filesystem

Selected packages form an overlay over the installed target. SlackResolve rejects unrelated file collisions and global SONAME shadowing.

Package actions are derived from actual paths:

- An exact installed package is `keep`.
- A package replacing paths owned by an installed package with the same base is `upgrade`.
- A package with no such overlap is `install`, even when another nonconflicting version of that base is installed.

An upgrade enables a complete installed-system ELF audit against the overlay. This catches old consumers that would lose a compatible provider. It does not prove all runtime behavior, but it prevents the modeled SONAME and versioned-symbol breakages.

## Plans and application

A dependency-first order is saved with pinned archives, hashes, target guards, dependency evidence, and package actions. Ready plans contain no unresolved issues. Apply revalidates the plan and uses `installpkg` or `upgradepkg` according to the recorded action. A journal supports inspection and safe continuation after interruption.

The CLI and `dialog` interface invoke the same backend. The terminal interface only chooses inputs, displays results, and confirms application; it never makes dependency decisions itself.

## Persistent resolution sessions

Every planning command saves its original argument vector, repository and
system signatures, and selected package archives. Checkpoints are replaced
atomically. Ctrl+C, TERM, or cancellation of the `dialog` gauge marks the
session interrupted and preserves the most recent package selection.

`slackresolve resume SESSION` reconstructs the original command without
`eval` or shell sourcing. A matching repository, architecture, and installed
system restores the checkpoint into the graph. If those guards changed, the
graph is recalculated while content-addressed package and ELF caches remain
available.

## Boundaries

The graph covers observable ELF runtime dependencies in the modeled loader context. Script interpreters, language modules, build dependencies, arbitrary `dlopen()` names, package descriptions, and full application semantics are outside the inference model.
