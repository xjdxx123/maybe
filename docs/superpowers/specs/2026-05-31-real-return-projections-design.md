# RealReturn Projections + Wealth Tier — Design Spec

**Date:** 2026-05-31
**Status:** Approved (brainstorming) — pending implementation plans
**Topic:** Forward-looking projection of the user's asset basket (20–30 yr) under pessimistic / neutral / optimistic scenarios via Monte Carlo on *building-block* expected real returns, plus a social wealth-tier placement (China national + global). Surfaced as a new "Projection" page reachable from the left nav.

---

## 1. Goal

Answer: **"Given my current asset basket, how does it plausibly develop over the next 20–30 years (pessimistic / neutral / optimistic), and what social wealth tier would it reach?"**

Concretely:
- A **rigorous, transparent methodology** for long-horizon expected returns per asset class (not extrapolated history).
- A **Monte Carlo** projection of the basket forward to chosen horizons (e.g., 2035 / 2040 / 2045), producing pessimistic / neutral / optimistic bands.
- A **wealth-tier** placement: where the basket sits today and at the projected median, vs **China national** and **global** wealth distributions.
- A **new left-nav page** showing a fan chart + terminal figures + tier + the editable assumption chain.

## 2. Relationship to existing RealReturn work

Builds on the shipped engine on branch `feature/real-return`:
- `RealReturn::{Xirr, Cpi, Benchmark, ReferenceData, Analysis, PortfolioReport}` (historical real return + benchmarks).
- Bundled annual data in `config/real_return/{cpi.yml, benchmarks.yml}` (used to estimate historical volatility & correlations).
- This feature adds a **forward** layer: capital-market assumptions, a Monte Carlo simulator, projection assembly, wealth-tier mapping, and a UI page.

## 3. Methodology — chain-structured building blocks (the "流程")

We use the **building-block / decomposition** method (academic + practitioner standard: Grinold-Kroner for equities; yield for bonds; cap-rate + growth for real estate; Erb-Harvey "golden constant" ≈ 0 for gold), **not** naive historical extrapolation. The inputs are organized along four transparent layers (matching the macro→valuation chain), all **documented + user-editable**:

1. **Macro** — expected inflation `π`, real risk-free / deposit rate, sovereign bond yield.
2. **Real growth** — expected real earnings growth (equities), real rent growth (real estate), tied to GDP/productivity assumptions.
3. **Cash-flow yield** — dividend yield − net dilution (equities); net rental yield / cap rate (real estate); gold has none.
4. **Valuation reversion** — expected ΔP/E or CAPE reversion (equities); Price/Rent reversion (real estate); real-gold-price mean reversion. **This layer is the primary lever for pessimistic vs optimistic.**

### Per-asset-class expected REAL return (the "neutral / medium" point estimate)

