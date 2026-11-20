# Module Spec: `auth`

> Depends on: `app-foundation` · Used by: `accounts`, `journal`, `balance` · Delivery: Stage 2 (`v0.2.0`)
> Status: draft, awaiting review

## Objective

Let the developer and invited family members create accounts and sign in, so every later module can rely on `auth.uid()`:
- email + password, confirmed with a 6-digit code
- Google (native on Android, redirect on web)
- forgot password and change password, both with codes
- sign out

Only emails the developer adds to an allowlist can create an account. The server enforces this, so a direct API call can't skip it.

## Scope

**In**
- **Allowlist** (`private` schema, not exposed to the Data API):
  - `private.signup_allowlist (email text primary key check (email = lower(btrim(email))), added_at timestamptz not null default now())`
  - the developer adds real emails with the SQL editor of each hosted project; real emails are never committed
  - `supabase/seed.sql` adds made-up `alice@example.com` and `bob@example.com` for the local stack only
- **Before User Created hook** `private.before_user_created(event jsonb) returns jsonb`:
  - `language plpgsql`, `security invoker`, `set search_path = ''`
  - allows the sign-up (returns `'{}'::jsonb`) only when `lower(btrim(event->'user'->>'email'))` is in the allowlist
  - otherwise returns `{"error": {"message": "Sign-up is not available for this email.", "http_code": 403}}`; a missing email is rejected too
  - grants: `usage on schema private`, `select on private.signup_allowlist` and `execute` on the hook to `supabase_auth_admin` only; `execute` revoked from `public`, `anon` and `authenticated`
- **`supabase/config.toml` (local stack):**
  - `[auth]`: `site_url = "http://localhost:3000"`; `additional_redirect_urls` adds `http://localhost:8080` (the `web` image); `minimum_password_length = 8`
  - `[auth.email]`: sign-up on, `enable_confirmations = true`, `otp_length = 6`
  - email templates `confirmation` and `recovery` from `supabase/templates/*.html`: they show `{{ .Token }}` (no links), with the text in English and Spanish in the same email, since the server doesn't know the device language
  - `[auth.hook.before_user_created]`: `enabled = true`, `uri = "pg-functions://postgres/private/before_user_created"`
  - `[auth.external.google]`: `enabled = true`, `client_id = "env(GOOGLE_WEB_CLIENT_ID)"`, `secret = "env(SUPABASE_AUTH_EXTERNAL_GOOGLE_SECRET)"`; both values live in the git-ignored `supabase/.env`
  - local emails go to the stack's built-in mail catcher (`supabase status` prints its URL), never to Gmail
