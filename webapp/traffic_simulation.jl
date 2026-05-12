# Traffic simulation for TDVRP instance generation.
# Produces per-edge per-hour speed profiles from a synthetic commuter population,
# then derives a 24xNxN time-dependent arc-cost tensor with FIFO enforcement.

using Random
using Graphs
using OpenStreetMapX
using OSMToolset
using SparseArrays

# A synthetic commuter is a (home, work) pair of road-graph vertex ids.
struct Commuter
    home::Int
    work::Int
end

const DEFAULT_SCHEDULE = Dict{String,Float64}(
    "morning_mu" => 8.0,
    "morning_sigma" => 0.75,
    "lunch_out_mu" => 12.0,
    "lunch_out_sigma" => 0.5,
    "lunch_back_mu" => 13.5,
    "lunch_back_sigma" => 0.5,
    "evening_mu" => 17.0,
    "evening_sigma" => 1.0,
    "lunch_share" => 0.25,
)

# OpenStreetMapX road-class integer codes (motorway=1, trunk=2, primary=3,
# secondary=4, tertiary=5, residential/service=6). Veh/h, single direction,
# typical urban-arterial values from the BPR literature.
const DEFAULT_CAPACITY_BY_CLASS = Dict{Int,Int}(
    1 => 2000,
    2 => 1800,
    3 => 1500,
    4 => 1200,
    5 => 800,
    6 => 500,
)

const TDVRP_NUM_BINS = 24
const TDVRP_BIN_SECONDS = 3600
const UNREACHABLE_TRAVEL_TIME = 1.0e9

# Sample residential home vertices via the existing clustered parametric sampler
# with a broad decay (~2 km), which approximates city-wide residential density.
# v2 may replace this with an OSM landuse=residential polygon query.
function select_residential_nodes(md::MapData,
                                  vertex_ll::Vector{Tuple{Float64,Float64}},
                                  n_homes::Int,
                                  decay_m::Float64,
                                  n_seeds::Int,
                                  rng::MersenneTwister)
    candidates = collect(1:length(md.n))
    isempty(candidates) && error("Empty road graph; cannot sample residential homes")
    n_actual = min(n_homes, length(candidates))
    homes = sample_clustered_vertices(candidates, vertex_ll, n_actual, n_seeds, decay_m, rng)
    if length(unique(homes)) < n_actual
        rem = setdiff(candidates, Set(homes))
        shuffle!(rng, rem)
        append!(homes, rem[1:(n_actual - length(unique(homes)))])
    end
    return unique(homes)[1:n_actual]
end

# Build a commuter population: each commuter has a home (residential sample)
# and a work (uniform pick over the provided work_vertices set).
function sample_commuter_population(md::MapData,
                                    vertex_ll::Vector{Tuple{Float64,Float64}},
                                    n_commuters::Int,
                                    work_vertices::Vector{Int},
                                    residential_decay_m::Float64,
                                    n_seeds::Int,
                                    rng::MersenneTwister)
    isempty(work_vertices) && error("No work vertices supplied to commuter sampler")
    home_v = select_residential_nodes(md, vertex_ll, n_commuters, residential_decay_m, n_seeds, rng)
    n_actual = length(home_v)
    work_v = rand(rng, work_vertices, n_actual)
    out = Vector{Commuter}(undef, n_actual)
    for i in 1:n_actual
        out[i] = Commuter(home_v[i], work_v[i])
    end
    return out
end

# Sample an hour-of-day bin from N(mu, sigma), clipped to [0, 23].
function sample_hour_bin(mu::Real, sigma::Real, rng::AbstractRNG)
    t = mu + sigma * randn(rng)
    return clamp(floor(Int, t), 0, TDVRP_NUM_BINS - 1)
end

