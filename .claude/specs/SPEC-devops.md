# Module Spec: `devops`

> Depends on: — · Used by: every module · Delivery: Stage 0 (`v0.0.0`)
> Status: draft, awaiting review

## Objective

Make the repo reproducible and gated before any feature code exists:
- one Docker toolchain shared by the laptop and CI
- required CI checks
- a local Supabase project
- staging and production environments with automatic migration deploys
- tag-driven releases
- pinned supply chain

The app itself stays the `flutter create` template in this stage.

## Scope

**In**
- **Toolchain pin:**
  - `pubspec.yaml` `environment: flutter: 3.47.6`, so `flutter pub get` refuses any other Flutter version
  - the Dockerfile's `ARG FLUTTER_VERSION=3.47.6` must match; a mismatch fails `pub get` inside Docker, so the pin checks itself
  - `version: 0.0.0+1`
- **Docker:**
  - `Dockerfile` stages:
    - **`toolchain`:** `ubuntu:24.04` pinned by digest; OpenJDK 21 from apt; Flutter cloned at the `FLUTTER_VERSION` tag from `github.com/flutter/flutter` and checked against `FLUTTER_COMMIT`; Android command-line tools from `dl.google.com`, checked against a pinned SHA-256; platform and build-tools preinstalled; a non-root user whose UID/GID come from build args
    - **`ci`:** from `toolchain`; copies the repo and runs: `flutter pub get --enforce-lockfile` → `dart format --output=none --set-exit-if-changed .` → `flutter analyze --fatal-infos` → `flutter test --coverage --exclude-tags integration` → `tool/check_coverage.sh 80` → `flutter build web` → `flutter build apk --debug`
    - **`ci-report`:** `FROM scratch` holding `coverage/lcov.info`, so CI exports coverage from the same build
    - **`build-web`:** `flutter build web --release --no-web-resources-cdn --dart-define-from-file=config/APP_ENV.json` (`APP_ENV` = `staging` or `prod`); CanvasKit is served from the image, so the CSP can stay `'self'`
    - **`web`:** `nginxinc/nginx-unprivileged:stable-alpine` pinned by digest, port 8080; `docker/nginx.conf` falls back to `index.html` for unknown paths (go_router) and sends `Content-Security-Policy` (with `frame-ancestors 'none'`), `X-Content-Type-Options: nosniff` and `Referrer-Policy: strict-origin-when-cross-origin`
  - `.dockerignore` keeps secrets and machine-local files out, so the build context matches a fresh clone: `.git`, `.dart_tool/`, `build/`, `coverage/`, `.idea/`, `.claude/`, `config/local.json`, `**/.env`, `**/.env.*` (except `.env.example`), `supabase/.temp/`, `**/key.properties`, `android/local.properties`, `android/.gradle/`, `android/gradlew`, `android/gradlew.bat`, `android/gradle/wrapper/gradle-wrapper.jar`, `**/*.jks`, `**/*.keystore`, `**/*.p12`, `**/*.pem`, `**/*.key`, `ios/`, `macos/`, `linux/`, `windows/`
- **Scripts** in `tool/` (the same scripts run locally and in CI):
  - `secret_scan.sh`: both scans from dev_rules §9; exits non-zero on any hit and prints file names only
  - `check_coverage.sh MIN`: reads `coverage/lcov.info`, excludes generated l10n, fails below MIN%
  - `check_pins.sh`: fails if any workflow `uses:` isn't pinned to a 40-character SHA, any `FROM` isn't pinned by digest, or the Dockerfile's `FLUTTER_VERSION` differs from the pubspec pin
- **CI** `.github/workflows/ci.yml`:
  - triggers: `pull_request` to `dev`/`main`, plus pushes to them
  - `permissions: contents: read`, no secrets
  - **Job `flutter`:**
    - `docker buildx build --target ci` with GitHub Actions layer cache; coverage exported as an artifact
    - `tool/secret_scan.sh`, `tool/check_pins.sh`
    - PR-title Conventional Commits check, a shell regex on the title: `^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\([a-z0-9-]+\))?!?: .+`
    - `docker build --target web --build-arg APP_ENV=staging`, then a smoke test with `curl`: `/` and `/journal/42` return 200 with the headers above
  - **Job `rules`:**
    - Supabase CLI 3.2.0 on the runner → `supabase start` → `supabase db lint` → `supabase db advisors` (if it can fail on findings, decided in Stage 0) → `supabase test db`
    - when `test/integration/` exists: `flutter test --tags integration` inside the `toolchain` image with `--network host` (added by the first module that has integration tests)
