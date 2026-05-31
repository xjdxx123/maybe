# RealReturn UI — Implementation Plan (Phase 3 of 3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Surface the RealReturn analysis as a page in the Maybe app — a portfolio overview (real annualized return + beat-inflation badge), a per-asset scorecard table, and a benchmark "opportunity cost" league table — reachable from the left nav.

**Architecture:** A read-only `RealReturnsController#show` scoped to `Current.family`, rendering `family.real_return_report` (Phase 2). A Tailwind/ERB view using Maybe's design tokens and `icon` helper (no bespoke D3 chart in v1 — numbers + semantic tables; a trend chart is a later polish). A `RealReturnsHelper` formats rates/money. A nav entry links to it.

**Tech Stack:** Rails 7.2 controllers/views, Hotwire layout, Tailwind v4 functional tokens (`text-primary`, `text-secondary`, `text-success`, `text-destructive`, `bg-container`, `border-secondary`), the `icon` helper, `Money#format`. Minitest integration test for the controller; browser verification via Claude_Preview.

**Depends on:** Phase 2 (`Family#real_return_report`, `RealReturn::PortfolioReport`, `RealReturn::Analysis`) on branch `feature/real-return`.

**Conventions:** Run from `/Users/clintongao/coding/maybe`; if `ruby -v` ≠ 3.4.4 prefix `export PATH="$HOME/.rbenv/shims:$PATH"; `. Do NOT run `bin/rails server` in responses (use Claude_Preview for the browser step). Use functional design tokens only; `icon` helper, never `lucide_icon`.

---

## File Structure

| File | Responsibility |
|---|---|
| `config/routes.rb` (modify) | add `resource :real_return, only: :show` |
| `app/controllers/real_returns_controller.rb` | `#show` → assigns `@report`, `@analyses`, `@breadcrumbs` |
| `app/models/real_return/portfolio_report.rb` (modify) | add public `inflation_rate` (expose the CPI annualized row) |
| `app/helpers/real_returns_helper.rb` | `rr_pct_yr`, `rr_money`, `rr_benchmark_label` |
| `app/views/real_returns/show.html.erb` | overview card + per-asset table + league table + empty state |
| `app/views/layouts/application.html.erb` (modify) | add a nav item |
| `test/controllers/real_returns_controller_test.rb` | GET show → 200 |

---

## Task 1: Route, controller, helper, PortfolioReport accessor, controller test

**Files:** modify `config/routes.rb`; create `app/controllers/real_returns_controller.rb`, `app/helpers/real_returns_helper.rb`, `test/controllers/real_returns_controller_test.rb`; modify `app/models/real_return/portfolio_report.rb`.

- [ ] **Step 1: write the failing controller test.** Create `test/controllers/real_returns_controller_test.rb`:

```ruby
require "test_helper"

class RealReturnsControllerTest < ActionDispatch::IntegrationTest
  setup { sign_in users(:family_admin) }

  test "show renders successfully" do
    get real_return_path
    assert_response :ok
  end
end
```

- [ ] **Step 2: run it → fails** (`undefined ... real_return_path` / no route): `bin/rails test test/controllers/real_returns_controller_test.rb`

