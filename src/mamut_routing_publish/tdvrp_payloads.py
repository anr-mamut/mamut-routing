"""Helpers to turn a Julia TDVRP generator output into a site payload.

The Julia generator writes three files per instance under
``instances_v2/osm_tdvrp/{city}/n{N+1}/``:

* ``{base}.tdvrp.json``    -- the BenchmarkInstanceTDVRP-compatible JSON
* ``{base}_meta.json``     -- geometry + ``edge_speeds`` profile
* ``{base}_manifest.json`` -- generation parameters + FIFO correction stats

This module reads those files and builds an ``InstancePageTDVRPPayload`` that
the webapp can consume directly (heatmap + slider + summary), without going
through the full benchmark-catalog discovery flow.
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from mamut_routing_lib.enums import BenchmarkName, ProblemType
from mamut_routing_lib.models import BenchmarkInstanceTDVRP

from mamut_routing_publish.site_payloads import (
    BenchmarkLocator,
    BreadcrumbItem,
    InstancePageSummary,
    InstancePageTDVRPPayload,
    SiteArtifactLinks,
    SitePayloadKind,
    SnapshotRef,
    TDVRPEdgeSpeedProfile,
)


def _load_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text())


def _build_edge_profiles(meta_payload: dict[str, Any]) -> list[TDVRPEdgeSpeedProfile]:
    road_cache = meta_payload.get("road_cache") or {}
    edge_speeds = road_cache.get("edge_speeds") or {}
    edge_geometry = road_cache.get("edge_geometry") or {}
    profiles: list[TDVRPEdgeSpeedProfile] = []
    for edge_id, speeds in edge_speeds.items():
        if not speeds:
            continue
        free_flow = max(speeds)
        polyline: list[tuple[float, float]] = []
        for lon_lat in edge_geometry.get(edge_id) or []:
            if len(lon_lat) >= 2:
                polyline.append((float(lon_lat[0]), float(lon_lat[1])))
        if not polyline:
            continue
        profiles.append(
            TDVRPEdgeSpeedProfile(
                edge_id=edge_id,
                coordinates=polyline,
                free_flow_speed=float(free_flow),
                speeds=[float(s) for s in speeds],
            )
        )
    return profiles


def build_tdvrp_payload_from_files(
    instance_folder: str | Path,
    base_name: str,
    *,
    snapshot: SnapshotRef,
    generated_at: str,
    route_path: str | None = None,
    title: str | None = None,
    workbench_route_path: str = "/workbench/",
) -> InstancePageTDVRPPayload:
    folder = Path(instance_folder)
    tdvrp_path = folder / f"{base_name}.tdvrp.json"
    meta_path = folder / f"{base_name}_meta.json"
    manifest_path = folder / f"{base_name}_manifest.json"

    if not tdvrp_path.is_file():
        raise FileNotFoundError(f"Missing TDVRP instance file: {tdvrp_path}")

    inst_payload = _load_json(tdvrp_path)
    meta_payload = _load_json(meta_path) if meta_path.is_file() else {}
    manifest_payload = _load_json(manifest_path) if manifest_path.is_file() else {}

    inst_payload.setdefault("instance_origin", "OsmCvrpGen")
    inst_payload.setdefault("benchmark_name", BenchmarkName.MAMUT_2026.value)

    instance = BenchmarkInstanceTDVRP(**inst_payload)

    tdvrp_stats = (manifest_payload or {}).get("tdvrp", {})
    fifo_ratio = tdvrp_stats.get("fifo_correction_ratio")
    traffic_intensity = tdvrp_stats.get("traffic_intensity")

    coordinates = [(float(c[0]), float(c[1])) for c in instance.coordinates]
    edge_profiles = _build_edge_profiles(meta_payload)

    summary = InstancePageSummary(
        display_name=instance.instance_name,
        problem_type=ProblemType.TDVRP,
        benchmark_name=BenchmarkName(instance.benchmark_name),
        num_customers=instance.num_customers,
        size_bucket=f"n{instance.num_customers + 1}",
        vehicle_capacity=instance.vehicle_capacity,
        supported_objective_functions=[],
        generated_at=manifest_payload.get("generated_at"),
        source_city=(manifest_payload.get("params") or {}).get("city"),
    )

    locator = BenchmarkLocator(
        problem_type=ProblemType.TDVRP,
        benchmark_name=BenchmarkName(instance.benchmark_name),
        place_slug=(manifest_payload.get("params") or {}).get("city"),
        size_bucket=summary.size_bucket,
        instance_identifier=base_name,
    )

    artifact_links = SiteArtifactLinks(
        vrp_json_path=str(tdvrp_path.name),
        meta_path=meta_path.name if meta_path.is_file() else None,
        manifest_path=manifest_path.name if manifest_path.is_file() else None,
    )

    route = route_path or f"/instances/tdvrp/{base_name}/"
    breadcrumbs = [
        BreadcrumbItem(label="Benchmarks", route_path="/benchmarks/"),
        BreadcrumbItem(label="TDVRP", route_path="/benchmarks/tdvrp/"),
        BreadcrumbItem(label=base_name, route_path=route),
    ]

    return InstancePageTDVRPPayload(
        generated_at=generated_at,
        snapshot=snapshot,
        route_path=route,
        title=title or f"TDVRP — {instance.instance_name}",
        breadcrumbs=breadcrumbs,
        locator=locator,
        summary=summary,
        artifact_links=artifact_links,
        workbench_route_path=workbench_route_path,
        num_time_bins=instance.num_time_bins,
        bin_seconds=instance.bin_seconds,
        coordinates=coordinates,
        edge_speed_profiles=edge_profiles,
        arc_costs_time_dependent=instance.arc_costs_time_dependent,
        fifo_correction_ratio=fifo_ratio,
        traffic_intensity=traffic_intensity,
    )
