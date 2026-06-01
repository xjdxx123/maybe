# Asset Intelligence Platform — North-Star PRD

**Date:** 2026-06-01
**Status:** Draft (brainstorming) — north-star / vision PRD. Frames the whole product and decomposes it into sequenced sub-projects; each sub-project gets its own spec → plan.
**Builds on:** the existing `real_return` work — see `docs/superpowers/specs/2026-05-30-real-return-on-maybe-design.md` and siblings.

---

## 1. Vision & problem statement

An all-asset intelligence app that answers, across one person's entire financial life, three questions that today require three different tools:

1. **"How is my wealth actually doing?"** — long-horizon portfolio modeling: money-weighted **real** (inflation-adjusted) returns, opportunity-cost benchmarking, forward projections. *(Largely built: the `real_return` engine.)*
2. **"What's happening in markets, and would this strategy have worked?"** — short/mid-term market analysis, technical/quant signals, and strategy **backtesting**. *(Not built.)*
3. **"Just do it for me."** — a natural-language **agent** that turns a spoken description of a financial situation into recorded, analyzed reality. *(Not built.)*

**Flagship scenario (the product's "hello world"):**

> **User:** *"I have ¥1M cash, a ¥6M property bought in 2021, and ¥6M of stocks — enter these into the system and analyze them."*
> **System:** parses → **confirms with the user** → records into the account model → computes lifetime real return, inflation-beating verdict, and opportunity-cost vs. benchmarks → presents a grounded, **uncertainty-aware** summary.

No single existing tool does all three (§4). The thesis: **fusing a personal balance-sheet system, a market/quant engine, and an LLM orchestration layer** — each properly bounded — produces something none of them is alone.

---

## 2. Positioning & constraints

**Positioning:** **Self-use first, architected to keep a commercialization door open.** Build the power-tool the author wants; do not foreclose a future product.

### The licensing reality (load-bearing)

- **Maybe is AGPL-3.0**, and Maybe Finance Inc. has **shut down** — the repo is explicitly *"no longer maintained."* Unlike OpenBB, **there is no vendor selling a commercial/closed-source license for Maybe's core.** "Maybe" is also a **trademark**; a fork may not use the name or logo.
- **OpenBB's core (ODP) is AGPL-3.0** as well (dual-licensed; a paid commercial license exists for hosting *modified* OpenBB as a SaaS).
- **AGPL does not forbid commercial use or charging money.** It forbids offering a **closed-source** network service built from AGPL code. Therefore:
  - **Open-core commercial** (charge for hosting/support/premium, **share source**) is **fully open** and needs no one's permission.
  - **Proprietary, closed-source SaaS on Maybe's core is effectively foreclosed** (no license seller exists).
  - **The escape valve is architectural** (§5): the high-value new IP lives in **separate, owned services** that communicate with Maybe over an API. A separate program merely communicating at arm's length over a network is, under the standard interpretation, **not a derivative work** — so its license is the author's to choose, and may be proprietary.
- **⚠️ Legal caveat:** the "API boundary ≠ derivative work" line is real but **contested and jurisdiction-sensitive**. This is *prudent architecture, not legal advice.* Get counsel before any commercial launch.
- **Some libraries cost money to commercialize** (all "pay later, at commercialization" — none blocks self-use): vectorbt (Apache + **Commons Clause** — usable inside a service, **cannot be resold as software**), vectorbtpro (paid), and **data-redistribution licenses** (Tiingo, Twelve Data, Polygon charge separately to *display* data to end users).

### Net constraint → governing design principle

> **Keep every new, valuable capability outside the AGPL shell, behind a clean API boundary, from day one.**

This single principle serves three goals at once: **Ruby/Python separation**, **horizontal scaling**, and **license optionality**.

---

## 2.5 Why this, not a bank or a private manager — the trust model

The right to win on long-term modeling is **not "more accurate math"** (a serious quant team will out-forecast us, and we do not claim otherwise — see §6.1). It rests on three axes a bank or private manager **structurally cannot** match:

- **Whole-picture coverage — better *inputs*, not a better formula.** A bank sees only assets held there; a private manager sees only the AUM they run. Neither sees your consolidated, cross-institution, multi-currency net worth (¥6M property + ¥6M equities held elsewhere + ¥1M cash + crypto + foreign accounts). A model is only as good as its inputs; ours are the *complete* balance sheet. Their "assessment report" is partial by construction.
- **Zero conflict of interest — alignment.** A bank's report and an advisor's plan are entangled with selling products and earning AUM / fund fees — often a sales document in disguise. Our model sells nothing. The same projection carries different trust from a fee-conflicted advisor vs. a tool you own.
- **Verifiable, not authoritative — the core mechanism (ties to §6.1).** Institutions hand you a black-box PDF and ask you to *believe*. We show every number's formula, every assumption with `source:` / `as_of:` provenance, the uncertainty band, and let you change an assumption and re-run. Institutions offer *trust-by-authority*; we offer **trust-by-verification** — you don't have to believe us, you can audit us (open-source / self-host amplifies this). For our beachhead user — the sophisticated DIY / cross-border individual who wants to *check* a number, not take it on faith — this is more durable than any brand.

Plus **accessibility**: private wealth management is gated by high investable-asset minimums; most people get nothing that honestly models their whole net worth. We serve that underserved middle and the DIY sophisticate.

**One-line positioning:** *not "more accurate," but "the honest, conflict-free model over your complete financial picture — that you can audit, not just believe."*

**What we honestly do *not* win** (stated so we never overclaim): no better point forecasts than a quant team; no brand authority, fiduciary status, human relationship, or regulatory standing; and **v1 is an analysis tool, not a regulated investment advisor** (no personalized buy/sell advice, no discretionary management — also a deliberate regulatory-safety line).

**Consequences — these become *core requirements*, not nice-to-haves:** (1) consolidate *everything* (cross-institution, multi-currency); (2) every figure carries provenance and is user-adjustable + re-runnable; (3) the product never sells a financial product; (4) the engine must be exact and reproducible enough to *be* audited (§6.1). **Non-goal added:** v1 is not a regulated advisor — it informs decisions, it does not make them for you.

---

## 3. The three pillars — scope & non-goals

### Pillar A — Personal portfolio & long-term return modeling *(mostly built)*
- **In scope:** money-weighted real returns (XIRR/CAGR + CPI/Fisher), opportunity-cost benchmark league tables, Monte Carlo projections (glide path + regime mixture), capital-market assumptions, property deal analysis (levered real MC), multi-currency consolidation — all on Maybe's `Account` / `Valuation` / `trades` / `holdings` / `BalanceSheet`.
- **Status:** `real_return` — 18 models, ~1,400 LOC, with a provider interface + bundled reference data.
- **Deferred (from the existing spec):** liability/mortgage return modeling, cash-vs-inflation, wealth percentile, capital improvements / partial dispositions, live data feeds.

### Pillar B — Market analysis, quant & backtesting *(not built; the big new capability)*
- **In scope (target):** market / fundamental / macro data access; technical & quant indicators; strategy definition and **historical backtesting** with honest methodology (costs, slippage, bias controls); results surfaced back into Maybe.
- **Hard out-of-scope (v1, and a safety line):** **live trading / order execution / moving money.** The system analyzes and backtests; it **never places an order.** This is both a safety stance and a major simplification (no broker integration, no real-time execution risk).
- **Tech reality:** this pillar is **Python** (the entire serious backtesting ecosystem is). It lives in an **owned Python service** (§5).

### Pillar C — LLM agent: natural language → execute *(not built; thin orchestration over A & B)*
- **In scope:** structured extraction from natural-language financial descriptions; mapping to the account/holding model; a **guarded write path** (propose → human confirm → deterministic write); narrating/explaining results; calling A's and B's capabilities as **typed tools**.
- **Hard rule:** the LLM **parses, routes, and explains** — it **never** computes a figure or persists data directly. All math and all writes are deterministic code; the LLM may only *invoke* them, and may **never emit a number it did not receive from the deterministic engine.**
- **Non-goals (v1):** autonomous decisions, unsupervised writes, any money-moving action, and trusting any LLM market **forecast** as signal.

---

## 4. Can existing projects meet the requirements?

**Short answer: no single one does — and that division of labor *is* the architecture.**

| Need | Maybe | OpenBB | Verdict |
|---|---|---|---|
| Personal bookkeeping, multi-currency net worth, lifetime real return (Pillar A) | ✅ core + your `real_return` | ❌ explicitly *not* net-worth/accounting (even paid "Open Portfolio" disclaims it) | **Maybe — you already own most of this** |
| Market / fundamental / macro **data** (Pillar B inputs) | ❌ | ✅ ~100 providers, free tier (yfinance/FRED/CBOE), standardized API + MCP server | **OpenBB as an *unmodified* data sidecar** |
| Technical indicators / quant metrics | ❌ | ✅ `openbb-technical`, `openbb-quantitative` | **OpenBB** |
| **Backtesting engine** | ❌ | ❌ (OpenBB stops at data + indicators) | **Build in an owned Python service** |
| Agent: NL → record/analyze (Pillar C) | ⚠️ basic AI-chat infra (`CreateChatResponseJob`) | ✅ open agent protocol (MIT examples) + MCP | **Build on Maybe's models; borrow OpenBB's agent/MCP *design*** |

### Tooling picks (from the landscape survey)
- **Backtesting / quant engine (Pillar B):** primary engine **Qlib** (Microsoft; **MIT**) — purpose-built for **factor research + daily backtest** (= v1 scope), headless via `qrun`/Python (job-queue friendly), ships **China A-share + US** datasets, models costs + China price-limits, **actively maintained into 2026**. **Avoid vectorbt as a spine** — its **Commons Clause forbids paid/hosted offerings**, which conflicts with the "keep commercialization open" principle (§2); fine for pure self-use, but we don't build the core on it. **Defer execution engines to v2**, behind the same strategy interface: **LEAN** (Apache-2.0) or **nautilus_trader** (LGPL) for US/global live, **vnpy** (MIT) for China futures/A-share live. **Exclude backtrader** (abandoned ~2019). Engines sit behind an owned `BacktestEngine` / `FactorResearch` interface over a **canonical Parquet store** (source of truth; thin one-way adapters feed each engine — no engine's format becomes the SoT).
- **Data providers:** **FRED** for macro (free). For prices/fundamentals, behind a **swappable provider interface**: start on free tiers / OpenBB; pay **FMP / Tiingo / Polygon** with a redistribution license **only at commercialization**. **yfinance = prototyping only** (Yahoo ToS forbids commercial use) — never in a commercial hot path.
- **Agent pattern:** LLM **tool-calling over a typed portfolio+market API** (the mature, productionizable pattern). **FinGPT/FinRobot** are useful for text/document NLP but **near-coin-flip at market forecasting — never trust their forecasts as signal.**
- **OpenBB usage:** run the **unmodified ODP as a sidecar** (REST on `:6900` and/or `openbb-mcp`); **do not fork it** (AGPL + the sunset Terminal). Borrow its `/agents.json` + `/query` + SSE agent-protocol design.

