#!/usr/bin/env python3
# /// script
# requires-python = ">=3.9"
# dependencies = [
#   "pyyaml>=6.0",
# ]
# ///
"""
Generate docker-compose.override.yml deterministically from the project's manifest files.

Usage:
  uv run scripts/gen-override.py --project-root /path/to/worktree --main-root /path/to/main

  --project-root   Absolute path to the worktree (where manifest files live)
  --main-root      Absolute path to the main checkout (where override file is written)
  --sandbox        Force sandbox mode (proxy env vars + CA bundle). Default: read IS_SANDBOX env var.
  --dry-run        Print the generated YAML to stdout instead of writing the file.

Exit codes:
  0  success
  1  argument or filesystem error
  2  no compose file found at project-root
  3  unsupported / undetected ecosystem
"""

import argparse
import os
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print("Error: pyyaml is required. Run: uv run scripts/gen-override.py ...", file=sys.stderr)
    sys.exit(1)


# ---------------------------------------------------------------------------
# Ecosystem detection
# ---------------------------------------------------------------------------

ECOSYSTEMS = [
    {
        "name": "node",
        "signals": ["package.json"],
        "vendor": "node_modules",
        "prefix": "nm",
        "proxy_vars": ["HTTPS_PROXY", "NODE_EXTRA_CA_CERTS", "YARN_HTTPS_PROXY=${HTTPS_PROXY}"],
        "depth": 5,
        "exclude_dirs": ["node_modules"],
    },
    {
        "name": "python",
        "signals": ["pyproject.toml", "requirements.txt"],
        "vendor": ".venv",
        "prefix": "venv",
        "proxy_vars": ["HTTPS_PROXY", "REQUESTS_CA_BUNDLE"],
        "depth": 3,
        "exclude_dirs": [".venv"],
    },
    {
        "name": "ruby",
        "signals": ["Gemfile"],
        "vendor": "vendor/bundle",
        "prefix": "bundle",
        "proxy_vars": ["HTTPS_PROXY", "SSL_CERT_FILE"],
        "depth": 3,
        "exclude_dirs": ["vendor"],
    },
    {
        "name": "rust",
        "signals": ["Cargo.toml"],
        "vendor": "target",
        "prefix": "target",
        "proxy_vars": ["HTTPS_PROXY", "SSL_CERT_FILE"],
        "depth": 3,
        "exclude_dirs": ["target"],
    },
    {
        "name": "php",
        "signals": ["composer.json"],
        "vendor": "vendor",
        "prefix": "vendor",
        "proxy_vars": ["HTTPS_PROXY", "SSL_CERT_FILE"],
        "depth": 3,
        "exclude_dirs": ["vendor"],
    },
    {
        "name": "go",
        "signals": ["go.mod"],
        "vendor": "vendor",
        "prefix": "vendor",
        "proxy_vars": ["HTTPS_PROXY", "SSL_CERT_FILE"],
        "depth": 3,
        "exclude_dirs": ["vendor"],
    },
]


def slug(path: Path) -> str:
    return re.sub(r'[^a-zA-Z0-9]', '_', path.name).rstrip('_')


def rel_suffix(directory: Path, project_root: Path) -> str:
    rel = directory.relative_to(project_root)
    if str(rel) == '.':
        return 'root'
    return re.sub(r'[/.\-]', '_', str(rel))


def find_manifest_dirs(project_root: Path, eco: dict) -> list:
    found = []
    signals = set(eco["signals"])
    exclude = set(eco["exclude_dirs"])
    max_depth = eco["depth"]

    for root, dirs, files in os.walk(project_root):
        dirs[:] = sorted(d for d in dirs if d not in exclude and not d.startswith('.'))

        current = Path(root)
        depth = len(current.relative_to(project_root).parts)
        if depth > max_depth:
            dirs.clear()
            continue

        if signals & set(files):
            found.append(current)

    return found


def detect_ecosystem(project_root: Path):
    for eco in ECOSYSTEMS:
        if find_manifest_dirs(project_root, eco):
            return eco
    return None


# ---------------------------------------------------------------------------
# Compose file parsing
# ---------------------------------------------------------------------------

COMPOSE_FILENAMES = ["docker-compose.yml", "docker-compose.yaml", "compose.yml"]


def load_compose(project_root: Path):
    for name in COMPOSE_FILENAMES:
        p = project_root / name
        if p.exists():
            with p.open() as f:
                return yaml.safe_load(f), p
    return None, None


