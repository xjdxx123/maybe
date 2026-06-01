# SP-1 — Conversational Asset Entry + Instant Real-Return Analysis — Design Spec

**Date:** 2026-06-01
**Status:** Draft (brainstorming). **Sequencing (2026-06-01): built *after* the Qlib quant/data service** — see parent roadmap §7. This spec remains valid as designed; only its build order moved.
**Parent:** `docs/superpowers/specs/2026-06-01-asset-intelligence-north-star-design.md` (§7 SP-1, §8, Pillar C).
**Builds on:** the `real_return` engine (18 models) and Maybe's account/valuation model.

---

## 1. Goal

Deliver the flagship scenario end-to-end, as the **first capability of the general agent (Pillar C)**:

> **User:** *"我有 100万现金、600万房产（2021年买入）、600万股票，帮我录入并分析。"*
> **System:** parse → **confirm** → record → compute lifetime real return + inflation verdict + benchmark league → **uncertainty-aware** summary.

And — equally important — **establish the owned external Python agent service, the clean Maybe↔agent boundary, and the guarded write loop** that every later capability (quant/backtest/factor) will reuse. SP-1 proves the *framework* on an easy capability before the hard ones.

## 2. What exists vs. what SP-1 adds (grounded in code)

**Exists (from exploration):**
- Maybe in-process `Assistant` (Ruby, OpenAI `gpt-4.1`) with **read-only** functions (`GetAccounts`, `GetBalanceSheet`, …); `Chat`/`Message`/`ToolCall` models; Turbo-broadcast chat UI. [assistant.rb](../../../app/models/assistant.rb), [configurable.rb](../../../app/models/assistant/configurable.rb)
- `real_return` engine: `RealReturn::Analysis.new(account)`, `Family#real_return_report`. [analysis.rb](../../../app/models/real_return/analysis.rb), [family.rb:121](../../../app/models/family.rb)
- Account write path: `Account.create_and_sync` + `Account::OpeningBalanceManager#set_opening_balance` (creates `opening_anchor` Valuation); `account.create_reconciliation` (current value). [opening_balance_manager.rb](../../../app/models/account/opening_balance_manager.rb)
- API: `Api::V1::BaseController` with OAuth + API-key auth and `read` / `read_write` scopes; `Api::V1::AccountsController#index`. [base_controller.rb](../../../app/controllers/api/v1/base_controller.rb)

**SP-1 adds:**
1. An owned **external Python agent service** (DeepSeek; tool-calling; `/query` + SSE).
2. A **Maybe↔agent bridge** (route a chat conversation to the external agent; stream the reply back into the existing chat UI).
3. **Read API** endpoints the agent needs for grounding/dedup.
4. A **proposed-assets confirmation UI** (Hotwire).
5. The **deterministic write-on-confirm** orchestration (the first *write* flow — all existing functions are read-only).
6. Reuse of the `real_return` display.

## 3. Locked decisions (from brainstorming)

