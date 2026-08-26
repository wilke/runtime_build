#!/usr/bin/env python3
"""Generate all-build.def: one reproducible, two-stage definition file.

Why this exists on top of merge_singularity_defs.py
---------------------------------------------------
The BV-BRC Perl runtime does not come from a tarball or an apt repo; it comes
from the `dxkb/dev_container` image. Pulling it needs a `%files from <stage>`,
which needs a multi-stage def -- and merge_singularity_defs.py emits exactly
one Bootstrap/From. So this script delegates the section merging (the fiddly
part) to that script, and adds only the two-stage composition around it.

The result is a single `apptainer build` from two Docker bases. No localimage,
no sandbox, and nothing extracted from a large SIF -- which is what made the
old path unreproducible: `apptainer build --fakeroot --build-arg base=<32GB
sif>` fails on UID/GID mapping, so rebuilds drifted to hand-editing an 84 GB
sandbox directory that no file in this repo describes.

Usage:
    ./assemble-folding-def.py                      # regenerate all-build.def
    ./assemble-folding-def.py --check              # verify it is up to date
    ./assemble-folding-def.py -o /tmp/try.def
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
MERGER = HERE / "merge_singularity_defs.py"

GENERATED_BANNER = "# GENERATED FILE -- do not edit by hand."

# Base images, pinned by digest. Tags move; digests do not.
# Resolved 2026-08-20 from the tags named in each comment.
#   dxkb/dev_container:cuda12-ubuntu22.04   (BV-BRC Perl runtime source stage)
DEVCONTAINER = ("dxkb/dev_container@sha256:"
                "36176f5e65dffb280263d7a9869db89f623aa485201bc04f71ce29c37c99c8b8")
#   nvidia/cuda:12.2.0-devel-ubuntu22.04    (final stage base)
CUDA_BASE = ("nvidia/cuda@sha256:"
             "c4e81887e4aa9f13b1119337323cba89601319ecb282383b879c4ba50510fd17")

# Application repos, pinned by commit. These become %arguments defaults, so a
# plain `apptainer build` is deterministic; override with --build-arg.
PINS = {
    # PredictStructureApp supplies BOTH the Python package (reqts-predict-
    # structure.def) and the Perl app (reqts-bvbrc-deploy.def). One pin for
    # both: every documented production failure here (#98, #110) was those two
    # drifting apart, which two independent `main` trackers cannot prevent.
    "ps_repo":         "https://github.com/CEPI-dxkb/PredictStructureApp.git",
    "ps_commit":       "ef0914b8ca815db19a95520a481760ec980f946e",
    "pc_repo":         "https://github.com/wilke/protein_structure_analysis.git",
    "pc_commit":       "7105946fdb3c77047d8fcf37286d42004abf3a45",
    "stab_app_repo":   "https://github.com/CEPI-dxkb/stabiliNNatorApp.git",
    "stab_app_commit": "5ed9b232709f65ebf56bed9dcc11b041699a8553",
    # p3x-app-shepherd (reqts-bvbrc-deploy.def). The old sandbox image inherited
    # this already built from the production base SIF; from clean bases it has
    # to be compiled, so the module is pinned like any other source input.
    # This is the commit the production base was built from -- verified by
    # rebuilding it in the new image and getting a byte-identical binary
    # (sha256 791325d6...). Repo HEAD as of 2026-08-20 is the same commit.
    "shepherd_repo":   "https://github.com/BV-BRC/p3_app_shepherd.git",
    "shepherd_commit": "6c78d7aedab24be01dae35b91296121e3881bc78",
}


def read_manifest(path: Path) -> list[Path]:
    """Ordered stage defs from stages.list, ignoring blanks and #-comments."""
    stages: list[Path] = []
    for lineno, raw in enumerate(path.read_text().splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        p = HERE / line
        if not p.exists():
            sys.exit(f"{path.name}:{lineno}: stage file not found: {line}")
        stages.append(p)
    if not stages:
        sys.exit(f"{path.name}: no stages listed")
    return stages


def merge_tool_stages(stages: list[Path]) -> str:
    """Run the existing merger and return the merged def as text."""
    proc = subprocess.run(
        [sys.executable, str(MERGER), *map(str, stages), "-o", "/dev/null",
         "--dry-run"],
        capture_output=True, text=True,
    )
    if proc.returncode != 0:
        sys.exit(f"merge_singularity_defs.py failed:\n{proc.stderr}")
    # Relay stderr even on success: the merger warns there about %arguments it
    # had to drop, and this is the only path that invokes it. Capturing that
    # warning and then discarding it would hide the exact silent failure the
    # warning exists to prevent.
    for line in proc.stderr.splitlines():
        if line.startswith("WARNING"):
            print(line, file=sys.stderr)
    return proc.stdout


def strip_header(merged: str) -> str:
    """Drop the merger's Bootstrap/From/Stage lines; we supply our own."""
    out, seen_section = [], False
    for line in merged.splitlines():
        if not seen_section:
            if re.match(r"^%[a-z]+", line):
                seen_section = True
            elif re.match(r"^(Bootstrap|From|Stage):", line, re.I) or not line.strip():
                continue
        out.append(line)
    return "\n".join(out).strip("\n")


def stabilinnator_pin() -> str:
    """The upstream model-code commit, read from reqts-stabilinnator.def.

    It lives in that def (not in PINS) so the def stays self-contained and
    buildable on its own; reading it back keeps one source of truth while still
    letting the image carry it as a label.
    """
    m = re.search(r"^\s*stabilinnator_commit=([0-9a-f]{7,40})\s*$",
                  (HERE / "reqts-stabilinnator.def").read_text(), re.M)
    return m.group(1) if m else "unknown"


def drop_section(body: str, name: str) -> str:
    """Remove a whole %<name> section from the merged body."""
    return re.sub(rf"^%{name}\b[^\n]*\n(?:(?!^%[a-z]).*\n?)*", "", body, flags=re.M)


# A single authoritative runscript. The merger concatenates every stage's
# %runscript, and the result is a trap: base-build's `exec "$@"` runs first, so
# `apptainer run <sif> cmd` works -- but with NO arguments `exec` with an empty
# list is a no-op, execution falls through, and the container silently runs
# `cd /app/alphafold; exec /app/run_alphafold.sh`. A bare `apptainer run` on a
# multi-tool image should not start AlphaFold.
RUNSCRIPT = """%runscript
    if [ "$#" -eq 0 ]; then
        cat >&2 <<'USAGE'
BV-BRC folding container. Run a command explicitly, e.g.

  predict-structure <tool> --protein in.fasta -o out/
  stabilinnator {proline|disulfide|both} --pdb-path in.pdb --output-path out.pdb
  App-PredictStructure params.json
  App-StabiliNNator   params.json

Tool environments live in /opt/conda-*; see `apptainer inspect <sif>`.
USAGE
        exit 2
    fi
    exec "$@"
"""


def build_def(body: str, devcontainer: str, cuda_base: str, pins: dict) -> str:
    args = "\n".join(f"    {k} = {v}" for k, v in pins.items())

    # Provenance, baked in at generation time so `apptainer inspect` reports
    # exactly what went in. Deliberately no build date or hostname: those would
    # make the generated file differ on every run and defeat --check.
    labels = {
        "BVBRC.base_devcontainer":       devcontainer,
        "BVBRC.base_cuda":               cuda_base,
        "BVBRC.predict_structure_commit": pins["ps_commit"],
        "BVBRC.protein_compare_commit":  pins["pc_commit"],
        "BVBRC.app_predictstructure_commit": pins["ps_commit"],
        "BVBRC.app_stabilinnator_commit": pins["stab_app_commit"],
        "BVBRC.app_shepherd_commit":     pins["shepherd_commit"],
        "BVBRC.stabilinnator_commit":    stabilinnator_pin(),
        "BVBRC.built_from":              "all-build.def (generated)",
    }
    label_lines = "\n".join(f"    {k} {v}" for k, v in labels.items())
    return f"""{GENERATED_BANNER}
# Regenerate with:  ./assemble-folding-def.py
# Contents and order are defined by:  stages.list
#
# Build with ./build-folding-container, or directly:
#
#   APPTAINER_TMPDIR=/disks/tmp apptainer build --fakeroot \\
#       folding_YYMMDD.N.sif all-build.def
#
# --fakeroot requires an /etc/subuid + /etc/subgid range for the build uid.
# Without one, ~30 of the OS packages fail to configure (their postinst chowns
# to a non-root user, and a root-mapped namespace has only uid 0). The failure
# appears far from its cause; build-folding-container checks for the range.
#
# Everything that can drift is pinned: both base images by digest, and every
# application repo by commit in %arguments below. Two builds of this file
# produce the same image. Bump a pin deliberately -- override for a one-off
# with `--build-arg ps_commit=<sha>`.

Bootstrap: docker
From: {devcontainer}
Stage: devcontainer

Bootstrap: docker
From: {cuda_base}
Stage: final

%arguments
{args}

# Provenance. `apptainer inspect <sif> | grep BVBRC` reports what went in
# without needing a separate stamping step.
%labels
{label_lines}

# The BV-BRC Perl runtime + build system, copied from the dev_container image.
# Subdirectories are listed individually: `%files` nests the source under the
# destination when the destination already exists.
%files from devcontainer
    /opt/patric-common/runtime /opt/patric-common/runtime
    /opt/patric-common/deployment /opt/patric-common/deployment
    /build/dev_container /build/dev_container

{body}
"""


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-o", "--output", type=Path, default=HERE / "all-build.def")
    ap.add_argument("--manifest", type=Path, default=HERE / "stages.list")
    ap.add_argument("--devcontainer", default=DEVCONTAINER,
                    help="BV-BRC runtime source image (pin by digest)")
    ap.add_argument("--cuda-base", default=CUDA_BASE,
                    help="final-stage base image (pin by digest)")
    ap.add_argument("--check", action="store_true",
                    help="exit non-zero if the output file is stale")
    args = ap.parse_args()

    stages = read_manifest(args.manifest)
    body = strip_header(merge_tool_stages(stages))
    body = drop_section(body, "runscript").rstrip("\n") + "\n\n" + RUNSCRIPT
    text = build_def(body, args.devcontainer, args.cuda_base, PINS)

    if args.check:
        current = args.output.read_text() if args.output.exists() else ""
        if current != text:
            sys.exit(f"{args.output.name} is stale -- run ./assemble-folding-def.py")
        print(f"{args.output.name} is up to date ({len(stages)} stages)")
        return

    args.output.write_text(text)
    print(f"Wrote {args.output} from {len(stages)} stages:", file=sys.stderr)
    for s in stages:
        print(f"  {s.name}", file=sys.stderr)


if __name__ == "__main__":
    main()