def container_src(compose: dict) -> str:
    for svc_def in (compose.get("services") or {}).values():
        for vol in svc_def.get("volumes") or []:
            if isinstance(vol, str):
                parts = vol.split(":")
                if len(parts) >= 2 and parts[0] in (".", "${PROJECT_ROOT}", "${APP_ROOT}"):
                    return parts[1].rstrip("/")
            elif isinstance(vol, dict):
                src = vol.get("source", "")
                if src in (".", "${PROJECT_ROOT}", "${APP_ROOT}"):
                    return vol.get("target", "/app").rstrip("/")
    return "/app"


def service_names(compose: dict) -> list:
    return list((compose.get("services") or {}).keys())


# ---------------------------------------------------------------------------
# Override generation
# ---------------------------------------------------------------------------

def build_override(project_root, main_root, compose, eco, is_sandbox) -> str:
    proj_slug = slug(main_root)
    c_src = container_src(compose)
    services = service_names(compose)
    manifest_dirs = find_manifest_dirs(project_root, eco)

    volumes = []
    for d in sorted(manifest_dirs):
        suffix = rel_suffix(d, project_root)
        vol_name = f"wt_{proj_slug}_{eco['prefix']}_{suffix}"
        rel = d.relative_to(project_root)
        if str(rel) == '.':
            container_path = f"{c_src}/{eco['vendor']}"
        else:
            container_path = f"{c_src}/{rel}/{eco['vendor']}"
        volumes.append((vol_name, container_path))

    out_services = {}
    for svc in services:
        svc_def = {}
        if is_sandbox:
            svc_def["environment"] = eco["proxy_vars"][:]
        vol_list = [f"{name}:{path}" for name, path in volumes]
        if is_sandbox:
            vol_list.append("/etc/ssl/certs/ca-certificates.crt:/etc/ssl/certs/ca-certificates.crt:ro")
        svc_def["volumes"] = vol_list
        out_services[svc] = svc_def

    top_volumes = {name: None for name, _ in volumes}
    doc = {"services": out_services, "volumes": top_volumes}
    return yaml.dump(doc, default_flow_style=False, sort_keys=False)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Generate docker-compose.override.yml from project manifests.",
        epilog="Run with: uv run scripts/gen-override.py --project-root <path> --main-root <path>",
    )
    parser.add_argument("--project-root", required=True, help="Absolute path to the worktree")
    parser.add_argument("--main-root", required=True, help="Absolute path to the main checkout")
    parser.add_argument("--sandbox", action="store_true", default=False,
                        help="Force sandbox mode (proxy env + CA bundle)")
    parser.add_argument("--dry-run", action="store_true",
                        help="Print generated YAML to stdout instead of writing")

    args = parser.parse_args()

    project_root = Path(args.project_root).resolve()
    main_root = Path(args.main_root).resolve()

    if not project_root.is_dir():
        print(f"Error: --project-root does not exist: {project_root}", file=sys.stderr)
        print("Usage: uv run scripts/gen-override.py --project-root <path> --main-root <path>", file=sys.stderr)
        sys.exit(1)

    if not main_root.is_dir():
        print(f"Error: --main-root does not exist: {main_root}", file=sys.stderr)
        sys.exit(1)

    is_sandbox = args.sandbox or (os.environ.get("IS_SANDBOX", "0") == "1")

    compose, _ = load_compose(project_root)
    if compose is None:
        print(f"Error: no compose file found in {project_root}", file=sys.stderr)
        print(f"Expected one of: {', '.join(COMPOSE_FILENAMES)}", file=sys.stderr)
        sys.exit(2)

    eco = detect_ecosystem(project_root)
    if eco is None:
        print(f"Error: no supported ecosystem detected in {project_root}", file=sys.stderr)
        print("Expected one of: package.json, pyproject.toml, requirements.txt, Gemfile, Cargo.toml, go.mod, composer.json", file=sys.stderr)
        sys.exit(3)

    override_yaml = build_override(project_root, main_root, compose, eco, is_sandbox)

    if args.dry_run:
        print(override_yaml)
        return

    out_path = main_root / "docker-compose.override.yml"
    out_path.write_text(override_yaml)
    print(f"Written: {out_path}")
    print(f"  ecosystem: {eco['name']}")
    print(f"  services:  {', '.join(service_names(compose))}")
    print(f"  sandbox:   {is_sandbox}")


if __name__ == "__main__":
    main()
