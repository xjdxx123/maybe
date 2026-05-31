# Real-return methodology: provenance & computation display

- **Date:** 2026-05-31
- **Branch:** feature/real-return
- **Status:** Approved (design), pending implementation plan

## Problem

The Projection page's "Methodology — every number is traceable" panel does not live up to its
name in two ways:

1. **Missing rows.** The panel iterates only the asset classes the user *holds*
   (`projection_asset_classes(@assets)`), but the "Compare portfolios" table shows numbers driven
   by model-portfolio classes the user may not hold (`equity_cn`, `govbond`, `gold`). Their
   formulas never appear — e.g. *All equity 5.3%/yr* is untraceable for a user holding only
   property/cash/other.
2. **No provenance.** Each shown class displays a one-line building-block formula
   (`projection_formula`) but never the **source / anchor** of each input, nor any signal of which
   inputs are *observable, data-anchored* values versus *judgment-based assumptions*. A user cannot
   tell "is this measured or guessed?" — which is precisely the question that motivated this work.

## Goal

Make every expected-real-return number shown anywhere on the Projection page fully traceable, in
the page itself, down to: each building-block input, its **signed contribution** to the total, its
**type** (`observable` vs `assumption`), and its **source/rationale**.

## Non-goals

- No econometric model (cointegration / ECM / fitted forecasting). The values remain transparent,
  editable assumptions; this work *exposes* their provenance, it does not change the methodology.
- No live data fetching. Inputs remain static, hand-maintained, as-of-dated values in
  `config/real_return/cma.yml`.
- No new numbers invented. We restructure provenance text **already present** in the YAML
  (`source:` strings + `#` comments). Assumptions stay labeled as assumptions.

## Approach (chosen: "A — granular breakdown")

Per asset class, replace the single formula line with a collapsible (`<details>/<summary>`,
Hotwire-first) breakdown table. Shown over the **page-referenced union** of asset classes
(held ∪ comparison), so the equity/gold/govbond rows appear automatically.

### Display

Panel header: overall `approach` + `as_of` (from `cma.yml` `metadata`) + a legend
(`● Anchored to data`, `○ Assumption (judgment)`).

Each asset class → `<details>`:
- **Summary:** `<asset_class> — <expected_real_return>/yr` + `σ`.
- **Expanded:** one row per building block — *label*, *signed contribution*, *type badge*, *source*
  — followed by a sum row equal to the expected real return.

Example (`real_estate_cn`, what the user holds):

```
▼ real_estate_cn — 0.6%/yr   σ 9%
    Input                Contribution   Type          Source / anchor
    Net rental yield     +1.6%          ● Anchored    Shanghai/CN residential net cap rate (market)
    Real rent growth     +0.0%          ○ Assumption  weak: demographics + oversupply
    Valuation reversion  −1.0%          ○ Assumption  elevated price/rent; BIS CN index correcting since 2021
    ──────────────────────────────────
    = Expected real return  0.6%/yr
```

### Signed contributions (also fixes an existing display bug)

`breakdown` returns each component's **signed contribution to the sum**, matching
`Cma#expected_real_return`'s formula — not the raw stored value. Notably `net_dilution` is stored
positive but *subtracted*, so its contribution is `−net_dilution`:
- `equity_cn`: dividend +2.8, dilution **−1.0**, real growth +3.5, valuation +0.0 → **5.3**
- `equity_us`: dividend +1.3, dilution **+0.5** (buybacks add), real growth +2.5, valuation −1.5 → **2.8**

This removes the current double-negative wart in `projection_formula` (`− dilution -0.5%`); rows
simply sum to the total.

## Data model changes

### `config/real_return/cma.yml`
- **Values unchanged.** Restructure the per-class `source:` string into a structured `sources:`
  map (component key → short source text), sourced from the existing inline comments / `source:`
  text. Keep `metadata` (`approach`, `as_of`, overall `sources`).
- Provenance text must remain honest: assumption inputs keep "assumption …" wording.

### `RealReturn::Cma` (`app/models/real_return/cma.rb`)
- Add `breakdown(asset_class)` → ordered `[{ key:, label:, contribution:, type:, source: }]` whose
  contributions sum to `expected_real_return(asset_class)`.
