# SlackResolve

SlackResolve finds packages containing missing files and resolves ELF library dependencies on Slackware. It can search for a filename, check one installed program, audit every package-owned ELF object in the system, or analyze a Slackware package before installation.

The application is written in Bash and awk. It uses Slackware's existing package records, `slackpkg`, `installpkg`, `upgradepkg`, `ldconfig`, and the official repository indexes. Packages do not need embedded dependency metadata.

Version **0.3.1** provides four direct workflows:

1. Check an installed program.
2. Find the package containing an exact filename or package path.
3. Check the complete system.
4. Install a package with its recursively discovered dependencies.

The supported target is Slackware x86_64. Slackware 15.0 is the reference release.

## What it does

- Reads ELF requirements and symbol versions with `readelf`.
- Resolves libraries through the target's loader paths, cache, RPATH and RUNPATH.
- Uses `slackpkg file-search` to locate official packages containing a missing library.
- Confirms an exact basename such as `libabc.so.1`, or an exact package path such as `/usr/bin/example`, inside downloaded candidates.
- Downloads candidates with `slackpkg download`, verifies them, and inspects their actual ELF contents.
- Repeats the analysis for every selected provider until the dependency chain is complete.
- Creates a reviewable plan containing exact package archives and hashes.
- Uses `installpkg` for additions and `upgradepkg` for replacements.
- Audits installed ELF consumers before approving an upgrade.
- Allows parallel package versions only when their paths and global library identities do not conflict.
- Refuses to apply incomplete, changed, ambiguous, or conflicting plans.
- Provides an English `dialog` interface for consoles, terminal emulators, and SSH sessions.

## Requirements

- Bash 4 or later and awk.
- GNU binutils (`readelf`).
- GNU tar, coreutils, findutils, grep and util-linux `flock`.
- `slackpkg` with a configured mirror and current indexes.
- `installpkg`, `upgradepkg`, and `ldconfig` for applying a plan.
- `dialog` for the terminal interface. The CLI works without it.
- Compression utilities required by the inspected Slackware packages.

Configure one mirror for the installed Slackware release and initialize the official indexes:

```sh
slackpkg update gpg
slackpkg update
```

## Installation

Install the included native package:

```sh
installpkg dist/slackresolve-0.3.1-noarch-1.txz
```

Or build it from the source tree:

```sh
make slackware-package
installpkg dist/slackresolve-0.3.1-noarch-1.txz
```

The CLI is installed as `/usr/sbin/slackresolve`. The terminal interface is installed as `/usr/bin/slackresolve-tui` and is also available from the desktop menu.

## Terminal interface

Run:

```sh
slackresolve-tui
```

The main menu contains:

- **Check an installed program**: select an ELF program and create a plan for its missing libraries.
- **Find the package containing a file**: enter an exact filename or package path, select a provider when necessary, and resolve any ELF dependencies in that package.
- **Check the complete system**: inspect package-owned ELF programs and libraries and create one repair plan.
- **Install a package with dependencies**: select a local archive or enter an exact official package name.
- **Review a saved plan**: show marked install, upgrade, and keep operations and dependency evidence.
- **Apply a saved plan**: review, confirm, and execute every marked operation.
- **Verify an applied plan**: compare installed package payloads and providers with the plan.
- **Repository and provider preferences**: choose official slackpkg indexes or a local package directory and resolve genuine provider alternatives.

Use arrow keys, Tab, Enter, and Esc. Planning does not modify the system. Applying to `/` requires a root shell.

## CLI examples

### Find a package by filename

```sh
slackresolve search-file libabc.so.1 \
  --output libabc.plan
```

An exact package path can also be used:

```sh
slackresolve search-file /usr/bin/example \
  --output example-file.plan
```

SlackResolve confirms the requested file in each downloaded candidate. If the selected package contains dynamic ELF objects, their missing libraries are resolved recursively. A package containing only data, configuration, or another non-ELF file can still produce a ready installation plan, but no unprovable runtime dependencies are invented.

When equally preferred packages contain the same file, review the reported candidates and rerun with an explicit provider:

```sh
slackresolve search-file libabc.so.1 \
  --prefer abc-libs \
  --output libabc.plan
```

### Check one installed program

```sh
slackresolve check-program /usr/bin/example \
  --output example.plan
```

