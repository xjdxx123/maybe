# Real Return on Maybe — Design Spec

**Date:** 2026-05-30
**Status:** Approved (brainstorming) — pending implementation plan
**Topic:** Lifetime real (inflation-adjusted) money-weighted returns + opportunity-cost benchmark comparison, built on top of the Maybe app.

---

## 1. Goal

Answer, for a Maybe user, the question they actually care about across their lifetime of capital-allocation decisions:

> *Did this investment make or lose money, did it beat inflation, and would I have done better putting the same money somewhere else?*

Concretely, for **each asset** and for the **whole portfolio**, compute and display:

1. **Nominal gain** — absolute and total % (Maybe already does this).
2. **Annualized return** — money-weighted (XIRR) where there are multiple cashflows, CAGR for a single buy→now.
3. **Real return** — the annualized return after deflating by CPI ("did it beat inflation?").
4. **Opportunity cost** — what the same money, contributed on the same dates, would be worth today in each benchmark vehicle (S&P 500, CSI 300, gold, bank deposit, government bond, real-estate index).

This is the "RealReturn" concept the user originally scoped, now built **on Maybe's data model** instead of a from-scratch app.

## 2. What Maybe already does, and the gap

Grounded in the current codebase:

- `Property#purchase_price` = first valuation amount (the `opening_anchor`); `Property#trend` = `Trend.new(current: account.balance_money, previous: first_valuation_amount)` → already yields **nominal** absolute + % gain.
- `Valuation` has `kind` enum: `reconciliation`, `opening_anchor` (purchase price), `current_anchor` (current market value).
- `Account` → `entries` → `valuations` / `trades`; plus `holdings`, `balances`. `delegated_type :accountable` over `Depository, Investment, Crypto, Property, Vehicle, OtherAsset, CreditCard, Loan, OtherLiability`.
- `BalanceSheet.new(family)` is the portfolio aggregation pattern (`Monetizable`, `net_worth`, `net_worth_series`).
- `Provider::Registry` + concept interfaces (`Provider::SecurityConcept`, `Provider::ExchangeRateConcept`), implemented by `Provider::Synth`.

A full-repo grep for `inflation | cpi | annualized | cagr | xirr | money.weighted` returns **zero hits**. So Maybe has **nominal gain + value-over-time + net worth**, but has **none** of: annualized/money-weighted return, inflation adjustment, or opportunity-cost benchmark comparison. Those three are exactly what this feature adds.

## 3. Scope & non-goals

**In scope (v1):**
- Per-asset and portfolio-level analysis for **investment-decision asset** accounts: `Investment, Crypto, Property, Vehicle, OtherAsset`.
- The four metrics in §1.
- A dedicated "Real Return" page in Maybe.
- Bundled annual reference data (CPI + benchmarks), behind a provider interface.
- Multi-currency consolidation into `family.currency`.

**Non-goals (v1, noted for the future):**
- **Liability accounts** (`CreditCard, Loan, OtherLiability`) — mortgage interest cost / debt return modeling is out of scope; liabilities still affect net worth via `BalanceSheet`, but get no per-asset return calc.
- **`Depository` (cash/checking/savings)** — "did my cash keep up with inflation" is meaningful but requires separating principal deposits from interest across many transactions; deferred. Cash balances still appear in the net-worth chart via `BalanceSheet`.
- **Live market/economic data** — bundled annual series only; the provider interface leaves room to add live sources (Synth/FRED) later with no call-site changes.
- **Wealth percentile** (national/global "where do I rank") — designed in the original RealReturn; deferred to a later milestone behind the same data layer.
- **Capital improvements / partial sells of property** — only purchase + current value (+ optional intermediate user valuations) are modeled for manually-valued assets.

## 4. Product decisions (locked during brainstorming)

| Decision | Choice |
|---|---|
| Depth of analysis | **Full**: nominal + annualized + real (CPI) + opportunity-cost benchmark |
| Lens | **Both** per-asset and portfolio, equally weighted |
| Data entry | **Reuse Maybe's existing account/valuation flow** — no new input UX; we read existing data |
| Compute + data location | **Pure Ruby inside Maybe + bundled annual reference data** (no Python sidecar, no required live feed) |
| Property current value / trajectory | **User's number wins; fall back to a regional house-price index estimate when absent, clearly labeled "estimated".** Market-priced assets (Investment/Crypto) are never estimated. |
| Benchmark set | Stocks/ETF (S&P 500, CSI 300), gold, bank deposit, government bond, real-estate index |

## 5. Architecture & domain model

Pure Ruby, under `app/models/real_return/` (Maybe convention: fat models / POROs, **no** `app/services/`). Self-answering entry points in the spirit of `account.balance_series`.

### 5.1 Objects

