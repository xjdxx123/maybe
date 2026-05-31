require "test_helper"

class RealReturn::CorrelationTest < ActiveSupport::TestCase
  test "matrix is equicorrelation: 1 on the diagonal, rho off-diagonal" do
    m = RealReturn::Correlation.new(rho: 0.3).matrix(3)
    assert_equal [ [ 1.0, 0.3, 0.3 ], [ 0.3, 1.0, 0.3 ], [ 0.3, 0.3, 1.0 ] ], m
  end

  test "cholesky factor reconstructs the matrix (L * L^T == matrix)" do
    corr = RealReturn::Correlation.new(rho: 0.25)
    n = 4
    l = corr.cholesky(n)
    m = corr.matrix(n)
    (0...n).each do |i|
      (0...n).each do |j|
        recon = (0...n).sum { |k| l[i][k] * l[j][k] }
        assert_in_delta m[i][j], recon, 1e-9, "L*L^T mismatch at #{i},#{j}"
      end
    end
  end

  test "cholesky of n=1 is [[1.0]]" do
    assert_equal [ [ 1.0 ] ], RealReturn::Correlation.new.cholesky(1)
  end
end