- **Equities** (`equity_cn`, `equity_us`): `E[r_real] = (dividend_yield − net_dilution) + real_earnings_growth + ΔPE_annualized`. Cross-check vs Damodaran implied ERP + (for CN) country risk premium = `default_spread × (equity_vol / bond_vol)`.
- **Real estate** (`real_estate_cn`, `real_estate_us`): `E[r_real] = net_rental_yield + real_rent_growth + ΔPriceRent_annualized`.
- **Government bonds** (`govbond`): `E[r_real] ≈ yield_to_maturity − π`.
- **Cash / deposit** (`deposit`): `E[r_real] ≈ deposit_rate − π`.
- **Gold** (`gold`): golden-constant `E[r_real] ≈ 0`, adjusted for current-vs-historical real price (mean-reversion drag possible).
- **Other / insurance / liquid products** (`other`): a stated/assumed yield class (e.g., the user's "流动资产 2.3%", "保险理财"), expressed real = `stated_nominal − π`.

**Sources (cited in the data files):** Grinold & Kroner (CFA curriculum); Damodaran ERP/country risk premium; Erb & Harvey "The Golden Dilemma"/"Golden Constant" (NBER); methodology echoes Vanguard VCMM / J.P. Morgan LTCMA (build blocks → Monte Carlo → percentile ranges).

### Scenarios = percentiles of the Monte Carlo outcome
Pessimistic / Neutral / Optimistic are **not** hand-set; they are **percentiles of the simulated horizon-T outcome**. **Defaults: neutral = 50th, pessimistic = 15th, optimistic = 85th** (a "likely range," not tail extremes; configurable). The band **narrows over 20–30 yr** (time diversification), as practitioners present it.

**Out of scope for this spec (future upgrade):** a fully *structural* macro model (population → productivity → GDP → wages → profits → EPS → PE modeled layer-by-layer). We adopt the building-block synthesis instead; a literal structural chain multiplies assumptions and compounding error without clearly improving a personal long-horizon forecast. The 4-layer organization above gives the chain's transparency without that machinery.

## 4. Architecture & components

Pure Ruby under `app/models/real_return/` (consistent with prior phases; fat models / POROs).

- **`RealReturn::Cma`** — Capital Market Assumptions. Reads `config/real_return/cma.yml` (the 4-layer inputs per asset class), computes each class's **expected real return** (building-block) and exposes its **volatility σ**. All inputs editable.
- **`RealReturn::AssetClass`** — maps an `Account` → asset-class key. Defaults by accountable type (`Property`→`real_estate_<region>`, `Investment`/`Crypto`→`equity_<region>`/`crypto`, `Depository`→`deposit`, `OtherAsset`→`other`), with an optional per-account override (stored on the account, e.g., metadata) for cases like "流动资产 2.3%".
- **`RealReturn::Correlation`** — cross-asset correlation matrix, estimated from the bundled historical annual series (`benchmarks.yml`) or a bundled fallback.
- **`RealReturn::MonteCarlo`** — inputs: per-asset `{value, expected_real_return, sigma, asset_class}`, correlation matrix, horizon (years), annual contribution (+ optional growth), seed. Simulates `N` correlated lognormal real-return paths; injects annual contributions; returns the **per-year distribution** of basket real value → percentile bands. RNG **seedable** (deterministic tests + stable display).
- **`RealReturn::Projection`** (per `Family`) — assembles the current basket (account values in base currency), maps to asset classes via `AssetClass`, runs `MonteCarlo`, and returns scenario trajectories (real, + nominal reference via an assumed inflation path) and terminal percentiles at each requested horizon.
- **`RealReturn::WealthTier`** — maps a (real) net worth to a **China national** and **global** wealth percentile via `config/real_return/wealth_distribution.yml` (log-linear interpolation; reuses the percentile-interpolation logic pattern from the original RealReturn W-series). Applied to current net worth and the projected neutral (and optionally pess/opt) real net worth, **vs today's distribution** (apples-to-apples in today's money). Returns percentile + a tier label.

## 5. Data (researched + bundled + editable; sourced & caveated)