**Sources (gathered 2026-06-01):** OpenBB [license FAQ](https://docs.openbb.co/platform/faqs/license) · [agents repo (MIT)](https://github.com/OpenBB-finance/agents-for-openbb) · [Open Portfolio "what it's NOT"](https://openbb.co/blog/open-portfolio-a-suite-for-asset-managers-on-openbb/) · [vectorbt](https://github.com/polakowo/vectorbt) · [nautilus_trader](https://github.com/nautechsystems/nautilus_trader) · [QuantConnect LEAN](https://github.com/QuantConnect/Lean) · [FRED ToU](https://fred.stlouisfed.org/docs/api/terms_of_use.html) · Maybe `LICENSE` + `README` (AGPL-3.0, unmaintained, trademark).

---

## 5. Target architecture

**Shape:** Maybe (Ruby/Rails) is the **system of record + UI + orchestrator**. Every new capability is an **owned service** behind a clean API. Python is a **first-class peer service**, never embedded in the Rails web tier.

```
┌──────────────────────────────────────────────────────────────┐
│  MAYBE (Rails, AGPL) — the shell                              │
│  system of record · UI · orchestration · auth                 │
│  Accounts · Valuations · Trades · Holdings · BalanceSheet     │
│  multi-currency · real_return engine (Pillar A)               │
└──────┬─────────────────────────────────────────┬─────────────┘
       │ typed HTTP/JSON                          │ typed HTTP/JSON
       ▼                                          ▼
┌────────────────────────────┐        ┌──────────────────────────────┐
│ AGENT service — Pillar C   │  HTTP  │ QUANT/DATA service — Pillar B │
│ (OWNED, closeable)         │───────▶│ (OWNED, closeable)           │
│ NL extraction ·            │        │ FastAPI (sync) + queue worker│
│ tool-calling ·             │        │ (heavy backtests) ·          │
│ guarded write→confirm      │        │ Qlib (MIT) · Parquet SoT     │
└────────────────────────────┘        └───────────┬──────────────────┘
                                                   │ data-provider interface
 ═════════════ AGPL boundary ═════════════         │ (swappable; fans out to
  left: Maybe (AGPL) · right: owned IP              ▼  siblings below)
                                       ┌──────────────────────────────┐
 shared infra: Postgres · Redis        │ OpenBB ODP (UNMODIFIED        │
 (job queue)                           │ sidecar, AGPL) · FRED (free)  │
                                       │ · later FMP/Tiingo/Polygon    │
                                       └──────────────────────────────┘
```

### Why this shape
- **Ruby↔Python:** the entire quant ecosystem is Python; Maybe is Rails. Python lives as a peer microservice (FastAPI for interactive calls + a queue worker for heavy backtests). **No PyCall in Puma** (its threading model is unsafe in the web request tier).
- **License optionality (strangler-fig):** the owned services sit **outside** the AGPL shell, so the valuable IP is the author's to license. The AGPL shell is the **least-differentiated** layer and can be **swapped for a React/Node front-of-house later** — but only once the product is validated and the closed-source upside is proven. **Earn the right to rewrite.**
- **OpenBB stays unmodified** → cleanest AGPL posture + no fork to maintain.
- **Engines behind an interface, data we own:** the quant service owns a **canonical Parquet OHLCV/factor store** as source of truth; backtest engines (**Qlib** now; LEAN / nautilus / vnpy in v2) sit behind a thin `BacktestEngine` interface fed by one-way adapters — no engine's format becomes the SoT, and the **v1 strategy abstraction is the seam** that backtest→live engines plug into in v2.

### Boundary discipline (the rule that makes Pillar B real)
Maybe never imports Python; it **calls owned services over typed HTTP**. Owned services never reach into Maybe's DB; they **call Maybe's API** or receive data in the request. Contracts are **versioned**. This discipline is what preserves all three payoffs.

---

## 6. The real difficulties (and how we blunt each)

Two classes. The **engineering/structural** ones are *hard work with known solutions*; the **epistemic** ones are *the deeper risk — they decide whether anyone trusts the output.*

### 6.1 — Trustworthy economic modeling *(the deepest difficulty)*
The instinct that "accurate economic modeling is the main hard part" is right. The subtlety is **what** must be precise. **"Precision" is not one thing** — the model is held to a high, *testable* standard on most of its meanings; only one kind of precision is genuinely unattainable by anyone, and we are honest about that one rather than faking it.

**Precision — of the right thing:**

| Layer | Standard we hold ourselves to | Testable? |
|---|---|---|
| **Measurement** (XIRR, real return, net worth, benchmark counterfactuals) | **Exact** — matches a verified oracle to the basis point | ✅ oracle + unit tests |
| **Computation given assumptions** (Monte Carlo convergence, arithmetic, deflators) | **Numerically exact, convergent, deterministic** — same inputs → identical output every run | ✅ seed-fixed golden tests + convergence checks |
| **Data inputs** (CPI, benchmark levels, FX, property index) | **Best available source, known granularity, error disclosed** (real-estate is the weakest series and is labeled as such) | ⚠️ partially — provenance + cross-check |
| **Forecast → the actual future** | **Not claimable as a point** by anyone; delivered as a band, never a bare number | — |
| **Calibration of the band** | The band's stated probability is **accurate** — a 90% band covers the realized outcome ≈90% of the time | ✅ backtest projections historically |

So the **engine is exact**; the only irreducibly uncertain thing is the *correspondence of a forecast to the future* — and even that is delivered as a **precisely computed, reproducible, calibrated** band, not as vagueness. The slogan: **we are precise about our uncertainty.** "Honest about uncertainty" must **never** become an excuse for a sloppy engine or hand-waved numbers — two users with identical inputs get the identical band to the decimal.

Where we and institutions genuinely diverge is only the fourth row: a serious quant team will produce **better point forecasts** than we will, and we don't pretend otherwise. We compete (and hold ourselves precise) on the other four — exact measurement, exact computation, sourced data, and **calibrated bands you can backtest** — which is also exactly what makes the §2.5 trust model real: *you can only "verify rather than believe" if the engine is genuinely exact and reproducible.*

This is also where the **agent is most dangerous**: an LLM will state an uncertain projection as confident fact. So **"constrain the agent" and "model honestly" are one problem** — the LLM may only relay numbers and bands the deterministic engine produced.

| Sub-difficulty | Mitigation |
|---|---|
| (a) Conflating fact with projection | Strict separation in code **and** UI; measurement results and projections are **different types, rendered differently** |
| (b) False precision | Forward-looking outputs **always** carry uncertainty bands + provenance; never a bare point estimate |
| (c) Indefensible assumptions | CMAs / inflation / correlations behind a **provider interface** with `source:` / `as_of:` citations; swappable |
| (d) Backtest self-deception | Methodology discipline: survivorship & look-ahead-bias controls, transaction costs + slippage, out-of-sample, no silent overfitting |
| (e) Heterogeneous assets | Consistent treatment of an illiquid, levered, appraisal-priced 2021 property **alongside** liquid equities; estimates **flagged, never fabricated** |
| (f) Bands that aren't calibrated | **Backtest projections historically** — a 90% band should cover ≈90% of realized outcomes; calibration is a *measured, reported* standard, not an assumed one |

**Good news:** the existing `real_return` engine already leans the right way (provider interface, `estimated` flags, regime mixtures, an explicit *"never imply false precision"* rule). This PRD elevates that from a per-feature habit to a **system-wide contract.**

### 6.2 — The Ruby↔Python boundary *(pervasive engineering)*
Every quant feature crosses it. Mitigation: Python as a **peer service** (§5), typed/versioned contracts, a queue for heavy work, **no PyCall in the web tier.** Hard work, known solution.

### 6.3 — Constraining the agent to deterministic, safe actions *(design)*
LLM parses/routes/explains only; deterministic code computes and persists; writes go through **propose → human-confirm**; **no money-moving actions** in v1; disambiguating vague input ("¥6M stocks" = which tickers? what cost basis?) is real UX work, handled by the confirm step.

### 6.4 — Data licensing *(legal/business; deferred to commercialization)*
yfinance is prototyping-only; commercial display needs paid redistribution licenses. Mitigation: **swappable provider interface from day one** so the hot path is never wedded to a non-commercial source.

### 6.5 — AGPL / IP boundary *(legal; handled by architecture)*
Owned services outside the shell; OpenBB unmodified; counsel before any commercial step. (§2, §5.)

---

## 6.6 — Modeling methodology: cited building blocks, mirroring the CMA industry

**Decision:** our long-horizon forecasts use the **same *class* of methodology as JPMorgan (LTCMA), Vanguard (VCMM), and BlackRock** — reduced-form **"building-block" / valuation** models, **not** deep structural causal chains. This is the industry's revealed preference and the CFA-curriculum standard, and it is honest *because* it is shallow: every term is observable or a transparent, cited assumption, so uncertainty is **contained rather than compounded**.

**Goal we keep:** every modeled quantity is grounded in a **published, citable method**, carries its **own uncertainty**, and is a **swappable component** behind the provider interface — a node `{method, value, distribution, source, as_of}`. This is what makes §2.5's "verify, don't believe" real.

**Topology we reject — deep causal nesting** (e.g. `Solow → TFP → GDP → EPS → P/E → equity return → portfolio`). Tempting and citable, but wrong on three independent grounds:

1. **The flagship link is empirically wrong-signed.** Long-run cross-country **per-capita GDP growth correlates −0.37 (→ ~0) with real equity returns** (Ritter 2005, *Pacific-Basin Finance Journal*; corroborated by Dimson-Marsh-Staunton, CS/UBS Yearbook "Growth Puzzle"). Growth accrues to *new* firms and share issuance (dilution — Arnott-Bernstein "2% dilution," *FAJ* 2003), to consumers/labor, and is already priced in. Forecasting equity returns *from* GDP would hardcode a relationship the data **reject**.
2. **The structural inputs aren't forecastable.** Solow's long-run growth rate **is** exogenous TFP — the "Solow residual" is the *unexplained* part (Solow 1956/1957). A Solow-based "forecast" merely **launders an assumption**. The models that would close the chain (DSGE, consumption-CAPM, Bansal-Yaron long-run risk) have poor out-of-sample records, are *calibrated* not estimated, and are **not used in practice for return projection** (Beeler-Campbell 2012; Stiglitz 2018; NY Fed SR844).
3. **Nesting compounds error into false precision.** Linked models multiply parameter + structural uncertainty (cascading-uncertainty literature); *acknowledging* model uncertainty beats adding structure (Garlappi-Uppal-Wang). More layers ≠ more accuracy — past a point, strictly worse and less honest (violates §6.1 calibration).

**What we build instead:**
- **Prior = building blocks.** Equity expected return via **Grinold-Kroner (2002)**: `E[R] ≈ D/P − %ΔS + i + g + %Δ(P/E)` (income − dilution + inflation + real earnings growth + repricing) — the CFA-curriculum standard; each term observable or a transparent, cited assumption. Bonds via yield + roll; etc.
- **Views = Black-Litterman (1992) overlay.** Start from a defensible equilibrium / building-block prior; let the user (or a model) add **views, each with mandatory explicit uncertainty**; the projection **degrades gracefully to the cited baseline** as confidence falls.
- **GDP is a *sanity cap*, never a driver.** Use **nominal** GDP as a soft ceiling on long-run aggregate earnings growth (Grinold-Kroner: profits can't outgrow GDP forever — JPM does exactly this), and **explicitly decouple** "higher forecast GDP → higher equity return," citing Ritter.
- **Uncertainty is propagated, not assumed away.** Monte Carlo over assumption distributions with **documented** cross-block correlations (never independence-by-default); fan charts, not point estimates (as VCMM and Research Affiliates present).

**Where deep structural models *do* belong (kept, but bounded):** optional **scenario / stress tests** ("what if TFP growth halves?") and **pedagogy / transparency** — clearly-labeled "what-if" tools behind the same interface, **never** the load-bearing forecasting spine.

This maps onto the existing engine (`RealReturn::CMA`, `correlation`, `monte_carlo`, `ReferenceData`): every assumption is formalized as a cited, uncertainty-carrying, swappable node. *(Citations: Appendix A.)*

---

## 7. Decomposition & roadmap

Each sub-project is independently shippable and gets its own spec → plan. Recommended order:

1. **SP-1 — Conversational asset entry + instant real-return analysis** *(flagship; first)*
   The flagship scenario end-to-end on existing assets (Maybe models + `real_return`). Establishes the **owned-agent-service + clean-API-boundary** pattern and the **guarded write path** on a small surface. ~3 tools (`parse_assets`, `upsert_account/holding`, `compute_real_return`).
   **Done when:** a user can describe a mixed portfolio in natural language and get it **recorded (after confirmation)** and **analyzed** (real return + inflation verdict + benchmark league), with **every number sourced from the deterministic engine** and projections shown with uncertainty.

2. **SP-2 — Owned Python quant/data service (foundation of Pillar B)**
   FastAPI + queue worker; canonical Parquet store + data-provider interface (FRED + OpenBB sidecar to start); first backtest capability via **Qlib (MIT)** behind an owned `BacktestEngine` interface. Decoupled — can begin any time, even in parallel with SP-1.
   **Done when:** Maybe can request a backtest of a defined strategy over a date range and receive results (equity curve, stats) with **costs/slippage and bias controls applied.**

3. **SP-3 — Market-analysis & backtest surfaces in Maybe** (indicators, screening, backtest UI) over SP-2.

4. **SP-4 — Agent grows to wrap Pillar B** (market/quant tools added to the agent as capabilities land — cheaply, since each tool is a thin wrapper).

5. **Ongoing — deepen Pillar A** (liabilities/mortgage, cash-vs-inflation, wealth percentile) — slot in opportunistically.

**Deferred across the whole roadmap (explicit non-goals):** live trading / order execution / moving money; closed-source rewrite of the shell (only "earned" post-validation); commercial data-redistribution licensing (only at commercialization).

---

## 8. SP-1 preliminary scope (next: its own spec)

- **Trigger:** a chat surface in Maybe (reuse `CreateChatResponseJob` infra) where the user describes assets in natural language.
- **Flow:** `parse_assets` (LLM structured extraction → typed list of `{asset_type, amount, currency, acquisition_date?, identifier?}`) → **disambiguation/confirmation UI** (user fixes tickers / cost basis / dates) → `upsert` into Maybe's `Account` / `Valuation` / `Holding` (deterministic, idempotent) → `compute_real_return` (existing engine) → **narrated, uncertainty-aware** summary.
- **Architecture:** the agent runs as an **owned service** (language decided in SP-1's spec — Python to share the LLM/quant stack, or Node) calling Maybe's API; Maybe exposes a **scoped, authenticated internal API** for the writes/reads it needs. This is the **first instance of the §5 boundary.**
- **Safety:** no write without explicit user confirmation; LLM never emits computed figures; ambiguous inputs always surface for confirmation.
- **Open for SP-1's spec:** agent-service language; exact internal API surface; chat UX (new surface vs. extend existing); how confirmation is rendered (Hotwire).

---

## 9. Open questions / future

- Agent-service implementation language (Python vs. Node) — decided in SP-1.
- Whether SP-2 begins in parallel with SP-1 or strictly after.
- Backtesting: vectorbt-first vs. committing to QuantConnect LEAN as a one-stack.
- When (if ever) to "earn the rewrite" of the AGPL shell to React/Node for closed-source.
- Live data adapters and wealth-percentile (carried over from the `real_return` spec).
- Eventually: counsel review of the AGPL boundary before any commercial step.

---

## Appendix A — References

*Sources gathered 2026-06-01. Methodology references back §6.6 / §6.1; tooling references back §4 / §5.*

**Long-horizon modeling methodology (§6.6):**
- Ritter, J. R. (2005). *Economic Growth and Equity Returns.* Pacific-Basin Finance Journal 13(5), 489–503. — cross-country per-capita GDP growth vs. real equity returns ≈ **−0.37**. https://site.warrington.ufl.edu/ritter/files/2015/04/Economic-growth-and-equity-returns-2005.pdf
- Arnott, R. & Bernstein, P. (2003). *Earnings Growth: The Two-Percent Dilution.* Financial Analysts Journal 59(5).
- Dimson, Marsh & Staunton — *Credit Suisse / UBS Global Investment Returns Yearbook* ("The Growth Puzzle"); *Triumph of the Optimists* (2002).
- Grinold, R. & Kroner, K. (2002). *The Equity Risk Premium* (building-block model; CFA-curriculum standard). https://larrysiegeldotorg.wordpress.com/wp-content/uploads/2018/07/supplymodeleqpremium.pdf
- Solow, R. (1956). *A Contribution to the Theory of Economic Growth*, QJE 70(1); (1957) *Technical Change and the Aggregate Production Function*, REStat 39 (the "Solow residual" / TFP).
- Black, F. & Litterman, R. (1992). *Global Portfolio Optimization.* Financial Analysts Journal 48(5) — equilibrium prior + views with explicit uncertainty.
- Bansal, R. & Yaron, A. (2004) long-run risk; Beeler, J. & Campbell, J. (2012), NBER w14788 (LRR empirical assessment); Stiglitz, J. (2018), *Where Modern Macroeconomics Went Wrong*, Oxford Rev. Econ. Policy 34(1-2); NY Fed Staff Report 844 (DSGE forecast misses); Garlappi, Uppal & Wang (2007) *Portfolio Selection with Parameter and Model Uncertainty*.
- Practitioner CMA methodology: [JPMorgan LTCMA](https://am.jpmorgan.com/us/en/asset-management/institutional/insights/portfolio-insights/ltcma/) · [Vanguard VCMM](https://corporate.vanguard.com/content/corporatesite/us/en/corp/vemo/vemo-return-forecasts.html) · [BlackRock expected returns](https://www.blackrock.com/us/financial-professionals/tools/expected-returns-analyzer-methodology) · [Research Affiliates AAI](https://www.researchaffiliates.com/content/dam/ra/documents/asset-allocation/aai-methodology-1124.pdf).

**Platforms & tooling (§4 / §5):**
- OpenBB: [license FAQ (AGPL-3.0)](https://docs.openbb.co/platform/faqs/license) · [custom-agent protocol, MIT](https://github.com/OpenBB-finance/agents-for-openbb) · [Open Portfolio — "not net-worth/accounting"](https://openbb.co/blog/open-portfolio-a-suite-for-asset-managers-on-openbb/).
- Backtest/quant engines: [Qlib (MIT)](https://github.com/microsoft/qlib) ([data docs](https://qlib.readthedocs.io/en/stable/component/data.html), [US-data caveat](https://github.com/microsoft/qlib/blob/main/scripts/data_collector/yahoo/README.md)) · [vnpy (MIT)](https://github.com/vnpy/vnpy) · [nautilus_trader (LGPL)](https://github.com/nautechsystems/nautilus_trader) · [QuantConnect LEAN (Apache-2.0)](https://github.com/QuantConnect/Lean) · [vectorbt license / Commons Clause](https://vectorbt.dev/terms/license/).
- Data providers / ToS: [FRED Terms of Use](https://fred.stlouisfed.org/docs/api/terms_of_use.html) · [Tiingo ToS](https://app.tiingo.com/tos/) · [Twelve Data commercial usage](https://support.twelvedata.com/en/articles/5332349-commercial-and-personal-usage) · [Yahoo Dev API ToS](https://legal.yahoo.com/us/en/yahoo/terms/product-atos/apiforydn/index.html).
- Maybe: repo `LICENSE` (AGPL-3.0) + `README` (unmaintained; "Maybe" trademark).
