# Module Spec: `accounts`

> Depends on: `auth` · Used by: `journal`, `balance` · Delivery: Stage 3 (`v0.3.0`)
> Status: draft, awaiting review

## Objective

Give each user their own chart of accounts, laid out like `Accounting.xlsx`. Every user starts with the default chart and adds their own bank, wallet and card accounts. v1 has a single Capital, Income and Expenses account per user (sub-accounts are on the roadmap).

## Scope

**In**
- **Table `public.accounts`:**
  ```sql
  id         bigint generated always as identity primary key,
  user_id    uuid not null default auth.uid() references auth.users (id) on delete cascade,
  name       text not null check (name = btrim(name) and char_length(name) between 1 and 60),
  section    text not null check (section in ('asset', 'liability', 'equity', 'income', 'expense')),
  archived   boolean not null default false,
  created_at timestamptz not null default now(),
  unique (user_id, id),  -- target for journal's composite foreign key
  check (not archived or section in ('asset', 'liability'))
  ```
  plus a unique index on `(user_id, lower(name))`
- **RLS and grants:**
  - RLS enabled; nothing granted to `anon`
  - `authenticated`: `select`; `insert (name, section)`; `update (name, archived)`; no `delete` (archive instead)
  - policies, all `to authenticated`:
    - select: `(select auth.uid()) = user_id`
    - insert: with check `(select auth.uid()) = user_id and section in ('asset', 'liability')`
    - update: using and with check `(select auth.uid()) = user_id`
- **Default chart:**
  - `private.seed_default_accounts(p_user_id uuid)` (`security definer`, `set search_path = ''`) inserts the chart below, only if the user has no accounts yet
  - `private.create_default_accounts()` is an `after insert` trigger on `auth.users` that calls it
  - the migration also calls it for every existing user, since Stage 2 users already exist on staging and production
  - `execute` on both is revoked from `public`, `anon` and `authenticated`

  | Order | Name | Section |
  |---|---|---|
  | 1 | Cash | asset |
  | 2 | A/R | asset |
  | 3 | Monthly | liability |
  | 4 | A/P | liability |
  | 5 | Capital | equity |
  | 6 | Income | income |
  | 7 | Expenses | expense |

  Monthly holds subscriptions, recurring bills and credit cards. Users add accounts such as their bank (asset) or a specific card (liability).
- **Flutter:**
  - `lib/domain/models/account.dart`: `Account`
  - `lib/data/repositories/accounts_repository.dart` (abstract, `ChangeNotifier`) and `accounts_repository_supabase.dart`
  - `lib/ui/accounts/`: `AccountsViewModel`, `AccountsScreen`
- **Accounts screen** (`/accounts`):
  - sections in sheet order (Assets, Liabilities, Equity, Income, Expenses) with localized headings; inside a section, creation order
  - "Add account": name + section, where only Asset and Liability are offered
  - each row's menu: Rename; Archive / Unarchive (assets and liabilities only)
  - "Show archived" toggle, off by default; archived rows are dimmed
  - loading, empty-error and retry states use the shared `LoadingView` / `ErrorView`
- **Error mapping:** Postgres `23505` (unique) → `duplicateName`, `23514` (check) → `invalidName`, `42501` (permission / RLS) → `notAllowed`, no row updated → `notFound`.

**Out:**
- deleting accounts
- more than one equity, income or expense account; sub-accounts or categories
- changing an account's section
- balances on this screen (`balance` adds the ledger link)
- per-person A/R and A/P
- localized default names (see Open questions)

## Data owned

`public.accounts`, `private.seed_default_accounts(uuid)`, `private.create_default_accounts()`.

- Archived accounts keep their lines and still count in every balance.
- The journal editor doesn't offer archived accounts for new lines.

## Interface exposed to other modules

```dart
final class Account {
  const Account({required this.id, required this.name, required this.section, required this.archived});
  final int id;
  final String name;
  final AccountSection section;
  final bool archived;
}

abstract class AccountsRepository extends ChangeNotifier {
  /// All of the user's accounts (archived included), sheet order then creation order.
  UnmodifiableListView<Account> get accounts;
  Future<Result<void>> load();
  Future<Result<Account>> create(String name, AccountSection section);
  Future<Result<void>> rename(int id, String name);
  Future<Result<void>> setArchived(int id, bool archived);
}

enum AccountsFailure { duplicateName, invalidName, notAllowed, notFound, network, unknown }
```

