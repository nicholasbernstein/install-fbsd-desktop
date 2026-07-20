#!/usr/bin/env python3
"""
Resolve FreeBSD releases to test in CI.

Primary source: https://www.freebsd.org/security/#sup
  (currently supported *-RELEASE lines, not stable/* placeholders)

Optional filter: releases available in vmactions/freebsd-vm (x86_64),
  scraped from that action's README so we do not schedule VMs that cannot boot.

Outputs are suitable for GitHub Actions matrix generation, e.g.:

  matrix=$(python3 scripts/freebsd-supported-releases.py --github-matrix)
  echo "matrix=$matrix" >> "$GITHUB_OUTPUT"

  strategy:
    matrix: ${{ fromJSON(needs.resolve.outputs.matrix) }}
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Iterable, List, Optional, Sequence, Set

FREEBSD_SECURITY_URL = "https://www.freebsd.org/security/"
VMACTIONS_README_URL = (
    "https://raw.githubusercontent.com/vmactions/freebsd-vm/master/README.md"
)

# Used only if network fetch fails and no --fallback-file is readable
BUILTIN_FALLBACK = ["15.1", "15.0", "14.4"]

SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_FALLBACK = SCRIPT_DIR / "data" / "freebsd-releases-fallback.json"

UA = "install-fbsd-desktop-ci/1.0 (+https://github.com/nicholasbernstein/install-fbsd-desktop)"


def fetch(url: str, timeout: float = 30.0) -> str:
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read().decode("utf-8", errors="replace")


def parse_freebsd_supported_releases(html: str) -> List[str]:
    """
    Extract major.minor from the Supported FreeBSD releases table.

    Prefer rows that mention both releng/X.Y and X.Y-RELEASE so we skip
    stable/* branches (Release column is n/a).
    """
    # Narrow to the supported-releases section when anchors exist
    section = html
    m = re.search(
        r'(?is)id=["\']sup["\'].*?(?=id=["\']model["\']|Unsupported FreeBSD|</html>)',
        html,
    )
    if m:
        section = m.group(0)
    else:
        m = re.search(
            r"(?is)Supported FreeBSD releases.*?(?=The FreeBSD support model|Unsupported)",
            html,
        )
        if m:
            section = m.group(0)

    found: List[str] = []
    seen: Set[str] = set()

    # releng/15.1 ... 15.1-RELEASE style pairs in nearby markup
    for releng, release in re.findall(
        r"releng/(\d+\.\d+).*?(\d+\.\d+)-RELEASE",
        section,
        flags=re.I | re.S,
    ):
        if releng == release and release not in seen:
            seen.add(release)
            found.append(release)

    # Fallback: any X.Y-RELEASE in the section (stable rows use n/a, not RELEASE)
    if not found:
        for release in re.findall(r"(\d+\.\d+)-RELEASE", section, flags=re.I):
            if release not in seen:
                seen.add(release)
                found.append(release)

    return _sort_releases(found)


def parse_vmactions_x86_64_releases(readme: str) -> Set[str]:
    """Parse vmactions README table rows that mark x86_64 as available."""
    supported: Set[str] = set()
    # | 15.1    |  ✅ (rsync,...)    | ...
    for line in readme.splitlines():
        m = re.match(r"^\|\s*(\d+\.\d+)\s*\|([^|]*)\|", line)
        if not m:
            continue
        ver, x86_cell = m.group(1), m.group(2)
        if "✅" in x86_cell or "yes" in x86_cell.lower():
            supported.add(ver)
    return supported


def _sort_releases(versions: Iterable[str]) -> List[str]:
    def key(v: str) -> tuple:
        parts = v.split(".")
        try:
            return tuple(int(p) for p in parts)
        except ValueError:
            return (0, 0)

    return sorted(set(versions), key=key, reverse=True)


def load_fallback(path: Optional[Path]) -> List[str]:
    if path and path.is_file():
        data = json.loads(path.read_text(encoding="utf-8"))
        if isinstance(data, dict) and "releases" in data:
            return _sort_releases(data["releases"])
        if isinstance(data, list):
            return _sort_releases(data)
    return list(BUILTIN_FALLBACK)


def write_fallback(path: Path, releases: Sequence[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "source": FREEBSD_SECURITY_URL,
        "comment": "Offline fallback when live discovery fails. Refresh with: python3 scripts/freebsd-supported-releases.py --write-fallback",
        "releases": list(releases),
    }
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def resolve_releases(
    *,
    pin: Optional[str] = None,
    fallback_file: Optional[Path] = None,
    use_vmactions_filter: bool = True,
    fallback_only: bool = False,
) -> List[str]:
    if pin:
        pin = pin.strip()
        # Accept 14.4-RELEASE or 14.4
        pin = re.sub(r"-RELEASE$", "", pin, flags=re.I)
        if not re.fullmatch(r"\d+\.\d+", pin):
            raise SystemExit(f"invalid --pin release: {pin!r} (expected major.minor)")
        return [pin]

    if fallback_only:
        return load_fallback(fallback_file)

    freebsd: List[str] = []
    try:
        html = fetch(FREEBSD_SECURITY_URL)
        freebsd = parse_freebsd_supported_releases(html)
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        print(f"warning: FreeBSD security fetch failed: {exc}", file=sys.stderr)

    if not freebsd:
        print(
            "warning: using fallback FreeBSD release list",
            file=sys.stderr,
        )
        freebsd = load_fallback(fallback_file)

    if not use_vmactions_filter:
        return freebsd

    vmactions: Optional[Set[str]] = None
    try:
        readme = fetch(VMACTIONS_README_URL)
        vmactions = parse_vmactions_x86_64_releases(readme)
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        print(f"warning: vmactions README fetch failed: {exc}", file=sys.stderr)

    if not vmactions:
        # Without a filter list, still return FreeBSD-supported releases
        return freebsd

    filtered = [r for r in freebsd if r in vmactions]
    skipped = [r for r in freebsd if r not in vmactions]
    if skipped:
        print(
            "info: skipping FreeBSD releases with no vmactions x86_64 image: "
            + ", ".join(skipped),
            file=sys.stderr,
        )
    if not filtered:
        print(
            "warning: intersection empty; falling back to FreeBSD-supported list",
            file=sys.stderr,
        )
        return freebsd
    return filtered


def github_matrix(releases: Sequence[str]) -> str:
    """Compact JSON for strategy.matrix: fromJSON(...)"""
    if not releases:
        raise SystemExit("no FreeBSD releases resolved for matrix")
    return json.dumps({"release": list(releases)}, separators=(",", ":"))


def main(argv: Optional[Sequence[str]] = None) -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument(
        "--github-matrix",
        action="store_true",
        help='print compact JSON object {"release":["X.Y",...]} for GHA matrix',
    )
    p.add_argument(
        "--json",
        action="store_true",
        help="print JSON array of releases",
    )
    p.add_argument(
        "--lines",
        action="store_true",
        help="print one release per line",
    )
    p.add_argument(
        "--pin",
        metavar="X.Y",
        help="use a single release (skip discovery)",
    )
    p.add_argument(
        "--fallback-file",
        type=Path,
        default=Path(os.environ.get("FREEBSD_RELEASES_FALLBACK", str(DEFAULT_FALLBACK))),
        help=f"JSON fallback list (default: {DEFAULT_FALLBACK})",
    )
    p.add_argument(
        "--fallback-only",
        action="store_true",
        help="do not fetch; only use fallback file / builtin",
    )
    p.add_argument(
        "--no-vmactions-filter",
        action="store_true",
        help="do not intersect with vmactions/freebsd-vm supported images",
    )
    p.add_argument(
        "--write-fallback",
        action="store_true",
        help="write resolved list to --fallback-file after discovery",
    )
    args = p.parse_args(argv)

    releases = resolve_releases(
        pin=args.pin,
        fallback_file=args.fallback_file,
        use_vmactions_filter=not args.no_vmactions_filter,
        fallback_only=args.fallback_only,
    )

    if args.write_fallback and not args.pin:
        write_fallback(args.fallback_file, releases)
        print(f"wrote {args.fallback_file}", file=sys.stderr)

    if args.github_matrix:
        print(github_matrix(releases))
    elif args.json:
        print(json.dumps(list(releases)))
    elif args.lines:
        print("\n".join(releases))
    else:
        # default: human-readable
        print(" ".join(releases))

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