If `libfoo.so.3` is missing, SlackResolve searches the official package file list, downloads the matching package, checks that it really provides a compatible library, and then examines that package's dependencies.

### Check the complete system

```sh
slackresolve check-system \
  --output system-repair.plan
```

The audit starts from ELF files listed in `/var/lib/pkgtools/packages`. Identical missing requirements are resolved once and shared by every affected consumer. Derived ELF metadata is cached by file hash, so unchanged files do not need to be parsed again.

### Analyze a local package before installation

```sh
slackresolve install ./example-1.0-x86_64-1.txz \
  --output example-install.plan
```

### Analyze an official package by name

```sh
slackresolve install example \
  --output example-install.plan
```

An exact full package name can be used when a base name is ambiguous.

### Review and apply

```sh
slackresolve show example-install.plan
slackresolve apply example-install.plan --dry-run
slackresolve apply example-install.plan
slackresolve verify example-install.plan
```

Keep the plan and its adjacent `.plan.d/` directory together. The directory stores the exact archives that were analyzed. A plan cannot be overwritten; generate a new filename after any system or repository change.

## Package actions and parallel versions

Each package receives one action:

| Action | Meaning |
| --- | --- |
| `install` | Add a package with `installpkg`. |
| `upgrade` | Replace an installed version with `upgradepkg`. |
| `keep` | The exact package and payload are already installed. |

Two versions with the same package base can be installed in parallel only when they use different, nonconflicting paths. Different library SONAMEs such as `libfoo.so.2` and `libfoo.so.3` can coexist when their remaining payloads also do not collide.

If a new version overwrites files owned by an installed version, the operation becomes an upgrade. Before marking it ready, SlackResolve analyzes package-owned installed ELF consumers against the planned filesystem. The upgrade is blocked if an old program would lose a required SONAME, symbol version, or versioned symbol.

Two incompatible libraries with the same SONAME can coexist only when the package already places one in a private directory and the program has a suitable RPATH or RUNPATH. SlackResolve does not rewrite or repackage arbitrary software automatically.

## Plan safety

A plan records:

- exact package archives and SHA-256 hashes;
- install, upgrade, and keep actions;
- dependency-first operation order;
- resolved consumer-to-provider evidence;
- relevant filesystem state and package-database state;
- pending decisions and rejected providers.

Before applying, SlackResolve checks that the target, package records, guarded files, and archived bytes still match. An application journal records started and completed operations. A partially completed operation must be inspected before retrying.

## Coverage limits

SlackResolve infers dynamic ELF requirements. It does not infer shell commands, Python or Perl modules, build dependencies, application data, or arbitrary names constructed for `dlopen()`.

Versioned symbols are checked, but this is not a complete proof of ABI or application-level compatibility. Unknown installation-script effects are never executed during analysis and keep the plan incomplete.

Official repository support covers the mirror configured in `slackpkg`. Local package trees can be selected explicitly. Third-party repositories are outside the default scope.

## Tests

Run:

```sh
make test
```

The suite builds real ELF programs and libraries and checks generic file lookup, recursive dependencies from a found library, data-only packages, provider selection, program repair, complete-system auditing, official `slackpkg file-search` and download contracts, dependency-first application, safe upgrades, blocked ABI-breaking upgrades, parallel versions, stale plans, and the `dialog` workflow.

Tests use temporary Slackware-like roots and controlled pkgtools/slackpkg stand-ins; they never install fixture packages on the host. Native acceptance on a disposable Slackware installation is still recommended before production use.

## Project layout

| Path | Purpose |
| --- | --- |
| `bin/slackresolve` | Command-line interface |
| `bin/slackresolve-tui` | `dialog` terminal interface |
| `lib/` | ELF, archive, repository, solver, loader, and plan modules |
| `awk/` | Structured parsers |
| `tests/` | Real ELF fixtures and integration tests |
| `packaging/` | SlackBuild and package description |
| `docs/` | Architecture, plan format, validation notes, and manual page |

## Publishing on GitHub

Create an empty repository and run from this directory:

```sh
git init -b main
git add .
git commit -m "Initial SlackResolve release"
git remote add origin https://github.com/YOUR_USERNAME/slackresolve.git
git push -u origin main
```

## License

GNU General Public License version 3 (`GPL-3.0-only`). See [LICENSE](LICENSE).
