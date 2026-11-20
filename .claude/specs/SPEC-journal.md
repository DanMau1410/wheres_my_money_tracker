# Module Spec: `journal`

> Depends on: `accounts` · Used by: `balance` · Delivery: Stage 4 (`v0.4.0`)
> Status: draft, awaiting review

## Objective

Record transactions the way the spreadsheets do, but as **one entry with N lines** instead of copies in several ledgers. An entry has a date, a description and 2–20 lines, and each line debits or credits one account.

The database refuses any entry whose debits don't equal its credits, even through direct API calls, so the spreadsheet's `Total Debit = Total Credit` self-test becomes a rule that can't be broken.

## Scope

**In**
- **Tables:**
  ```sql
  public.journal_entries (
    id          bigint generated always as identity primary key,
    user_id     uuid not null default auth.uid() references auth.users (id) on delete cascade,
    entry_date  date not null check (entry_date between '2000-01-01' and '2099-12-31'),
    description text not null check (description = btrim(description) and char_length(description) between 1 and 200),
    created_at  timestamptz not null default now(),
    unique (user_id, id)
  )

  public.journal_lines (
    id           bigint generated always as identity primary key,
    user_id      uuid not null default auth.uid() references auth.users (id) on delete cascade,
    entry_id     bigint not null,
    account_id   bigint not null,
    debit_cents  bigint not null default 0 check (debit_cents between 0 and 99999999999),
    credit_cents bigint not null default 0 check (credit_cents between 0 and 99999999999),
    check ((debit_cents > 0) <> (credit_cents > 0)),  -- exactly one side, and it's positive
    foreign key (user_id, entry_id)   references public.journal_entries (user_id, id) on delete cascade,
    foreign key (user_id, account_id) references public.accounts (user_id, id)
  )
  ```
  - indexes: entries `(user_id, entry_date desc, id desc)`; lines `(user_id, entry_id)` and `(user_id, account_id)`
  - lines keep insertion order (`id`); the same account may appear on more than one line
- **Balance invariant** `private.check_entry_balanced()`:
  - `security definer`, `set search_path = ''`, so it sees every line of the entry whoever fires it (including the cascade when a user is deleted)
  - deferred constraint triggers (`deferrable initially deferred`, checked at commit): after insert, update or delete on `journal_lines`, and after insert on `journal_entries`
  - for the affected entry, if it still exists: 2–20 lines, and Σ debit = Σ credit
  - errors use custom SQLSTATEs: `WM001` unbalanced, `WM002` wrong line count
  - `execute` revoked from `public`, `anon` and `authenticated`
- **Save function** `public.save_entry(p_entry_id bigint, p_entry_date date, p_description text, p_lines jsonb) returns bigint`:
  - `security invoker`, `set search_path = ''`, so RLS and grants apply as usual
  - `p_lines` is a JSON array of `{"account_id": 1, "debit_cents": 1000, "credit_cents": 0}`; anything else (not an array, a missing key, a non-integer) raises an error
  - `p_entry_id` null → inserts the entry and its lines; otherwise updates the date and description, deletes the entry's lines and inserts the new ones
  - an id that doesn't exist or isn't the caller's raises `P0002` (not found) and changes nothing
  - returns the entry id; the whole call is one transaction, and the triggers check it at commit
  - `execute` granted to `authenticated` only
- **RLS and grants** (all policies `to authenticated`, owner check `(select auth.uid()) = user_id`; nothing for `anon`):
  - `journal_entries`: `select`, `insert (entry_date, description)`, `update (entry_date, description)`, `delete`
  - `journal_lines`: `select`, `insert (entry_id, account_id, debit_cents, credit_cents)`, `delete`; no `update` (an edit replaces the lines)
- **Flutter:**
  - `lib/domain/models/`: `Entry`, `EntryLine`, `EntrySummary`, `AccountLine`, `EntryDraft`, `LineDraft`
  - `lib/data/repositories/journal_repository.dart` (abstract, `ChangeNotifier`) and `journal_repository_supabase.dart`
  - `lib/ui/journal/`: `JournalViewModel` + `JournalScreen`, `EntryEditorViewModel` + `EntryEditorScreen`
