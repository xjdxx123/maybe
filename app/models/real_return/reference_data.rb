module RealReturn
  # Read-only access to bundled reference series (CPI + benchmarks).
  #
  # Interface contract (implementations provide these instance methods; all `on:`
  # arguments are a Date and values are interpolated by day-fraction between years):
  #   #cpi_index(area:, on:)               -> Float | nil
  #   #benchmark_level(key:, on:, region:) -> Float | nil   (region: defaults to nil)
  #   #cpi_range(area:)                    -> (Date..Date) | nil
  #   #benchmark_range(key:, region:)      -> (Date..Date) | nil
  module ReferenceData
    # Swap point for a future live source. Phase 2 points the bundled reader at
    # config/real_return/*.yml; callers depend only on this factory.
    def self.default
      @default ||= Bundled.new
    end
  end
end
