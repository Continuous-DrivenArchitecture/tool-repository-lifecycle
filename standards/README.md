# CDA Standards — Reference, Not a Copy

The standards are normative. This tooling implements them, but does not
define them, own them, or duplicate their text — the standard documents
are the single source of truth for what a compliant CDA repository *is*;
this repository is one implementation of *how* to get there.

## Current canonical source (as of this repository's creation)

The approved standard documents live in the `Continuous-DrivenArchitecture`
workspace, not in this repository:

- `docs/standards/cda-repository-baseline-v1.md` — the baseline every CDA
  repository must satisfy (branching, pull requests, merge strategy,
  branch protection, Actions permissions and supply-chain posture,
  secrets/variables handling, dependency automation, baseline security
  controls, **repository hygiene** — including the orphan
  workflow/environment/Pages rules this tooling's `hygiene.*` capabilities
  implement — and baseline documentation). Explicitly out of scope for the
  baseline: package/build systems, release/publish mechanics, and anything
  tied to what a repository actually produces.
- `docs/standards/cda-npm-library-profile-v1.md` — the npm-library
  profile that extends the baseline (`profiles/npm-library.json` in this
  repository is its machine-readable desired-state projection).

This document records that location explicitly, per this repository's own
governing task: **do not infer the canonical location from this prompt or
from convenience — state it, so a reader always knows where to go for the
authoritative text.** If the standards are ever moved (for example, into
their own repository, or into this one), this file is the place that
record changes, and this repository's own `profiles/*.json` files are
updated to match — never the reverse.

## Why the standards are not copied here

Two authorities for the same policy text drift. A profile that quietly
re-states baseline rules in its own words (rather than referencing them)
eventually disagrees with the baseline it claims to extend, and nobody
knows which one is wrong. This repository avoids that by keeping exactly
one authority (the standard documents, wherever they canonically live) and
treating every JSON profile, schema, and script here as a downstream,
falsifiable implementation of that authority — checkable against it, never
a substitute for it.

## What belongs here instead

- `profiles/*.json` — desired GitHub-side state, one file per profile,
  each `extends`-linked to the baseline/profile pair it implements (see
  [docs/profiles.md](../docs/profiles.md)).
- `docs/*.md` — this tooling's own architecture, lifecycle, safety model,
  and artifact model. These describe how the tooling works, not what the
  standard requires — where they reference a requirement, they cite the
  standard document by name rather than restating its text.
- `COMPLIANCE.md` — this repository's own self-assessment against the CDA
  repository baseline (see [../COMPLIANCE.md](../COMPLIANCE.md)), which
  necessarily *does* read the standard directly rather than working from
  a profile, since no npm-library (or other kind-specific) profile applies
  to a repository whose product is tooling, not a package.
