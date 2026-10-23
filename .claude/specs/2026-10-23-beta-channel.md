# Beta channel

## Goal
Changes are tested by installing them through ReaPack, and every release
reaches every member. Add a beta channel on the same ReaPack index: a beta
is a pre-release version, which ReaPack installs only where pre-releases are
enabled for the package, so the maintainer can test a change through ReaPack
before members get it.

## Acceptance criteria
- `CLAUDE.md` § Releasing describes both release kinds: a beta carries
  `@version <next>-beta.<n>` and the tag `v<next>-beta.<n>`; the stable
  release of the same changes bumps to `<next>` and is tagged `v<next>`. The
  same three steps and the same "last commit that touches
  `Scripts/ReaperPluginManager/`" rule apply to both.
- It states why this works: ReaPack treats a version containing letters as a
  pre-release, installs it only where pre-releases are enabled, and orders
  `1.5.0` above `1.5.0-beta.2` above `1.5.0-beta.1`.
- It states that `master` is the one branch: a stable release ships
  everything on `master`, so while a beta is out the next stable is that
  beta's version.
- `README.md` § Installing gains a short *Beta versions* subsection: in
  *Extensions > ReaPack > Browse packages*, right-click the
  ReaperPluginManager package and choose *Enable pre-releases
  (bleeding-edge)*; synchronising then installs betas; choosing it again
  returns to stable releases from the next one.
- The release workflow is unchanged: its tag check already accepts
  `v1.5.0-beta.1`.

## Decisions
- Pre-releases on the one index and the one branch rather than a second
  index or a `beta` branch: members keep their single repository URL, and
  ReaPack already filters pre-releases per package.
- The `-beta.<n>` form: ReaPack splits versions into digit and letter runs,
  so `1.5.0-beta.1` and `1.5.0beta1` are the same version, and the dashed
  form also reads as SemVer.

## Hints
- CLAUDE.md (§ Releasing)
- README.md (§ Installing, after *Updating and removing*)
- .github/workflows/release.yml (tag check, read only)

## Drift
- `CLAUDE.md` § Releasing — settles: how a pre-release is versioned and
  tagged, which the section left unstated.
- `README.md` § Installing — settles: how a member opts into betas.
