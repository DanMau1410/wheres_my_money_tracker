# Module Spec: `app-foundation`

> Depends on: `devops` · Used by: every feature module · Delivery: Stage 1 (`v0.1.0`)
> Status: draft, awaiting review

## Objective

Replace the template app with the MVVM skeleton that every feature plugs into:
- configuration and Supabase initialization
- dependency injection
- the go_router shell
- theme and EN/ES localization
- the shared vocabulary (money in cents, account sections, dates)
- the test harness

No user-visible feature yet beyond the empty, navigable shell.

## Scope

**In**
- **`lib/main.dart`:**
  - read `AppConfig.fromEnvironment()`; if any key is empty, show a developer-facing "Missing configuration: KEY" screen and stop, with no Supabase call
  - otherwise run `Supabase.initialize(url:, publishableKey:)`, then `runApp(MultiProvider(providers: dependencies, child: App()))`
- **`lib/config/`:**
  - `app_config.dart` reads `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY` and `GOOGLE_WEB_CLIENT_ID` via `String.fromEnvironment`
  - `dependencies.dart` provides `SupabaseClient` (`Supabase.instance.client`) and `AppConfig`; later modules add their services and repositories here
- **`lib/routing/`:**
  - `routes.dart` holds path constants: `/balance`, `/journal`, `/accounts`, `/settings`
  - `router.dart` holds a `GoRouter` with a `StatefulShellRoute` for the four destinations; `/` redirects to `/balance`, and unknown paths show a localized "Page not found" with a link home
  - the `redirect` and `refreshListenable` hooks exist but allow everything; `auth` fills them in
- **`lib/ui/core/`:**
  - `app_shell.dart`: Balance, Journal, Accounts, Settings, with a `NavigationBar` below 840 px wide and a `NavigationRail` at 840 px and above; each destination shows a localized empty placeholder
  - `theme.dart`: Material 3, `ColorScheme.fromSeed(seedColor: Colors.deepPurple)` (kept from the template), light and dark following the system
  - shared widgets: `MoneyText` (formats cents, tabular figures), `LoadingView`, `ErrorView` (localized generic message + retry)
- **Localization:** `l10n.yaml`, `lib/l10n/app_en.arb` and `app_es.arb`, `generate: true`. The locale follows the device; unsupported locales fall back to English. The app title is "Where's My Money" / "¿Dónde está mi dinero?".
- **`lib/utils/`:**
  - `result.dart`: sealed `Result<T>` with `Ok`/`Error`, following the guide
  - `command.dart`: `Command<T>`, `Command0<T>`, `Command1<T, A>` (`running`, `error`, `completed`, `result`, `clearResult()`); `execute` while running is ignored
  - `money.dart`: `kMaxLineCents = 99999999999`, `int? parseCents(String input)`, `String formatCents(int cents, String locale)`
  - `dates.dart`: `String toDateKey(DateTime)`, `DateTime? fromDateKey(String)`, `bool isEntryDateInRange(DateTime)` (2000-01-01 to 2099-12-31), `DateTime todayLocal()`
- **`lib/domain/models/account_section.dart`:**
  - `enum AccountSection { asset, liability, equity, income, expense }`
  - `bool debitNormal`, true for asset and expense
  - `String wireName`, plus `static AccountSection? fromWire(String)`
  - the localized labels live in `ui/core`
- **`testing/`:**
  - `app.dart`: a `testApp(child, {locale, providers})` helper that wraps a widget in `MaterialApp` with l10n and theme
  - an empty `fakes/` folder that later modules fill

**Out:**
- sign-in and every data screen (later modules)
- any repository or table
- an in-app language switch

## `parseCents` rules

The parser accepts digits with **at most one** decimal separator, `.` or `,`, followed by 1–2 digits. Surrounding spaces are trimmed. The result must be between 1 and `kMaxLineCents`. Anything else returns `null`; the screen shows the validation message.

| Input | Result |
|---|---|
| `"12"` | 1200 |
| `"12.5"` | 1250 |
| `"12,50"` | 1250 |
| `"0.01"` | 1 |
| `" 7 "` | 700 |
| `"999999999.99"` | 99999999999 |
| `""`, `"abc"`, `"-5"`, `"1.234"`, `"1e9"`, `"1.2.3"`, `"1,234.56"`, `"0"`, `"0.00"`, `"1000000000"` | `null` |