- **Draft validation** (`EntryDraft.validate()`, pure Dart, mirrors the database):
  - date in range; description trimmed, 1–200 characters
  - 2–20 lines; every line has an account and exactly one positive amount from `parseCents`
  - Σ debit = Σ credit > 0
- **Routes and screens:**
  - `/journal`:
    - entries newest first (`entry_date desc, id desc`): date, description, total debit
    - loads 50 more at the end of the list (keyset pagination, no offsets)
    - "New entry" button; empty state
  - `/journal/new` and `/journal/:id`:
    - date picker (default today), description, line rows, "Add line"
    - each line row: account picker (not-archived accounts; when editing, plus any archived account the line already uses), Debit and Credit fields, remove button
    - typing an amount in one column clears the other on that line
    - "Add line" is disabled at 20 lines; remove is disabled at 2
    - footer: total debit, total credit and difference, updated as the user types
    - Save is enabled only when the draft is valid
    - on `/journal/:id`: Delete, with a confirmation dialog
    - leaving with unsaved changes asks "Discard changes?"
    - an id that is missing, not a number or another user's shows "Entry not found" with a link back
- **Error mapping:** `WM001` → `unbalanced`; `WM002` → `lineCount`; `P0002` → `notFound`; `23503` (foreign key) → `invalidAccount`; `23514` (check) → `invalidInput`; `42501` → `notAllowed`.

**Out:**
- recurring or scheduled entries (Monthly automation is on the roadmap)
- search and filters, attachments, line memos (see Open questions)
- import from the spreadsheets, CSV export
- currencies other than USD

## Data owned

`public.journal_entries`, `public.journal_lines`, `private.check_entry_balanced()`, `public.save_entry(…)`.

## Interface exposed to other modules

```dart
final class LineDraft { const LineDraft({this.accountId, this.debitCents = 0, this.creditCents = 0}); final int? accountId; final int debitCents, creditCents; }
final class EntryDraft { final int? id; final DateTime date; final String description; final List<LineDraft> lines; List<EntryIssue> validate(); }
final class EntryLine { final int accountId; final int debitCents, creditCents; }
final class Entry { final int id; final DateTime date; final String description; final List<EntryLine> lines; }
final class EntrySummary { final int id; final DateTime date; final String description; final int totalCents; }
final class AccountLine { final int entryId; final DateTime date; final String description; final int debitCents, creditCents; }
final class Page<T> { final List<T> items; final Object? next; } // next == null on the last page

abstract class JournalRepository extends ChangeNotifier {
  Future<Result<Page<EntrySummary>>> listEntries({Object? after, int limit = 50});
  Future<Result<Entry>> getEntry(int id);
  Future<Result<int>> saveEntry(EntryDraft draft);
  Future<Result<void>> deleteEntry(int id);
  Future<Result<Page<AccountLine>>> listAccountLines(int accountId, {Object? after, int limit = 50});
}

enum JournalFailure { unbalanced, lineCount, invalidAccount, invalidInput, notFound, notAllowed, network, unknown }
```

- `JournalRepository` keeps no rows between calls. It notifies listeners after every successful save or delete, which is how `balance` knows to reload.
- `listAccountLines` orders by `entry_date desc, entry_id desc, id desc` and is used by the `balance` ledger.

## Security

- **Data classification:** sensitive (financial): dates, descriptions (which may name third parties) and amounts.
- **Trust boundaries:** the Data API (`/rest/v1/journal_*`, `/rest/v1/rpc/save_entry`) is callable directly with any user's token, so every rule lives in the database; the editor only mirrors it.
- **Abuse cases:**
  - an unbalanced, one-line or 21-line entry through the API → the deferred trigger rejects it at commit
  - an entry with no lines → the trigger on `journal_entries` rejects it
  - deleting one line of a two-line entry, or posting a line on its own → rejected at commit
  - changing an amount in place → no update grant on lines
  - a line on someone else's entry or account → the composite foreign keys include `user_id`
  - `save_entry` with another user's entry id → RLS hides it → not found, nothing changed
  - zero, negative, both-sided or huge amounts → check constraints (and `parseCents` in the app)
  - huge `p_lines` payloads → more than 20 lines are rejected
- **Logs:** no descriptions or amounts in logs.

## Acceptance criteria

