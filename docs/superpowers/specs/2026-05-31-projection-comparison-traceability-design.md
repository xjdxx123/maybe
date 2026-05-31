# Projection: Portfolio Comparison + Traceability — Design Spec

**Date:** 2026-05-31
**Status:** Approved (brainstorming) — pending implementation plan
**Topic:** Two additions to the `/projection` page: (1) compare the current basket against alternative model portfolios (presets + custom allocation), and (2) a "methodology / formulas" panel that makes every projected number traceable (有迹可循).

---

## 1. Goal

- **Comparison:** show how the *same* starting capital + *same* annual savings would project under different allocations (current basket vs all-equity, 60/40, diversified, all-cash, and a custom mix) — a comparison table + the alternatives' median trajectories overlaid on the fan chart.
- **Traceability:** show the actual formulas and inputs behind the projection — per-asset-class building-block breakdown (with numbers), the Monte-Carlo method + parameters, and the Fisher real-terms identity — so nothing is a black box.

## 2. Relationship to existing code

Builds on the shipped projection engine on branch `feature/real-return`:
- `RealReturn::{Cma, AssetClass, Correlation, MonteCarlo, Projection}` (P-A/P-B), `ProjectionsController`, `app/views/projections/show.html.erb`, `ProjectionsHelper#projection_fan_svg`.
- Alternatives reuse `MonteCarlo` directly (it takes any `[{value:, expected_real_return:, sigma:}]` list), so no engine rewrite — just an allocation→asset-list builder and a comparison orchestrator.

## 3. Model portfolios (allocations)

Allocations are weights over **buckets**, mapped region-aware to CMA classes:

| Bucket | CMA class |
|---|---|
| `equity` | `equity_<region>` |
| `bonds` | `govbond` |
| `real_estate` | `real_estate_<region>` |
| `gold` | `gold` |
| `cash` | `deposit` |

`region = RealReturn::Region.real_estate(currency).downcase` (CNY→`cn`, else `us`).

**Presets** (weights over buckets, sum 1.0), in display order:
- **All equity** — `{equity: 1.0}`
- **60/40** — `{equity: 0.6, bonds: 0.4}`
- **Diversified** — `{equity: 0.4, bonds: 0.2, real_estate: 0.15, gold: 0.15, cash: 0.1}`
- **All cash** — `{cash: 1.0}`

**Current** is the user's actual basket (from `Projection`), shown as the baseline (band + median); it is NOT a fixed allocation.
**Custom** — user-entered bucket weights (normalized to 1.0).

Each alternative is projected with the **same** start capital (= current basket value), **same** annual savings, horizon, correlation, and RNG seed as the current projection — only the allocation differs.

## 4. Architecture & components

- **`RealReturn::ModelPortfolio`** (new, module/PORO):
  - `PRESETS` — ordered hash `name => { bucket => weight }`.
  - `bucket_class(bucket, currency)` → CMA class key (the table above).
  - `assets_for(weights, total:, currency:, cma:)` → `[{ value:, asset_class:, expected_real_return:, sigma: }]`: normalizes weights, allocates `total` by weight to each bucket's CMA class, pulls `expected_real_return`/`sigma` from `cma`; skips buckets whose CMA class is missing.
  - `expected_real_return(weights, currency:, cma:)` → weighted Σ of class expected real returns (normalized).
- **`RealReturn::PortfolioComparison`** (new, per family): given `(family, as_of:, horizon:, annual_contribution:, custom_weights:, cma:, correlation:, paths:, seed:)`, returns ordered `rows`, each `{ name:, weights: (nil for Current), expected_real_return:, median: [..], terminal: { p15:, p50:, p85: } }`. Row 0 = "Current" (reuses `Projection`); then presets; then "Custom" if `custom_weights` present and non-empty. Alternatives reuse `MonteCarlo` with `assets_for`.
- **`RealReturn::Cma#components(asset_class)`** (add) → the raw input hash for a class (`{kind:, dividend_yield:, ... , sigma:, source:}`) or nil — powers the formula breakdown.
- **`ProjectionsController#show`** (modify) — also reads custom-weight params, builds `@comparison = PortfolioComparison.new(...).rows`, and exposes the assumptions for the methodology panel.
- **`ProjectionsHelper`** (modify) — `projection_fan_svg(..., overlays:)` accepts extra median lines (dashed, distinct strokes); y-scale uses the max across the band and all overlays. Add `projection_formula(cma, asset_class)` → a human formula string with numbers (e.g. `"2.8% − 1.0% + 3.5% + 0.0% = 5.3%/yr"`).
- **`app/views/projections/show.html.erb`** (modify) — add: custom-allocation inputs in the params panel; the comparison table; overlay lines on the fan; the methodology/formulas panel.

