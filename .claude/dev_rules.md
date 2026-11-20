# Dev rules: how the developer and Claude work together

"The developer" is the human who owns this repo. "Claude" means Claude or any other AI assistant working on it.
Sections 7 and 8 mirror the Boundaries in [SPEC.md](specs/SPEC.md#boundaries); change both together.

## 1. Git and GitHub belong to the developer

Only the developer:
- stages changes (`git add`)
- makes commits
- creates, renames and deletes branches, locally and on GitHub
- pushes
- opens PRs
- approves, requests changes on, or closes PRs
- merges PRs
- creates tags and GitHub Releases
- changes rulesets, branch protection and repo settings

Claude (or any other AI):
- only reads git and GitHub state: `git status`, `diff`, `log`, `show`, `fetch`, and read-only `gh api` / `gh pr list` / `gh pr view` calls
- never runs `git add`, `commit`, `push`, `merge`, `tag`, `switch -c`, `branch -d`, or `gh pr create`, `merge`, `review` or `comment`
- leaves every change uncommitted in the working tree
- writes the git and GitHub commands for the developer to run
- checks a GitHub step the developer reports as done with a read-only call before ticking its box, and says so if the result doesn't match

## 2. Branches and PRs

- Feature work goes on a branch off `dev`, then through a PR that is **squash-merged into `dev`**.
- At the end of a stage, a PR from `dev` to `main` is **merged with a merge commit**, and the developer tags it `v0.<stage>.0` (starting at `v0.0.0`). When a full version ships, it also gets its own tag (`v1.0.0`).
- The rulesets `Dev PR` and `Main PR` require a PR for every change, and `Main PR` allows merge commits. From the end of Stage 0 they also require the `flutter` and `rules` checks. Nothing merges while a check is red.
- Suggested branch names: `feat/<module-id>-<slice>` (e.g. `feat/app-foundation-domain`), `fix/…`, `docs/…`. The developer may choose another name; Claude reads the real one from git before writing cleanup commands.
- **When work is ready for a PR** (squash into `dev` or merge into `main`), Claude suggests:
  - a quick breakdown of what was done
  - a PR title
  - a PR description, ending with `🤖 Generated with [Claude Code](https://claude.com/claude-code)`
  - a name for the `--head` branch
  - the commands to create the branch, commit, push, open the PR, and clean up after the merge
- Claude reviews a PR and reports the findings in chat. It doesn't approve or comment on GitHub.

## 3. How work moves

- Spec → plan → tasks → code. Specs live in `.claude/specs/`, the plan in `.claude/tasks/plan.md`, the task list in `.claude/tasks/todo.md`.
- Claude plans a stage only when the developer asks, and implements nothing until the developer approves the plan.
- Claude never overwrites a plan that still has unfinished tasks without asking.
- When a decision recorded in a spec changes, the spec is updated first.
- One slice at a time. The next slice starts only after the developer has reviewed and merged the current one.
- Claude ticks a box only after checking it, and lists anything it could not verify.

## 4. The handoff at the end of every slice

In chat **and** in `.claude/specs/REVIEW.md` (overwritten each slice):
1. **What & why**: the slice, tied to its spec section and acceptance criteria.
2. **Files changed**: clickable paths grouped by layer, one line each.
3. **What to look for**: the few places that need human eyes, as `file:line`, plus anything uncertain.
4. **How to verify**: exact commands with expected results, manual steps, and what wasn't verified.
5. **Proposed commit message**: Conventional Commits with the module id as scope, ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
6. **PR handoff**: everything listed in section 2.

At the end of a stage, the handoff also gives the version bump in `pubspec.yaml`, the tag commands and a rollback note.

## 5. Quality bar

- Before handing over a slice, Claude runs the quality gate, the same steps as CI ([SPEC-devops.md](specs/SPEC-devops.md)): `docker build --target ci .`, which runs the format check, `flutter analyze --fatal-infos`, the tests with the coverage gate, `flutter build web` and `flutter build apk --debug`. When migrations, RLS policies or repositories change, it also runs `supabase test db` and `flutter test --tags integration` against the local stack.
- The Flutter version is the same in the Dockerfile, CI and the developer's machine.
- Every UI string goes in both `app_en.arb` and `app_es.arb`.
- Schema changes are additive only (new optional fields, and readers default the missing ones).

## 6. Commands Claude gives the developer

- The developer's shell is **fish**. Commands never contain `<angle-bracket>` placeholders. They use real values or UPPER_CASE names like `PROJECT_ID`.
- Each command goes in its own code block, so it can be copied and run alone.
- Command substitution uses fish syntax: `(pwd)`, `(id -u)`, never `$(...)`.
- Claude doesn't change the developer's machine (environment variables, `PATH`, system packages, anything that needs `sudo`). It gives the commands to run.

## 7. Ask first

- Adding a dependency (package, Docker image or GitHub Action) that isn't in SPEC.md's Tech Stack
- Data-model or RLS changes beyond the specs
- Any manual deploy to the staging or production Supabase projects (`supabase db push`, dashboard schema changes). The CD pipeline is the normal path
- A paid Supabase plan or Edge Functions
- New target platforms (anything beyond Web and Android)
- Weakening or removing a CI check, or changing workflow triggers or permissions
- Destructive data migrations, which also need a backup first

## 8. Never

- Commit, or bake into a Docker image, the Supabase secret (`sb_secret_…`) or `service_role` key, the database password, the Gmail app password, the Google client secret, or tokens. (The Supabase project URL and publishable key are public config and fine to commit.)
- Disable RLS on a table, or loosen a policy to `using (true)` / `with check (true)`.
- Delete or skip failing tests.
- Force-push `main`.
- Point tests at the staging or production Supabase projects. Test accounts exist only in the local Supabase stack.

## 9. Security

Security is part of every slice from the spec onward, not a pass at the end. This section adds to sections 7 and 8. SPEC.md's Boundaries point here instead of repeating it. For deeper patterns, Claude loads the `security-and-hardening` skill (or equivalent).

**The fact everything else follows from:** the app is a client talking straight to Supabase. Anyone can take the public URL and publishable key and call the Data API and Auth without our app. **Row Level Security (RLS) policies, table grants and database constraints are the only server-side boundary.** Everything in the app (Dart validation, hidden buttons, constants, assets, `--dart-define` values) can be read and bypassed by the user.

### In the workflow

- **Spec**: every new field is classified as non-personal, personal (email, name, Google identity) or sensitive (financial data: account names, amounts, entry descriptions, anything that names a third party), with its purpose and how it gets deleted with the account. A field with no purpose isn't collected.
- **Plan**: every slice in `plan.md` has a **Security** line: the trust boundaries it crosses (user input, the database, another user's data, an external API, a deep link), what's worth attacking, and 2–3 abuse cases ("how would I misuse this?"). "None: UI only" is a valid answer, but it's written down.
- **Build**: abuse cases are the first tests. RLS deny-tests (pgTAP) in `supabase/tests/` for data access, unit tests for parsers and validators.
- **Gate**: on top of section 5, Claude runs the secret scan below, and checks the advisories `flutter pub get` prints when `pubspec.yaml` changed.
- **Handoff**: "What to look for" (section 4) has a Security line: RLS policies, grants or migrations touched, new inputs, new personal data, new dependencies or permissions, or "no security-relevant change".
- **Findings**: a security problem outside the current slice is reported in chat and in the handoff, not fixed silently. If it exposes one user's data to another, or a secret is in the repo, Claude stops and reports it before anything else.

### Threat model in five minutes (STRIDE, for this app)

| Threat | What it looks like here | Default control |
|---|---|---|
| Spoofing | acting as another user | Supabase Auth; policies use `auth.uid()`, never a uid the client wrote into a row |
| Tampering | bad shapes, changed owner or `created_at` | column types, `not null` and `check` constraints (sizes, allowed values); immutable columns stay unchanged on update |
| Repudiation | "I didn't delete that" in shared data | where the spec has shared data, the database forces `updated_by = auth.uid()` and timestamps to `now()` |
| Information disclosure | reading someone else's ledger; PII or amounts in logs; raw errors | owner check on every read; generic errors; no PII in logs |
| Denial of service / cost | huge rows, endless writes, unbounded queries | size caps in `check` constraints, `.limit()` on queries, spend cap and usage alerts |
| Elevation of privilege | adding yourself to the sign-up allowlist; making yourself an admin | the allowlist (and any future role) lives in a schema the Data API doesn't expose, and only the developer edits it from the dashboard |

### RLS policies (and Storage)

- Deny by default: RLS is enabled on every table in an exposed schema (`public` included), and each table gets explicit grants for only what clients need. No `using (true)` policies on user data. Split `select`, `insert`, `update` and `delete` policies when they need different checks.
- `to authenticated` alone is never enough for user data. Compare `(select auth.uid())` with the row's stored owner column. Update policies have both `using` and `with check`.
- Validate shape in the schema: `not null` for required columns, a column type per field, a `check` max length for every text column, a max size for every array and `jsonb`, allowed values for enums. Grant `insert` and `update` only on the columns clients may write.
- Owner and `created_at` can't change on update (`with check`, column grants or a trigger). Server times use `now()`, never a client value.
- Views and `security definer` functions bypass RLS. Views use `security_invoker = true`. A `security definer` function is a last resort: it checks `auth.uid()` itself and `anon` can't execute it.
- Schema changes are additive (section 5), so a new column updates its constraints, grants and tests in the same slice.
- Every policy or schema change ships with pgTAP deny-tests for: signed out (`anon`), another user, a column the client may not write, a wrong type, an oversized string, a changed immutable column. Plus the allowed path.
- Supabase Storage, if ever added: per-user paths enforced by policies on `storage.objects`, a bucket file-size limit and an allowed MIME types list.

### App code

- Client validation is for UX. Still validate at the edge (trim, length, ranges, dates) and pass typed values inward: the domain layer never sees raw form strings.
- Database rows are untrusted too, since another client may have written them. Parse defensively, default missing fields, never crash on a bad row.
- User text renders only through Flutter text widgets. Never through `HtmlElementView`, `innerHTML` or a WebView.
- `url_launcher` with a URL from a user or an API: `https` only (plus `mailto` if a feature needs it). Never `javascript:` or `file:`.
- An ID in a deep link or web route never implies access. RLS decides.
- Users see a generic error from the arb files. Raw `PostgrestException` and `AuthException` messages and stack traces go to debug logs only.
- No tokens, passwords, emails or whole rows in `print`, `debugPrint` or `log`. Log IDs and error codes.
- `shared_preferences` is plaintext: non-sensitive settings only. Auth tokens stay with the Supabase SDK.
- Sign-out must not leave the previous user's data readable on the device (in-memory state, any local cache, local storage). The spec says how.
- HTTPS only. The one cleartext exception is the debug-only Android network security config that allows `127.0.0.1` and `localhost` (the local stack over `adb reverse`). Release builds have none, and nothing sets `usesCleartextTraffic`. Never a `badCertificateCallback` that returns `true`.
- Auth is Supabase Auth only: no home-made login, password storage or token handling. Google Sign-In goes through Supabase (`signInWithIdToken` on Android, `signInWithOAuth` on web), and the app keeps no Google tokens of its own.

### Secrets

- Public by design: the Supabase project URL and the publishable key (`sb_publishable_…`). RLS and grants protect the data, not hiding the key.
- Anything shipped in the app is public. A key that must stay secret (paid API, LLM, admin, the Supabase secret or `service_role` key) can't live in the app. It needs a server, which means Edge Functions, which means ask first (section 7).
- Docker images hold no secrets: nothing secret in `COPY`, `ARG` or `ENV`, `.dockerignore` keeps secret files out of the build context, and a build that needs a secret gets it as a BuildKit secret.
- Never in the repo: the Supabase secret (`sb_secret_…`) or `service_role` key, Supabase access tokens (`sbp_…`), the database password, the Gmail app password, the Google OAuth client secret (`GOCSPX-…`), the Android upload keystore (`*.jks`, `*.keystore`, `key.properties`), iOS certificates and profiles (`*.p12`, `*.mobileprovision`), `.env` files with real values. Example files hold placeholders only.
- Before every handoff Claude runs both scans. Each must print nothing. They list file names only, so a hit never echoes the secret into chat or logs:

```
git grep --untracked -lIiE 'BEGIN [A-Z ]*PRIVATE KEY|"private_key"|client_secret|refresh_token|sk-[a-z0-9_-]{20,}|gh[pousr]_[a-z0-9]{30,}|github_pat_|sb_secret_[a-z0-9_-]{10,}|sbp_[a-z0-9]{20,}|GOCSPX-[a-z0-9_-]{20,}' -- ':!.claude/dev_rules.md'
```

```
git ls-files --cached --others --exclude-standard | grep -iE '\.(jks|keystore|p12|pem|mobileprovision)$|key\.properties$|service-?account|(^|/)\.env'
```

- A secret that reaches GitHub is compromised. The developer rotates it first, then cleans history. Claude writes the steps.

### Dependencies

- New packages are already ask-first (section 7). When asking, Claude reports the publisher (verified? `dart.dev`, `flutter.dev` and `supabase.io` preferred), last release date, pub points, license, what it pulls in, and whether a few lines of our own code would do. Check the exact name on pub.dev: typosquats exist. Docker base images come from official or verified publishers, pinned by digest. GitHub Actions are pinned by commit SHA.
- `pubspec.lock` stays committed. Installs follow it. CI pins the Supabase CLI version.
- Dependabot PRs (`pub`, `github-actions`, `docker`) go through the full gate like any other PR.
- At stage end Claude runs `flutter pub outdated` and checks the Flutter, base-image and Supabase CLI pins against their latest releases, then triages by reachability: app runtime dependencies first, while `supabase/` and CI are tooling. Upgrade one package at a time and rerun the gate. Every deferred finding goes in `todo.md` with a reason and a review date.

### Personal data

- Collect the minimum the spec needs. "Might be useful later" isn't a purpose.
- A user's data stays findable by uid, so deleting the account removes all of it (database rows through `on delete cascade` from `auth.users`, Storage, the Auth user) and export stays possible. Deletion is real deletion, not a flag.
- No PII in analytics, crash reports or logs.
- Tests, fixtures, seed data and screenshots use made-up data only, in the local Supabase stack. Never rows from the developer's spreadsheets.

### Before a stage merges into `main`

- Claude walks the security review checklist over `git diff main...dev` and reports the findings in the handoff, along with the dependency check above.
- Before the first release to family (the first APK installed on someone else's phone), Claude lists what the developer checks:
  - **Supabase dashboard (staging and production):** Security Advisor clean (RLS on every exposed table); the Data API's exposed schemas and table grants; Auth settings (sign-ups on with the allowlist hook enabled, Site URL and redirect URLs, email confirmation, minimum password length, rate limits, custom SMTP); usage alerts; database network restrictions and SSL enforcement.
  - **Google Cloud console:** consent screen with basic scopes only; authorized JavaScript origins and redirect URIs; Android clients with the debug and release SHA-1s.
  - **GitHub:** rulesets, required reviewer on the `production` environment, environment secrets present.
  - **Web hosting, once decided:** security headers from the `web` image (CSP, HSTS, `X-Content-Type-Options`, `frame-ancestors`).

### Ask first (security)

- Auth changes: new providers, account linking, sign-in, sign-out or account-deletion flows, or the sign-up allowlist hook.
- A new category of personal data (photos, location, contacts, bank or card numbers, Google profile data beyond email).
- A new external service or SDK that receives user data (analytics, crash reporting, email providers, bank-sync or exchange-rate APIs, LLMs).
- New platform permissions (camera, location, notifications, contacts).
- File uploads or Supabase Storage.
- Enabling CAPTCHA protection, changing the Data API's exposed schemas, or changing hosting headers or CORS.
- Any role, admin flag or cross-user access.

### Never (security)

- Treat client-side checks or hidden UI as access control.
- Loosen an RLS policy or grant, or weaken a deny-test, to make a test pass.
- Put a secret in the app, the repo, a log or a chat message.
- Show raw errors or stack traces to users.
- Disable TLS checks, or allow cleartext traffic beyond the debug-only localhost exception.
- Blanket-approve install scripts, or use unpinned Docker images or Actions in CI.
- Use real user data in tests, fixtures, seed data or screenshots.
