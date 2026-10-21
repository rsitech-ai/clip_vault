#!/usr/bin/env python3
"""Bundle dependency license texts for the actual build host, without private paths."""
import argparse
import json
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument("output", type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
host = next(line.split(": ", 1)[1] for line in subprocess.check_output(["rustc", "-vV"], text=True).splitlines() if line.startswith("host: "))
metadata = json.loads(subprocess.check_output([
    "cargo", "metadata", "--manifest-path", str(root / "rust/DeviceSync/Cargo.toml"),
    "--format-version", "1", "--locked", "--filter-platform", host,
], text=True))
nodes = {node["id"]: node for node in metadata["resolve"]["nodes"]}
reachable = set()
pending = list(metadata["workspace_members"])
while pending:
    package = pending.pop()
    if package in reachable:
        continue
    reachable.add(package)
    pending.extend(nodes[package]["dependencies"])

sections = ["ClipVault device sharing: third-party software notices", "System GTK/libadwaita libraries on Linux are dynamically linked and supplied by your distribution."]
for package in sorted(metadata["packages"], key=lambda p: (p["name"], p["version"])):
    if package["id"] not in reachable or not package.get("source"):
        continue
    directory = Path(package["manifest_path"]).parent
    files = sorted(path for path in directory.iterdir() if path.is_file() and path.name.lower().startswith(("license", "licence", "copying", "notice", "copyright", "unlicense")))
    if package.get("license_file"):
        explicit = directory / package["license_file"]
        if explicit not in files:
            files.append(explicit)
    if not files:
        raise SystemExit(f"Missing license text for {package['name']} {package['version']}")
    sections.append(f"\n{'=' * 72}\n{package['name']} {package['version']}\nSPDX: {package.get('license', 'see license text')}\nSource: {package.get('repository') or 'https://crates.io/crates/' + package['name']}")
    sections.extend(f"\n--- {path.name} ---\n{path.read_text(errors='replace')}" for path in files)
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text("\n".join(sections) + "\n")
print(f"Bundled license texts for {len(reachable)} resolved packages.")
