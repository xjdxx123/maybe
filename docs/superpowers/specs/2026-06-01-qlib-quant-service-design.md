# Qlib Quant/Data Service — Design Spec

**Date:** 2026-06-01
**Status:** Draft (brainstorming). **Build order: this is now the *first* sub-project** (quant-service-first; see parent roadmap §7).
**Parent:** `docs/superpowers/specs/2026-06-01-asset-intelligence-north-star-design.md` (§4 tooling, §5 architecture, §7).
**Sibling:** `2026-06-01-sp1-conversational-asset-entry-design.md` (the agent, built second).

---

## 1. Goal

Stand up the **owned Python quant/data service** (Pillar B's foundation) and prove it on a **thin end-to-end vertical slice**:

> Send a strategy definition → the service runs a **CSI300, Qlib-native daily backtest** (with realistic costs + A-share ±10% price-limits) → returns an **equity curve + key stats**.

This de-risks the biggest genuinely-new technical territory (the Python quant stack, Qlib, the data path, backtest methodology) **in isolation**, and establishes the **`BacktestEngine` contract**, the **typed `StrategySpec`** the future agent will emit, and the **dev deployment** — all of which later capabilities reuse. It is deliberately *not* the whole Qlib surface (no rabbit hole).

## 2. What exists vs. what this adds

**Exists:** essentially nothing for quant — this is greenfield. Maybe has a `Provider`/HTTP-client pattern (e.g., `Provider::Openai`) to mirror for a thin Ruby client; Postgres + Redis are shared infra; `Procfile.dev` runs dev processes (`web` / `css` / `worker`).

**This adds:**
1. An owned **Python service** (FastAPI) exposing a `/backtest` endpoint over a typed contract.
2. The **Qlib (MIT)** engine behind an owned **`BacktestEngine`** interface (so the engine is swappable later — nautilus/LEAN).
3. The typed **`StrategySpec`** (primary contract) + a translator to Qlib config; an **optional raw-Qlib escape hatch** for power use.
4. A queue worker for heavy backtests (Redis-backed).
5. A thin Maybe-side **`Quant::Client`** (Ruby) that calls the service.
6. Dev deployment (a `Procfile.dev` entry).

## 3. Locked decisions (from brainstorming)

| Decision | Choice |
|---|---|
| Service | Owned **Python** service (FastAPI sync + queue worker), **read-data/compute only** — no live trading |
| Engine | **Qlib (MIT)** behind an owned `BacktestEngine` interface (swappable later) |
| Strategy definition | **Typed `StrategySpec`** (our schema) translated to Qlib config; Qlib **factor expressions** allowed in the signal field; **no arbitrary code execution** in this path |
| Power-user escape hatch | An **advanced raw-Qlib mode** (write native Qlib config), **separated from the agent path** — the agent only ever emits the typed `StrategySpec` |
| First slice | **CSI300**, a Qlib-native strategy (`TopkDropoutStrategy` over a simple signal), daily backtest with Qlib's Exchange cost + ±10% price-limit model |
| Data (first slice) | Qlib's bundled **`cn_data`** to prove the pipeline fast; the **canonical Parquet SoT + ingestion adapters** are the *next* increment |

## 4. Scope & non-goals

**In scope (this slice):** the FastAPI service; the `StrategySpec` → Qlib translation for a `TopkDropout`-style CSI300 backtest; Qlib daily backtest with **costs + slippage + price-limits**; the `BacktestResult` contract (equity curve + stats); a thin Maybe client; dev deployment; pytest coverage of the translation + a deterministic known-result backtest.

**Non-goals (this slice):**
- ML-factor richness (Alpha158/360 + LightGBM) — the **next** increment.
- The canonical **Parquet SoT + live ingestion** (AkShare/Tushare) — next increment (slice 1 uses `cn_data`).
- **US markets** (Qlib's `us_data` is weak — later, with our own data).
- Any **user-facing UI** (that's the later "market-analysis surfaces in Maybe").
- **Live trading / execution** (Pillar B hard line).
- **Commercial data-redistribution licensing** (CN + US) — only at commercialization.

## 5. Architecture

```
┌───────────────────────────┐        ┌──────────────────────────────────────────┐
│ MAYBE (Rails)             │  HTTP  │ QUANT/DATA service (OWNED, Python)         │
│ • Quant::Client (thin)    │───────▶│ • FastAPI: POST /backtest (StrategySpec)   │
│   calls the service       │  JSON  │ • StrategySpec → Qlib-config translator    │
│ • (no UI yet — SP-3)      │◀───────│ • BacktestEngine iface → Qlib runner       │
└───────────────────────────┘ result │ • queue worker (heavy backtests)           │
                                      │ • raw-Qlib escape hatch (guarded, non-agent)│
                                      └───────────────┬────────────────────────────┘
                                                      │ data
                                      ┌───────────────▼────────────────────────────┐
                                      │ Qlib cn_data bundle (slice 1)               │
                                      │ → later: canonical Parquet SoT + CN adapter │
                                      └─────────────────────────────────────────────┘
                                   shared infra: Postgres · Redis (queue)
        ═══════════ AGPL boundary ═══════════  (this service is owned, closeable IP)
```

- The service is **internal** (network-isolated + a shared token); Maybe calls it, never the reverse.
- Qlib sits **behind** the `BacktestEngine` interface so the v1 strategy abstraction is the seam nautilus/LEAN plug into later (backtest→live parity).
- **No arbitrary code execution** in the typed path; the raw-Qlib escape hatch is a separate, guarded route never exposed to the agent.

## 6. The `StrategySpec` contract (primary, typed)

```jsonc
{
  "universe": "csi300",                  // named pool (csi300|csi500|... ; us later)
  "period": { "start": "2018-01-01", "end": "2023-12-31" },
  "signal": {                            // what to rank by
    "kind": "expression | model",
    "expression": "($close-Ref($close,20))/Ref($close,20)",  // Qlib factor DSL (kind=expression)
    "model": null                        // (kind=model) → named model + factor handler, next increment
  },
  "strategy": {                          // how to trade the signal
    "kind": "topk_dropout",
    "topk": 50, "n_drop": 5
  },
  "costs": { "open_bps": 5, "close_bps": 15, "min_cost": 5, "limit_threshold": 0.095 },
  "rebalance": "daily"
}
```

- Validated (Pydantic) before anything runs; an LLM can emit it via **structured output** (same pattern as SP-1's `ProposedAssets`).
- Translated deterministically to a Qlib workflow (data handler + `TopkDropoutStrategy` + `Exchange(deal_price, costs, limit_threshold)` + `backtest`).
- **Escape hatch (power use only):** a separate `{ "raw_qlib_config": <yaml/dict> }` route, guarded, **never** reachable by the agent.

## 7. The `BacktestResult` contract

```jsonc
{
  "equity_curve": [ { "date": "YYYY-MM-DD", "nav": 1.0234 }, ... ],
  "stats": { "annualized_return": 0.0, "sharpe": 0.0, "max_drawdown": 0.0,
             "volatility": 0.0, "turnover": 0.0, "win_rate": 0.0 },
  "trades": [ ... ],                     // optional in slice 1
  "methodology": { "costs": {...}, "limit_threshold": 0.095, "deal_price": "close",
                   "data_source": "qlib:cn_data", "as_of": "..." }   // provenance, always returned
}
```

The `methodology` block is **always** returned — backtest stats are meaningless without the assumptions behind them (§6.1/§6.6 honesty).

## 8. Flow

1. Caller (Maybe `Quant::Client`, or a test/console in slice 1) **POSTs a `StrategySpec`** to `/backtest`.
2. Service **validates** (Pydantic) → translates to a Qlib workflow.
3. Runs the Qlib **daily backtest** over `cn_data` (CSI300) with `Exchange` costs + ±10% limits.
4. Returns a **`BacktestResult`** (equity curve + stats + methodology). *(Slice 1: synchronous. Heavy/long runs: enqueue to the worker, return a job id, poll — established but not exercised in slice 1.)*

## 9. Data

- **Slice 1:** Qlib bundled **`cn_data`** (has CSI300 pool; daily) — fastest path to prove the pipeline.
- **Next increment:** stand up the **canonical Parquet SoT** + a **CN ingestion adapter** (AkShare / Tushare → Parquet → Qlib `.bin` via a one-way adapter), so no engine format is the SoT. *(US later, with our own data; `us_data` is weak.)*
- **Flag:** CN market-data **redistribution licensing** is its own concern for any future commercial/user-facing use (parallel to the US redistribution issue) — out of scope for self-use MVP.

## 10. Methodology guardrails (§6.6 / §6.1)

- **Realistic costs + slippage + price-limits are always applied** (Qlib `Exchange`); never a frictionless backtest.
- **No look-ahead / survivorship sloppiness** — use Qlib's point-in-time universe + `deal_price` discipline.
- **Methodology provenance is always returned** with results (no naked stats).
- The **heavier overfitting guardrails** (mandatory out-of-sample, multiple-testing penalties) attach when strategies are **auto-generated** (the later agent milestone) — the foundation (honest costs, provenance, no look-ahead) starts here.

## 11. Error handling

- Invalid `StrategySpec` → 422 with field-level validation errors.
- Unknown universe / out-of-range dates vs. the data bundle → clear error, no silent truncation.
- Qlib runtime failure → graceful 5xx with a diagnostic; no partial/garbage result.
- Long backtest → enqueue to the worker (job id + poll), don't block the request.

## 12. Auth / security

- Service is **internal**: network-isolated + a shared token Maybe presents.
- **Typed path = no code execution.** The **raw-Qlib escape hatch** is a separate guarded route for the power user only, **never** exposed to the agent.
- DeepSeek / LLM has **no** part here (this is pure compute; the agent calls it later via the same contract).

## 13. Testing (pytest)

- **`StrategySpec` → Qlib config** translation: known spec → expected Qlib workflow.
- **Deterministic backtest:** a fixed `StrategySpec` + a small fixed `cn_data` slice → **expected stats** (seeded, reproducible — the §6.1 "computation is exact" standard).
- **Validation:** malformed specs rejected with clear errors.
- **Contract:** `/backtest` request/response shape (`StrategySpec` in, `BacktestResult` out).
- **Maybe side:** `Quant::Client` calls the service (stubbed) and parses `BacktestResult`.

## 14. Repo layout & dev deployment

- **Repo:** this service is its **own git repo** at `~/coding/Finance/quant-service/`, kept **outside** the AGPL `maybe` repo so the owned IP stays independently-licensable (§2 / §5). All new owned services live under **`~/coding/Finance/`** (the agent service later as `~/coding/Finance/agent-service/`); the AGPL Rails shell stays at `~/coding/maybe/`.
- **Dev:** run the service + worker via its own process manager, or add entries to Maybe's `Procfile.dev` that launch the sibling service (e.g., `quant: uvicorn ...` from `../Finance/quant-service`). Settle exact process/port/venv management in the plan. *(`Procfile.dev` is already locally modified — coordinate.)*

## 15. Open questions (proposed defaults — confirm at review / in the plan)

- **Data for slice 1:** Qlib `cn_data` bundle (proposed) vs. stand up the Parquet SoT first.
- **Sync vs. queue for slice 1:** synchronous endpoint (proposed) with the worker path established-but-unexercised.
- **Result persistence:** return inline (proposed) vs. persist to Postgres now.
- **How Maybe triggers a backtest pre-UI:** a Rails console / test (proposed) vs. a minimal internal endpoint.
- **Service layout / libs:** FastAPI + Pydantic v2 + Qlib; package/venv layout; how the Python service is structured in the repo (a sibling dir? separate repo?).
- **CN ingestion adapter:** AkShare (free) vs. Tushare (registration/points) — for the next increment.
- **Universe/pool handling:** rely on Qlib's CSI300 pool definition (proposed) vs. our own.
