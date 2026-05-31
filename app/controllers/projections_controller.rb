class ProjectionsController < ApplicationController
  def show
    @horizon = params[:years].to_i
    @horizon = 30 unless (5..40).cover?(@horizon)
    @contribution = [ params[:contribution].to_f, 0.0 ].max
    @currency = Current.family.currency

    @cma = RealReturn::Cma.new
    projection = RealReturn::Projection.new(Current.family, as_of: Date.current, cma: @cma)
    @assets = projection.assets(horizon: @horizon)
    @result = projection.project(horizon: @horizon, annual_contribution: @contribution)

    tier = RealReturn::WealthTier.new
    @start_value = @result[:p50].first
    @tier_now = tier.placement(@start_value)
    @tier_future = tier.placement(@result[:p50].last)

    @custom_weights = {
      equity: params.dig(:w, :equity).to_f, bonds: params.dig(:w, :bonds).to_f,
      real_estate: params.dig(:w, :real_estate).to_f, gold: params.dig(:w, :gold).to_f,
      cash: params.dig(:w, :cash).to_f
    }
    comparison = RealReturn::PortfolioComparison.new(
      Current.family, as_of: Date.current, horizon: @horizon, annual_contribution: @contribution,
      custom_weights: @custom_weights, cma: @cma
    )
    @comparison = comparison.rows
    @methodology_classes = comparison.referenced_asset_classes

    @breadcrumbs = [ [ "Home", root_path ], [ "Projection", nil ] ]
  end
end
