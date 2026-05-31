# RealReturn Projection UI (P-D) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A "Projection" page (reachable from the left nav) that shows the basket's forward pessimistic/neutral/optimistic real-value fan, terminal figures at the horizon, the social wealth tier (today vs projected, CN & global), and the editable assumptions — driven by horizon + annual-savings inputs.

**Architecture:** `ProjectionsController#show` runs `RealReturn::Projection` (P-B) + `RealReturn::WealthTier` (P-C) + `RealReturn::Cma` (P-A) and renders a view. The fan chart is a **server-rendered SVG** (band polygon p15↔p85 + median polyline) via a helper — no JS/D3 dependency. Inputs (`years`, `contribution`) are query params (Hotwire-friendly GET form).

**Tech Stack:** Rails 7.2 controllers/views, Tailwind functional tokens, the `icon` helper, existing `RealReturnsHelper` (`rr_money`, `rr_pct_yr`). Minitest controller test + browser verification (Claude_Preview).

**Depends on:** P-A/P-B/P-C (all on `feature/real-return`).

**Conventions:** Run from `/Users/clintongao/coding/maybe`; if `ruby -v` ≠ 3.4.4 prefix `export PATH="$HOME/.rbenv/shims:$PATH"; `. Don't run `bin/rails server` (use Claude_Preview). Functional tokens only; `icon` helper.

---

## File Structure

| File | Responsibility |
|---|---|
| `config/routes.rb` (modify) | `resource :projection, only: :show` |
| `app/controllers/projections_controller.rb` (create) | `#show` → assigns projection result, tiers, assumptions |
| `app/helpers/projections_helper.rb` (create) | `projection_fan_svg(...)` server-rendered SVG |
| `app/views/projections/show.html.erb` (create) | params + fan + terminal + tier + assumptions |
| `app/views/layouts/application.html.erb` (modify) | add "Projection" nav item |
| `test/controllers/projections_controller_test.rb` (create) | GET show → 200 |

---

## Task 1: Route, controller, fan-chart helper, controller test

**Files:** modify `config/routes.rb`; create `app/controllers/projections_controller.rb`, `app/helpers/projections_helper.rb`, `test/controllers/projections_controller_test.rb`.

- [ ] **Step 1: Write the failing controller test.** Create `test/controllers/projections_controller_test.rb`:

```ruby
require "test_helper"

class ProjectionsControllerTest < ActionDispatch::IntegrationTest
  setup { sign_in users(:family_admin) }

  test "show renders successfully" do
    get projection_path
    assert_response :ok
  end

  test "show accepts horizon and contribution params" do
    get projection_path(years: 20, contribution: 50_000)
    assert_response :ok
  end
end
```

- [ ] **Step 2: Run it → fails** (`undefined ... projection_path`): `bin/rails test test/controllers/projections_controller_test.rb`

- [ ] **Step 3: Add the route.** In `config/routes.rb`, next to the other top-level `resource`/`resources` (e.g. right after `resource :real_return, only: :show`), add:

```ruby
  resource :projection, only: :show
```

- [ ] **Step 4: Create the controller.** Create `app/controllers/projections_controller.rb`:

```ruby
class ProjectionsController < ApplicationController
  def show
    @horizon = params[:years].to_i
    @horizon = 30 unless (5..40).cover?(@horizon)
    @contribution = [ params[:contribution].to_f, 0.0 ].max
    @currency = Current.family.currency

    projection = RealReturn::Projection.new(Current.family, as_of: Date.current)
    @assets = projection.assets
    @result = projection.project(horizon: @horizon, annual_contribution: @contribution)
    @cma = RealReturn::Cma.new

    tier = RealReturn::WealthTier.new
    @start_value = @result[:p50].first
    @tier_now = tier.placement(@start_value)
    @tier_future = tier.placement(@result[:p50].last)

    @breadcrumbs = [ [ "Home", root_path ], [ "Projection", nil ] ]
  end
end
```

- [ ] **Step 5: Create the helper.** Create `app/helpers/projections_helper.rb`:

