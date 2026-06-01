# Property Deal Analysis page

- **Date:** 2026-05-31
- **Branch:** feature/real-return
- **Status:** Design approved (Approach A); spec for review.

## Problem / goal

A per-property "deal analysis" tool, separate from the portfolio Projection. Given a property +
financing + market assumptions, it computes and visualizes: cash-flow pro forma, a **levered**
real-return distribution (regime-aware, fat-left-tailed), an appreciation decomposition, and a
benchmark comparison. It is the quantitative core of the user's 12-step real-estate framework,
reusing the `real_return` engine (regime mixture, horizon valuation, glide). It is a **standalone
calculator** (like `/projection`): `Property` accounts store only year_built/area/address — no rent
or financing — so inputs come from a form (the property's balance can prefill the price).

This is the **compute + visualize** layer. The **research** layer (live web data for city
fundamentals, rates, policy, valuation percentiles) is an on-demand Claude pass, deferred to a later
agent; here those enter as editable assumptions + free-text notes.

## Non-goals (v1)
- No live web research / data pipeline (Steps 2–5 of the framework → editable inputs + notes).
- No narrative investment memo (Step 12 → the later research agent).
- No income-side stochasticity/regime (v1 puts the randomness + regime on the PRICE path; income/NOI
  grows deterministically at the real-rent-growth glide — documented simplification).
- Reuses, does not modify, the portfolio Projection page.

## Page

- Route: `resource :property_analysis, only: :show` (singleton, like `:projection`).
- `PropertyAnalysisController#show`: reads form params, builds a `RealReturn::PropertyAnalysis`,
  renders. `Current.family.currency` for display; region (CN/US) picks the `real_estate_*` CMA class.
- View `app/views/property_analyses/show.html.erb`: a parameters form (GET, Hotwire — mirrors
  `/projection`), then the result panels. Functional Tailwind tokens; native `<details>`; reuse
  `projection_fan_svg` for the distribution chart and `rr_money`/`rr_pct_yr`/`projection_signed_pct`.
- Nav: add a "Property analysis" entry near the existing Projection nav item.

## Inputs (form params; defaults from the `real_estate_<region>` CMA, all editable)

- Property: `price`, `monthly_rent`, `holding_years` (5..40), `region` (cn/us).
- Financing: `ltv` (%), `mortgage_rate` (% nominal), `amortization_years`.
- Operating: `opex_pct` (% of rent), `vacancy_pct` (% of rent).
- Market: `real_rent_growth` (+ optional `real_rent_growth_end` glide), valuation `price_to_rent_current` / `price_to_rent_target`, `inflation` (for nominal→real debt). Regime mixture + per-class offsets come from `Cma` (`real_estate_<region>`); editable later.

## `RealReturn::PropertyAnalysis` (the new model)

Construction: `PropertyAnalysis.new(price:, monthly_rent:, holding_years:, ltv:, mortgage_rate:, amortization_years:, opex_pct:, vacancy_pct:, real_rent_growth:, real_rent_growth_end: nil, price_to_rent_current:, price_to_rent_target:, inflation:, cma:, correlation:, regimes:, sigma:, paths: 5000, seed: 123_456)`. (Controller fills `cma`/`regimes`/`sigma` from the `real_estate_<region>` CMA class; `sigma` = that class's σ.)

### Cash-flow pro forma (deterministic, year 1) — `#cash_flow`
- `annual_rent = monthly_rent * 12`
- `gross_yield = annual_rent / price`
- `effective_rent = annual_rent * (1 - vacancy_pct)`
- `noi = effective_rent - annual_rent * opex_pct`     (operating costs as % of gross rent)
- `cap_rate = noi / price`                              (net yield)
- `loan = price * ltv`; `down_payment = price - loan`
- `debt_service` = standard fixed-rate annual amortization payment on `loan` at `mortgage_rate` over `amortization_years` (nominal). If `ltv == 0` → 0.
- `cash_on_cash = (noi - debt_service) / down_payment`  (down_payment > 0; if 0 → nil)
- `dscr = debt_service.zero? ? nil : noi / debt_service`
- `break_even_occupancy = (debt_service + annual_rent * opex_pct) / annual_rent`
Returns a Hash of these (for the view's pro-forma table).

### Levered real Monte Carlo — `#distribution`
Real terms throughout; **debt is nominal** (fixed), so its real value erodes with inflation — a core
leverage effect we model explicitly. Per path p, per year t = 1..N (N = holding_years):

1. Draw one regime `g_p` per path from `regimes` (shared; gated on non-empty — reuse the
   `MonteCarlo.pick_regime` logic/pattern). Appreciation regime offset `off = regime_offsets[g_p] || 0`.
2. **Real price appreciation** (price ≈ rent / cap-rate ⇒ %Δprice ≈ real rent growth + valuation change):
   - `mean_a(t) = lerp(real_rent_growth, real_rent_growth_end, t/N) + valuation_amort(N) + off`
   - `valuation_amort(N) = (price_to_rent_target / price_to_rent_current)^(1/N) − 1`
   - `drift = log(1 + clamp(mean_a, > −0.99)) − 0.5σ²`; `value *= exp(drift + σ·z)`, z ~ N(0,1).
3. **Real NOI** grows deterministically with the rent-growth glide:
   `noi(t) = noi(0) * Π_{s≤t}(1 + lerp(real_rent_growth, real_rent_growth_end, s/N))`.
4. **Nominal debt**: amortization schedule → `nominal_balance(t)`; `real_balance(t) = nominal_balance(t) / (1+inflation)^t`; `real_debt_service(t) = nominal_debt_service / (1+inflation)^t`.
5. **Real net cash flow(t)** = `noi(t) − real_debt_service(t)`; accumulate (no reinvestment in v1).
6. **Levered real equity(t)** = `real_value(t) − real_balance(t) + Σ_{s≤t} real_net_cash_flow(s)`.

Output: percentiles **{p10, p25, p50, p75, p90}** of levered real equity at each year 0..N (for the
fan chart), plus a terminal **annualized levered real return** distribution = `(equity(N)/down_payment)^(1/N) − 1` at the same percentiles. The single N-year sim records equity at **every** year, so a **5/10/20/30y** table (those years ≤ N) is read straight from the same run — no separate sims. Negative equity is allowed (ruin) — report the share of paths with equity(N) ≤ 0.

Reproducible (seeded). σ = the real-estate CMA class σ (total-return vol ≈ price vol, documented approximation).

### Decomposition — `#appreciation_breakdown`
Reuse the building-block idea: real rent growth (start→end note), valuation (`current→target over Ny`
note), and list the income (`cap_rate`) separately. Render with the methodology-panel pattern
(label / contribution / ●anchored-○assumption / source/note). Sums to the price-appreciation mean.

### Benchmark comparison — `#benchmarks`
For bonds (`govbond`), equities (`equity_<region>`), gold, cash (`deposit`): the CMA
`expected_real_return(klass, horizon: holding_years)` + σ. A simple row table (return + σ) so the
user sees the levered property vs unlevered liquid alternatives. (vol/tail/regime columns deferred to B.)

## View panels
1. Inputs form.
2. Cash-flow pro forma table (yields, NOI, cash-on-cash, DSCR, break-even occupancy).
3. Levered real-equity fan chart (`projection_fan_svg`, p10..p90 band + median) + terminal
   percentile table + annualized levered-return percentiles + "share of paths with negative equity".
4. Appreciation decomposition (methodology panel).
5. Benchmark comparison table.
6. A methodology/assumptions note: regime mix, the income-deterministic + price-stochastic
   simplification, real-terms + nominal-debt handling, and a free-text "city / supply / policy notes"
   area (the deferred research inputs), all flagged as assumptions.

## Honesty
Every assumption editable + labeled; the page states it's a model of *assumptions*, the research
layer (real city/policy/rate data) is deferred, and leverage cuts both ways (show ruin probability).
No number is presented as a guaranteed outcome — distributions only.

## Testing
- `PropertyAnalysis#cash_flow`: yields/NOI/cap_rate/cash-on-cash/DSCR/break-even on a worked example
  (e.g. price 1,000,000, rent 3,000/mo, ltv 0.6, rate 0.05, term 30, opex 0.25, vacancy 0.05) — assert each formula.
- `#cash_flow` with `ltv: 0` → debt_service 0, dscr nil, cash_on_cash = noi/price.
- `#distribution`: percentiles ordered (p10≤p25≤…≤p90); higher LTV widens the band AND raises the
  negative-equity share (leverage amplifies); reproducible for a fixed seed; valuation gap makes the
  median price path bend.
- `#benchmarks`: returns the four classes' horizon-aware ER + σ.
- Controller: `GET /property_analysis` (signed-in) renders :ok with sane defaults and with params.

## Files
- `config/routes.rb` (+ `resource :property_analysis`)
- `app/controllers/property_analysis_controller.rb`
- `app/models/real_return/property_analysis.rb`
- `app/views/property_analyses/show.html.erb`
- `app/helpers/property_analyses_helper.rb` (if any property-specific formatting) — else reuse projections/real_returns helpers
- nav partial (add the link)
- tests: `test/models/real_return/property_analysis_test.rb`, `test/controllers/property_analysis_controller_test.rb`