- **`RealReturn::Analysis`** (per account) — input: an `Account`. Produces nominal, annualized, real, and per-benchmark opportunity-cost results for that asset. Internally:
  1. **Cashflow extraction** (absorbs account-type differences — see §5.2).
  2. **Valuation resolution** for the ending value & trajectory (see §5.3).
  3. Delegates math to the PORO calculators (§5.4).
- **`RealReturn::PortfolioReport`** (per family) — mirrors `BalanceSheet.new(family)`. Merges per-account cashflow series into one schedule → portfolio money-weighted real return + portfolio-level benchmark league table. Iterates only over in-scope asset accounts.
- **`RealReturn::Xirr`** — money-weighted IRR solver (Newton-Raphson with bisection fallback).
- **`RealReturn::Cpi`** — CPI lookup + annualized-inflation + real-return (Fisher) helper.
- **`RealReturn::Benchmark`** — counterfactual terminal value & money-weighted return for a given cashflow schedule against one benchmark series; builds the league table.

### 5.2 Cashflow extraction by accountable type

A cashflow is `{date:, amount:}` in `family.currency` (outflows = contributions = negative; ending value = positive terminal mark). The terminal value is appended at the `as_of` date.

| Accountable | Contribution cashflows | Terminal value | Estimated? |
|---|---|---|---|
| `Investment`, `Crypto` | `trades` (qty × price ± fees), as real cashflows on trade dates | current `holdings` market value (Maybe-priced) | No |
| `Property` | `opening_anchor` valuation amount @ its date (the purchase) | latest user valuation if present; else **house-price-index estimate** | Only when estimated |
| `Vehicle`, `OtherAsset` | `opening_anchor` valuation @ date | latest user valuation; else (Vehicle) optional depreciation curve, (OtherAsset) require user value | Vehicle: maybe; OtherAsset: no estimate |

Intermediate `reconciliation` valuations on manually-valued assets are **marks** (used to draw the trajectory), **not** cashflows.

### 5.3 Valuation resolution rule (manually-valued assets)

```
current_value =
  user's latest valuation            if present
  else purchase_price × ( house_index[as_of_year] / house_index[purchase_year] )   # flagged estimated: true
  else  → mark account "needs current value" (skip return calc, no crash)

trajectory_point(year) =
  user valuation for that year        if present
  else purchase_price × ( house_index[year] / house_index[purchase_year] )         # estimated
  else linear interpolation between nearest known points (no regional index)
```

- Every estimated figure carries `estimated: true` → the UI renders an "指数估算 / index-estimated" label + a tooltip noting the index reflects the **regional average**, not this specific property.
- The `house_index` is the `real_estate` benchmark series (§6), region-keyed — **one dataset, two uses** (fallback valuation **and** opportunity-cost benchmark).

### 5.4 The math (algorithms ported from the validated RealReturn Python engine, used as oracles)

- **XIRR**: find `r` such that `Σ CF_i / (1+r)^(t_i) = 0`, with `t_i = (date_i − date_0)/365.0`. Newton-Raphson; on non-convergence or sign issues, bisection over `[-0.9999, 10]`; final fallback CAGR.
- **CAGR** (single contribution → terminal): `(terminal / contribution)^(1/years) − 1`.
- **Annualized inflation** over the holding period: `π = (CPI[end] / CPI[start])^(1/years) − 1`.
- **Real return** (Fisher): `r_real = (1 + r_nominal) / (1 + π) − 1`. "Beat inflation" ⟺ `r_real > 0`.
- **Benchmark counterfactual**: invest each contribution `c_i` into benchmark `B` at its level `B(date_i)`; terminal value `V_B = Σ c_i × B(as_of) / B(date_i)`. Report `V_B` and its money-weighted return on the same schedule, so it is apples-to-apples with the asset. League table ranks `V_B` (and real return) across benchmarks + the asset itself.

### 5.5 Multi-currency

All amounts normalized to `family.currency` before any math, using Maybe's existing `ExchangeRate` / provider. CPI area defaults from currency/country (CNY→CN, USD→US, else WLD). Money formatting is server-side via `Money` (Maybe convention).

## 6. Data layer (bundled annual reference series + provider interface)

### 6.1 Interface

`RealReturn::ReferenceData` — a concept interface mirroring `Provider::*Concept`:

- `cpi(area:, year:)` → index value
- `benchmark_level(key:, year:, currency:)` → index/level value (`key ∈ {sp500, csi300, gold, deposit, govbond, real_estate}`)
- `available_years(series)` → range, for graceful out-of-range handling

A single bundled implementation `RealReturn::ReferenceData::Bundled` reads YAML. Swapping in a live source later (Synth/FRED) means adding a new implementation — **no call-site changes**.

### 6.2 Bundled data files (`config/real_return/`)