```ruby
module ProjectionsHelper
  # Server-rendered SVG fan chart: shaded p15..p85 band + p50 median line.
  # years/p15/p50/p85 are parallel arrays. Returns an html_safe SVG string.
  def projection_fan_svg(years, p15, p50, p85, width: 640, height: 220, pad: 6)
    n = years.size
    max = p85.max.to_f
    return "".html_safe if n < 2 || max <= 0

    xs = ->(i) { (pad + (width - 2 * pad) * (i.to_f / (n - 1))).round(1) }
    ys = ->(v) { (height - pad - (height - 2 * pad) * (v.to_f / max)).round(1) }

    top = (0...n).map { |i| "#{xs.call(i)},#{ys.call(p85[i])}" }
    bottom = (n - 1).downto(0).map { |i| "#{xs.call(i)},#{ys.call(p15[i])}" }
    band = (top + bottom).join(" ")
    median = (0...n).map { |i| "#{xs.call(i)},#{ys.call(p50[i])}" }.join(" ")

    <<~SVG.html_safe
      <svg viewBox="0 0 #{width} #{height}" class="w-full text-success" role="img" aria-label="Projection fan chart">
        <polygon points="#{band}" fill="currentColor" fill-opacity="0.15" />
        <polyline points="#{median}" fill="none" stroke="currentColor" stroke-width="2" />
      </svg>
    SVG
  end

  # Unique asset-class keys present in the projection basket, in stable order.
  def projection_asset_classes(assets)
    assets.map { |a| a[:asset_class] }.uniq
  end
end
```

- [ ] **Step 6: Add a minimal placeholder view so the action renders** (replaced in Task 2). Create `app/views/projections/show.html.erb` with exactly:

```erb
<%# Projection page (built in the next task) %>
```