| Decision | Choice |
|---|---|
| Agent location | **Owned external service** (not Maybe's in-process Assistant) — establishes the §5 boundary now |
| Language | **Python** (a "Python microservice"; co-located with the future Qlib service; best agent libs; API-bounded → low-stakes) |
| MVP LLM | **DeepSeek** (`deepseek-chat`), OpenAI-compatible API, **behind a swappable `LLMProvider` interface** |
| Division of labor | **Maybe** = chat UI + deterministic writes + `real_return` math. **Agent** = brain (parse / propose / narrate) with **read-only** access to Maybe. Writes happen in Maybe **post-confirm** → agent needs **no write access** (§6.3) |
| Framework vs. tools | Build the **general agent framework**; asset entry is its **first toolset**; quant tools come after SP-2 |

## 4. Scope & non-goals

**In scope:** NL entry of **cash (Depository), property (Property), stocks (Investment)**; the property-bought-2021 case (`opening_anchor`@purchase + `current_anchor`@now); the confirmation UI; deterministic write; real-return analysis display; the agent framework (`/query`, SSE, tool-calling, DeepSeek provider, read tools, the proposed-assets contract).

**Non-goals (SP-1):**
- Quant / backtest / factor tools (Pillar B; after SP-2).
- **Itemized holdings with live market pricing** for stocks — SP-1 uses lump-value entry; itemization is a fast-follow (§9).
- Money-moving / trading; autonomous (unconfirmed) writes.
- Liabilities (loans/mortgage) — inherits the `real_return` non-goals.
- Complex multi-turn planning beyond the entry+analyze flow.

## 5. Architecture

```
┌─────────────────────────────────────────────┐        ┌──────────────────────────────┐
│ MAYBE (Rails shell)                          │  HTTP  │ AGENT service (OWNED, Python)│
│ • chat UI (reuse Chat/Message + Turbo)       │  /query│ • DeepSeek (swappable provider)│
│ • bridge: proxy convo → agent, stream back   │───SSE─▶│ • tool-calling orchestration  │
│ • confirmation UI (Hotwire, from payload)    │◀───────│ • read tools → Maybe read API │
│ • DETERMINISTIC write-on-confirm (PORO)      │  read  │ • emits ProposedAssets payload│
│ • real_return math + display                 │◀──API──│   + narration over SSE        │
└─────────────────────────────────────────────┘ (read- └──────────────────────────────┘
        Maybe owns writes + math               only)            (no write access)
                                                          DeepSeek key lives here only
```

- The agent is **read-only** into Maybe (API key, `read` scope) — for grounding/dedup, never to write.
- All money-affecting writes + all math stay in Maybe's deterministic Ruby (§6.3).
- Protocol: borrow OpenBB's **`/agents.json` + `/query` + SSE** shape (minimal fidelity now, fuller later).
- This is the **first instance of the §5 owned-service boundary** and the seam later capabilities reuse.

## 6. Flow

1. User describes assets in **Maybe's chat UI** (reuse `Chat`/`Message`).
2. Maybe's **bridge** POSTs the conversation to the agent `/query` (SSE).
3. Agent runs DeepSeek with **read tools** (calls Maybe's read API for existing accounts / base currency → dedup & disambiguation grounding).
4. Agent streams **narration** + a final **structured `ProposedAssets` payload** (validated; retried on invalid).
5. Maybe renders a **Hotwire confirmation UI** from the payload — user fixes amount / currency / acquisition date / ticker / current value.
6. On **confirm**, Maybe writes deterministically in-process (`AssetIntake::Recorder` → `Account.create_and_sync` + `opening_anchor`@acquisition + `current_anchor`@now), then computes `RealReturn::Analysis` / `Family#real_return_report`.
7. Maybe displays the analysis (reuse `real_returns` view components).

## 7. Components

### 7.1 Agent service (Python)
- **Endpoints:** `GET /agents.json` (capability descriptor), `POST /query` (SSE stream of narration + final payload).
- **LLM provider abstraction:** `LLMProvider` interface; `DeepSeekProvider` (OpenAI-compatible `base_url`) is the first impl. Swappable.
- **Orchestration:** **pydantic-ai** (recommended) for typed tool-calling + provider-agnostic structured output. (Alt: LangGraph / raw OpenAI-compatible client — confirm at review.)
- **Tools (read-only, into Maybe):** `get_portfolio_context` (existing accounts, family base currency) for dedup/disambiguation. Parsing itself is the LLM's **structured-output** job, not a tool.
- **Output:** streamed narration + a final `ProposedAssets` object, **validated against the schema with a repair/retry loop**; on persistent failure, returns a "couldn't parse — please rephrase" signal.
- **Secrets:** DeepSeek API key in the agent service env only.

### 7.2 Maybe side
- **Bridge:** for an agent-backed chat, a path that streams the agent's SSE into the existing `AssistantMessage` Turbo broadcast, reusing `Chat`/`Message` + the chat UI. *(Proposed: a dedicated proxy controller/responder. Alt: a `Provider::Llm` "AgentService" impl plugged into the existing `Assistant`. Confirm at review.)*
- **Read API:** scoped **read-only** endpoints the agent calls (accounts + base currency; possibly a `real_return` context). Reuse `Api::V1` + an API key with `read` scope. `accounts#index` already exists.
- **Confirmation UI:** a Hotwire view rendering the `ProposedAssets` payload as an editable per-asset form (type, amount, currency, acquisition date, current value, identifier, `estimated` flag) + confirm/cancel.
- **`AssetIntake::Recorder` (PORO):** maps confirmed `ProposedAssets` → `Account.create_and_sync` + `OpeningBalanceManager` (`opening_anchor`@acquisition) + `current_anchor`. Idempotent. **This is the thin capability PORO** that keeps later extraction cheap.
- **Analysis display:** compute `Family#real_return_report`, render with existing `real_returns` components.

## 8. The `ProposedAssets` contract (boundary schema)

```jsonc
{
  "assets": [
    {
      "asset_type": "depository | property | investment | crypto | vehicle | other_asset",
      "name": "string",
      "amount": "decimal",            // current value (and, for cash, the balance)
      "currency": "ISO-4217",
      "acquisition_date": "YYYY-MM-DD | null",   // purchase date (property/investment)
      "acquisition_amount": "decimal | null",    // cost basis at acquisition, if given
      "identifier": "string | null",  // ticker/symbol, if itemizing (fast-follow)
      "estimated": "bool",            // true if any figure was inferred, not stated
      "notes": "string | null"
    }
  ],
  "narration": "string"               // human-facing summary of what was parsed (NO computed returns)
}
```

Validated on **both** sides. The agent's `narration` describes *what it parsed*; it must **not** state a return figure (returns are computed post-write by `real_return`).

## 9. Asset-type handling

- **cash → `Depository`**: current balance.
- **property → `Property`**: `opening_anchor` @ `acquisition_date` (purchase price) + `current_anchor` @ today (current value; if unknown → `real_return`'s regional house-price-index estimate, flagged `estimated`).
- **stocks → `Investment`**: **SP-1 default = lump value** (record acquisition value @ date + current value) so `real_return` can compute a money-weighted real return. **Open integration point:** `RealReturn::Analysis` currently market-prices `Investment` via `holdings`/`trades`, while manual-valued types use valuations. SP-1 must either (a) record lump-valued stocks through a valuation path that `Analysis` can consume, or (b) make a small `Analysis` extension to accept a lump-valued investment. **Proposed:** record via the valuation/anchor path; settle the exact mechanism in the implementation plan. **Itemized holdings (real tickers + market pricing) = fast-follow.**

## 10. Guarded write & safety (§6.3)

- **Nothing persists without explicit user confirmation.**
- The **LLM never emits a computed figure** — returns are computed by `real_return` *after* the write; the agent narration only restates parsed inputs.
- **Ambiguous input is always surfaced** in the confirmation UI, never silently guessed.
- **No money-moving actions** of any kind.

## 11. Auth / security across the boundary

- **Agent → Maybe:** API key with **`read` scope only** (no write). Family-scoped via the key's user.
- **Maybe → Agent:** the bridge calls the agent `/query`; the agent endpoint is network-isolated + a shared token.
- **DeepSeek key** lives only in the agent service.
- No write scope is ever issued to the agent — writes are exclusively Maybe's deterministic, post-confirm path.

## 12. Error handling / edge cases

- **Structured-output invalid** → repair/retry; persistent failure → "couldn't parse, please rephrase."
- **DeepSeek tool-calling flakiness** → keep the tool surface tiny; validate every payload; deterministic fallback. (Provider is swappable if needed.)
- **Agent service down / timeout** → chat shows a graceful error; **no partial writes**.
- **Missing current value** → `real_return`'s existing degrade ("needs current value" / index estimate, flagged `estimated`).
- **Missing FX leg** → `real_return`'s existing annotate-and-skip.
- **Duplicate entry** → `Recorder` is idempotent and dedups via `get_portfolio_context` (asks before duplicating).

## 13. Testing (Minitest + fixtures on Maybe; pytest on the agent)

- **Maybe (Minitest):** `AssetIntake::Recorder` maps `ProposedAssets` → correct `Account`/`Entry`/`Valuation` (property opening+current; cash; stocks); confirm controller renders the payload and writes only on confirm; real-return display renders the key figures. Do **not** test ActiveRecord itself.
- **Agent (pytest):** NL → `ProposedAssets` for representative CN + EN inputs against expected structured output (mock/recorded LLM); `/query` SSE contract; `LLMProvider` abstraction with a fake provider; schema validation + retry loop.
- **Boundary:** a stubbed agent (recorded SSE) for Maybe-side integration; a stubbed Maybe read API for agent tests; VCR-style cassettes for DeepSeek.

## 14. Open questions (proposed defaults — confirm at review / in the plan)

- **Stocks:** lump-value-first (proposed) vs. require itemization; and the exact `real_return` mechanism for lump-valued `Investment` (valuation path vs. small `Analysis` extension).
- **Bridge mechanism:** dedicated proxy controller/responder (proposed) vs. a `Provider::Llm` "AgentService" plugged into the existing `Assistant`.
- **Conversation model:** reuse Maybe's `Chat`/`Message` (proposed: yes) vs. a new model for agent conversations.
- **Orchestration lib:** pydantic-ai (proposed) vs. LangGraph vs. raw OpenAI-compatible client.
- **Protocol fidelity:** minimal `/agents.json` + `/query` + SSE now (proposed) vs. fuller OpenBB-protocol parity.
- **Deployment:** how the Python agent service runs alongside Maybe in dev (Procfile entry?) and prod — settle in the plan.