- **`config/real_return/cma.yml`** — per asset class: the 4-layer building-block inputs + resulting expected real return (neutral) + volatility σ. Each entry carries `source` notes. Inputs are a documented snapshot (current dividend yields, CAPE/Price-Rent, bond/deposit yields, growth assumptions), refreshable. *Researched at implementation time from public sources, like the benchmark data.*
- **Correlation matrix** — estimated from `benchmarks.yml` annual series, or a small bundled matrix with documented values.
- **`config/real_return/wealth_distribution.yml`** — CN + WLD percentile → real-net-worth thresholds in **CNY (today's money)**. Researched from CHFS (China Household Finance Survey), Credit Suisse/UBS Global Wealth Report, WID.world. More granular than the original placeholder (e.g., 10/25/50/75/90/95/99th). Explicitly labeled **approximate** with `source`/`as_of`; wealth data is the weakest link (as flagged for real-estate).

Runtime stays **offline** (data assembled once and frozen, consistent with the project's approach).

## 6. Engine math

- **Expected real return** per class — §3 building-block formulas.
- **Monte Carlo**: each asset's annual real return drawn from a **correlated multivariate lognormal** (means = building-block `E[r_real]`, covariance from σ + correlation). Basket value compounds yearly; **annual contribution** added each year (split across assets by current weights or a target mix; v1: by current weights). Across `N` paths, take percentiles at each year → pess/neutral/opt bands. `N` large enough (e.g., 5,000–10,000) for stable percentiles; **seeded** RNG.
- **Nominal reference** = real path × assumed cumulative inflation (from the macro layer's `π`).
- **Wealth percentile**: log-linear interpolation of net worth within the distribution thresholds → percentile; percentile → tier label.

## 7. UI

### Left nav
Add a **"Projection"** item to `app/views/layouts/application.html.erb` `mobile_nav_items`, after "Returns": `{ name: "Projection", path: projection_path, icon: <valid lucide icon, e.g. "telescope" or "chart-line">, icon_custom: false, active: page_active?(projection_path) }`. So the nav reads **Home · Transactions · Budgets · Returns · Projection**.

### Page (`resource :projection, only: :show` → `ProjectionsController#show`)
1. **Parameters panel** — horizon target years (presets 2035 / 2040 / 2045, adjustable to ~30 yr); **annual savings** amount (+ optional annual growth %). Changing params re-runs the projection (Hotwire/Turbo; query params for state).
2. **Fan chart** — real net worth over time with pessimistic / neutral / optimistic shaded bands; nominal as a reference toggle. Real charting (D3 or a Stimulus controller / lightweight SVG) — the trend chart deferred in the Returns page is delivered here.
3. **Terminal cards** — for each target year: real net worth pess / neutral / opt (+ nominal reference).
4. **Social tier** — today's percentile (CN + global) and projected-neutral percentile, with tier labels and a "your position on the distribution" bar.
5. **Assumption chain panel** — the 4-layer building-block inputs per asset class, displayed and **editable**, with source citations (the transparency core).
- Built with Maybe's ViewComponents + Tailwind functional tokens + `icon` helper.

## 8. Error handling & edge cases

- Account with no asset-class mapping → fallback `other` (or excluded with a note).
- Missing CMA entry for a class → exclude that asset with a flagged note (no silent zero).
- Missing wealth-distribution data for a region → tier shows "n/a".
- Empty basket / zero net worth → clean empty state.
- Invalid params (negative contribution, horizon out of range) → validate & clamp.
- Monte Carlo: **seeded** RNG for reproducibility; enough paths for stable percentiles.
- Multi-currency basket → values normalized to `family.currency` (reuse `Money#exchange_to`).

## 9. Testing (Minitest + fixtures; never RSpec/factories)

- **`Cma`**: building-block formula per layer/class on known inputs.
- **`MonteCarlo`**: with a **fixed seed**, assert deterministic percentile outputs on a small known case (e.g., single asset, known mean/σ → percentiles match analytic lognormal within tolerance); contribution injection; correlation handling (2-asset correlated case).
- **`AssetClass`**: mapping per accountable type + override.
- **`WealthTier`**: percentile interpolation on known thresholds (CN + global); out-of-range → clamp/n-a.
- **`Projection`**: assembles a fixture family's basket and returns sane bands (pess ≤ neutral ≤ opt; bands present at each horizon).
- **Controller**: `#show` returns 200 and renders.

## 10. Phasing (each its own plan → spec → subagent implementation)

- **P-A — CMA core**: `RealReturn::Cma` (4-layer building-block math) + `AssetClass` mapping + researched/bundled `cma.yml` (with sources). Unit-tested against synthetic inputs.
- **P-B — Monte Carlo + Projection**: `Correlation`, `MonteCarlo` (seeded, correlated, contributions), `Projection` (basket assembly, real/nominal, scenarios). Unit-tested with fixed seed.
- **P-C — Wealth tier + data**: `WealthTier` + researched/bundled `wealth_distribution.yml` (CN + global). Unit-tested.
- **P-D — UI**: route + `ProjectionsController` + page (params, fan chart, terminal cards, social tier, assumption-chain panel) + **left-nav item** + browser verification.

## 11. Open questions / future scope

- **Full structural macro model** (population → … → PE) as an opt-in deeper mode.
- City-tier (一线城市) wealth distribution (data scarce).
- Rental-income modeling for properties (also benefits the historical Returns page — currently appreciation-only).
- Editable per-account asset-class override UI.
- Saving/sharing projection scenarios.
