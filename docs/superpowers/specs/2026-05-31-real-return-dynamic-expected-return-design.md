# Real-return: dynamic (non-constant) expected return

- **Date:** 2026-05-31
- **Branch:** feature/real-return
- **Status:** Implemented. (This spec was revised mid-design: an initial Gaussian "parameter
  uncertainty" layer was **replaced by a regime mixture** — see "Uncertainty layer" below. The
  implementation plan `docs/superpowers/plans/2026-05-31-real-return-dynamic-expected-return.md` is
  the authoritative task-level record.)

## Problem

The projection treated each asset's expected real return as a single known constant for all
horizons, all years, and all simulated paths. In reality the long-run mean is **uncertain and
regime-dependent**, the growth term **trends** over decades (e.g. China growth maturing), and a
**valuation gap reverts over the horizon** (a CAPE normalizing 33→20 is a far bigger annual drag
over 10y than 30y). A fixed constant misrepresents all three. The Monte Carlo already varied
returns *year to year* via σ; what was wrongly held fixed is the **mean**.

This work was shaped by two reference frameworks the user supplied: a Siegel/Arnott building-block
CMA decomposition (which the module already embodies), and a McQuarrie structural/regime critique
(non-stationarity, skew, "few regimes dominate"). The reconciliation for a long-horizon **personal
projector** is: keep the transparent decomposition as the central tendency, make valuation
horizon-aware, let growth glide, and represent regime risk as an explicit, editable mixture that
skews the bands — rather than a fitted regime-detection oracle (infeasible, and McQuarrie's own
"transitions are unpredictable" undercuts forecasting them).

## Goal

For asset *i*, path *p*, year *t*:

> **μ_i(t,p) = lerp(mean_start_i, mean_end_i, t/N) + regimeOffset_i(g_p)**

- **glide** — `mean_start`/`mean_end` differ when a growth component has a `glide:` terminal; the
  mean interpolates linearly over the horizon. Flat otherwise.
- **valuation, horizon-amortized** — `(target/current)^(1/N) − 1` (constant across years for a given
  N), baked into both `mean_start` and `mean_end`. Replaces the fixed annual `valuation_reversion`.
- **regime mixture (the uncertainty layer)** — one macro regime `g_p` is drawn **per path** from a
  global mixture `{base, bear, bull}` (probabilities sum to 1), **shared across all assets** in the
  path; each asset applies its `regime_offsets[g_p]` for all years (`base` ⇒ 0). A bear-heavier,
  deeper offset gives the left-skewed, structural-impairment tail.

Then `drift = log(1+μ) − 0.5σ²`, clamp μ > −0.99; returns stay correlated-lognormal; σ unchanged.

**`expected_real_return`** (displayed/weighted) is the **base-regime** central return
`(mean_start+mean_end)/2`; the regime mixture is the dispersion layer (median ≈ base; the bands and
mean skew down). The panel shows base + the regime mix explicitly.

**Backward-compatible:** a class with fixed `valuation_reversion`, no `glide`, no `regime_offsets`,
under a regime-free MC run, behaves exactly as before (and `expected_real_return` with no horizon
returns the old constant). **Reproducible:** the regime draw is seeded and is skipped (no RNG
consumed) when the mixture is empty.

## Uncertainty layer: why a regime mixture (not Gaussian)

An earlier draft modeled mean uncertainty as a continuous Gaussian offset ε ~ N(0, τ²) per path.
That was replaced by a **discrete regime mixture** because: (1) it literally implements the hybrid
`Σ P(regime)·E[R|regime]`; (2) it produces **skew** (a heavier/deeper bear), which a symmetric
Gaussian cannot; (3) per-year fat tails wash out over a 30-year terminal distribution (CLT) — the
real long-horizon risk is a *persistent* bad regime, which a per-path shared regime captures; (4) it
is transparent and editable (regime probabilities + per-class offsets live in `cma.yml`).

## Data model — `config/real_return/cma.yml`

