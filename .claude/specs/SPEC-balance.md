# Module Spec: `balance`

> Depends on: `journal` (and `accounts`, `auth`) · Used by: — · Delivery: Stage 5 (`v0.5.0`)
> Status: draft, awaiting review

## Objective

Show the user's books laid out like `Accounting.xlsx`, always calculated from the journal, so nothing is carried forward by hand and nothing can drift:
- an **all-time** view: gross debits and credits per account, plus each account's balance
- a **monthly** view: the trial balance for one month, like each `Gastos.xlsx` sheet
- an **account ledger**: every line posted to one account
- a **default view** preference that follows the user between web and phone

Both views show total debit = total credit, the self-test from the spreadsheets.

## Scope

**In**
- **All-time view** `public.account_totals` (`with (security_invoker = true)`):
  - one row per account (archived included): `account_id`, `name`, `section`, `archived`, `debit_cents`, `credit_cents`
  - accounts left join lines, `coalesce(…, 0)`; gross sums
  - `select` granted to `authenticated` only; RLS on the underlying tables does the filtering
- **Monthly function** `public.monthly_balance(p_month date)`:
  - `returns table (account_id bigint, name text, section text, archived boolean, debit_cents bigint, credit_cents bigint)`, `language sql`, `stable`, `security invoker`, `set search_path = ''`
  - any day of the month selects that month; months outside 2000-01 … 2099-12 raise an error
  - per account, the net amount `n = Σ debit − Σ credit` over:
    - **asset, liability:** lines dated up to the month's end (closing balance)
    - **income, expense:** lines dated inside the month
    - **equity:** its own lines up to the month's end, **plus** every income and expense line dated before the month (earlier results closed into Capital; v1 has exactly one equity account)
  - shown as `debit_cents = n` when `n ≥ 0`, otherwise `credit_cents = −n`
  - those groups cover every line up to the month's end exactly once, and each entry is balanced, so the debit column always equals the credit column
  - `execute` granted to `authenticated` only
- **Preference:** `balance_period` (`all_time` | `monthly`) in the user's `user_metadata`, written with `auth.updateUser(data:)`; missing or unknown values mean `all_time`. It's display-only and never used for authorization.
- **Flutter:**
  - `lib/domain/models/`: `BalanceRow`, `BalanceSheet` (rows + totals), `BalancePeriod`
  - `lib/data/repositories/`: `balance_repository.dart` (`allTime()`, `month(DateTime)`) and `preferences_repository.dart`, each with a Supabase implementation
  - `lib/ui/balance/`: `BalanceViewModel` + `BalanceScreen`, `LedgerViewModel` + `LedgerScreen`
  - the settings section for the default view
- **Balance screen** (`/balance`):
  - `/balance` opens the user's default view (monthly = the current month); `/balance?view=all` is all-time; `/balance?month=YYYY-MM` is that month; a malformed or out-of-range `month` is ignored
  - an All-time | Monthly toggle; in Monthly, previous / next month arrows and a month picker
  - rows grouped by section in sheet order:
    - all-time: Debit, Credit and Balance columns, where Balance is on the account's normal side (`D − C` for debit-normal, `C − D` for credit-normal)
    - monthly: Debit and Credit columns
  - every not-archived account is listed (zero shows "—"); archived accounts only when they're non-zero
  - footer: total debit, total credit and a check badge ("Debits = Credits"); if they ever differ, a warning with the difference
  - tapping an account opens its ledger
  - reloads when the journal or the accounts change
- **Ledger** (`/accounts/:id`):
  - the account's name, section, gross totals and balance (from `account_totals`)
  - its lines newest first (`JournalRepository.listAccountLines`), 50 at a time: date, entry description, debit, credit
  - tapping a line opens `/journal/ENTRY_ID`
  - a missing, non-numeric or other user's id shows "Account not found"
  - the Accounts screen's rows also open the ledger
- **Settings:** "Default balance view": All-time / Monthly. A failed save shows an error and reverts the choice.

**Out:**
- running balances on ledger lines
- section subtotals, charts, custom date ranges, year views
- exporting, printing
- currency conversion (roadmap v2)

## Data owned

`public.account_totals`, `public.monthly_balance(date)`, `user_metadata.balance_period`.

## Interface exposed to other modules

