# ModHub Submission Plan (PC/Mac)

Project: `FS25_HoldToSteer`  
Scope: GIANTS ModHub submission for PC/Mac only (no console target)

## 1) Goal and Constraints

### Goal
- Submit a stable, review-ready build of `FS25_HoldToSteer` to GIANTS ModHub.

### Constraints
- Platform target is strictly PC/Mac.
- Documentation and in-repo comments stay in English.
- No temporary debug instrumentation in release artifacts.

## 2) Submission Strategy

- Use a phase-based checklist with explicit pass/fail criteria.
- Freeze feature work during release hardening (bugfix-only window).
- Treat `log.txt` cleanliness and reproducible behavior as release blockers.

## 3) Phase Plan

## Phase A - Release Candidate Freeze

### Tasks
- [ ] Create/confirm release branch or release commit point.
- [ ] Stop feature additions; allow only targeted bugfixes.
- [ ] Confirm current versioning strategy for this release.

### Definition of Done
- [ ] A single identifiable release candidate (RC) exists.
- [ ] Team agrees that scope is frozen.

## Phase B - Metadata and Packaging Compliance

### Tasks
- [ ] Validate `modDesc.xml` fields (`name`, `version`, `descVersion`, `author`, titles/descriptions).
- [ ] Verify icon and branding assets are present and correct.
- [ ] Confirm ZIP root layout is correct (no extra wrapper folder).
- [ ] Remove non-release files (debug dumps, local notes, temp artifacts).

### Definition of Done
- [ ] Packaged ZIP can be dropped into mods folder and loads immediately.
- [ ] Metadata matches intended release version and description.

## Phase C - Functional Validation (Ingame)

### Core behavior checks
- [ ] LMB steering activation/deactivation behaves as expected.
- [ ] Steering coast after LMB release feels correct and consistent.
- [ ] Reverse-driving behavior keeps practical camera usability (no unwanted recentering after LMB release while reversing).
- [ ] Frontloader suppression behavior works for tractor/trailer vs loader/tool selection.

### Coverage checks
- [ ] Test with multiple vehicle classes (tractor, truck, combine if applicable).
- [ ] Test with and without implements attached.
- [ ] Validate settings persistence across restart/reload.

### Definition of Done
- [ ] No functional regressions against documented behavior.
- [ ] All critical control flows were manually verified at least once.

## Phase D - Stability and Log Quality

### Tasks
- [ ] Fresh game session test (new save).
- [ ] Existing save load test.
- [ ] Review `log.txt` for errors/warnings during key scenarios.
- [ ] Confirm no repetitive log spam from update loops/hooks.

### Definition of Done
- [ ] Zero release-blocking errors in `log.txt`.
- [ ] No recurring warning spam caused by the mod.

## Phase E - Localization and Store Presentation

### Tasks
- [ ] Verify `l10n_en.xml` and `l10n_de.xml` keys are complete and referenced correctly.
- [ ] Align in-game labels/tooltips with actual behavior.
- [ ] Prepare ModHub description text for PC/Mac audience.
- [ ] Prepare 2-4 clear screenshots that represent real use.

### Definition of Done
- [ ] No missing localization keys in tested language set.
- [ ] Store text and screenshots are ready to paste/upload.

## Phase F - Final Release Assembly

### Tasks
- [ ] Sync version references (`modDesc.xml`, changelog, release notes).
- [ ] Generate final release ZIP named `FS25_HoldToSteer.zip`.
- [ ] Run one last clean smoke test with final ZIP artifact.
- [ ] Archive submission notes (what was tested, known limitations).

### Definition of Done
- [ ] Final ZIP is validated and traceable to a specific commit.
- [ ] Release notes/changelog match exactly what is shipped.

## Phase G - ModHub Submission and Follow-up

### Tasks
- [ ] Submit package and metadata via GDN/ModHub workflow.
- [ ] Track review feedback and convert items into actionable fixes.
- [ ] If required, prepare rapid resubmission patch with minimal delta.

### Definition of Done
- [ ] Submission is complete and tracked.
- [ ] A response plan exists for review feedback.

## 4) Release Blockers

- Any Lua errors in `log.txt` caused by this mod.
- Broken input behavior in core scenarios (LMB steer, reverse use case, frontloader selection logic).
- Missing/invalid metadata or bad ZIP structure.
- Localization gaps in shipped languages.

## 5) Suggested Ownership Template

- Release owner: `[name]`
- QA owner: `[name]`
- Packaging owner: `[name]`
- Localization owner: `[name]`
- Submission owner: `[name]`

## 6) Quick Execution Checklist (One-Pass)

- [ ] Metadata validated
- [ ] ZIP structure validated
- [ ] Core driving scenarios tested
- [ ] `log.txt` reviewed and clean
- [ ] Localization checked
- [ ] Changelog/version synchronized
- [ ] Final ZIP smoke-tested
- [ ] ModHub submission completed
