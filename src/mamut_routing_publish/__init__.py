"""Snapshot, site, and release-archive generation toolkit for MAMUT-routing.

This package owns:

- Site payload generation (JSON files consumed by the Julia webapp).
- Static HTML shell generation.
- Release archive (.zip) generation and manifest.
- Site assets (CSS, JS, icons, logos) shipped alongside the static site.

The package depends on `mamut_routing_lib` (the contract/runtime library) for
benchmark discovery, model definitions, and JSON I/O.
"""

from mamut_routing_publish.release_artifacts import (
    ReleaseArtifactGenerationSummary,
    generate_release_artifacts,
)
from mamut_routing_publish.site_payloads import (
    SITE_PAYLOAD_SCHEMA_VERSION,
    BenchmarksIndexPayload,
    CatalogIndexPayload,
    HistoryDetailPayload,
    HomePagePayload,
    InstancePagePayload,
    InstancePageTDVRPPayload,
    ObjectivesPagePayload,
    ProblemIndexPayload,
    SiteHistoryLedger,
    SitePayloadGenerationSummary,
    SitePayloadKind,
    SiteSnapshotManifest,
    TDVRPEdgeSpeedProfile,
    derive_historical_taxonomy,
    generate_site_payloads,
)
from mamut_routing_publish.site_webapp import (
    SiteWebappGenerationSummary,
    generate_site_webapp,
)
from mamut_routing_publish.tdvrp_payloads import build_tdvrp_payload_from_files

__all__ = [
    "BenchmarksIndexPayload",
    "CatalogIndexPayload",
    "HistoryDetailPayload",
    "HomePagePayload",
    "InstancePagePayload",
    "InstancePageTDVRPPayload",
    "ObjectivesPagePayload",
    "ProblemIndexPayload",
    "ReleaseArtifactGenerationSummary",
    "SITE_PAYLOAD_SCHEMA_VERSION",
    "SiteHistoryLedger",
    "SitePayloadGenerationSummary",
    "SitePayloadKind",
    "SiteSnapshotManifest",
    "SiteWebappGenerationSummary",
    "TDVRPEdgeSpeedProfile",
    "build_tdvrp_payload_from_files",
    "derive_historical_taxonomy",
    "generate_release_artifacts",
    "generate_site_payloads",
    "generate_site_webapp",
]