- **Local Supabase project** from `supabase init`:
  - `supabase/config.toml`: project id `wheres-my-money-tracker`; auth `site_url` `http://localhost:3000`, with that URL in the redirect allow list; local emails go to `[local_smtp]` (the CLI v3 name)
  - `supabase/seed.sql` (empty for now)
  - `supabase/tests/000_rls_guard.test.sql`: fails if any table in `public` has RLS disabled, or any view in `public` lacks `security_invoker = true`
- **Environments and config:**
  - `config/local.example.json` (placeholders), `config/staging.json` and `config/prod.json` (public URL + publishable key, filled once the projects exist)
  - keys: `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY` (`auth` adds `GOOGLE_WEB_CLIENT_ID`)
  - `.gitignore` is Flutter's app template plus:
    - `config/local.json`
    - `.env` and `.env.*`, except `.env.example` (the Supabase CLI v3 reads env files from both `supabase/` and the root)
    - `key.properties`, `*.jks`, `*.keystore`, `*.p12`, `*.pem`, `*.key`
    - `.claude/specs/REVIEW.md`, the per-slice handoff
- **CD** `.github/workflows/deploy-db.yml`:
  - push to `dev` → `supabase db push --remote=PROJECT_REF --yes` with environment `staging` (CLI v3: no `link` step, and changes to a hosted project need `--yes`)
  - push to `main` → the same with environment `production` (required reviewer: the developer)
  - secrets are scoped to those environments
- **Release** `.github/workflows/release.yml`, on a tag `v*` pushed by the developer, in the `toolchain` image. The job runs in environment `production`, so it waits for the developer's approval before the signing secrets are used:
  - `flutter build apk --release --build-number=RUN_NUMBER --dart-define-from-file=config/prod.json` (`staging.json` for tags ending in `-rc.N`), signed with the upload key passed as a BuildKit secret or step env, never a layer
  - the `build-web` output zipped
  - both attached to a **draft** GitHub Release for the developer to publish
- **Android:**
  - `android/app/build.gradle.kts` release `signingConfig` reads `key.properties` locally or env vars in CI; a debug build never needs them
  - `android/app/src/debug/` network security config allows cleartext only to `127.0.0.1` and `localhost`, for `adb reverse` to the local stack
  - nothing under `src/main` or `src/release` allows cleartext
- **Dependabot** `.github/dependabot.yml`: `pub`, `github-actions` and `docker`, weekly, one dependency per PR.

**Developer setup outside the repo** (Claude gives the exact commands; the developer runs them):
- install the Supabase CLI and Android platform-tools
- create the hosted projects `wmmt-staging` and `wmmt-production` (free plan) and copy their URL and publishable key into `config/staging.json` and `config/prod.json`
- create a scoped Supabase personal access token for CI
- generate the Android upload keystore with `keytool`, kept outside the repo and backed up in a password manager; losing it means family phones must uninstall and reinstall, since app data lives on the server
- create GitHub environments `staging` (deployment branch `dev`) and `production` (deployment branch `main` and tags `v*`, with a required reviewer) and their secrets:
  - per environment: `SUPABASE_ACCESS_TOKEN`, `SUPABASE_PROJECT_REF`, `SUPABASE_DB_PASSWORD`
  - in `production` only, for the release job: `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`
