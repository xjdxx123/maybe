module RealReturn
  # Money-weighted annualized return (Actual/365). Faithful port of the validated
  # RealReturn Python solver: Newton's method, then bisection on [-0.9999, 10.0].
  module Xirr
    DAYS_PER_YEAR = 365.0

    module_function

    # flows: Array of [Date, Float]. Sign convention: outflows negative, inflows positive.
    # Returns Float rate, or nil if degenerate (need >= 2 flows with both signs).
    def compute(flows)
      return nil if flows.length < 2

      amounts = flows.map { |(_, a)| a }
      return nil if amounts.min >= 0 || amounts.max <= 0

      t0 = flows.map { |(d, _)| d }.min

      rate = 0.1
      100.times do
        denom = dnpv(rate, flows, t0)
        break if denom.abs < 1e-12

        nxt = rate - npv(rate, flows, t0) / denom
        break unless nxt.finite? && nxt > -1.0
        return nxt if (nxt - rate).abs < 1e-9

        rate = nxt
      end

      lo = -0.9999
      hi = 10.0
      f_lo = npv(lo, flows, t0)
      f_hi = npv(hi, flows, t0)
      return nil if f_lo * f_hi > 0

      200.times do
        mid = (lo + hi) / 2.0
        f_mid = npv(mid, flows, t0)
        return mid if f_mid.abs < 1e-7

        if f_lo * f_mid < 0
          hi = mid
        else
          lo = mid
          f_lo = f_mid
        end
      end

      (lo + hi) / 2.0
    end

    def npv(rate, flows, t0)
      flows.sum(0.0) do |(d, amount)|
        years = (d - t0).to_i / DAYS_PER_YEAR
        amount / (1.0 + rate)**years
      end
    end

    def dnpv(rate, flows, t0)
      flows.sum(0.0) do |(d, amount)|
        years = (d - t0).to_i / DAYS_PER_YEAR
        -years * amount / (1.0 + rate)**(years + 1.0)
      end
    end
  end
end