- **For `journal`:**
  - foreign key target `(user_id, id)`
  - pick accounts from `AccountsRepository.accounts` where `!archived`
- **For `balance`:** every account, archived included, with its section.
- **Caching:** `AccountsRepositorySupabase` caches the list. It clears the cache and reloads when the client's auth state reports a sign-out or a different user.

## Security

- **Data classification:** sensitive (financial): account names can reveal banks and cards.
- **Trust boundaries:** the Data API (`/rest/v1/accounts`) is callable directly with any user's token.
- **Abuse cases:**
  - user B reads, renames or archives user A's account → RLS returns 0 rows
  - inserting with `user_id` = A → no insert grant on `user_id` → permission denied
  - moving an account to another user or section → no update grant on `user_id` or `section`
  - creating a second Income to split it → the insert policy only allows asset and liability
  - deleting an account that has lines → no delete grant
  - names with control characters or 10,000 characters → trim and length check, in the app and the database
  - calling the seed function from a client → `private` schema, no execute grant

## Acceptance criteria

1. **AC-ACC-1:** a new user has exactly the seven default accounts with the sections in the table (pgTAP + screen).
2. **AC-ACC-2:** after the migration, a user who existed before it also has the default chart. Running `seed_default_accounts` twice doesn't add duplicates.
3. **AC-ACC-3:** the Accounts screen groups accounts by section in sheet order, with English and Spanish headings.
4. **AC-ACC-4:** adding "Chase" as an asset shows it under Assets. A name differing only in letter case from an existing one shows the duplicate message. Surrounding spaces are trimmed; an empty name or one over 60 characters is refused on the screen.
5. **AC-ACC-5:** rename works, with the same name rules.
6. **AC-ACC-6:** archiving hides an asset or liability account unless "Show archived" is on; unarchiving brings it back. Equity, income and expense rows have no archive action.
7. **AC-ACC-7:** pgTAP deny-tests:
   - user B can't select, update or archive user A's accounts (0 rows)
   - inserting with `user_id` set, updating `section` or `user_id`, and deleting all fail with a permission error
   - inserting an equity, income or expense account fails
   - archiving an equity, income or expense account fails the check
   - `anon` can't select
   - duplicate (case-insensitive), untrimmed, empty and 61-character names fail
8. **AC-ACC-8:** integration test: `alice` and `bob` (seed users) each see only their own accounts through `AccountsRepositorySupabase`.
9. **AC-ACC-9:** signing out and in as a different user never shows the previous user's accounts, not even briefly.
10. **AC-ACC-10:** every `AccountsFailure` maps to a message in English and Spanish.

## Tests

- `supabase/tests/020_accounts.test.sql`: AC-ACC-1 (data), AC-ACC-2 (idempotency), AC-ACC-7.
- `test/data/repositories/accounts_repository_supabase_test.dart` (fake client): error mapping, ordering, cache clearing on a user change (AC-ACC-9, AC-ACC-10).
- `test/ui/accounts/view_models/accounts_view_model_test.dart` (with `FakeAccountsRepository`): AC-ACC-4, AC-ACC-5, AC-ACC-6.
- `test/ui/accounts/widgets/accounts_screen_test.dart`: AC-ACC-3, AC-ACC-6, AC-ACC-10.
- `test/integration/accounts_repository_test.dart`: AC-ACC-8.
- Manual, recorded in `REVIEW.md`: AC-ACC-1 (screen), AC-ACC-2 on staging after the deploy, AC-ACC-9 on the phone.

## Open questions

1. **Default account names** are created in English (Cash, A/R, Monthly, A/P, Capital, Income, Expenses), since the server doesn't know the device language. Users can rename them. Keep English, or show localized names in the app for default accounts the user hasn't renamed (needs a `default_key` column)?
2. Should the default chart include a bank account (for example "Bank"), as `Gastos.xlsx` did, or is Cash enough as the starting asset?