Thousands separators are rejected on input to avoid `1.234` vs `1,234` ambiguity. Output formatting uses the locale's separators.

## Interface exposed to other modules

```dart
sealed class Result<T> { const factory Result.ok(T value) = Ok._; const factory Result.error(Exception e) = Error._; }
abstract class Command<T> extends ChangeNotifier {
  bool get running; bool get error; bool get completed; Result<T>? get result; void clearResult();
}
class Command0<T> extends Command<T> { Command0(Future<Result<T>> Function() action); Future<void> execute(); }
class Command1<T, A> extends Command<T> { Command1(Future<Result<T>> Function(A) action); Future<void> execute(A arg); }

enum AccountSection { asset, liability, equity, income, expense;
  bool get debitNormal; String get wireName; static AccountSection? fromWire(String value); }

const int kMaxLineCents = 99999999999;
int? parseCents(String input);
String formatCents(int cents, String locale);
String toDateKey(DateTime date);
DateTime? fromDateKey(String value);
bool isEntryDateInRange(DateTime date);

class AppConfig { final String supabaseUrl, supabasePublishableKey, googleWebClientId; }
```

Each module adds its routes to `lib/routing/router.dart` and its providers to `lib/config/dependencies.dart`.

## Security

- **Trust boundaries:** user input enters through `parseCents` and the date helpers; config comes from dart-defines (public values only).
- **Abuse cases:**
  - `"1e9"`, `"-5"` or a 40-digit amount → rejected by `parseCents`, and later by the database
  - a missing config key → fail fast, so the app never points at the wrong backend
- **No personal data in this module.**

## Acceptance criteria

1. **AC-FND-1:** with `config/local.json`, the app starts on web (Chromium, port 3000) and on the phone (debug build), and shows the shell with four localized placeholder destinations.
2. **AC-FND-2:** each empty or missing config key stops startup with "Missing configuration: KEY", and no Supabase call is made.
3. **AC-FND-3:** the shell shows a `NavigationBar` at 400 px wide and a `NavigationRail` at 1000 px.
4. **AC-FND-4:** on web, `/balance`, `/journal`, `/accounts` and `/settings` open their destinations, `/` goes to `/balance`, an unknown path shows "Page not found", and browser back works.
5. **AC-FND-5:** a Spanish device locale shows Spanish; French falls back to English.
6. **AC-FND-6:** `parseCents` matches the table above exactly.
7. **AC-FND-7:** `formatCents(123456, 'en')` is `$1,234.56`, and `formatCents(123456, 'es')` uses Spanish separators (`1.234,56`) with the `$` symbol.
8. **AC-FND-8:** `AccountSection.debitNormal` is true only for asset and expense. `wireName` / `fromWire` round-trip all five, and an unknown value gives `null`.
9. **AC-FND-9:** the date helpers round-trip, invalid keys give `null`, and 1999-12-31 and 2100-01-01 are out of range.
10. **AC-FND-10:** a `Command` goes running → completed (`Ok`) or running → error (`Error`), `clearResult` resets it, and `execute` while running does nothing.
11. **AC-FND-11:** a release build with `config/staging.json` runs on the phone over HTTPS and shows the shell.
12. **AC-FND-12:** the quality gate passes, including coverage ≥ 80%.

## Tests

- `test/config/app_config_test.dart`, `test/main_missing_config_test.dart`: AC-FND-2.
- `test/ui/core/app_shell_test.dart`: AC-FND-1 (shell part), AC-FND-3, AC-FND-5.
- `test/routing/router_test.dart`: AC-FND-4 (paths, redirect, not found).
- `test/utils/money_test.dart`: AC-FND-6, AC-FND-7.
- `test/domain/models/account_section_test.dart`: AC-FND-8.
- `test/utils/dates_test.dart`: AC-FND-9.
- `test/utils/command_test.dart`, `result_test.dart`: AC-FND-10.
- Manual: AC-FND-1 (devices), AC-FND-4 (browser back), AC-FND-11.
- CI: AC-FND-12.

## Open questions

1. The app's display name ("Where's My Money" / "¿Dónde está mi dinero?") and the seed color (template purple) are placeholders until you pick a design.
