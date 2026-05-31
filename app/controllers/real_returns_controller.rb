class RealReturnsController < ApplicationController
  def show
    @report = Current.family.real_return_report
    @analyses = @report.analyses
    @breadcrumbs = [ [ "Home", root_path ], [ "Real Return", nil ] ]
  end
end