- `cpi.yml` — annual CPI index per area: `CN`, `US`, `WLD`.
- `benchmarks.yml` — annual total-return level per series, where relevant region-keyed (esp. `real_estate`): `sp500`, `csi300`, `gold`, `deposit`, `govbond`, `real_estate`.

**There is no curated dataset to "port".** The original RealReturn fetched all benchmark prices/FX live via yfinance and CPI via a live FRED-style `CpiSource`; its `benchmarks.yaml` held only ticker *definitions*, and tests used in-memory synthetic data (`sources/memory.py`). What *is* reusable is the **validated pure math** (XIRR, Fisher real-return, counterfactual terminal value), which we port to Ruby.

The bundled annual series are therefore **assembled once from cited public sources** and frozen into the YAML files (so runtime stays offline). Each series file records `source:` and `as_of:`. Canonical sources: US/CN CPI from FRED-style public CPI tables; index annual closes (S&P 500, CSI 300) and gold from public market data; deposit/govbond from published reference rates; `real_estate` from Case-Shiller/FHFA (US) and NBS 70-city (CN). This is a deliberate data task, **not hand-fabricated numbers in the plan** — and it is isolated so the engine can be built and unit-tested against synthetic series before any real data exists.

### 6.3 Sourcing & accuracy notes

- **Granularity is annual.** For decade-scale decisions this is accurate enough, and keeps the feature offline, deterministic, testable, and self-host-friendly.
- **`real_estate` is the weakest series and is labeled as such.** US has clean long-history indices (Case-Shiller / FHFA). China's freely available data is mainly NBS 70-city price indices; city-level *total-return* series are sparse. The UI must surface data provenance + a precision caveat for real estate, and never imply false precision.
- Each series file carries `source:` and `as_of:` metadata for display.

## 7. UI surface

### 7.1 Route & controller

- `resource :real_return, only: :show` → `RealReturnsController#show`, scoped to `Current.family`.
- Add a nav entry alongside the existing dashboard.

### 7.2 Page layout (minimalist, per the user's DESIGN.md taste; both lenses)

1. **Portfolio overview card** — portfolio real annualized %, a **beat-inflation badge** (✓/✗), and a **net-worth-vs-CPI cumulative chart** (one nominal net-worth line + one CPI baseline line → see at a glance whether you beat inflation). The return/benchmark metrics are computed over the in-scope **decision assets**; the net-worth line uses Maybe's familiar `BalanceSheet` net worth (all accounts, including cash). This split is stated on the card so the two numbers aren't conflated.
2. **Per-asset scorecard table** — one row per asset account: nominal % / annualized % / real % / vs-best-benchmark. Estimated values carry an "index-estimated" tag. Clicking a row drills into that asset (its cashflow timeline + its counterfactual curves vs each benchmark).
3. **Benchmark league table** — your portfolio vs S&P 500 / CSI 300 / gold / deposit / govbond / real-estate: same money, same dates, terminal value today (opportunity cost).

### 7.3 Components & styling

Reuse Maybe's existing ViewComponents and chart components; Tailwind **functional tokens** only (`text-primary`, `bg-container`, …); the `icon` helper (never `lucide_icon`). No new design-system styles.

## 8. Error handling & edge cases

- Account missing purchase price/date → tag "needs purchase info", skip its return calc (no crash).
- Benchmark/CPI missing a year → nearest available / linear interpolation; out of data range → mark `n/a`.
- Current value missing **and** no regional house index → degrade to "needs current value" (do **not** fabricate).
- XIRR non-convergence → fall back to CAGR.
- Divide-by-zero (`previous == 0`) → reuse Maybe `Trend`'s existing ∞ handling.
- Missing exchange rate for a currency leg → annotate and skip that leg rather than crash.

## 9. Testing (Minitest + fixtures — never RSpec/factories)

- **Fixtures:** one `Property` (with `opening_anchor` + `current_anchor` valuations) and one `Investment` account (with trades + holdings).
- **Algorithm POROs** (`Xirr`, `Cpi`, `Benchmark`): known-input→known-output, using the validated cases from the RealReturn Python test suite as oracles.
- **`RealReturn::Analysis`:** correct cashflow extraction per account type; the "user value wins, else index-estimate and flag `estimated`" branch.
- **`RealReturn::PortfolioReport`:** correct aggregation across asset accounts; liabilities excluded.
- **Controller:** `#show` returns 200 and renders the key figures.
- Test only critical paths; do not test ActiveRecord itself.

## 10. Open questions / future scope

- Live data adapters (Synth for prices/FX; FRED for CPI/rates) behind `RealReturn::ReferenceData`.
- Wealth percentile (national/global) reusing the same data layer.
- Liability-aware "true net" lifetime return (mortgage cost vs property appreciation).
- Capital improvements / partial dispositions for property.
- Upstreamability: keep everything idiomatic so it could be proposed to maybe-finance if desired.
