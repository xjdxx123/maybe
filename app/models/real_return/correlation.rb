module RealReturn
  # Cross-asset correlation as a single documented equicorrelation rho (1 on the
  # diagonal, rho off-diagonal). Always positive-semidefinite for rho in
  # [-1/(n-1), 1], so its Cholesky factor always exists. Pairwise-from-history
  # correlations are a future refinement.
  class Correlation
    DEFAULT_RHO = 0.25

    def initialize(rho: DEFAULT_RHO)
      @rho = rho
    end

    # n x n equicorrelation matrix (Array of Arrays of Float).
    def matrix(n)
      Array.new(n) do |i|
        Array.new(n) { |j| i == j ? 1.0 : @rho.to_f }
      end
    end

    # Lower-triangular Cholesky factor L of matrix(n), so L * L^T == matrix(n).
    def cholesky(n)
      a = matrix(n)
      l = Array.new(n) { Array.new(n, 0.0) }
      (0...n).each do |i|
        (0..i).each do |j|
          s = (0...j).sum { |k| l[i][k] * l[j][k] }
          l[i][j] = if i == j
            Math.sqrt([ a[i][i] - s, 0.0 ].max)
          else
            l[j][j].zero? ? 0.0 : (a[i][j] - s) / l[j][j]
          end
        end
      end
      l
    end
  end
end
