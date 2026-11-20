# Stage 0 Tasks: `devops`

> Plan: [plan.md](plan.md) · Spec: [SPEC-devops.md](../specs/SPEC-devops.md) · Gate = `docker build --target ci .` + both secret scans (dev_rules §9); from Slice 3 also `supabase test db`

---

## Before Slice 1 (you)

- Create the rulesets on GitHub:
  - `Dev PR`, targeting `dev`: PR required, squash only, block force-push and deletion
  - `Main PR`, targeting `main`: PR required, merge commits allowed, block force-push and deletion
- Commit `.claude/` on `docs/project-definition`, open a PR into `dev` and squash-merge it.
- Update your local `main` (it's behind `origin/main`).

Claude gives the exact commands, then checks both rulesets with a read-only `gh api` call.

---

## Slice 1: `feat/devops-gate`

> Before Task 1 (you): branch `feat/devops-gate` off the updated `dev`.

### Task 1: Spec corrections, Flutter pin, version, lockfile, `.gitignore`

**Description:**
- **Specs first** (plan.md › Architecture decisions):
  - SPEC.md: the Starting point lockfile line; Tech Stack gets the five Actions and Supabase CLI 3.2.0
  - SPEC-devops: CLI v3 forms (`db push --remote=REF --yes`, `[local_smtp]`, `db advisors`), config keys, AC-OPS-5's canary, the view guard, the release job's environment
  - SPEC-app-foundation and SPEC-auth: `GOOGLE_WEB_CLIENT_ID` moves to `auth`
- **pubspec.yaml:** `environment: flutter: 3.47.6`, `version: 0.0.0+1`, and a real `description`.
- **.gitignore:**
  - remove the `*.lock` line and the Flutter-framework-only entries (`/bin/cache/`, `/dev/…`, `/packages/…`)
  - add `config/local.json`, `supabase/.env` and `*.keystore` (`*.jks`, `key.properties` and `coverage/` are already there)
- `pubspec.lock` becomes tracked.

**Acceptance criteria:**
- [x] `flutter pub get` passes, and `git status` shows `pubspec.lock` as a new file
- [x] With the pin temporarily changed to `3.48.0`, `flutter pub get` fails (AC-OPS-1, local half), then the change is reverted
- [x] Each spec edit matches plan.md, and dev_rules §7/§8 still mirror SPEC.md's Boundaries

**Verification:**
- [x] `flutter pub get && flutter analyze --fatal-infos && flutter test`
- [x] Both secret scans print nothing
- [x] `git check-ignore -v pubspec.lock` prints nothing

**Dependencies:** none
**Files:** `pubspec.yaml`, `pubspec.lock`, `.gitignore`, `.claude/specs/SPEC.md`, `.claude/specs/SPEC-devops.md` (plus one-line edits in SPEC-app-foundation and SPEC-auth)
**Scope:** S

### Task 2: Dockerfile `toolchain` stage and `.dockerignore`

**Description:** `toolchain` stage:
- `FROM ubuntu:24.04@sha256:73b9…` (full digest from plan.md)
- `apt-get install --no-install-recommends` OpenJDK 21 (headless), git, curl, unzip, xz-utils, ca-certificates
- remove the image's `ubuntu` user and create `dev` from `ARG UID=1000` / `ARG GID=1000`
- Android command-line tools: Claude reads the current zip name and SHA-256 from developer.android.com, pins both in `ARG`s and checks them with `sha256sum -c`; `sdkmanager` accepts the licenses and installs `platform-tools`, `platforms;android-36`, `build-tools;36.0.0` and `ndk;28.2.13676358`
- Flutter: `ARG FLUTTER_VERSION=3.47.6` and `ARG FLUTTER_COMMIT=5fc346839b5d0eef006ed8404392afb4dfae428d`; a shallow clone at the tag, failing if `git rev-parse HEAD` differs
- analytics off for `flutter` and `dart`; `flutter precache --web --android`
- `USER dev`, `WORKDIR /app`

`.dockerignore` gets the spec's list.

**Acceptance criteria:**
- [x] The toolchain image builds, and `flutter --version` inside it prints 3.47.6 with commit `5fc3468`
- [x] `id -u` inside the image prints your UID (not 0), and `flutter doctor` shows the Android toolchain with licenses accepted
- [x] A wrong `FLUTTER_COMMIT` or SHA-256 fails the build (tried once each, then reverted)

**Verification:**
- [x] `docker build --target toolchain --build-arg UID=(id -u) --build-arg GID=(id -g) -t wmmt-toolchain .`
- [x] `docker run --rm wmmt-toolchain sh -c 'id -u && flutter --version && flutter doctor'`
- [x] Image size and first-build time recorded in REVIEW

**Dependencies:** Task 1
**Files:** `Dockerfile`, `.dockerignore`
**Scope:** S (but long-running)

### Task 3: `ci` stage, coverage script, `integration` tag

**Description:**
- **`ci` stage:** `FROM toolchain`; copy `pubspec.yaml` and `pubspec.lock`, then `flutter pub get --enforce-lockfile`; copy the rest. Then run, in order:
  1. `dart format --output=none --set-exit-if-changed .`
  2. `flutter analyze --fatal-infos`
  3. `flutter test --coverage --exclude-tags integration`
  4. `tool/check_coverage.sh 80`
  5. `flutter build web`
  6. `flutter build apk --debug`, with a BuildKit cache mount for `~/.gradle`
- **`tool/check_coverage.sh MIN`** (POSIX sh + awk):
  - sums `LF`/`LH` in `coverage/lcov.info`, skipping `lib/l10n/` files
  - prints the percentage, and exits 1 below MIN or when the file is missing
- **`dart_test.yaml`** declares the `integration` tag so `flutter test` doesn't warn about an unknown tag.

**Acceptance criteria:**
- [x] `docker build --target ci .` passes on a fresh clone (AC-OPS-2, local half)
- [x] A mis-formatted Dart file fails the build at the format step (AC-OPS-3, local half); reverted afterwards
- [x] `tool/check_coverage.sh` exits 1 on a missing file and when MIN is above the actual coverage, and 0 otherwise (tried with 101 and with 0)

**Verification:**
- [x] `git clone . SCRATCH/clone`, then `docker build --target ci SCRATCH/clone`
- [x] Both secret scans print nothing

**Dependencies:** Task 2
**Files:** `Dockerfile`, `tool/check_coverage.sh`, `dart_test.yaml`
**Scope:** S

### Checkpoint 1
- [x] Tasks 1–3 verified, and `git status` shows only the intended files
- [x] REVIEW written → you commit, open a PR into `dev` (no CI yet), squash-merge (PR #3, merged 2026-11-20)

---

## Slice 2: `feat/devops-ci`

### Task 4: `tool/secret_scan.sh` and `tool/check_pins.sh`

**Description:**
- **`secret_scan.sh`:** runs both dev_rules §9 scans exactly (file names only). Exits 1 if either prints anything.
- **`check_pins.sh`:** exits 1, naming the file and line, when:
  - a `uses:` in `.github/workflows/*.yml` isn't `@` followed by 40 hex characters (local `./` actions excepted)
  - a `FROM` in the Dockerfile has no `@sha256:` (stage references such as `FROM toolchain AS ci` excepted)
  - the Dockerfile's `FLUTTER_VERSION` differs from pubspec's `environment: flutter`

**Acceptance criteria:**
- [x] Both scripts exit 0 on the repo
- [x] Untracked throwaway files make them fail:
  - a canary with one of scan 1's plain-word patterns
  - a file named `x.keystore`
  - a workflow with `uses: actions/checkout@v4`
  - `FROM ubuntu:24.04`
  - a Flutter pin mismatch

  All throwaway files are deleted afterwards.

**Verification:**
- [x] `sh tool/secret_scan.sh; echo $status` and `sh tool/check_pins.sh; echo $status` (fish), before and after the throwaway files

**Dependencies:** Checkpoint 1
**Files:** `tool/secret_scan.sh`, `tool/check_pins.sh`
**Scope:** XS

### Task 5: `build-web` and `web` stages, `nginx.conf`, config placeholders, smoke script

**Description:**
- **`build-web` stage:** `FROM ci`, with `ARG APP_ENV`; refuses anything but `staging` or `prod`. Runs `flutter build web --release --no-web-resources-cdn --dart-define-from-file=config/$APP_ENV.json`.
- **`web` stage:** `FROM nginxinc/nginx-unprivileged:stable-alpine@sha256:f511…`; copies `build/web` and `docker/nginx.conf`; listens on 8080.
- **`docker/nginx.conf`:**
  - `try_files $uri $uri/ /index.html`
  - headers on every response (`always`):
    - CSP: `default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; connect-src 'self' https://*.supabase.co wss://*.supabase.co; frame-ancestors 'none'; base-uri 'self'; form-action 'self'`, tuned in the Chromium check below
    - `X-Content-Type-Options: nosniff`
    - `Referrer-Policy: strict-origin-when-cross-origin`
  - `server_tokens off`
- **Config:** `config/local.example.json`, `staging.json` and `prod.json` with placeholder values for `SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY`. Slice 5 fills in the real public values.
- **`tool/smoke_web.sh URL`:** `curl` checks that `/` and `/journal/42` return 200 with the three headers.

**Acceptance criteria:**
- [x] `docker run` of the `web` image, then `tool/smoke_web.sh http://localhost:8080`, passes (AC-OPS-7)
- [x] Chromium at `http://localhost:8080` (checked on :8088, since a local `flutter` dev server held :8080) renders the template app, and the console shows no CSP violations; every CSP change from the draft above is recorded in REVIEW with its reason
- [x] `docker run --rm wmmt-web id -u` is not 0
- [x] With dummy `config/local.json`, `android/key.properties` and `supabase/.env` present, `find` inside the `ci` and `web` images finds none of them (AC-OPS-8)

**Verification:**
- [x] `docker build --target web --build-arg APP_ENV=staging -t wmmt-web .`
- [x] `docker run --rm -d -p 8080:8080 --name wmmt-web wmmt-web`, then the smoke script, then `docker stop wmmt-web`
- [x] `docker build --target web --build-arg APP_ENV=nope .` fails

**Dependencies:** Checkpoint 1
**Files:** `Dockerfile`, `docker/nginx.conf`, `config/local.example.json`, `config/staging.json`, `config/prod.json`, `tool/smoke_web.sh`
**Scope:** M (6 small files)

### Task 6: `ci.yml` job `flutter`, plus `dependabot.yml`

**Description:**
- **`.github/workflows/ci.yml`:**
  - on `pull_request` and `push` to `dev` and `main`
  - `permissions: contents: read`; `concurrency` per ref, cancelling in-progress PR runs
  - **job `flutter`** (`ubuntu-latest`, `timeout-minutes: 30`):
    1. checkout
    2. `tool/secret_scan.sh` and `tool/check_pins.sh`
    3. on PRs only: the title check, with the title passed through `env: PR_TITLE`
    4. setup-buildx; build-push with `target: ci-report`, `outputs: type=local,dest=out`, the GHA cache (`mode=max`), and the runner's UID/GID as build args
    5. upload `out/lcov.info` as the `coverage` artifact
    6. build the `web` image (`APP_ENV=staging`, `load: true`), run it and run `tool/smoke_web.sh`
- **Dockerfile:** add the `ci-report` stage (`FROM scratch`, `COPY --from=ci /app/coverage/lcov.info /`).
- **`.github/dependabot.yml`:** `pub`, `github-actions` and `docker`, weekly, `target-branch: dev`, Conventional Commits prefixes (`build(deps)` for pub and docker, `ci(deps)` for github-actions).

**Acceptance criteria:**
- [ ] The slice PR into `dev` shows `flutter` green; job time and cache hits recorded in REVIEW (AC-OPS-4, `flutter` half)
- [x] `ci.yml` meets AC-OPS-12: `contents: read`, and no `secrets.` anywhere
- [ ] Throwaway PRs, closed unmerged, fail at the right step:
  - a mis-formatted file (AC-OPS-3)
  - the canary file, the title `update stuff`, and `uses: actions/checkout@v4` (AC-OPS-5)
- [ ] After the merge, GitHub lists the three Dependabot ecosystems (AC-OPS-13)

**Verification:**
- [ ] Read-only `gh pr checks` / `gh run view` on each PR
- [x] `sh tool/check_pins.sh` passes locally

**Dependencies:** Tasks 4, 5
**Files:** `.github/workflows/ci.yml`, `.github/dependabot.yml`, `Dockerfile`
**Scope:** S

### Checkpoint 2
- [ ] Tasks 4–6 verified; the slice PR is green; throwaway PRs closed
- [ ] REVIEW → you commit, open the PR, squash-merge once green
- [ ] You make `flutter` a required check in both rulesets

---

## Slice 3: `feat/devops-supabase`

> Before Task 7 (you): install Supabase CLI 3.2.0 (Claude gives the download and checksum commands for `~/.local/bin`).

### Task 7: `supabase init`, `config.toml`, empty seed, RLS and view guard test

**Description:**
- **`supabase init`** with the v3 CLI; Claude checks every command and key against `--help` and the generated file first.
- **`config.toml`:**
  - `project_id = "wheres-my-money-tracker"`
  - `[auth] site_url = "http://localhost:3000"`, with that URL in `additional_redirect_urls`
  - `[local_smtp]` as generated
  - nothing secret: only `env()` references, and none needed yet
- **`supabase/seed.sql`:** empty, with a comment: made-up data only.
- **`supabase/tests/000_rls_guard.test.sql`** (pgTAP):
  - no table in `public` has RLS disabled
  - no view in `public` lacks `security_invoker=true`
  - when either fails, the output names the offender
- **Advisors:** find out whether `supabase db advisors` can fail on findings. If it can, it joins the `rules` job; if not, Claude reports that and it stays a manual check.

**Acceptance criteria:**
- [ ] `supabase start`, `supabase db lint` and `supabase test db` are green
- [ ] A throwaway local migration with a `public` table without RLS makes the guard fail (AC-OPS-6, local half); the same for a plain view; both deleted afterwards
- [ ] `supabase db advisors` output (or why it's skipped) recorded in REVIEW

**Verification:**
- [ ] `supabase start`, `supabase db reset`, `supabase db lint`, `supabase test db`, `supabase stop`
- [ ] Both secret scans print nothing

**Dependencies:** Checkpoint 2
**Files:** `supabase/config.toml`, `supabase/seed.sql`, `supabase/tests/000_rls_guard.test.sql`, `supabase/.gitignore` (generated)
**Scope:** S

### Task 8: `ci.yml` job `rules`

**Description:** Job `rules` (`ubuntu-latest`, `timeout-minutes: 20`):
1. checkout
2. `supabase/setup-cli` with `version: 3.2.0`
3. `supabase start`, excluding services the tests don't use (names checked with `--help`)
4. `supabase db lint`
5. `supabase db advisors`, if Task 7 kept it
6. `supabase test db`

There's no integration step yet (plan.md).

**Acceptance criteria:**
- [ ] The slice PR shows `flutter` and `rules` green (AC-OPS-4 complete; AC-OPS-6, CI half)
- [ ] `rules` job time recorded
- [ ] `check_pins.sh` passes with the new `uses:`

**Verification:**
- [ ] Read-only `gh pr checks` on the slice PR

**Dependencies:** Task 7
**Files:** `.github/workflows/ci.yml`
**Scope:** XS

### Checkpoint 3
- [ ] Tasks 7–8 verified
- [ ] REVIEW → PR → squash-merge once green
- [ ] You make `rules` a required check in both rulesets

---

## Slice 4: `feat/devops-android`

> Before Task 9 (you): generate the upload keystore with `keytool` outside the repo, back it up in your password manager, and write `android/key.properties` (git-ignored). Claude gives the commands; you choose the passwords.

### Task 9: debug network security config and release signing

**Description:**
- **Debug only:**
  - `android/app/src/debug/res/xml/network_security_config.xml` allows cleartext only for `127.0.0.1` and `localhost`
  - the debug `AndroidManifest.xml` points `<application android:networkSecurityConfig>` at it
- **`android/app/build.gradle.kts` release signing:**
  - reads `android/key.properties` if it exists, otherwise the env vars `ANDROID_KEYSTORE_PATH`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS` and `ANDROID_KEY_PASSWORD`
  - with neither, release signing stays unset, so a release APK can never be signed with the debug key
  - debug builds never read either
- The `TODO` template comments go.

**Acceptance criteria:**
- [ ] The merged debug manifest references the config; the merged release manifest has no `networkSecurityConfig` and no `usesCleartextTraffic`; nothing under `src/main` or `src/release` allows cleartext (AC-OPS-9)
- [ ] With `key.properties`, `flutter build apk --release` produces an APK that `apksigner verify --print-certs` shows signed with the upload certificate, not the debug one
- [ ] Without `key.properties` and the env vars, the release build does not produce a debug-signed APK
- [ ] `docker build --target ci .` stays green (debug build, no key)

**Verification:**
- [ ] `flutter build apk --release`, then `~/Android/Sdk/build-tools/36.0.0/apksigner verify --print-certs build/app/outputs/flutter-apk/app-release.apk`
- [ ] `grep -r cleartext android/app/src/main android/app/src/release` prints nothing
- [ ] The scans print nothing; in particular, scan 2 doesn't list `key.properties`

**Dependencies:** Checkpoint 3
**Files:** `android/app/build.gradle.kts`, `android/app/src/debug/AndroidManifest.xml`, `android/app/src/debug/res/xml/network_security_config.xml`
**Scope:** S

### Checkpoint 4
- [ ] Task 9 verified
- [ ] REVIEW → PR → squash-merge once green

---

## Slice 5: `feat/devops-delivery`

> Before Task 10 (you), with steps from Claude:
> - create the free Supabase projects (staging, production) in the region closest to you and your family
> - create a scoped Supabase access token limited to those two projects
> - create the GitHub environments:
>   - `staging`: deployment branch `dev`; secrets `SUPABASE_ACCESS_TOKEN`, `SUPABASE_PROJECT_REF`, `SUPABASE_DB_PASSWORD`
>   - `production`: required reviewer you; deployment branch `main` and tags `v*`; the same three secrets plus the four `ANDROID_*` secrets
> - send Claude each project's URL and publishable key (public values)

### Task 10: real `config/staging.json` and `prod.json`, plus `deploy-db.yml`

**Description:**
- **Config:** fill both files with the real project URL and publishable key.
- **`.github/workflows/deploy-db.yml`:**
  - on `push` to `dev` and `main`; `permissions: contents: read`
  - one job whose `environment` is `staging` on `dev` and `production` on `main`
  - `concurrency` per environment, never cancelling a running deploy
  - steps: checkout, `supabase/setup-cli` 3.2.0, then `supabase db push --remote="$SUPABASE_PROJECT_REF" --yes`, with the token and database password as env vars
  - the exact flags are checked against `supabase db push --help` (v3.2.0) first

**Acceptance criteria:**
- [ ] The config files hold only public values, and the scans print nothing
- [ ] After the slice merges, `deploy-db` runs against staging and succeeds (AC-OPS-10, staging half)
- [ ] `deploy-db.yml` meets AC-OPS-12, and `check_pins.sh` passes

**Verification:**
- [ ] Read-only `gh run list --workflow deploy-db.yml` / `gh run view` after the merge
- [ ] The staging dashboard's migration history shows no migrations yet

**Dependencies:** Checkpoint 4, plus your setup above
**Files:** `config/staging.json`, `config/prod.json`, `.github/workflows/deploy-db.yml`
**Scope:** XS

### Task 11: `release.yml`

**Description:**
- **Trigger and job:** on `push` of tags `v*`; job `release` in `environment: production`, with `permissions: contents: write`.
- **Steps:**
  1. checkout; setup-buildx
  2. build the `toolchain` image (GHA cache, the runner's UID/GID, `load: true`)
  3. decode `ANDROID_KEYSTORE_BASE64` to `$RUNNER_TEMP/upload.jks`
  4. `docker run` the toolchain with the repo and the keystore mounted read-only and the signing values as env vars:
     - `flutter build apk --release --build-number=$GITHUB_RUN_NUMBER --dart-define-from-file=config/prod.json` (`staging.json` for `-rc.N` tags)
     - `apksigner verify` on the result
  5. build `build-web` with the matching `APP_ENV` and a local output, then zip it to `web.zip`
  6. `gh release create "$GITHUB_REF_NAME" --draft` with `app-release.apk` and `web.zip`
  7. an `always()` step deletes the keystore file
- Secrets are never echoed; no step runs with `set -x`.

**Acceptance criteria:**
- [ ] A throwaway tag `v0.0.0-rc.1` waits for your approval, then produces a draft release with both files; `apksigner verify --print-certs` on the downloaded APK shows the upload certificate. The draft and the tag are deleted afterwards
- [ ] `release.yml` meets AC-OPS-12 (`contents: write` only on this job), and `check_pins.sh` passes

**Verification:**
- [ ] Read-only `gh release view v0.0.0-rc.1` and `gh run view`
- [ ] `apksigner verify --print-certs app-release.apk` locally on the downloaded file

**Dependencies:** Task 10
**Files:** `.github/workflows/release.yml`
**Scope:** S

### Checkpoint 5
- [ ] Tasks 10–11 verified
- [ ] REVIEW → PR → squash-merge once green; staging deploy observed

---

## Stage close

### Task 12: Stage 0 close

**Description:**
- **Claude:**
  - runs `flutter pub outdated` and checks the Flutter, base-image, Action and Supabase CLI pins against the latest releases, recording deferred findings below with a reason and a review date
  - walks the security review over `git diff main...dev`
  - re-runs AC-OPS-8 with the keystore setup in place
  - ticks the AC-OPS boxes with evidence in REVIEW
  - writes the stage PR (merge commit), the tag commands and the rollback note
- **You:**
  - merge `dev` → `main` with a merge commit, and approve the production deploy
  - push the tag `v0.0.0` and approve the release
  - publish the draft and install the APK on your phone with `adb install -r`
  - confirm the keystore backup exists
- **Claude checks with read-only calls:** rulesets (AC-OPS-14), Dependabot (AC-OPS-13), the production deploy run (AC-OPS-10), the release assets (AC-OPS-11).

**Acceptance criteria:**
- [ ] AC-OPS-1 to AC-OPS-14 all pass, each with its evidence named in REVIEW
- [ ] `v0.0.0` is published with a signed APK and `web.zip`, and the APK runs on your phone
- [ ] Deferred findings recorded

**Dependencies:** Checkpoint 5
**Files:** `.claude/specs/SPEC.md` and `SPEC-devops.md` (ticks, Known Issues), `.claude/tasks/todo.md`, `.claude/specs/REVIEW.md`
**Scope:** S

### Checkpoint 6: Stage 0 done
- [ ] Every AC-OPS ticked with evidence
- [ ] `main` and `dev` both require `flutter` and `rules`
- [ ] Next: Stage 1 (`app-foundation`) planning, when you ask for it

---

## Deferred findings

None yet.
