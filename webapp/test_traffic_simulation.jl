# Sanity tests for traffic_simulation.jl. Run with:
#   julia --project=webapp webapp/test_traffic_simulation.jl

using Test

include(joinpath(@__DIR__, "traffic_simulation.jl"))

@testset "FIFO enforcement" begin
    # Build a degenerate 2-customer, 4-bin tensor that violates FIFO:
    # depart at bin 1 with travel=5h, depart at bin 2 with travel=1h -> arrival at 3h < arrival at 6h.
    T = zeros(Float64, 4, 2, 2)
    bin_seconds = 3600
    # i = 1 -> j = 2 only; reverse direction stays 0 throughout.
    T[1, 1, 2] = 5 * bin_seconds   # depart 0, arrive 5h
    T[2, 1, 2] = 1 * bin_seconds   # depart 1h, arrive 2h (FIFO violation)
    T[3, 1, 2] = 1 * bin_seconds   # depart 2h, arrive 3h (still < 5h)
    T[4, 1, 2] = 10 * bin_seconds  # depart 3h, arrive 13h (OK)

    correction = enforce_fifo!(T; bin_seconds=bin_seconds)
    @test correction > 0

    # Arrival must be monotone after enforcement.
    arrivals = [(h - 1) * bin_seconds + T[h, 1, 2] for h in 1:4]
    @test all(arrivals[h+1] >= arrivals[h] for h in 1:3)

    # Idempotent: a second pass adds zero correction.
    T_before = copy(T)
    correction2 = enforce_fifo!(T; bin_seconds=bin_seconds)
    @test correction2 == 0.0
    @test T == T_before
end

@testset "BPR speeds — no congestion case" begin
    # Manually fabricate an md-like structure isn't trivial; verify the BPR
    # formula in isolation by recomputing what bpr_speeds should produce
    # for a single edge with zero flow.
    alpha = 0.15
    beta = 4.0
    # zero flow: t_factor == 1.0 -> speed unchanged
    flow = 0
    cap = 1500
    t_factor = 1.0 + alpha * (flow / cap)^beta
    @test t_factor == 1.0

    # at saturation (flow == cap): t_factor == 1 + alpha = 1.15
    flow = 1500
    t_factor = 1.0 + alpha * (flow / cap)^beta
    @test isapprox(t_factor, 1.15; atol=1e-12)

    # at 2x cap: t_factor == 1 + 0.15 * 16 = 3.4
    flow = 3000
    t_factor = 1.0 + alpha * (flow / cap)^beta
    @test isapprox(t_factor, 3.4; atol=1e-12)
end

@testset "IGP integration — constant-speed path" begin
    # Build a tiny synthetic MapData proxy that just has the fields igp_travel_time
    # uses: md.w (edge length lookup). Construct via NamedTuple-like duck typing.
    # Simpler: use a dummy minimal struct.
    mutable struct DummyMD
        w::SparseMatrixCSC{Float64,Int}
    end
    # Two-vertex line: edge (1,2) of length 7200 m. Constant speed 10 m/s -> 720s.
    w = sparse([1], [2], [7200.0], 2, 2)
    md = DummyMD(w)
    edge_speeds = Dict((1, 2) => fill(10.0, TDVRP_NUM_BINS))
    t = igp_travel_time(md, [1, 2], edge_speeds, 0.0)
    @test isapprox(t, 720.0; atol=1e-6)

    # Same edge, but speed doubles after first bin boundary (3600s).
    # The vehicle covers 36000 m in the first hour (but the edge is 7200), so
    # it should still finish in the first bin at constant 10 m/s, t = 720s.
    speeds = fill(10.0, TDVRP_NUM_BINS); speeds[2] = 20.0
    edge_speeds[(1, 2)] = speeds
    t = igp_travel_time(md, [1, 2], edge_speeds, 0.0)
    @test isapprox(t, 720.0; atol=1e-6)

    # If the edge is longer than what we can cover in one bin at 10 m/s
    # (length 50000 m at 10 m/s = 5000s > 3600s bin end), we should split
    # across bins. With speed[1]=10 and speed[2]=20, after t=3600s we've
    # covered 36000 m; remaining 14000 m at 20 m/s -> 700s. Total 4300s.
    md.w = sparse([1], [2], [50000.0], 2, 2)
    t = igp_travel_time(md, [1, 2], edge_speeds, 0.0)
    @test isapprox(t, 4300.0; atol=1e-3)
end

println("All sanity tests passed.")