# Accumulate per-edge per-hour flow over the commuter population using
# free-flow shortest-time paths. Returns Dict (u,v) -> Vector{Int} of length 24.
function simulate_hourly_flows(md::MapData,
                               commuters::Vector{Commuter},
                               schedule::Dict{String,Float64},
                               w_time::AbstractMatrix,
                               rng::MersenneTwister)
    flows = Dict{Tuple{Int,Int},Vector{Int}}()
    state_cache = Dict{Int,Any}()

    function dij(src::Int)
        haskey(state_cache, src) && return state_cache[src]
        s = dijkstra_shortest_paths(md.g, src, w_time)
        state_cache[src] = s
        return s
    end

    function add_trip!(src::Int, dst::Int, h::Int)
        src == dst && return
        state = dij(src)
        path = enumerate_paths(state, dst)
        (isempty(path) || length(path) < 2) && return
        @inbounds for k in 1:length(path)-1
            edge = (path[k], path[k+1])
            v = get!(flows, edge) do
                zeros(Int, TDVRP_NUM_BINS)
            end
            v[h + 1] += 1
        end
    end

    morning_mu = schedule["morning_mu"]; morning_sigma = schedule["morning_sigma"]
    lunch_out_mu = schedule["lunch_out_mu"]; lunch_out_sigma = schedule["lunch_out_sigma"]
    lunch_back_mu = schedule["lunch_back_mu"]; lunch_back_sigma = schedule["lunch_back_sigma"]
    evening_mu = schedule["evening_mu"]; evening_sigma = schedule["evening_sigma"]
    lunch_share = clamp(schedule["lunch_share"], 0.0, 1.0)

    for c in commuters
        h_morn = sample_hour_bin(morning_mu, morning_sigma, rng)
        add_trip!(c.home, c.work, h_morn)
        if rand(rng) < lunch_share
            h_lout = sample_hour_bin(lunch_out_mu, lunch_out_sigma, rng)
            h_lback = sample_hour_bin(lunch_back_mu, lunch_back_sigma, rng)
            add_trip!(c.work, c.home, h_lout)
            add_trip!(c.home, c.work, h_lback)
        end
        h_eve = sample_hour_bin(evening_mu, evening_sigma, rng)
        add_trip!(c.work, c.home, h_eve)
    end
    return flows
end

# BPR volume-delay function: t(h) = t_free * (1 + alpha * (f/c)^beta).
# Returns Dict (u,v) -> Vector{Float64} of speeds in m/s, length 24.
# Edges without flow get the free-flow speed for every hour.
function bpr_speeds(md::MapData,
                    flows::Dict{Tuple{Int,Int},Vector{Int}};
                    alpha::Float64=0.15,
                    beta::Float64=4.0,
                    capacity_by_class::Dict{Int,Int}=DEFAULT_CAPACITY_BY_CLASS,
                    speeds_kmh=SPEED_ROADS_URBAN)
    edge_speeds = Dict{Tuple{Int,Int},Vector{Float64}}()
    @inbounds for i in eachindex(md.e)
        osm_u, osm_v = md.e[i]
        u, v = md.v[osm_u], md.v[osm_v]
        dist_m = md.w[u, v]
        dist_m <= 0 && continue
        cls = md.class[i]
        spd_free_kmh = get(speeds_kmh, cls, 30)
        spd_free_mps = spd_free_kmh / 3.6
        cap = get(capacity_by_class, cls, 500)
        flow_vec = get(flows, (u, v), nothing)
        speeds = Vector{Float64}(undef, TDVRP_NUM_BINS)
        if flow_vec === nothing
            fill!(speeds, spd_free_mps)
        else
            for h in 1:TDVRP_NUM_BINS
                ratio = flow_vec[h] / cap
                tfactor = 1.0 + alpha * ratio^beta
                speeds[h] = spd_free_mps / tfactor
            end
        end
        edge_speeds[(u, v)] = speeds
    end
    return edge_speeds
end

# Walk a single shortest path under stepwise per-hour edge speeds. Returns the
# travel time in seconds for departure at t0 (Ichoua-Gendreau-Potvin integration).
# `md` only needs to expose `md.w` (an edge-length matrix indexable by [u, v]).
function igp_travel_time(md,
                         path::Vector{Int},
                         edge_speeds::Dict{Tuple{Int,Int},Vector{Float64}},
                         t0::Float64;
                         bin_seconds::Real=TDVRP_BIN_SECONDS,
                         n_bins::Int=TDVRP_NUM_BINS)
    (isempty(path) || length(path) < 2) && return 0.0
    t = t0
    @inbounds for k in 1:length(path)-1
        u, v = path[k], path[k+1]
        speeds = get(edge_speeds, (u, v), nothing)
        speeds === nothing && return UNREACHABLE_TRAVEL_TIME
        dist_remain = md.w[u, v]
        while dist_remain > 1.0e-9
            h_idx = floor(Int, t / bin_seconds)
            h_idx = h_idx >= n_bins ? n_bins - 1 : (h_idx < 0 ? 0 : h_idx)
            v_now = speeds[h_idx + 1]
            v_now <= 0 && return UNREACHABLE_TRAVEL_TIME
            bin_end = (h_idx + 1) * bin_seconds
            dt_to_bin_end = bin_end - t
            dt_to_finish = dist_remain / v_now
            if dt_to_finish <= dt_to_bin_end
                t += dt_to_finish
                dist_remain = 0.0
            else
                dist_remain -= v_now * dt_to_bin_end
                t = bin_end
            end
        end
    end
    return t - t0