- [ ] **Step 3: add the route.** In `config/routes.rb`, add this line next to the other top-level `resource`/`resources` declarations (e.g., immediately after the `resources :accounts` line, or anywhere inside the `Rails.application.routes.draw do` block that isn't a nested namespace):

```ruby
  resource :real_return, only: :show
```

- [ ] **Step 4: expose the inflation rate on PortfolioReport.** In `app/models/real_return/portfolio_report.rb`, add a public method (place it right after the `cpi_area` method, before the `private` keyword):

```ruby
    # Annualized inflation over the portfolio's holding period (public accessor).
    def inflation_rate
      return nil if start_date.nil?

      @cpi.annualized(area: cpi_area, from: start_date, to: as_of)
    end
```

- [ ] **Step 5: create the controller.** Create `app/controllers/real_returns_controller.rb`:

```ruby
class RealReturnsController < ApplicationController
  def show
    @report = Current.family.real_return_report
    @analyses = @report.analyses
    @breadcrumbs = [ [ "Home", root_path ], [ "Real Return", nil ] ]
  end
end
```

- [ ] **Step 6: create the helper.** Create `app/helpers/real_returns_helper.rb`:

```ruby
module RealReturnsHelper
  BENCHMARK_LABELS = {
    "sp500" => "S&P 500",
    "csi300" => "CSI 300",
    "gold" => "Gold",
    "deposit" => "Bank deposit",
    "govbond" => "Gov bond",
    "real_estate" => "Real estate",
    "cpi" => "Inflation (CPI)",
    "You" => "Your portfolio"
  }.freeze

  # Annualized rate (a Float like 0.025) -> "2.5%/yr", or em dash if nil.
  def rr_pct_yr(rate)
    return "—" if rate.nil?

    "#{(rate * 100).round(1)}%/yr"
  end

  # Float amount in `currency` -> formatted money string, or em dash if nil.
  def rr_money(amount, currency)
    return "—" if amount.nil?

    Money.new(amount, currency).format(precision: 0)
  end

  def rr_benchmark_label(key)
    BENCHMARK_LABELS.fetch(key, key.to_s.humanize)
  end
end
```

- [ ] **Step 7: run the controller test → passes** (1 run, 0 failures): `bin/rails test test/controllers/real_returns_controller_test.rb`

- [ ] **Step 8: run the model suite to confirm the PortfolioReport tweak didn't break anything:** `bin/rails test test/models/real_return/` → all green.

- [ ] **Step 9: commit**

```bash
git add config/routes.rb app/controllers/real_returns_controller.rb app/helpers/real_returns_helper.rb \
        app/models/real_return/portfolio_report.rb test/controllers/real_returns_controller_test.rb
git commit -m "feat(real_return): add real_return route, controller, helper

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: The show view (overview + tables + empty state)

**Files:** Create `app/views/real_returns/show.html.erb`

- [ ] **Step 1: create the view.** Create `app/views/real_returns/show.html.erb` with EXACTLY:

```erb
<% content_for :page_header do %>
  <div class="space-y-1 mb-6">
    <h1 class="text-xl lg:text-3xl font-medium text-primary">Real Return</h1>
    <p class="text-sm lg:text-base text-secondary">Did your investment decisions beat inflation — and what was the opportunity cost?</p>
  </div>
<% end %>

<% currency = @report.base_currency %>

<% if @analyses.empty? %>
  <div class="bg-container rounded-xl border border-secondary p-8 text-center">
    <div class="text-secondary inline-flex flex-col items-center gap-2">
      <%= icon "trending-up" %>
      <p class="max-w-md">No investment-decision assets yet. Add a property, investment, or crypto account with a purchase price and date, and your real return will appear here.</p>
    </div>
  </div>
<% else %>
  <%# 1. Portfolio overview %>
  <div class="bg-container rounded-xl border border-secondary shadow-xs p-5 mb-5">
    <div class="flex items-start justify-between flex-wrap gap-4">
      <div>
        <p class="text-sm text-secondary">Portfolio real return <span class="text-subdued">(after <%= @report.cpi_area %> inflation)</span></p>
        <p class="text-3xl font-medium <%= @report.real_return.to_f >= 0 ? "text-success" : "text-destructive" %>">
          <%= rr_pct_yr(@report.real_return) %>
        </p>
        <p class="text-sm text-secondary mt-1">
          Nominal <%= rr_pct_yr(@report.nominal_return) %> · Inflation <%= rr_pct_yr(@report.inflation_rate) %>
        </p>
      </div>
      <% unless @report.real_return.nil? %>
        <span class="inline-flex items-center gap-1 px-3 py-1.5 rounded-lg border border-secondary text-sm font-medium <%= @report.beats_inflation? ? "text-success" : "text-destructive" %>">
          <%= icon(@report.beats_inflation? ? "check" : "x", color: "current") %>
          <%= @report.beats_inflation? ? "Beat inflation" : "Lost to inflation" %>
        </span>
      <% end %>
    </div>
  </div>

  <%# 2. Per-asset scorecard %>
  <div class="bg-container rounded-xl border border-secondary shadow-xs p-5 mb-5">
    <h2 class="text-lg font-medium text-primary mb-3">By asset</h2>
    <div class="overflow-x-auto">
      <table class="w-full text-sm">
        <thead>
          <tr class="text-secondary text-left border-b border-secondary">
            <th class="py-2 pr-4 font-medium">Asset</th>
            <th class="py-2 pr-4 font-medium">Nominal</th>
            <th class="py-2 pr-4 font-medium">Real</th>
            <th class="py-2 pr-4 font-medium">vs inflation</th>
            <th class="py-2 pr-4 font-medium">Best alternative</th>
          </tr>
        </thead>
        <tbody>
          <% @analyses.each do |a| %>
            <% best_key, best_rate = a.benchmark_returns.compact.max_by { |_k, v| v } %>
            <tr class="border-b border-secondary">
              <td class="py-2 pr-4 text-primary">
                <%= a.account.name %>
                <% if a.estimated? %>
                  <span class="ml-1 text-xs text-subdued">(index-estimated)</span>
                <% end %>
              </td>
              <td class="py-2 pr-4 text-primary"><%= rr_pct_yr(a.nominal_return) %></td>
              <td class="py-2 pr-4 <%= a.real_return.to_f >= 0 ? "text-success" : "text-destructive" %>"><%= rr_pct_yr(a.real_return) %></td>
              <td class="py-2 pr-4">
                <% unless a.beats_inflation?.nil? %>
                  <span class="<%= a.beats_inflation? ? "text-success" : "text-destructive" %>"><%= a.beats_inflation? ? "✓" : "✗" %></span>
                <% end %>
              </td>
              <td class="py-2 pr-4 text-secondary">
                <%= best_key ? "#{rr_benchmark_label(best_key)} #{rr_pct_yr(best_rate)}" : "—" %>
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
  </div>

  <%# 3. Benchmark league (opportunity cost) %>
  <div class="bg-container rounded-xl border border-secondary shadow-xs p-5">
    <h2 class="text-lg font-medium text-primary mb-1">Opportunity cost</h2>
    <p class="text-sm text-secondary mb-3">Same money, same dates — annualized return by vehicle.</p>
    <ul class="space-y-1">
      <% @report.league_table.each do |label, rate| %>
        <li class="flex items-center justify-between py-1.5 px-2 rounded-lg <%= label == "You" ? "bg-container-inset" : "" %>">
          <span class="<%= label == "You" ? "text-primary font-medium" : "text-secondary" %>"><%= rr_benchmark_label(label) %></span>
          <span class="<%= label == "You" ? "text-primary font-medium" : "text-secondary" %>"><%= rr_pct_yr(rate) %></span>
        </li>
      <% end %>
    </ul>
  </div>
<% end %>
```

- [ ] **Step 2: smoke-render via the controller test.** Re-run `bin/rails test test/controllers/real_returns_controller_test.rb` — the existing `assert_response :ok` now also exercises the view template (a template error would surface here). Expected: PASS. (If `users(:family_admin)`'s family has no in-scope assets, the empty-state branch renders, which is fine.)

- [ ] **Step 3: lint the view.**

```bash
bundle exec erb_lint app/views/real_returns/show.html.erb -a
```
Expected: no remaining offenses (auto-correct any it can).

- [ ] **Step 4: commit**

```bash
git add app/views/real_returns/show.html.erb
git commit -m "feat(real_return): add Real Return page (overview, per-asset, league)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Nav link

**Files:** modify `app/views/layouts/application.html.erb`

- [ ] **Step 1: add the nav item.** In `app/views/layouts/application.html.erb`, the file begins with a `mobile_nav_items = [ ... ]` array. Add a new entry immediately after the `Budgets` line so the array reads:

```erb
<% mobile_nav_items = [
  { name: "Home", path: root_path, icon: "pie-chart", icon_custom: false, active: page_active?(root_path) },
  { name: "Transactions", path: transactions_path, icon: "credit-card", icon_custom: false, active: page_active?(transactions_path) },
  { name: "Budgets", path: budgets_path, icon: "map", icon_custom: false, active: page_active?(budgets_path) },
  { name: "Returns", path: real_return_path, icon: "trending-up", icon_custom: false, active: page_active?(real_return_path) },
  { name: "Assistant", path: chats_path, icon: "icon-assistant", icon_custom: true, active: page_active?(chats_path), mobile_only: true }
] %>
```

- [ ] **Step 2: verify the app boots & nav renders** via the controller test (still green) plus a quick route check:

```bash
bin/rails runner 'include Rails.application.routes.url_helpers; puts real_return_path'
```
Expected: prints `/real_return`.

- [ ] **Step 3: commit**

```bash
git add app/views/layouts/application.html.erb
git commit -m "feat(real_return): add Returns nav link

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Browser verification (controller-executed, Claude_Preview)

Not a subagent task — the controller runs this with the Claude_Preview MCP (the `maybe` launch config already exists in the Finance repo's `.claude/launch.json`).

- [ ] **Step 1:** Build CSS once so styles are present: `bin/rails tailwindcss:build`.
- [ ] **Step 2:** Start the server via `preview_start` (name `maybe`), then in the browser sign in with the demo account `user@maybe.local` / `password`.
- [ ] **Step 3:** Navigate to `/real_return`. Screenshot. Confirm: the "Returns" nav item shows; the overview card renders a real/nominal/inflation figure and a beat-inflation badge; the per-asset table lists the demo family's property/investment accounts; the league table ranks vehicles. Check `preview_logs`/`preview_console_logs` for errors.
- [ ] **Step 4:** If anything is broken (template error, nil crash, layout issue), fix the view/controller, rebuild CSS, reload, re-screenshot. Iterate until clean.
- [ ] **Step 5:** Stop the preview server when done.

---

## Done criteria for Phase 3

- `bin/rails test test/controllers/real_returns_controller_test.rb` and `bin/rails test test/models/real_return/` pass.
- `/real_return` renders the three zones (or a clean empty state) and is reachable from the nav, verified in the browser with the demo account.
- erb_lint clean on the new view.

**Follow-ups (noted, not in scope):** net-worth-vs-CPI trend chart (D3/Stimulus), terminal-value ("would be worth ¥X") column in the league, per-asset drill-down page, cross-currency FX on foreign benchmarks, wealth-percentile section.