```yaml
regimes:                 # global mixture (sum to 1); bear heavier than bull ⇒ left skew
  base: 0.60
  bear: 0.25
  bull: 0.15

equity_us:
  ...
  valuation:             # replaces fixed valuation_reversion for this class (horizon-amortized)
    current: 33          # CAPE
    target: 20
  glide:                 # only components that trend
    real_earnings_growth: 0.020
  regime_offsets:        # per-class real-return offset; base implied 0
    bear: -0.04
    bull:  0.02
  sources: { ... valuation:, glide:, regime_offsets: documented ... }
```

- `valuation:{current,target}` preferred; absent ⇒ fixed `valuation_reversion` (horizon-independent); absent ⇒ 0.
- `glide:` maps a building-block key → its terminal value; the terminal expected return stays derived from the blocks (traceable).
- Per-class `regime_offsets:` (note: distinct from the global `regimes:` mixture). Absent ⇒ no regime sensitivity.
- Classes without these (deposit) stay flat + regime-insensitive. `gold` is a bear hedge (positive bear offset).

Seeded offsets (editable, sourced, shown in the panel): global base 60 / bear 25 / bull 15;
equities bear −0.04 / bull +0.02–0.03; real estate bear −0.025/−0.03; gold bear +0.03 / bull −0.01;
crypto ±0.10; deposit 0. Valuation: equity_us 33→20, equity_cn ≈12→12 (no drag), RE_cn 1.35→1.0,
RE_us 1.16→1.0. Growth glide: equities 3.5%/2.5% → 2.0%.

## Interfaces (implemented)

- `Cma#projection_inputs(ac, horizon:)` → `{mean_start, mean_end, regime_offsets, sigma}` (nil if unknown).
- `Cma#regimes` → global mixture Hash `{name=>prob}` (or {}).
- `Cma#expected_real_return(ac, horizon: nil)` → base start/end average; no-horizon + fixed-reversion = old constant.
- `Cma#breakdown(ac, horizon:)` → rows summing to `expected_real_return(horizon:)`, with `note:` annotating glide ("3.5% → 2.0%") / valuation ("33→20 over 30y"). A single private `contribution_bounds` is the source of truth.
- `Cma#asset_classes` excludes the reserved `metadata`/`regimes` keys.
- `MonteCarlo` gains `regimes:` kwarg; composes μ as above; `pick_regime` draws one regime/path, gated on a non-empty mixture (RNG-free otherwise).
- `Projection#assets(horizon:)` (memoized per horizon) + `ModelPortfolio.{resolved,assets_for,expected_real_return}(… horizon …)` carry the new fields; `project`/`alternative_row` pass `regimes: @cma.regimes` to `MonteCarlo`. Controller + `PortfolioComparison` thread `@horizon`.
- Methodology panel: summary `mean_start → mean_end over Ny · σ`; breakdown notes; a "Regime offsets" row listing each offset + the global mixture; the MC footnote mentions glide + regime.

## Non-goals
- No live data, no fitted/econometric or regime-**detection** model. Inputs stay hand-maintained, as-of-dated, editable.
- No per-year fat-tailed return distribution (CLT washout at 30y; the regime mixture carries the skew/tail instead).
- No factor model / factor-instability analysis (the app is a multi-asset projector, not a factor strategy).
- No full equity-index research report.

## Honesty
The deliverable is the **mechanism** — the model can now express trend, horizon-dependent valuation,
and regime risk. The specific endpoints, valuation levels, regime probabilities, and offsets are
**editable assumptions**, seeded conservatively, **labeled as assumptions** in the panel
(observable/assumption tags persist). This surfaces "it changes, it's uncertain, regimes dominate
the tails" instead of hiding it in one constant.

## Testing (implemented)
- `Cma`: valuation horizon-dependence (10y vs 30y); glide start/end; `regime_offsets`/`regimes`
  exposure; breakdown rows sum to ER + notes; backward-compat (0.045) + unknown-class nil + asset_classes excludes `regimes`.
- `MonteCarlo`: bear-heavy mixture widens the band AND skews the median down; glide bends p50;
  old-style assets run; regime-free runs bit-identical (reproducibility).
- `Projection`/`ModelPortfolio`: assets carry the new fields under a horizon; `PortfolioComparison`
  exact-value assertions (deposit/equity_cn) hold (horizon-independent base ER).
- Integration: the panel renders with anchored/assumption tags.