- **Seed users** in `supabase/seed.sql`: confirmed made-up users `alice@example.com` and `bob@example.com` with a local-only password, for integration tests and manual checks.
- **Config:** `AppConfig` gains `googleWebClientId` from `GOOGLE_WEB_CLIENT_ID`, added to all three `config/*.json` files in the same slice (startup fails fast when it's empty).
- **Flutter, `lib/data/services/`:**
  - `google_sign_in_service.dart` wraps `GoogleSignIn.instance` (v7: `initialize(serverClientId: GOOGLE_WEB_CLIENT_ID)`, then `authenticate()`) and returns the ID token and access token
- **Flutter, `lib/data/repositories/`:**
  - `auth_repository.dart` (abstract, `ChangeNotifier`) and `auth_repository_supabase.dart`
  - Android: Google tokens → `auth.signInWithIdToken(provider: OAuthProvider.google, idToken:, accessToken:)`
  - web: `auth.signInWithOAuth(OAuthProvider.google)` with the redirect back to the current origin
  - notifies listeners on every `onAuthStateChange` event
- **Routes and screens** (`lib/ui/auth/`):

  | Route | Screen |
  |---|---|
  | `/sign-in` | email + password, "Continue with Google", links to sign-up and forgot password |
  | `/sign-up` | email + password + confirm password, "Continue with Google" |
  | `/sign-up/verify` | 6-digit code, "Resend code" (disabled for 60 s after each send) |
  | `/forgot-password` | step 1: email; step 2: code + new password + confirm |

  - the email travels between screens in memory (go_router `extra`), never in the URL; after a web reload the verify screen asks for the email again
  - `/settings` gains a section showing the signed-in email, "Change password" (current + new + confirm; shown only when the user has an email identity) and "Sign out"
- **Router** (fills the hooks `app-foundation` left open):
  - `refreshListenable` is the `AuthRepository`
  - signed out: any route except the four above redirects to `/sign-in?from=PATH`
  - signed in: the four auth routes redirect to `from`, or `/balance` when it's missing
  - `from` is used only when it starts with `/` and not with `//`, so it can't send the user off-site
- **Client-side validation** before any network call: email format, password ≥ 8 characters, matching confirmation, code of exactly 6 digits.
- Text fields use autofill hints (`email`, `password`, `newPassword`, `oneTimeCode`); password fields are obscured.

**Developer setup outside the repo** (Claude gives the steps; the developer does them):
- **Google Cloud** (one project for every environment):
  - OAuth consent screen: External, scopes `openid`, `email`, `profile`
  - Web client: JavaScript origins `http://localhost:3000` and `http://localhost:8080`; redirect URIs `https://STAGING_REF.supabase.co/auth/v1/callback`, `https://PROD_REF.supabase.co/auth/v1/callback` and `http://127.0.0.1:54321/auth/v1/callback`
  - Android clients for `com.danmau.wheres_my_money_tracker` with the laptop's debug SHA-1 and the upload key's SHA-1
  - the Web client ID goes into the three `config/*.json` files (public); the client secret goes only into the Supabase dashboards and `supabase/.env`
- **Each hosted Supabase project:**
  - the same auth settings as `config.toml` (sign-up, confirmations, OTP length, password length, URLs, templates, hook, Google provider)
  - custom SMTP: `smtp.gmail.com`, port 465, the developer's Gmail address and app password, sender name "Where's My Money"
  - allowlist emails added with the SQL editor

**Out:**
- self-service account deletion (roadmap; the developer deletes users in the dashboard, and the cascade removes their data)
- MFA, CAPTCHA, magic links, other OAuth providers, display names or avatars
- changing the email address
- setting a first password for Google-only users

## Interface exposed to other modules

```dart
abstract class AuthRepository extends ChangeNotifier {
  bool get isSignedIn;
  String? get userId;
  String? get email;
  bool get hasPasswordIdentity;

  Future<Result<void>> signUp(String email, String password);
  Future<Result<void>> verifySignUpCode(String email, String code);
  Future<Result<void>> resendSignUpCode(String email);
  Future<Result<void>> signIn(String email, String password);
  Future<Result<void>> signInWithGoogle();
  Future<Result<void>> sendPasswordResetCode(String email);
  Future<Result<void>> resetPassword(String email, String code, String newPassword);
  Future<Result<void>> changePassword(String currentPassword, String newPassword);
  Future<Result<void>> signOut();
}

enum AuthFailure {
  invalidCredentials, emailNotConfirmed, invalidOrExpiredCode, weakPassword,
  signUpNotAllowed, rateLimited, cancelled, network, unknown,
}

final class AuthException implements Exception { const AuthException(this.failure); final AuthFailure failure; }
```

- `changePassword` checks the current password with `signInWithPassword` before `updateUser`.
- Other modules use `auth.uid()` in SQL and never read `user_metadata` for authorization.
- Repositories that cache rows clear them when the client's auth state reports a sign-out or a different user (see SPEC.md › Data Model).

## Security

- **Data classification:** personal: the auth email, the Google identity (Google adds name and avatar URL to `user_metadata`), allowlist emails. No financial data in this module.
- **Trust boundaries:**
  - app ↔ Supabase Auth: the Auth API is public, and anyone with the publishable key can call it directly
  - Google ↔ Supabase (ID tokens, OAuth redirect)
  - Supabase ↔ Gmail SMTP
  - the web session is stored in the browser's local storage, so XSS would expose it (the devops CSP limits scripts)
- **Abuse cases:**
  - a direct `POST /auth/v1/signup` or a Google sign-in with a non-allowlisted email → the hook rejects it and no `auth.users` row is created
  - `Alice@Example.com ` instead of `alice@example.com` → compared lower-cased and trimmed; Gmail aliases (`alice+x@`) need their own allowlist entry
  - guessing a 6-digit code or a password → Supabase rate limits and code expiry; Claude reports the defaults in Stage 2
  - finding out who has an account → sign-in shows one message for an unknown email and a wrong password; forgot password always says "If an account exists, we sent a code"; signing up an already-registered email shows the same "code sent" screen
  - **accepted risk:** a 403 on sign-up reveals that an email is *not* on the allowlist; it reveals nothing about accounts or data
  - the email in a URL ends up in browser history or logs → it never goes in a URL
  - an open redirect through `from` → only relative app paths are accepted
  - the hook is called by a client → it's in `private`, and only `supabase_auth_admin` can execute it
- **Logs:** no emails, codes, passwords or tokens in logs; raw `AuthException` text only in debug logs.

## Acceptance criteria

1. **AC-AUTH-1:** an allowlisted email signs up with a password, receives a 6-digit code (mail catcher locally, Gmail on staging), enters it and lands on `/balance` signed in. The email shows the code in English and Spanish.
2. **AC-AUTH-2:** a non-allowlisted email signing up in the app sees the localized "can't create an account with this email" message, and no `auth.users` row exists for it.
3. **AC-AUTH-3:** a direct Auth API sign-up (curl with the publishable key) with a non-allowlisted email is refused, and no `auth.users` row exists.
4. **AC-AUTH-4:** the hook (pgTAP):
   - allows an allowlisted email in any letter case and with surrounding spaces
   - rejects a non-allowlisted email and a missing email with `http_code` 403
   - `anon` and `authenticated` can't execute the hook or read the allowlist; `supabase_auth_admin` can
5. **AC-AUTH-5:** on the phone, "Continue with Google" with an allowlisted Google account signs in. A non-allowlisted Google account is refused with the same message as AC-AUTH-2, and no user is created.
6. **AC-AUTH-6:** on web (Chromium), "Continue with Google" goes to Google and comes back signed in on `/balance`.
7. **AC-AUTH-7:** a user who signed up with email + password and later uses Google with the same email gets the same user id and the same data (`auth.identities` shows two identities).
8. **AC-AUTH-8:** sign-in with a wrong password and with an unknown email shows the same message. A correct password for an unconfirmed email goes to the code screen and lets the user resend the code.
9. **AC-AUTH-9:** forgot password always shows "If an account exists, we sent a code". A valid code with a new password signs the user in; afterwards the new password works and the old one doesn't. A wrong or expired code shows the code error.
10. **AC-AUTH-10:** change password needs the current password; a wrong one shows an error and changes nothing. It isn't shown to a Google-only user.
11. **AC-AUTH-11:** sign out returns to `/sign-in`. Browser back or opening `/journal` afterwards redirects to `/sign-in`.
12. **AC-AUTH-12:** a signed-out user opening `/journal` lands on `/sign-in?from=/journal` and goes back to `/journal` after signing in. `from=//evil.example` and `from=https://evil.example` go to `/balance`.
13. **AC-AUTH-13:** the session survives an app restart and a web reload.
14. **AC-AUTH-14:** invalid email, a password under 8 characters, mismatched confirmation and a code that isn't 6 digits are rejected on the screen without a network call.
15. **AC-AUTH-15:** "Resend code" is disabled for 60 s after each send.
16. **AC-AUTH-16:** every `AuthFailure` maps to a message in English and Spanish; no raw error text reaches the screen.
17. **AC-AUTH-17:** no route carries an email (router test over every auth route).

## Tests

- `supabase/tests/010_auth_allowlist.test.sql`: AC-AUTH-4.
- `test/data/repositories/auth_repository_supabase_test.dart` (fake client): error → `AuthFailure` mapping, AC-AUTH-16 (mapping part).
- `test/ui/auth/view_models/*_test.dart` (with `FakeAuthRepository`): AC-AUTH-8, AC-AUTH-9, AC-AUTH-10, AC-AUTH-14, AC-AUTH-15.
- `test/ui/auth/widgets/*_test.dart`: AC-AUTH-14, AC-AUTH-16 (EN/ES), autofill hints.
- `test/routing/auth_redirect_test.dart`: AC-AUTH-11 (redirect part), AC-AUTH-12, AC-AUTH-17.
- `test/integration/auth_repository_test.dart` (local stack, seed users): sign-in, wrong password, sign-up refused for a non-allowlisted email (AC-AUTH-2 server part), sign-out.
- Manual, recorded in `REVIEW.md`: AC-AUTH-1, AC-AUTH-2 (no row), AC-AUTH-3, AC-AUTH-5, AC-AUTH-6, AC-AUTH-7, AC-AUTH-13, and AC-AUTH-1 again on staging with Gmail.

## Open questions

1. **Android nonce:** Supabase checks the ID token's nonce by default. Claude tests `google_sign_in` 7.2 with `signInWithIdToken` on the phone in Stage 2. If it fails, the options are passing a nonce or turning the check off; turning it off weakens replay protection, so it needs your approval.
2. **Does the Before User Created hook run for Google sign-ups?** Claude checks the current docs and tests it locally. If it doesn't, the fallback is keeping the Google consent screen in Testing mode with the allowlisted emails as test users, so Google itself refuses everyone else.
3. **Hosted auth settings:** set by hand in each dashboard (with a checklist in `REVIEW.md`), or with `supabase config push` if CLI v3 supports it safely with `env()` secrets. Claude checks and proposes in Stage 2.
