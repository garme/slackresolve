# Validation

The automated suite builds real x86_64 ELF programs and shared libraries with GCC. It also exercises architecture-neutral repository selection with a synthetic Slackware i586 target. It uses temporary Slackware-like target roots and does not modify the host package database.

Current coverage includes:

- generic exact-basename lookup with recursive library dependencies;
- generic exact-path lookup for a data-only package;
- ambiguous generic providers and explicit preference;
- an installed program with a missing library;
- an already healthy program;
- a complete package-owned system audit;
- recursive dependency discovery;
- official generic `slackpkg file-search`, download, checksum, and signature contracts;
- persistent official slackpkg `filelist` provider indexing without a per-library
  `slackpkg file-search` invocation;
- the exact 32-bit search result `[uninstalled] - librsvg-2.52.5-i586-1`;
- dependency-first dry-run and application;
- post-application verification;
- a safe same-package upgrade;
- rejection of an upgrade that breaks an old versioned-symbol consumer;
- parallel versions with nonconflicting files and different SONAMEs;
- ambiguous providers and explicit preference;
- continued recursive ELF resolution in the presence of an unknown
  installation-script effect, while the final plan remains blocked;
- declarative recognition of the official gdk-pixbuf loader-cache update;
- stale package-database rejection;
- interruption checkpointing and successful continuation of the same
  recursive resolution;
- deterministic handling of a cyclic package dependency as one strongly
  connected installation group;
- explicit non-x86 architecture matching;
- the `dialog` package-planning workflow.

The pkgtools and slackpkg tests use controlled stand-ins around the real resolver. They prove command contracts and state handling, but they do not replace acceptance testing with the exact Slackware release and mirror configuration where the software will run.

Before production use, test in disposable installations of every target
architecture that will be supported operationally:

1. Configure the correct official mirror and run `slackpkg update gpg` and `slackpkg update`.
2. Run `slackresolve doctor`.
3. Check a known program and inspect the resulting plan.
4. Run `apply --dry-run`.
5. Apply the plan and verify it.
6. Run the affected application.
7. Exercise a complete-system audit and review its performance and results.