## 5. Data flow

1. Controller: `projection = Projection.new(family, as_of:)`; `current = projection.project(horizon:, annual_contribution:)`; `start_value = current[:p50].first`.
2. `@comparison = PortfolioComparison.new(family, as_of:, horizon:, annual_contribution:, custom_weights:, ...).rows` — Current row reuses `current`; each alternative builds `ModelPortfolio.assets_for(weights, total: start_value, currency:, cma:)` → `MonteCarlo(...).run` (same horizon/seed/correlation/contribution).
3. View renders the fan (current band+median + alternatives' median overlays), the comparison table, and the methodology panel (per-class `projection_formula` via `Cma#components`, MC params, Fisher note).

## 6. Custom allocation input

Params panel adds 5 inputs named `w[equity]`, `w[bonds]`, `w[real_estate]`, `w[gold]`, `w[cash]` (parsed as `params[:w]`), **blank by default** — custom is opt-in; the four presets always show. Controller reads them into `custom_weights = { equity: params.dig(:w, :equity).to_f, ... }` as relative weights (e.g. `50 / 30 / 20`); `ModelPortfolio.assets_for` normalizes (they need not sum to 100). All blank/zero → no Custom row.

## 7. Methodology / formulas panel (traceability)

A section showing:
- **Per-asset-class building blocks (with numbers):** for each class in the current basket, render the formula from `Cma#components` → expected real return, e.g. `equity_cn: dividend 2.8% − dilution 1.0% + real growth 3.5% + valuation 0.0% = 5.3%/yr`; bonds = real yield; cash = real rate; gold = golden-constant ≈ 0. Each with its `source`.
- **Monte-Carlo method:** "each asset's annual real return ~ correlated lognormal (mean = expected real return, vol = σ); N paths; report 15th/50th/85th percentiles." Show the actual parameters: paths, seed, correlation ρ, horizon, annual contribution.
- **Real terms:** `real = (1 + nominal) / (1 + inflation) − 1` (Fisher); values are today's purchasing power.

## 8. Error handling & edge cases

- Empty basket → existing empty state (no comparison/methodology).
- A bucket whose CMA class is missing → skipped in `assets_for` (weights renormalize over the rest).
- Custom weights all zero/blank → omit the Custom row.
- Overlay y-scale includes all series' maxima so no line clips; `projection_fan_svg` returns "" when degenerate.
- All alternatives use the same seed as Current for comparability.

## 9. Testing (Minitest)

- **`ModelPortfolio`:** `assets_for` splits `total` by normalized weights to the right CMA classes with `cma` returns/σ; `expected_real_return` is the weighted average; missing CMA class skipped.
- **`PortfolioComparison`:** rows include Current + presets (+ Custom when weights given); each row has ordered terminal (p15 ≤ p50 ≤ p85) and a median array of horizon+1 length; all-cash row's expected real return equals the deposit CMA.
- **`Cma#components`:** returns the raw hash for a known class; nil for unknown.
- **`ProjectionsHelper`:** `projection_fan_svg` with overlays includes the extra polylines and scales to the combined max; `projection_formula` renders the component arithmetic string.
- **Controller:** `#show` (with and without custom-weight params) returns 200.

## 10. Out of scope (follow-ups)

- Saving named custom portfolios; rebalancing assumptions; per-bucket region choice (e.g. US equities for a CN investor); contribution allocated to a target mix (v1 splits by current weights inside `MonteCarlo`); nominal overlay.