- `type` and human `label` come from a model-level constant keyed by component key (methodological
  facts, independent of the stored numbers):

  | key | label | type |
  |---|---|---|
  | `dividend_yield` | Dividend yield | observable |
  | `net_dilution` | Net dilution / buybacks | observable |
  | `real_earnings_growth` | Real earnings growth | assumption |
  | `valuation_reversion` | Valuation reversion | assumption |
  | `net_rental_yield` | Net rental yield | observable |
  | `real_rent_growth` | Real rent growth | assumption |
  | `real_yield` | Real yield | observable |
  | `real_rate` | Real rate | observable |
  | `real_return` | Real return | assumption |

  (`observable` ⇒ `● Anchored`; `assumption` ⇒ `○ Assumption`. Nuance, e.g. "real yield = yield −
  expected inflation," lives in the source text.)
- `source` per component read from the new `sources:` map (fallback "—" if absent).
- `expected_real_return`, `sigma`, `components`, `asset_classes` **unchanged**.

### `RealReturn::PortfolioComparison` (`app/models/real_return/portfolio_comparison.rb`)
- Memoize the internal `projection` (currently a local in `rows`) so it can be reused.
- Add `referenced_asset_classes` → ordered, de-duped CMA classes across all rows:
  `held (projection.assets) + PRESETS-resolved + custom-resolved`, via
  `ModelPortfolio.resolved` (already filters to positive-weight, valid-CMA buckets).
  Held ⊆ Current row, so this equals "every class any comparison row uses."

## Controller (`app/controllers/projections_controller.rb`)
- Keep one comparison instance instead of discarding it:
  ```ruby
  comparison = RealReturn::PortfolioComparison.new(...)
  @comparison = comparison.rows
  @methodology_classes = comparison.referenced_asset_classes
  ```

## View (`app/views/projections/show.html.erb`)
- Methodology panel: iterate `@methodology_classes` (not `projection_asset_classes(@assets)`).
- Render each class as a `<details>` with the breakdown table + header legend/metadata.
- `projection_formula` becomes redundant for this panel; remove it (and its helper test) or leave
  unused — decide during planning (lean: remove to avoid dead code).

## Honesty constraints (hard)

- `● Anchored` only for inputs with a genuine market/index source (yields, cap rates, rates,
  valuation level). `real_earnings_growth`, `real_rent_growth`, `valuation_reversion`, and gold/
  other/crypto `real_return` are always `○ Assumption`.
- Do not imply freshness/precision the data lacks: header states the single `as_of` date; values
  are static.

## Testing

- `Cma#breakdown`: a known class returns correct labels, **signed** contributions summing to
  `expected_real_return`, correct `type`s, and source strings. Verify `net_dilution` sign for both
  `equity_cn` (−) and `equity_us` (+).
- `PortfolioComparison#referenced_asset_classes`: a family holding only property/cash/other still
  includes `equity_cn`, `govbond`, `gold` (proves comparison numbers became traceable).
- Update any existing test/fixture that referenced the old scalar `source:` field
  (grep `cma_test`, `bundled_data_test`, `test/fixtures/files/real_return/cma.sample.yml`).

## Edge cases

- `start_value <= 0`: `rows` returns only *Current*, but `referenced_asset_classes` still lists
  presets. Chosen: **keep it simple** — listing the preset assumptions in the degenerate net-worth
  case is harmless and still valid reference. Not mirroring `rows` exactly.

## Files touched

- `config/real_return/cma.yml` (restructure `source:` → `sources:`)
- `app/models/real_return/cma.rb` (add `breakdown` + label/type map)
- `app/models/real_return/portfolio_comparison.rb` (memoize `projection`, add `referenced_asset_classes`)
- `app/controllers/projections_controller.rb` (wire `@methodology_classes`)
- `app/views/projections/show.html.erb` (breakdown UI)
- `app/helpers/projections_helper.rb` (remove/retire `projection_formula` if unused)
- tests + possibly `test/fixtures/files/real_return/cma.sample.yml`
