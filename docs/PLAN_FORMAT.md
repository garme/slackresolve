# Plan format, schema 3

Plans are UTF-8 tab-separated data. They are parsed as records and are never sourced or evaluated as shell code.

Empty fields use `%00`. Percent, tab, newline, and carriage return use `%25`, `%09`, `%0A`, and `%0D`.

| Record | Fields after the tag |
| --- | --- |
| `SLACKRESOLVE_PLAN` | schema version |
| `META` | key, value |
| `PACKAGE` | identity, full name, pinned archive path, SHA-256, origin, action, previous installed package |
| `FILE` | package identity, path, F/L/D type, hash or target, mode |
| `EDGE` | consumer, needed library, provider path, provider owner, status, provider identity or reason |
| `ISSUE` | category, object, requirement, explanation |
| `REJECT` | rejected package, library, explanation |
| `ORDER` | package identity |
| `GUARD` | existing path, original type, original value |

Package actions are `install`, `upgrade`, and `keep`. An upgrade must name the installed package it replaces.

Schema 3 records the detected target package architecture. Apply and verify
reject a plan when its architecture differs from the current target.

The adjacent `PLAN.d/` directory holds the exact package archives. A ready plan has no issue records and has one complete operation order. Unknown records, unsupported schemas, missing archives, changed hashes, and paths escaping the plan directory are rejected.

Resolution sessions are separate from plans. They live under the selected
cache directory in `sessions/`, contain only escaped tab-separated records,
and are never sourced as shell programs. A checkpoint may accelerate continued
analysis, but it is not actionable: only a complete, ready plan can be applied.