- [ ] **Step 7: Run the controller test → passes** (2 runs, 0 failures): `bin/rails test test/controllers/projections_controller_test.rb`. (If `family_admin`'s family has no in-scope assets, the projection is an empty/zero basket — still renders 200.)

- [ ] **Step 8: Commit**

```bash
git add config/routes.rb app/controllers/projections_controller.rb app/helpers/projections_helper.rb \
        app/views/projections/show.html.erb test/controllers/projections_controller_test.rb
git commit -m "feat(real_return): add projection route, controller, fan-chart helper

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: The projection view

**Files:** Modify `app/views/projections/show.html.erb` (overwrite the placeholder).

- [ ] **Step 1: Overwrite the view.** Replace `app/views/projections/show.html.erb` with EXACTLY:

```erb
<% content_for :page_header do %>
  <div class="space-y-1 mb-6">
    <h1 class="text-xl lg:text-3xl font-medium text-primary">Projection</h1>
    <p class="text-sm lg:text-base text-secondary">Where could your basket go over the next decades — and what wealth tier would it reach?</p>
  </div>
<% end %>

<% currency = @currency %>

<% if @assets.empty? %>
  <div class="bg-container rounded-xl border border-secondary p-8 text-center">
    <div class="text-secondary inline-flex flex-col items-center gap-2">
      <%= icon "telescope" %>
      <p class="max-w-md">No assets to project yet. Add a property, investment, crypto, cash, or other-asset account and your forward projection will appear here.</p>
    </div>
  </div>
<% else %>
  <%# 1. Parameters %>
  <div class="bg-container rounded-xl border border-secondary shadow-xs p-5 mb-5">
    <%= form_with url: projection_path, method: :get, class: "flex flex-wrap items-end gap-4" do |f| %>
      <div>
        <%= f.label :years, "Horizon (years)", class: "block text-xs text-secondary mb-1" %>
        <%= f.select :years, options_for_select([ 10, 15, 20, 30 ], @horizon), {}, class: "rounded-lg border border-secondary bg-container text-primary text-sm px-3 py-2" %>
      </div>
      <div>
        <%= f.label :contribution, "Annual savings (#{currency})", class: "block text-xs text-secondary mb-1" %>
        <%= f.number_field :contribution, value: @contribution.round, step: 10_000, min: 0, class: "rounded-lg border border-secondary bg-container text-primary text-sm px-3 py-2 w-40" %>
      </div>
      <%= f.submit "Update", class: "rounded-lg bg-gray-900 text-white text-sm font-medium px-4 py-2 cursor-pointer" %>
    <% end %>
  </div>

  <%# 2. Fan chart %>
  <div class="bg-container rounded-xl border border-secondary shadow-xs p-5 mb-5">
    <h2 class="text-lg font-medium text-primary mb-1">Real net worth (today's purchasing power)</h2>
    <p class="text-sm text-secondary mb-3">Shaded band = pessimistic→optimistic (15th–85th pct); line = neutral (median).</p>
    <%= projection_fan_svg(@result[:years], @result[:p15], @result[:p50], @result[:p85]) %>
    <div class="flex justify-between text-xs text-subdued mt-1">
      <span><%= Date.current.year %></span>
      <span><%= Date.current.year + @horizon %></span>
    </div>
  </div>

  <%# 3. Terminal figures %>
  <div class="bg-container rounded-xl border border-secondary shadow-xs p-5 mb-5">
    <h2 class="text-lg font-medium text-primary mb-3">In <%= Date.current.year + @horizon %> (real)</h2>
    <div class="grid grid-cols-3 gap-4">
      <% [ [ "Pessimistic", @result[:p15].last, "text-destructive" ], [ "Neutral", @result[:p50].last, "text-primary" ], [ "Optimistic", @result[:p85].last, "text-success" ] ].each do |label, value, color| %>
        <div>
          <p class="text-xs text-secondary"><%= label %></p>
          <p class="text-lg font-medium <%= color %>"><%= rr_money(value, currency) %></p>
        </div>
      <% end %>
    </div>
    <p class="text-xs text-subdued mt-3">Today: <%= rr_money(@start_value, currency) %>. Values are real (today's purchasing power); nominal amounts would be larger because of inflation.</p>
  </div>

  <%# 4. Social wealth tier %>
  <div class="bg-container rounded-xl border border-secondary shadow-xs p-5 mb-5">
    <h2 class="text-lg font-medium text-primary mb-3">Wealth tier</h2>
    <table class="w-full text-sm">
      <thead>
        <tr class="text-secondary text-left border-b border-secondary">
          <th class="py-2 pr-4 font-medium"></th>
          <th class="py-2 pr-4 font-medium">Today</th>
          <th class="py-2 pr-4 font-medium">Projected (neutral)</th>
        </tr>
      </thead>
      <tbody>
        <% [ [ "China", :cn ], [ "Global", :global ] ].each do |name, key| %>
          <tr class="border-b border-secondary">
            <td class="py-2 pr-4 text-secondary"><%= name %></td>
            <td class="py-2 pr-4 text-primary"><%= @tier_now[key][:label] %> <span class="text-subdued">(<%= @tier_now[key][:percentile]&.round(1) %>%)</span></td>
            <td class="py-2 pr-4 text-primary"><%= @tier_future[key][:label] %> <span class="text-subdued">(<%= @tier_future[key][:percentile]&.round(1) %>%)</span></td>
          </tr>
        <% end %>
      </tbody>
    </table>
  </div>

  <%# 5. Assumptions %>
  <div class="bg-container rounded-xl border border-secondary shadow-xs p-5">
    <h2 class="text-lg font-medium text-primary mb-1">Assumptions</h2>
    <p class="text-sm text-secondary mb-3">Forward expected real returns per asset class (editable in <code>config/real_return/cma.yml</code>).</p>
    <table class="w-full text-sm">
      <thead>
        <tr class="text-secondary text-left border-b border-secondary">
          <th class="py-2 pr-4 font-medium">Asset class</th>
          <th class="py-2 pr-4 font-medium">Expected real return</th>
          <th class="py-2 pr-4 font-medium">Volatility (σ)</th>
        </tr>
      </thead>
      <tbody>
        <% projection_asset_classes(@assets).each do |klass| %>
          <tr class="border-b border-secondary">
            <td class="py-2 pr-4 text-primary"><%= klass %></td>
            <td class="py-2 pr-4 text-primary"><%= rr_pct_yr(@cma.expected_real_return(klass)) %></td>
            <td class="py-2 pr-4 text-secondary"><%= number_to_percentage((@cma.sigma(klass) || 0) * 100, precision: 0) %></td>
          </tr>
        <% end %>
      </tbody>
    </table>
  </div>
<% end %>
```

- [ ] **Step 2: Verify the page renders** (controller test exercises the template): `bin/rails test test/controllers/projections_controller_test.rb` → 2 runs, 0 failures. If it errors with a template/NoMethod error, STOP and report BLOCKED with the full error.

- [ ] **Step 3: Lint the view:** `bundle exec erb_lint app/views/projections/show.html.erb -a` → ends clean.

- [ ] **Step 4: Commit**

```bash
git add app/views/projections/show.html.erb
git commit -m "feat(real_return): build Projection page (fan, terminal, tier, assumptions)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Projection nav link

**Files:** Modify `app/views/layouts/application.html.erb`.

- [ ] **Step 1: Add the nav item.** In `app/views/layouts/application.html.erb`, the `mobile_nav_items = [ ... ]` array currently has a "Returns" entry. Add a "Projection" entry immediately AFTER the Returns line:

```erb
  { name: "Projection", path: projection_path, icon: "telescope", icon_custom: false, active: page_active?(projection_path) },
```

So the array reads Home · Transactions · Budgets · Returns · Projection · (Assistant, mobile_only).

- [ ] **Step 2: Verify nav renders + route resolves:**

```bash
bin/rails runner 'include Rails.application.routes.url_helpers; puts projection_path'
bin/rails test test/controllers/projections_controller_test.rb test/controllers/real_returns_controller_test.rb
```
Expected: prints `/projection`; tests green (the layout/nav renders on each).

- [ ] **Step 3: Run whole suite + rubocop:**

```bash
bin/rails test test/models/real_return/ test/controllers/real_returns_controller_test.rb test/controllers/projections_controller_test.rb
bin/rubocop app/models/real_return/ app/controllers/projections_controller.rb app/helpers/projections_helper.rb
```
Expected: all green; no offenses.

- [ ] **Step 4: Commit**

```bash
git add app/views/layouts/application.html.erb
git commit -m "feat(real_return): add Projection nav link

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Browser verification (controller-executed, Claude_Preview)

Not a subagent task — the controller runs this with Claude_Preview.

- [ ] **Step 1:** `bin/rails tailwindcss:build`. If a stale server holds port 3000, clear it (`rm -f tmp/pids/server.pid` after killing the pid) before starting.
- [ ] **Step 2:** `preview_start` (name `maybe`); sign in as `admin@maybe.local` / `password` (CNY family). Login tip: set the email/password input values via the native setter + `input` event, then call `form.submit()` (plain `.submit()`, not `requestSubmit`).
- [ ] **Step 3:** Navigate to `/projection`. Screenshot. Confirm: the "Projection" nav item is present and active; the fan chart renders (shaded band + median line); terminal cards show pessimistic/neutral/optimistic real ¥ for the horizon year; the Wealth tier table shows China + Global, Today vs Projected (Top 1%); the Assumptions table lists the basket's asset classes with expected real return + σ. Check `preview_console_logs` for errors.
- [ ] **Step 4:** Change the horizon (select 20) and set annual savings (e.g. 200000) → Update → confirm the chart/terminals update.
- [ ] **Step 5:** If broken, fix view/controller/helper, rebuild CSS, reload, re-screenshot. Stop the preview server when done.

---

## Done criteria

- `bin/rails test test/models/real_return/ test/controllers/` (real_return + projections) passes.
- `/projection` renders the fan chart + terminal + wealth tier + assumptions (or a clean empty state), reachable from the nav, verified in the browser with the demo CNY account; horizon/savings inputs update the result.
- erb_lint + rubocop clean on touched files.

**This completes the RealReturn + Projection feature.** Follow-ups (noted, not in scope): nominal toggle on the fan, finer top-tier labels (Top 0.1%), editable assumptions UI, per-account asset-class overrides, rental-income modeling, full structural macro mode.