1. **AC-JRN-1:** a balanced two-line entry saves and appears at the top of `/journal` with its date, description and total.
2. **AC-JRN-2:** Save stays disabled until the draft is valid (see Draft validation), and the footer shows the difference as the user types.
3. **AC-JRN-3:** typing in Debit clears Credit on that line and the reverse; amounts follow `parseCents`.
4. **AC-JRN-4:** "Add line" is disabled at 20 lines and remove at 2.
5. **AC-JRN-5:** these patterns, with made-up amounts, save and load back unchanged:
   - opening balance: Dr bank / Cr Capital
   - income: Dr bank / Cr Income
   - expense: Dr Expenses / Cr Cash
   - transfer: Dr Cash / Cr bank
   - paying for someone (3 lines): Dr Expenses + Dr A/R / Cr bank
   - card purchase: Dr Expenses / Cr Monthly; paying the card: Dr Monthly / Cr bank
   - being repaid: Dr Cash / Cr A/R
6. **AC-JRN-6:** editing changes the date, the description and the lines (adding and removing lines), and the list and the reopened entry show the change.
7. **AC-JRN-7:** delete asks for confirmation, then the entry and its lines are gone.
8. **AC-JRN-8:** invariant (pgTAP): rejected at commit: unbalanced; 1 line; 21 lines; an entry without lines; deleting one line of a two-line entry. Rejected by checks: a line with both sides, zero, a negative amount, or more than the maximum. Updating a line's amount → permission denied.
9. **AC-JRN-9:** ownership (pgTAP):
   - user B can't see A's entries or lines
   - B can't add a line to A's entry or use A's account in B's own entry
   - `save_entry` with A's entry id raises not found and A's entry is unchanged
   - `anon` can't select either table or execute `save_entry`
10. **AC-JRN-10:** an unbalanced entry sent directly to the Data API (integration test, and once with curl) is rejected with `unbalanced`.
11. **AC-JRN-11:** `/journal/abc`, a missing id and another user's id all show "Entry not found".
12. **AC-JRN-12:** with 120 entries, including several on the same date, scrolling loads 50, 100, then 120, with no duplicates or gaps.
13. **AC-JRN-13:** tapping Save twice quickly creates one entry.
14. **AC-JRN-14:** leaving the editor with unsaved changes asks to discard them; with no changes it leaves directly.
15. **AC-JRN-15:** archived accounts aren't offered for new lines; editing an entry whose line uses a now-archived account keeps that account on the line.
16. **AC-JRN-16:** every `EntryIssue` and `JournalFailure` has an English and a Spanish message.

## Tests

- `supabase/tests/030_journal_invariant.test.sql`: AC-JRN-8.
- `supabase/tests/031_journal_rls.test.sql`: AC-JRN-9.
- `supabase/tests/032_save_entry.test.sql`: insert, replace on edit, bad `p_lines` shapes, not found.
- `test/domain/models/entry_draft_test.dart`: AC-JRN-2 (validation table), AC-JRN-4 limits.
- `test/ui/journal/view_models/entry_editor_view_model_test.dart`: AC-JRN-2, AC-JRN-3, AC-JRN-4, AC-JRN-13, AC-JRN-14, AC-JRN-15.
- `test/ui/journal/view_models/journal_view_model_test.dart`: AC-JRN-12 (with a fake), AC-JRN-7.
- `test/ui/journal/widgets/*_test.dart`: AC-JRN-1, AC-JRN-11, AC-JRN-16.
- `test/data/repositories/journal_repository_supabase_test.dart` (fake client): error mapping, `p_lines` encoding.
- `test/integration/journal_repository_test.dart`: AC-JRN-5, AC-JRN-6, AC-JRN-10, AC-JRN-12 (keyset against the real database).
- Manual, recorded in `REVIEW.md`: AC-JRN-1 and AC-JRN-5 on the phone and in Chromium; the curl half of AC-JRN-10.

## Open questions

1. **Description required?** Proposed: yes, 1–200 characters, since every `Gastos.xlsx` row has one.
2. **Line memos:** `Gastos.xlsx` tracks A/R per person on the side. An optional memo per line (for example "A/R: who owes it") would cover that without per-person accounts. Add it in v1, or leave it for the per-person debts version?