end

# Build the 24xNxN time-dependent arc-cost tensor (axis: hour, from, to).
# Customer-to-customer travel time computed via IGP integration along the
# free-flow shortest path (path frozen across hours; standard simplification).
function time_dependent_arc_costs(md::MapData,
                                  customer_vertices::Vector{Int},
                                  edge_speeds::Dict{Tuple{Int,Int},Vector{Float64}},
                                  w_time::AbstractMatrix;
                                  bin_seconds::Real=TDVRP_BIN_SECONDS,
                                  n_bins::Int=TDVRP_NUM_BINS)
    n = length(customer_vertices)
    T = zeros(Float64, n_bins, n, n)

    # Each thread owns its own Dijkstra computation per source vertex i to
    # avoid sharing the Dict result cache across threads (which would race).
    Threads.@threads for i in 1:n
        src = customer_vertices[i]
        state = dijkstra_shortest_paths(md.g, src, w_time)
        for j in 1:n
            i == j && continue
            p = enumerate_paths(state, customer_vertices[j])
            if isempty(p) || length(p) < 2
                @inbounds for h in 1:n_bins
                    T[h, i, j] = UNREACHABLE_TRAVEL_TIME
                end
                continue
            end
            @inbounds for h in 1:n_bins
                t0 = (h - 1) * float(bin_seconds)
                T[h, i, j] = igp_travel_time(md, p, edge_speeds, t0;
                                             bin_seconds=bin_seconds, n_bins=n_bins)
            end
        end
    end
    return T
end

# Enforce FIFO (non-passing) by isotonic-up monotonization of the arrival
# function: for each (i,j), arrival[h] = depart[h] + T[h,i,j] is made
# non-decreasing in h via the running-max operator. Returns total correction
# mass (seconds) added across all entries.
function enforce_fifo!(T::Array{Float64,3}; bin_seconds::Real=TDVRP_BIN_SECONDS)
    n_bins = size(T, 1)
    n = size(T, 2)
    total_correction = 0.0
    @inbounds for i in 1:n, j in 1:n
        i == j && continue
        running_max = -Inf
        for h in 1:n_bins
            t_depart = (h - 1) * float(bin_seconds)
            arrival = t_depart + T[h, i, j]
            if arrival < running_max
                total_correction += running_max - arrival
                arrival = running_max
                T[h, i, j] = arrival - t_depart
            end
            if arrival > running_max
                running_max = arrival
            end
        end
    end
    return total_correction
end

# Serialize edge speeds to a JSON-friendly dict keyed by "u_v" strings.
function edge_speeds_to_dict(edge_speeds::Dict{Tuple{Int,Int},Vector{Float64}})
    out = Dict{String,Vector{Float64}}()
    for ((u, v), s) in edge_speeds
        out["$(u)_$(v)"] = s
    end
    return out
end

# Produce straight-segment polylines (lon/lat endpoints) for every directed
# edge in md.e. Used by the webapp heatmap to color road segments by speed
# without a server roundtrip. Keys match those of edge_speeds_to_dict.
function edge_geometry_to_dict(md::MapData)
    out = Dict{String,Vector{Vector{Float64}}}()
    @inbounds for i in eachindex(md.e)
        osm_u, osm_v = md.e[i]
        u = md.v[osm_u]; v = md.v[osm_v]
        lla_u = LLA(md.nodes[osm_u], md.bounds)
        lla_v = LLA(md.nodes[osm_v], md.bounds)
        out["$(u)_$(v)"] = [[lla_u.lon, lla_u.lat], [lla_v.lon, lla_v.lat]]
    end
    return out
end
