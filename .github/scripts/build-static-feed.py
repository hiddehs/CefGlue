#!/usr/bin/env python3
"""
Generate / refresh a NuGet v3 static feed (flat container) under a target
directory. Idempotent: re-running with the same inputs is a no-op; running
with new nupkgs adds them and updates the per-package version index.

Usage: build-static-feed.py <incoming-dir> <feed-root> <base-url>

  incoming-dir : directory containing newly built .nupkg files
  feed-root    : root of the static feed (e.g. checked-out gh-pages branch)
  base-url     : public URL that serves <feed-root>, e.g. https://hiddehs.github.io/CefGlue

The script writes:
  <feed-root>/index.json                       NuGet v3 service index
  <feed-root>/v3-flatcontainer/<id>/index.json versions list per package
  <feed-root>/v3-flatcontainer/<id>/<ver>/<id>.<ver>.nupkg
  <feed-root>/v3-flatcontainer/<id>/<ver>/<id>.nuspec
"""
import json
import os
import re
import shutil
import sys
import zipfile
from pathlib import Path


def lower(s: str) -> str:
    return s.lower()


def extract_id_version(nupkg: Path) -> tuple[str, str]:
    """Read .nuspec inside the nupkg to get authoritative id + version."""
    with zipfile.ZipFile(nupkg) as z:
        nuspec_names = [n for n in z.namelist() if n.endswith(".nuspec") and "/" not in n]
        if not nuspec_names:
            raise RuntimeError(f"No .nuspec at root of {nupkg}")
        content = z.read(nuspec_names[0]).decode("utf-8")
    m_id = re.search(r"<id>([^<]+)</id>", content)
    m_ver = re.search(r"<version>([^<]+)</version>", content)
    if not (m_id and m_ver):
        raise RuntimeError(f"Could not parse id/version from {nuspec_names[0]}")
    return m_id.group(1).strip(), m_ver.group(1).strip()


def install_package(nupkg: Path, feed_root: Path) -> tuple[str, str]:
    pkg_id, version = extract_id_version(nupkg)
    lid, lver = lower(pkg_id), lower(version)
    target_dir = feed_root / "v3-flatcontainer" / lid / lver
    target_dir.mkdir(parents=True, exist_ok=True)

    # Copy the nupkg under its lowercase name.
    nupkg_target = target_dir / f"{lid}.{lver}.nupkg"
    shutil.copyfile(nupkg, nupkg_target)

    # Extract the .nuspec next to it (NuGet v3 expects <id>.nuspec at the version path).
    with zipfile.ZipFile(nupkg) as z:
        nuspec_names = [n for n in z.namelist() if n.endswith(".nuspec") and "/" not in n]
        with z.open(nuspec_names[0]) as src, open(target_dir / f"{lid}.nuspec", "wb") as dst:
            shutil.copyfileobj(src, dst)
    return lid, lver


def regenerate_version_index(feed_root: Path, lid: str) -> None:
    """Write <id>/index.json listing all versions present on disk."""
    pkg_dir = feed_root / "v3-flatcontainer" / lid
    versions = sorted(
        [d.name for d in pkg_dir.iterdir() if d.is_dir() and (d / f"{lid}.{d.name}.nupkg").exists()],
        key=lambda v: [int(x) if x.isdigit() else x for x in re.split(r"[.\-+]", v)],
    )
    (pkg_dir / "index.json").write_text(json.dumps({"versions": versions}, indent=2))


def write_service_index(feed_root: Path, base_url: str) -> None:
    base = base_url.rstrip("/")
    doc = {
        "version": "3.0.0",
        "resources": [
            {
                "@id": f"{base}/v3-flatcontainer/",
                "@type": "PackageBaseAddress/3.0.0",
                "comment": "Base URL of NuGet flat-container resource.",
            },
        ],
    }
    (feed_root / "index.json").write_text(json.dumps(doc, indent=2))


def main(argv: list[str]) -> int:
    if len(argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2
    incoming = Path(argv[1])
    feed_root = Path(argv[2])
    base_url = argv[3]

    feed_root.mkdir(parents=True, exist_ok=True)
    (feed_root / "v3-flatcontainer").mkdir(parents=True, exist_ok=True)

    touched_ids: set[str] = set()
    for nupkg in sorted(incoming.glob("*.nupkg")):
        lid, lver = install_package(nupkg, feed_root)
        print(f"  installed {lid} {lver}")
        touched_ids.add(lid)

    for lid in touched_ids:
        regenerate_version_index(feed_root, lid)

    # Always rewrite the service index so base_url stays in sync.
    write_service_index(feed_root, base_url)
    # A static .nojekyll prevents GitHub Pages from filtering directories starting with _.
    (feed_root / ".nojekyll").touch()
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