```dart
enum BalancePeriod { allTime, monthly }

final class BalanceRow { final int accountId; final String name; final AccountSection section; final bool archived; final int debitCents, creditCents; }
final class BalanceSheet { final List<BalanceRow> rows; int get totalDebitCents; int get totalCreditCents; bool get isBalanced; }

abstract class BalanceRepository {
  Future<Result<BalanceSheet>> allTime();
  Future<Result<BalanceSheet>> month(DateTime anyDayInMonth);
}

abstract class PreferencesRepository extends ChangeNotifier {
  BalancePeriod get balancePeriod;
  Future<Result<void>> setBalancePeriod(BalancePeriod period);
}

enum BalanceFailure { notFound, network, unknown }
```

Nothing depends on `balance` in v1.

## Security

- **Data classification:** sensitive (financial) for every view and ledger row; the preference is non-personal.
- **Trust boundaries:** the view and the function are on the Data API.
- **Abuse cases:**
  - user B reads A's totals → `security_invoker` view and function, so RLS on accounts and lines applies; B sees only B's rows
  - `anon` calls them → no grant
  - a user sets `balance_period` to something odd with `updateUser` → it only picks a view; unknown values mean `all_time`
  - `?month=` with junk → parsed strictly, ignored when invalid; the function also checks the range

## Acceptance criteria

Worked example (made-up amounts), used by pgTAP, the integration test and the manual check:
- January: Dr bank 1,000 / Cr Capital 1,000; Dr bank 500 / Cr Income 500; Dr Expenses 200 / Cr bank 200
- February: Dr Expenses 50 + Dr A/R 30 / Cr bank 80

1. **AC-BAL-1:** January monthly view: bank 1,300 Dr, Capital 1,000 Cr, Income 500 Cr, Expenses 200 Dr; totals 1,500 = 1,500.
2. **AC-BAL-2:** February monthly view: bank 1,220 Dr, A/R 30 Dr, Capital 1,300 Cr (January's result closed in), Income —, Expenses 50 Dr; totals 1,300 = 1,300.
3. **AC-BAL-3:** all-time view: bank D 1,500 / C 280 (balance 1,220), Capital C 1,000, Income C 500, Expenses D 250, A/R D 30; totals 1,780 = 1,780.
4. **AC-BAL-4:** for every month from December (before any entry) to March (after the last), the monthly totals are equal (pgTAP).
5. **AC-BAL-5:** user B's `account_totals` and `monthly_balance` contain none of A's accounts; `anon` can't use either (pgTAP).
6. **AC-BAL-6:** `/balance` opens the default view; `?view=all` and `?month=2026-02` open those views; `?month=2026-13` and `?month=abc` fall back to the default.
7. **AC-BAL-7:** changing the default on the phone makes web open that view after a reload, and the reverse.
8. **AC-BAL-8:** saving or deleting an entry, then returning to Balance, shows the new totals without a manual refresh.
9. **AC-BAL-9:** the ledger lists the account's lines newest first and opens the entry on tap; another user's account id shows "Account not found".
10. **AC-BAL-10:** an archived account with a non-zero balance still appears in both views; with zero it doesn't.
11. **AC-BAL-11:** with 10,000 made-up lines for one user on the local stack, `account_totals` and `monthly_balance` each return in under 500 ms (`explain analyze`).
12. **AC-BAL-12:** every label, column heading and message is in English and Spanish.

## Tests

- `supabase/tests/040_balance.test.sql`: AC-BAL-1, AC-BAL-2, AC-BAL-3, AC-BAL-4, AC-BAL-5, AC-BAL-10 (data).
- `test/domain/models/balance_sheet_test.dart`: totals, `isBalanced`, normal-side balance.
- `test/ui/balance/view_models/balance_view_model_test.dart` (fakes): AC-BAL-6 (route parsing), AC-BAL-8 (reload on journal change), default view.
- `test/ui/balance/view_models/ledger_view_model_test.dart`: AC-BAL-9 (pagination, not found).
- `test/ui/balance/widgets/*_test.dart`: AC-BAL-10 (display), AC-BAL-12.
- `test/integration/balance_repository_test.dart`: AC-BAL-1 to AC-BAL-3 through the repositories; preference round trip.
- Manual, recorded in `REVIEW.md`: AC-BAL-7, AC-BAL-11 (local-only script generating made-up lines, never committed data), plus the worked example on the phone.

## Open questions

1. **All-time layout:** gross Debit, Credit and Balance (as `Accounting.xlsx`), as proposed, or only the net balance per account?
2. **Monthly rows:** list every account with "—" for zero, as proposed, or hide zero rows?
