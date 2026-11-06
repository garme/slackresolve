# Validation

The automated suite builds real x86_64 ELF programs and shared libraries with GCC. It uses temporary Slackware-like target roots and does not modify the host package database.

Current coverage includes:

- generic exact-basename lookup with recursive library dependencies;
- generic exact-path lookup for a data-only package;
- ambiguous generic providers and explicit preference;
- an installed program with a missing library;
- an already healthy program;
- a complete package-owned system audit;
- recursive dependency discovery;
- official generic `slackpkg file-search`, download, checksum, and signature contracts;
- dependency-first dry-run and application;
- post-application verification;
- a safe same-package upgrade;
- rejection of an upgrade that breaks an old versioned-symbol consumer;
- parallel versions with nonconflicting files and different SONAMEs;
- ambiguous providers and explicit preference;
- rejection of unknown installation-script effects;
- stale package-database rejection;
- the `dialog` package-planning workflow.

The pkgtools and slackpkg tests use controlled stand-ins around the real resolver. They prove command contracts and state handling, but they do not replace acceptance testing with the exact Slackware release and mirror configuration where the software will run.

Before production use, test in a disposable Slackware x86_64 installation:

1. Configure the correct official mirror and run `slackpkg update gpg` and `slackpkg update`.
2. Run `slackresolve doctor`.
3. Check a known program and inspect the resulting plan.
4. Run `apply --dry-run`.
5. Apply the plan and verify it.
6. Run the affected application.
7. Exercise a complete-system audit and review its performance and results.
