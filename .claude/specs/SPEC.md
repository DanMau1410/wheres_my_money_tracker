# Spec: Where's My Money Tracker

> Status: **draft 4, awaiting approval** · Last updated: 2026-11-19
> This is the project-wide spec and the index of the module specs (see [Capability Map](#capability-map)).
> It's a living document: update it before changing any decision it records. Module details live in each `SPEC-MODULE.md`.

## Objective

A personal finance tracker built on **double-entry bookkeeping**. It replaces the developer's spreadsheets (`Accounting.xlsx` for the account structure, `Gastos.xlsx` for how entries are posted).

In the spreadsheets, every transaction is copied by hand into two or more account tables, and the self-test is `Total Debit = Total Credit`. In the app, a transaction is **one journal entry with N lines**, and the database refuses any entry that doesn't balance. The self-test becomes a rule that can't be broken, and balances are always calculated from the entries, so there's no monthly carry-forward to drift.

**Users:** the developer and family members. Each person creates their own account and sees only their own data. The data is detailed personal financial information, so security matters as much as the features.

**Platforms in v1:**
- **Web:** runs locally, opened in Chromium. Hosting is not decided yet.
- **Android:** debug builds go to the developer's own phone. Family members get release builds installed from the developer's laptop over USB debugging.
- iOS, macOS, Linux and Windows aren't built, tested or supported in v1.

**Engineering principle:** DevOps comes first. CI/CD, environments, checks and the Docker toolchain are Stage 0, built before any feature, and every later change goes through them. The same Docker image runs the quality gate on the laptop and in CI.

**User stories (v1)**

1. As a family member, I create my own account with email and password (confirmed with a 6-digit code), or with Google. Only people the developer allowed can create accounts.
2. As a user, I sign in, sign out, reset a forgotten password with a code, and change my password.
3. As a user, I start with a default chart of accounts and add my own bank, wallet and card accounts.
4. As a user, I record a transaction as a dated entry with a description and 2 or more lines, each line a debit or a credit to one account. I can't save it until debits equal credits.
5. As a user, I fix mistakes by editing or deleting an entry.
6. As a user, I see a balance page laid out like `Accounting.xlsx`, either **all-time** or for **one month**. I pick which view opens by default, and that choice follows me between web and phone.
7. As a user, I open one account and see every line posted to it.
8. I can use the app in English or Spanish.

**Success looks like:** see [Success Criteria](#success-criteria).

## Tech Stack

| Piece | Choice | Notes |
|---|---|---|
| Flutter / Dart | Flutter 3.47.6 stable, Dart `^3.13.5` | pinned in `pubspec.yaml` (`environment: flutter`), the Dockerfile and CI |
| Backend | Supabase (Postgres, Auth, Data API) | local stack + two hosted free-plan projects (staging, production) |
| `supabase_flutter` | `^2.18.3` | publisher `supabase.io` (verified), MIT. The changelog announced v3 on 2026-11-06 but pub.dev still lists 2.18.3 as latest, so re-check in Stage 1 |
| `provider` | `^6.1.5+1` | publisher `dash-overflow.net` (verified), Flutter Favorite, MIT; dependency injection, as the Flutter guide recommends |
| `go_router` | `^18.1.4` | publisher `flutter.dev` (verified), BSD; routes, auth redirect, web URLs |
| `google_sign_in` | `^7.2.0` | publisher `flutter.dev` (verified), BSD; native Google sign-in on Android |
| Localization | `flutter_localizations` (SDK) + `intl: any` | gen-l10n from `lib/l10n/app_en.arb`, `app_es.arb`; `intl` also formats money and dates |
| API key | publishable key (`sb_publishable_…`) | legacy `anon`/`service_role` keys are being retired by the end of 2026 |
| Lints | `flutter_lints` | analyzed with `--fatal-infos` |
| DB tests | pgTAP via `supabase test db` | `supabase/tests/` |
| Supabase CLI | 3.2.0 + Docker | pinned in CI through `supabase/setup-cli`; v3 targets the local stack by default (`--remote=REF` for hosted projects); check commands with `--help` |
| Email | Gmail SMTP with an app password | v1; Resend or Brevo later |
| Docker toolchain | `ubuntu:24.04` + OpenJDK 21 + Flutter 3.47.6 + Android command-line tools | official sources, pinned; JDK 21 suits the project's AGP 9.1 / Gradle 9.3.1 |
| Docker web server | `nginxinc/nginx-unprivileged:stable-alpine` | non-root, pinned by digest |
| CI/CD | GitHub Actions + Dependabot | see [SPEC-devops.md](SPEC-devops.md) |
| Actions | `actions/checkout` v7.0.1, `docker/setup-buildx-action` v4.4.1, `docker/build-push-action` v7.4.0, `actions/upload-artifact` v7.0.2, `supabase/setup-cli` v3.2.0 | official publishers, pinned by commit SHA (approved 2026-11-19) |

No `freezed`, `shared_preferences` or mocking packages in v1. Anything else needs asking first (dev_rules §7).

## Commands

The developer runs these in fish. Prerequisites: Docker (installed), the Supabase CLI and Android platform-tools (`adb`). Stage 0 gives the install commands.

Setup:
```fish
flutter pub get
```
```fish
supabase start
```
```fish
supabase db reset
```
```fish
supabase status
```

Quality gate (same checks as CI):
```fish
docker build --target ci .
```
```fish
supabase test db
```
```fish
flutter test --tags integration
```

Run (dev). Web (then open `http://localhost:3000` in Chromium), on the host or in the toolchain container:
```fish
flutter run -d web-server --web-port=3000 --dart-define-from-file=config/local.json
```
```fish
docker build --target toolchain --build-arg UID=(id -u) --build-arg GID=(id -g) -t wmmt-toolchain .
```
```fish
docker run --rm -it --network host -v (pwd):/app -w /app wmmt-toolchain flutter run -d web-server --web-port=3000 --dart-define-from-file=config/local.json
```

Phone (debug, against the local stack):
```fish
adb reverse tcp:54321 tcp:54321
```
```fish
flutter devices
```
```fish
flutter run -d DEVICE_ID --dart-define-from-file=config/local.json
```

Build:
```fish
docker build --target web --build-arg APP_ENV=staging -t wmmt-web .
```
```fish
docker run --rm -p 8080:8080 wmmt-web
```
```fish
adb install -r app-release.apk
```

Stop:
```fish
supabase stop
```

## Project Structure

Follows the Flutter guide's case-study layout.

```
lib/
  main.dart                   → reads config, initializes Supabase, MultiProvider, runApp
  config/                     → app_config.dart (dart-defines), dependencies.dart (provider list)
  domain/models/              → immutable models (no Flutter, no Supabase imports)
  data/services/              → stateless SDK wrappers (Supabase, Google Sign-In)
  data/repositories/          → abstract repositories + Supabase implementations (rows ↔ models)
  ui/core/                    → app shell, theme, shared widgets
  ui/FEATURE/view_models/     → FEATURE_view_model.dart
  ui/FEATURE/widgets/         → FEATURE_screen.dart and its widgets
  routing/                    → go_router config, route paths, auth redirect
  utils/                      → result.dart, command.dart, money.dart, dates.dart
  l10n/                       → app_en.arb, app_es.arb
test/                         → mirrors lib/; test/integration/ is tagged `integration`
testing/                      → fakes/ and the testApp helper shared by tests
supabase/
  config.toml                 → local stack (auth hook, Google provider, email templates)
  migrations/                 → hand-written SQL, created with `supabase migration new NAME`
  seed.sql                    → made-up local data and test users only
  templates/                  → auth email templates (6-digit code, English + Spanish)
  tests/                      → pgTAP
config/                       → local.example.json, staging.json, prod.json (local.json is git-ignored)
android/app/src/debug/        → debug-only network security config (cleartext to localhost)
Dockerfile, .dockerignore     → stages: toolchain, ci, build-web, web
docker/nginx.conf             → web server: SPA fallback + security headers
.github/                      → workflows/ (ci, deploy-db, release), dependabot.yml
.claude/specs/                → SPEC.md (this file), SPEC-MODULE.md, REVIEW.md (git-ignored per-slice handoff)
.claude/tasks/                → plan.md, todo.md
```

## Architecture

MVVM following Flutter's official guide (docs.flutter.dev/app-architecture).

- **Layers:**
  - View → ViewModel → Repository → Service. Each layer knows only the one below it, and data flows one way.
  - Views hold no logic beyond layout and simple flags.
  - ViewModels keep their repositories private.
- **Views** get their ViewModel through the constructor and rebuild with `ListenableBuilder`.
- **ViewModels** extend `ChangeNotifier`:
  - They expose state through getters (lists as `UnmodifiableListView`).
  - User actions are **Commands** (`Command0`/`Command1`, with `running`/`error`/`completed`).
- **Repositories** are abstract classes with a Supabase implementation (`ThingRepositorySupabase`).
  - Each is the source of truth for its data and turns rows into domain models.
  - They never know about each other. When one needs another's changes, a ViewModel listens to both.
- **Services** are stateless wrappers over external SDKs (`SupabaseClient`, `GoogleSignIn`).
- **Errors:** services and repositories return `Result<T>` (sealed `Ok`/`Error`), and ViewModels `switch` on it. No exception crosses a layer boundary. Each module defines its failure enum, and every value maps to an arb message.
- **Dependency injection:** `MultiProvider` at the root, in `lib/config/dependencies.dart`. ViewModels are built in `GoRoute` builders with `context.read()`. Each module adds its providers and routes.
- **Domain:**
  - Models are immutable, hand-written `final class`es (no code generation).
  - No use-case layer in v1. The guide makes it optional, and no logic merges repositories.

## Code Style

Dart follows `flutter_lints` (with `--fatal-infos`) and `dart format`. Files use `snake_case.dart` and types use `PascalCase`. ViewModels are named `FeatureViewModel`, screens `FeatureScreen`, repositories `ThingRepository` with `ThingRepositorySupabase` implementations, and fakes `FakeThingRepository`. `dynamic` is allowed only where repositories parse rows. Comments explain *why*, never *what*.

```dart
class EntryEditorViewModel extends ChangeNotifier {
  EntryEditorViewModel({required JournalRepository journalRepository})
      : _journalRepository = journalRepository {
    save = Command0<int>(_save);
  }

  final JournalRepository _journalRepository;
  late final Command0<int> save;

  final List<LineDraft> _lines = [const LineDraft(), const LineDraft()];
  UnmodifiableListView<LineDraft> get lines => UnmodifiableListView(_lines);

  int get debitCents => _lines.fold(0, (sum, l) => sum + l.debitCents);
  int get creditCents => _lines.fold(0, (sum, l) => sum + l.creditCents);

  // The database enforces the same rule; this only drives the Save button.
  bool get canSave =>
      _lines.length >= 2 && debitCents > 0 && debitCents == creditCents;

  Future<Result<int>> _save() => _journalRepository.saveEntry(_toEntry());
}
```

SQL is lowercase with `snake_case` plural table names. Policies name the role and compare the owner with the cached uid:

```sql
create policy "owner reads accounts" on public.accounts
  for select to authenticated
  using ((select auth.uid()) = user_id);
```

UI strings come only from `AppLocalizations`. Users see generic error messages from the arb files. Raw `PostgrestException` and `AuthException` text goes only to debug logs.

## Testing Strategy

| Level | Tool, location | Covers |
|---|---|---|
| Domain / utils unit | `flutter test`, `test/domain/`, `test/utils/` | parsers, validation, models; abuse-case input tables |
| ViewModel unit | `flutter test`, `test/ui/`, with fakes from `testing/fakes/` | state changes, commands, error mapping |
| Widget | `flutter test`, `test/ui/`, with the same fakes and `testApp` | screens render ViewModel state; EN/ES strings |
| Repository integration | `flutter test --tags integration`, `test/integration/` | each repository against the local stack, with seeded made-up users |
| Database | pgTAP, `supabase test db`, `supabase/tests/` | constraints, invariants, RLS deny-tests (dev_rules §9 list), functions, triggers, hooks |
| Manual | Chromium + the developer's phone | each module's manual ACs |

- **Coverage:** CI fails below 80% of lines in `lib/` (generated l10n excluded).
- **Traceability:** every acceptance criterion names its test, or is marked as manual.
- **Isolation:** tests never touch staging or production.

## Boundaries

Mirrors dev_rules §7 and §8; change both together. Security details are in dev_rules §9.

- **Always:**
  - run the quality gate before a handoff (the same steps as CI), plus both secret scans
  - put every UI string in `app_en.arb` and `app_es.arb`
  - keep schema changes additive
  - use integer cents for money
  - add RLS, grants and pgTAP tests in the same migration slice as each new table
  - follow MVVM layering (no Supabase calls outside `data/`)
  - keep the Flutter version the same in the Dockerfile, CI and the developer's machine
- **Ask first:**
  - adding a dependency (package, Docker image or GitHub Action) not in Tech Stack
  - data-model or RLS changes beyond this spec
  - any manual deploy to the staging or production Supabase projects (`supabase db push`, dashboard schema changes); the CD pipeline is the normal path
  - a paid Supabase plan or Edge Functions
  - new target platforms (anything beyond Web and Android)
  - weakening or removing a CI check, or changing workflow triggers or permissions
  - destructive data migrations (backup first)
- **Never:**
  - commit or bake into a Docker image the Supabase secret (`sb_secret_…`) or `service_role` key, the database password, the Gmail app password, the Google client secret, or tokens (the project URL and publishable key are fine to commit)
  - disable RLS or loosen a policy to `using (true)` / `with check (true)`
  - delete or skip failing tests
  - force-push `main`
  - point tests at the staging or production Supabase projects; test accounts exist only in the local Supabase stack

## Capability Map

Draft 2026-11-19, part of this spec's approval. Module ids are stable kebab-case: specs, plans, branches (`feat/MODULE-SLICE`) and commit scopes refer to them.

| Module id | Responsibility | Depends on | Spec |
|---|---|---|---|
| `devops` | Dockerfile, `.dockerignore`, CI (`flutter`, `rules`), CD (staging/production migrations), release workflow, Dependabot, environments and config files, local Supabase project, Android signing and debug cleartext config, RLS guard test | — | [SPEC-devops.md](SPEC-devops.md) |
| `app-foundation` | MVVM skeleton: Result, Command, config, Supabase init, provider wiring, go_router shell, theme, EN/ES l10n, shared vocabulary (money in cents, `AccountSection`, dates), test harness | devops | [SPEC-app-foundation.md](SPEC-app-foundation.md) |
| `auth` | email + password sign-up with a code, sign in, Google (Android + web), forgot/change password, sign out, sign-up allowlist hook, auth redirect | app-foundation | [SPEC-auth.md](SPEC-auth.md) |
| `accounts` | chart of accounts per user: table, RLS, default chart trigger, Accounts screen | auth | [SPEC-accounts.md](SPEC-accounts.md) |
| `journal` | entries and lines, the balance invariant, save function, Journal list, entry editor, per-account line queries | accounts | [SPEC-journal.md](SPEC-journal.md) |
| `balance` | all-time view, monthly function, Balance screen, Account ledger, default-view preference | journal | [SPEC-balance.md](SPEC-balance.md) |

**Build order:** `devops` → `app-foundation` → `auth` → `accounts` → `journal` → `balance`. Each module is one stage (see [Stages](#stages)).

**Out of scope for v1 (roadmap):**
- **v2:** convert the display to another currency.
- **v3:** multiple currencies; each line keeps its currency plus the exchange rate from its transaction date.
- **v4:** a live exchange-rate service refreshes rates on an interval; posted lines keep the rate from their date.
- **Later (unassigned):**
  - sub-accounts or categories under Income and Expenses
  - per-person A/R and A/P
  - automation for Monthly items
  - a transactional email provider (Resend or Brevo) on the app's own domain
  - web hosting and publishing the `web` image to a registry
  - iOS, macOS, Linux and Windows
  - self-service account deletion (Edge Function)
  - MFA and CAPTCHA (not documented for Flutter)
  - CSV export and spreadsheet import
  - custom date-range reports
  - offline mode
  - an in-app language switch (the app follows the device language)

## Data Model (Supabase)

Each object is owned by exactly one module, and that module's spec defines its columns, constraints, grants and policies.

| Object | Kind | Owner |
|---|---|---|
| `private.signup_allowlist` | table (not exposed) | auth |
| `private.before_user_created(event jsonb)` | Before User Created auth hook | auth |
| `public.accounts` | table | accounts |
| `private.seed_default_accounts(p_user_id uuid)`, `private.create_default_accounts()` | default chart; `after insert` trigger on `auth.users` | accounts |
| `public.journal_entries`, `public.journal_lines` | tables | journal |
| `private.check_entry_balanced()` | deferred constraint triggers | journal |
| `public.save_entry(…)` | `security invoker` function | journal |
| `public.account_totals` | view (`security_invoker = true`) | balance |
| `public.monthly_balance(p_month date)` | `security invoker` function | balance |
| `auth.users` `user_metadata.balance_period` | Auth metadata (display preference) | balance |

**Cross-module rules**
- **Ownership:**
  - every user-owned row has `user_id uuid not null default auth.uid() references auth.users on delete cascade`, and that column can't be changed
  - deleting the Auth user deletes everything (dev_rules §9)
- **Keys:** `bigint generated always as identity` primary keys. A child points to its parent with a composite foreign key that includes `user_id`, so a row can't reference another user's row.
- **Exposure:**
  - RLS on every `public` table, with policies `to authenticated` comparing `(select auth.uid())` with `user_id`
  - explicit grants for only what clients need (new tables aren't exposed by default)
  - `security definer` code lives only in `private`, which the Data API doesn't expose, and `anon`/`authenticated` can't execute it
  - the devops RLS guard test fails if any `public` table lacks RLS
- **Money:**
  - integer cents (`bigint` / Dart `int`) end to end, USD only in v1, never `double` or `numeric`
  - a line amount is between 1 and 99,999,999,999 cents
  - shown with the device locale's separators (`$1,234.56`)
- **Dates:** entry dates are Postgres `date` and `yyyy-MM-dd` on the wire (calendar days, no time zone), between 2000-01-01 and 2099-12-31. Timestamps are `timestamptz` set by the database (`now()`).
- **Sections:**
  - `asset`, `liability`, `equity`, `income`, `expense`
  - debit-normal: asset and expense; credit-normal: the rest
  - defined once in `app-foundation` (Dart) and as a `check` in `accounts` (SQL)
- **User switch:** any repository that caches rows clears them when the Supabase client's auth state reports a sign-out or a different user (repositories don't depend on each other).
- **Future versions** add columns, never rewrite them. v3 multi-currency adds currency and exchange-rate columns to `journal_lines`, defaulting to USD and 1.

**Data classification** (dev_rules §9; the details are in each module spec):
- **personal:** the auth email, the Google identity, allowlist emails
- **sensitive (financial):** account names, entry dates, descriptions and amounts; descriptions may name third parties
- **non-personal:** the `balance_period` display preference

No analytics, no crash reporting, and no financial data or emails in logs.

## DevOps & Delivery

**Goals:**
- **stable:** nothing reaches `dev` or `main` without green checks
- **backtrackable:** every merge and release can be reverted or rebuilt
- **reproducible:** the same toolchain and locked dependencies locally, in Docker and in CI

**Starting point (2026-11-19):**
- GitHub remote `origin` (public repo), branches `main` and `dev`
- rulesets `Dev PR` (squash only) and `Main PR` (merge commits only) require a PR, with no checks yet; no tags, no CI
- Flutter 3.47.6 locally; `pubspec.lock` was ignored by the repo's original `.gitignore` (`*.lock`), and Stage 0 commits it

The details (environments, Docker, CI, CD, release, supply chain) are in [SPEC-devops.md](SPEC-devops.md).

### Collaboration protocol

The working rules are in [`.claude/dev_rules.md`](../dev_rules.md):
- the developer owns every git and GitHub write
- one slice at a time, each ending in the `REVIEW.md` handoff
- squash into `dev` per slice, and a merge commit `dev` → `main` per stage

### Stages

| Stage | Tag | Module | Done when |
|---|---|---|---|
| 0 | `v0.0.0` | `devops` | every AC in SPEC-devops.md passes; rulesets require `flutter` and `rules` |
| 1 | `v0.1.0` | `app-foundation` | its ACs pass |
| 2 | `v0.2.0` | `auth` | its ACs pass; the first family member can sign up on staging |
| 3 | `v0.3.0` | `accounts` | its ACs pass |
| 4 | `v0.4.0` | `journal` | its ACs pass |
| 5 | `v0.5.0` | `balance` | its ACs pass |
| — | `v1.0.0` | — | every [Success Criterion](#success-criteria) passes on production |

**Module loop (each stage):**
1. Re-read the module spec. Open questions are answered before planning.
2. Claude writes `.claude/tasks/plan.md` and `todo.md` for that module, with a Security line per slice. The developer approves.
3. The developer creates `feat/MODULE-SLICE` off `dev`. Claude implements one slice that passes the gate and writes the `REVIEW.md` handoff. The developer reviews, commits, opens the PR, and squash-merges once CI is green. Merging to `dev` deploys migrations to staging.
4. At module end, Claude bumps `version: 0.STAGE.0+BUILD` and drafts the stage PR and tag commands. The developer merges `dev` → `main` (approving the production deploy) and tags `v0.STAGE.0`.
5. The tag builds the draft release (signed APK + web bundle). The developer publishes it and installs the APK where needed.

### Release & rollback

- **Code:** `git revert` the squash commit on `dev`. Any stage can be rebuilt exactly with `git checkout v0.N.0` then `docker build --target ci .`.
- **Database:**
  - migrations are additive, so older app versions keep working
  - a bad migration is fixed with a new forward migration, never by editing an applied one
  - before any destructive migration (ask first), the developer runs `supabase db dump --data-only` against that project and keeps the file outside the repo
- **Android:** rebuild the previous tag with a higher build number (`versionCode` must always increase).
- **Web:** not hosted in v1. The `web` image is rebuilt from any tag.

## Success Criteria

v1 is done (tag `v1.0.0`) when:

- [ ] Every module's acceptance criteria pass, each with its named test or recorded manual check.
- [ ] Two allowlisted users, one on Android (release build, production) and one on web, each see only their own data. pgTAP proves user B can't read or write user A's rows.
- [ ] Every entry pattern from `Gastos.xlsx` can be recorded. Both balance views always show Σ debit = Σ credit, and the database rejects any unbalanced entry, even through direct API calls.
- [ ] Every screen is fully usable in English and Spanish (no hard-coded strings).
- [ ] CI (`flutter`, `rules`) is required and green; coverage ≥ 80%; the secret scans print nothing; Dependabot is active; `docker build --target ci .` passes on a clean checkout.

## Known Issues

Deferred problems, each with what triggers its fix. Delete an entry when its fix merges.

- **KI-1: free-plan pausing.** Supabase pauses a free project after 7 days without activity, and restoring is manual in the dashboard. *Fix trigger:* family use is irregular enough to hit it. Options: a paid plan, or a scheduled keep-alive (ask first either way).
- **KI-2: Gmail as mail server.** Gmail allows about 500 emails a day and may land in spam. *Fix trigger:* any delivery problem, or the app gets its own domain. Then move to Resend or Brevo (ask first).
- **KI-3: tokens outlive deletion.** A deleted user's access token stays valid until it expires (about 1 hour). *Fix trigger:* self-service deletion (Edge Function) is added.

## Decisions log

| Date | Decision |
|---|---|
| 2026-11-19 | Supabase instead of Firebase; USD only in v1 (currency roadmap v2–v4); single Income/Expenses accounts; no per-person debts in v1 |
| 2026-11-19 | Web + Android only; Android tested on the developer's phone; family installs release APKs over USB; web runs locally for now |
| 2026-11-19 | Debug builds may use HTTP to the local stack (localhost only); release builds are HTTPS-only |
| 2026-11-19 | Balance: all-time and monthly views, with a per-user default |
| 2026-11-19 | Tags for every stage (`v0.0.0`, `v0.1.0`, …) plus full-version tags (`v1.0.0`) |
| 2026-11-19 | DevOps and Docker from Stage 0; MVVM (Flutter guide) with `provider` and `go_router` |
| 2026-11-19 | Self sign-up with email/password and Google, limited to an allowlist; Gmail SMTP app password for v1 emails |
| 2026-11-19 | Specs split into this project spec plus one spec per module; one module per stage |
| 2026-11-19 | Stage 0 plan: five pinned Actions and Supabase CLI 3.2.0; Android signing secrets in `production`, behind a required reviewer; each CI check is required as soon as it's green; `GOOGLE_WEB_CLIENT_ID` arrives with `auth` |
| 2026-11-20 | CI builds without the GitHub Actions layer cache: uploading it cost 5–11 min per run, while a runner rebuilds the toolchain in about 1.5 min |

## Open Questions

None at the project level. Each module spec lists its own, answered before that module is planned.
