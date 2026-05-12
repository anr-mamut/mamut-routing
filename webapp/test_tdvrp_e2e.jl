# End-to-end TDVRP generation on the bundled Brest map. Run with:
#   julia --project=webapp -t auto webapp/test_tdvrp_e2e.jl

using Test
using JSON3
using Statistics
using Dates

include(joinpath(@__DIR__, "osm_generation.jl"))

const OUT_ROOT = mktempdir(prefix="tdvrp_e2e_")
println("Output root: ", OUT_ROOT)

payload = Dict(
    :city => "Brest",
    :osmPath => joinpath(@__DIR__, "..", "osmdata", "Brest.osm"),
    :method => "poi_categories",
    :nCustomers => 15,
    :demandType => 7,
    :avgRouteSize => 4,
    :seed => 42,
    :commuterCount => 400,
    :residentialDecayMeters => 1500.0,
    :traffic_intensity => 1.0,
    :outputRoot => OUT_ROOT,
)

t0 = time()
result = generate_single_tdvrp_instance(payload)
elapsed = time() - t0
println("Generation OK in $(round(elapsed; digits=1))s")

@testset "TDVRP end-to-end (Brest)" begin
    @test result["ok"] === true
    base = result["base_name"]
    folder = result["folder"]
    tdvrp_json = joinpath(folder, base * ".tdvrp.json")
    meta_json = joinpath(folder, base * "_meta.json")
    manifest_json = joinpath(folder, base * "_manifest.json")
    @test isfile(tdvrp_json)
    @test isfile(meta_json)
    @test isfile(manifest_json)

    inst = JSON3.read(read(tdvrp_json, String))
    @test inst["problem_type"] == "TDVRP"
    @test inst["num_time_bins"] == 24
    @test inst["bin_seconds"] == 3600
    @test length(inst["arc_costs_time_dependent"]) == 24
    n = inst["num_customers"] + 1
    @test length(inst["arc_costs_time_dependent"][1]) == n
    @test length(inst["arc_costs_time_dependent"][1][1]) == n
    @test length(inst["arc_costs"]) == n

    # Spot-check: travel time at morning peak (h=9) should be greater than
    # at off-peak (h=4) on average across customer pairs.
    h_peak = 9
    h_off = 4
    peak_total = 0.0
    off_total = 0.0
    count = 0
    for i in 1:n, j in 1:n
        if i == j
            continue
        end
        peak_total += inst["arc_costs_time_dependent"][h_peak][i][j]
        off_total += inst["arc_costs_time_dependent"][h_off][i][j]
        count += 1
    end
    peak_mean = peak_total / count
    off_mean = off_total / count
    println("Mean travel time off-peak (h=$(h_off-1)): $(round(off_mean, digits=1))s, peak (h=$(h_peak-1)): $(round(peak_mean, digits=1))s")
    @test peak_mean >= off_mean  # could be == when traffic is sparse and the depot doesn't sit on commute routes

    # FIFO check: arrival(h+1, i, j) >= arrival(h, i, j) for all h, i, j.
    bin_seconds = inst["bin_seconds"]
    n_bins = inst["num_time_bins"]
    fifo_ok = true
    for i in 1:n, j in 1:n
        i == j && continue
        prev_arrival = -Inf
        for h in 1:n_bins
            arrival = (h - 1) * bin_seconds + inst["arc_costs_time_dependent"][h][i][j]
            if arrival + 1e-6 < prev_arrival
                fifo_ok = false
                break
            end
            prev_arrival = arrival
        end
        fifo_ok || break
    end
    @test fifo_ok

    manifest = JSON3.read(read(manifest_json, String))
    @test manifest["problem_type"] == "TDVRP"
    @test manifest["tdvrp"]["fifo_correction_ratio"] >= 0
    @test manifest["tdvrp"]["edge_count_with_flow"] > 0
    println("FIFO correction ratio: ", manifest["tdvrp"]["fifo_correction_ratio"])
    println("Edges with flow: ", manifest["tdvrp"]["edge_count_with_flow"])

    meta = JSON3.read(read(meta_json, String))
    @test haskey(meta, "road_cache")
    @test haskey(meta["road_cache"], "edge_speeds")
    @test length(meta["road_cache"]["edge_speeds"]) > 0
end

println("End-to-end TDVRP generation OK.")
println("Files at: ", result["folder"])