- rulesets (created 2026-11-19 without checks; `flutter` is added once it's green in Slice 2, `rules` in Slice 3):
  - `Dev PR`: PR required, squash only, checks `flutter` + `rules`, no force-push or deletion
  - `Main PR`: PR required, merge commits allowed, the same checks, no force-push or deletion

**Out:**
- app code beyond the template (`app-foundation`)
- tables and migrations other than the RLS guard
- Google, SMTP and auth hook config (`auth`)
- web hosting, publishing images to a registry, Play Store tracks

## Interface exposed to other modules

- **Check names:** `flutter` and `rules`. Rulesets depend on these names, so they never change.
- **Test tag:** `integration` marks repository tests that need the local stack; they run in `rules`.
- **Config contract:** `AppConfig` reads `SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY` (plus `GOOGLE_WEB_CLIENT_ID` from Stage 2, added by `auth`) from `--dart-define-from-file=config/ENV.json`. New keys are added to all three config files in the same slice.
- **Migrations:** every module adds SQL under `supabase/migrations/` and pgTAP under `supabase/tests/`. Merging to `dev` deploys to staging; the stage merge to `main` deploys to production after approval.
- **Scripts:** `tool/secret_scan.sh` is the dev_rules gate scan, and modules don't duplicate it.

## Security

- **Trust boundaries:** GitHub Actions (public repo, PRs from forks possible), GitHub environment secrets, the Supabase hosted projects, Docker images.
- **Controls:**
  - PR workflows use `pull_request`, never `pull_request_target`, and get no secrets
  - secrets exist only in the `staging` and `production` environments, which accept only `dev`, `main` and `v*` tags; the release job runs in `production`
  - production needs the developer's approval
  - Actions are pinned by SHA and base images by digest
  - `.dockerignore` and BuildKit secrets keep secrets out of image layers
- **Abuse cases:**
  - a fork PR edits a workflow to print secrets → there are none to print
  - a moved Action tag or image tag brings in new code → SHA and digest pins, enforced by `check_pins.sh`
  - a key is committed or baked into an image → `secret_scan.sh` in CI, plus AC-OPS-8

## Acceptance criteria

1. **AC-OPS-1:** changing `environment: flutter` in `pubspec.yaml` to another version makes `flutter pub get` fail locally and in `docker build --target ci .`.
2. **AC-OPS-2:** `docker build --target ci .` passes on a clean checkout.
3. **AC-OPS-3:** a deliberately mis-formatted Dart file fails `docker build --target ci .` at the format step, locally and in CI (throwaway PR, closed unmerged).
4. **AC-OPS-4:** a PR to `dev` runs `flutter` and `rules`, and both are green.
5. **AC-OPS-5:** throwaway PRs (closed unmerged) prove three failures:
   - a canary file containing one of the first secret scan's plain-word patterns (dev_rules §9) fails `flutter` at the secret scan (a key-shaped fake could be blocked by GitHub push protection before CI sees it)
   - the PR title `update stuff` fails the title check
   - an unpinned `uses: actions/checkout@v4` fails `check_pins.sh`
6. **AC-OPS-6:** `supabase test db` passes locally and in `rules`. A local, uncommitted migration that creates a `public` table without RLS, or a `public` view without `security_invoker`, makes the guard test fail.
7. **AC-OPS-7:** the `web` image runs as a non-root user. `GET /` and `GET /journal/42` both return 200 with `index.html`, and both responses carry the three security headers (CI smoke test).
8. **AC-OPS-8:** with a dummy `config/local.json`, `android/key.properties` and `supabase/.env` in the working tree, none of them appears in any image stage (`find` inside the `ci` and `web` images), and `docker history` shows no secret values.
9. **AC-OPS-9:** the debug network security config allows cleartext only to `127.0.0.1` and `localhost`. `src/main` and `src/release` contain no cleartext permission and no `usesCleartextTraffic`.
10. **AC-OPS-10:** a push to `dev` runs `deploy-db` against staging and succeeds. A push to `main` waits for approval on `production`, then succeeds.
11. **AC-OPS-11:** pushing tag `v0.0.0` waits for approval on `production`, then creates a draft release with `app-release.apk` and `web.zip`. `apksigner verify --print-certs` shows the upload certificate. The APK installs with `adb install -r` over the previous build on the phone.
12. **AC-OPS-12:** every workflow declares `permissions: contents: read` (or narrower, except the release job's `contents: write`). No `pull_request` job references `secrets.`.
13. **AC-OPS-13:** GitHub shows Dependabot active for `pub`, `github-actions` and `docker`.
14. **AC-OPS-14:** a read-only `gh api repos/DanMau1410/wheres_my_money_tracker/rulesets` shows both rulesets with the required checks. `Main PR` allows merge commits.

## Tests

- CI itself: AC-OPS-2, AC-OPS-4, AC-OPS-7.
- Throwaway PRs, recorded in `REVIEW.md`: AC-OPS-3, AC-OPS-5.
- `supabase/tests/000_rls_guard.test.sql`: AC-OPS-6.
- Manual, recorded in `REVIEW.md`: AC-OPS-1, AC-OPS-8, AC-OPS-9, AC-OPS-10, AC-OPS-11, AC-OPS-13.
- Read-only `gh` calls: AC-OPS-12 (workflow files), AC-OPS-14.

## Open questions

1. ~~Supabase CLI version to pin~~ **3.2.0**, the latest stable on 2026-11-19; its v3 command changes are folded into this spec.
2. The hosted project names `wmmt-staging` / `wmmt-production` are a proposal. Any names work, since only the project refs go into secrets.
