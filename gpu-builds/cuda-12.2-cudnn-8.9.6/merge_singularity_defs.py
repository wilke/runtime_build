#!/usr/bin/env python3
"""Merge multiple Singularity/Apptainer definition files into a single file.

This script intelligently combines multiple .def files by:
- Using the Bootstrap/From from the first file (or allowing override)
- Concatenating %setup and %post sections in order
- Preserving -c flags on %setup, %post, and %test sections (first flag wins)
- Merging %environment, %labels, %files, %runscript sections
- Preserving %help and %test sections
- Handling duplicate entries in %labels and %environment

Usage:
    merge_singularity_defs.py stage1.def stage2.def stage3.def -o merged.def
    merge_singularity_defs.py *.def -o merged.def --from nvidia/cuda:12.1.0-runtime-ubuntu22.04
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional


@dataclass
class DefSection:
    """Container for a section's content."""
    lines: list[str] = field(default_factory=list)
    flags: str = ""  # e.g., "-c /bin/bash" for %post -c /bin/bash

    def append(self, line: str):
        self.lines.append(line)

    def extend(self, lines: list[str]):
        self.lines.extend(lines)

    def is_empty(self) -> bool:
        return len(self.lines) == 0 or all(not line.strip() for line in self.lines)

    def __str__(self) -> str:
        return "\n".join(self.lines)


@dataclass
class DefFile:
    """Parsed Singularity definition file."""
    source_path: Optional[Path] = None
    bootstrap: str = ""
    from_image: str = ""
    stage: str = ""
    header_lines: list[str] = field(default_factory=list)  # Other header directives

    # Sections
    setup: DefSection = field(default_factory=DefSection)
    post: DefSection = field(default_factory=DefSection)
    environment: DefSection = field(default_factory=DefSection)
    labels: DefSection = field(default_factory=DefSection)
    files: DefSection = field(default_factory=DefSection)
    runscript: DefSection = field(default_factory=DefSection)
    startscript: DefSection = field(default_factory=DefSection)
    test: DefSection = field(default_factory=DefSection)
    help: DefSection = field(default_factory=DefSection)
    app_sections: dict = field(default_factory=dict)  # %apprun, %appenv, etc.


class DefParser:
    """Parse Singularity definition files."""

    # Match %section followed by optional flags/arguments
    SECTION_PATTERN = re.compile(r"^%(\w+)(.*)$")
    HEADER_PATTERN = re.compile(r"^(Bootstrap|From|Stage|Include|MirrorURL|OSVersion|Fingerprints):\s*(.*)$", re.IGNORECASE)

    # Sections that can have -c flag for shell specification
    SHELL_SECTIONS = {"post", "setup", "test"}

    KNOWN_SECTIONS = {
        "post", "environment", "labels", "files", "runscript",
        "startscript", "test", "help", "setup", "arguments"
    }

    APP_SECTIONS = {
        "apprun", "appenv", "appinstall", "applabels", "appfiles", "apphelp", "apptest"
    }

    def parse(self, path: Path) -> DefFile:
        """Parse a definition file."""
        deffile = DefFile(source_path=path)
        content = path.read_text()
        lines = content.split("\n")

        current_section: Optional[str] = None
        current_app: Optional[str] = None
        in_header = True

        for line in lines:
            stripped = line.strip()

            # Check for section header
            section_match = self.SECTION_PATTERN.match(stripped)
            if section_match:
                section_name = section_match.group(1).lower()
                section_arg = (section_match.group(2) or "").strip()

                in_header = False

                if section_name in self.APP_SECTIONS:
                    current_section = section_name
                    current_app = section_arg
                    if current_app:
                        key = f"{section_name}_{current_app}"
                        if key not in deffile.app_sections:
                            deffile.app_sections[key] = DefSection()
                elif section_name in self.KNOWN_SECTIONS:
                    current_section = section_name
                    current_app = None
                    # Capture flags (e.g., -c /bin/bash) for shell sections
                    if section_name in self.SHELL_SECTIONS and section_arg:
                        section_obj = getattr(deffile, section_name, None)
                        if section_obj is not None:
                            section_obj.flags = section_arg
                else:
                    # Unknown section, treat as post-like
                    current_section = section_name
                    current_app = None
                continue

            # Check for header directives (Bootstrap, From, etc.)
            if in_header:
                header_match = self.HEADER_PATTERN.match(stripped)
                if header_match:
                    directive = header_match.group(1).lower()
                    value = header_match.group(2).strip()

                    if directive == "bootstrap":
                        deffile.bootstrap = value
                    elif directive == "from":
                        deffile.from_image = value
                    elif directive == "stage":
                        deffile.stage = value
                    else:
                        deffile.header_lines.append(line)
                    continue
                elif stripped and not stripped.startswith("#"):
                    # Non-empty, non-comment line without directive - might be malformed
                    in_header = False

            # Add line to current section
            if current_section:
                if current_app and current_section in self.APP_SECTIONS:
                    key = f"{current_section}_{current_app}"
                    deffile.app_sections[key].append(line)
                else:
                    section = getattr(deffile, current_section, None)
                    if section is not None:
                        section.append(line)

        return deffile


class DefMerger:
    """Merge multiple definition files."""

    def __init__(
        self,
        bootstrap_override: Optional[str] = None,
        from_override: Optional[str] = None,
        add_stage_comments: bool = True,
    ):
        self.bootstrap_override = bootstrap_override
        self.from_override = from_override
        self.add_stage_comments = add_stage_comments

    def merge(self, deffiles: list[DefFile]) -> DefFile:
        """Merge multiple DefFiles into one."""
        if not deffiles:
            raise ValueError("No definition files to merge")

        merged = DefFile()

        # Use first file's bootstrap/from or overrides
        merged.bootstrap = self.bootstrap_override or deffiles[0].bootstrap or "docker"
        merged.from_image = self.from_override or deffiles[0].from_image

        # Collect unique header lines
        seen_headers = set()
        for df in deffiles:
            for line in df.header_lines:
                normalized = line.strip().lower()
                if normalized not in seen_headers:
                    seen_headers.add(normalized)
                    merged.header_lines.append(line)

        # Merge %setup sections (concatenate with stage markers, runs on host before container)
        setup_flags = None
        for df in deffiles:
            if not df.setup.is_empty():
                if self.add_stage_comments and df.source_path:
                    merged.setup.append(f"\n# === Setup from: {df.source_path.name} ===")
                merged.setup.extend(df.setup.lines)
                # Use first non-empty flags, warn if conflicting
                if df.setup.flags:
                    if setup_flags is None:
                        setup_flags = df.setup.flags
                    elif setup_flags != df.setup.flags:
                        merged.setup.append(f"# WARNING: Conflicting flags ignored: {df.setup.flags}")
        if setup_flags:
            merged.setup.flags = setup_flags

        # Merge %post sections (concatenate with stage markers)
        post_flags = None
        for df in deffiles:
            if not df.post.is_empty():
                if self.add_stage_comments and df.source_path:
                    merged.post.append(f"\n# === Stage from: {df.source_path.name} ===")
                merged.post.extend(df.post.lines)
                # Use first non-empty flags, warn if conflicting
                if df.post.flags:
                    if post_flags is None:
                        post_flags = df.post.flags
                    elif post_flags != df.post.flags:
                        merged.post.append(f"# WARNING: Conflicting flags ignored: {df.post.flags}")
        if post_flags:
            merged.post.flags = post_flags

        # Merge %environment by CONCATENATING each file's block verbatim.
        #
        # This used to hoist every `export VAR=` into a dict (last wins) and
        # emit the leftovers first. That was wrong twice over:
        #
        #  1. It reordered exports out of the compound statements containing
        #     them, leaving `if [[ -d /local_databases/chai ]] ; then` directly
        #     followed by `fi`. That is a bash syntax error, and Apptainer
        #     parses 90-environment.sh as a whole -- so the ENTIRE environment
        #     block is discarded at runtime, including the exports that came
        #     before the error. Images built this way come up with no PATH,
        #     KB_TOP, PERL5LIB or LD_LIBRARY_PATH and fail at job start.
        #
        #  2. Last-wins is wrong for accumulating variables. Three stages here
        #     export `PATH=<something>:$PATH`; keeping only the last one
        #     silently drops /opt/conda-predict/bin and /opt/miniforge/bin.
        #
        # Concatenating verbatim preserves both the conditionals and the
        # accumulation order, and duplicate plain assignments are harmless --
        # the shell already gives last-wins semantics at evaluation time, which
        # is exactly what the dedup was trying to emulate.
        for df in deffiles:
            if df.environment.is_empty():
                continue
            if self.add_stage_comments and df.source_path:
                merged.environment.append(f"\n# --- From: {df.source_path.name} ---")
            merged.environment.extend(df.environment.lines)

        # Merge %labels (deduplicate, last wins)
        labels = {}  # label_name -> value
        for df in deffiles:
            for line in df.labels.lines:
                stripped = line.strip()
                if stripped and not stripped.startswith("#"):
                    parts = stripped.split(None, 1)
                    if len(parts) >= 1:
                        key = parts[0]
                        value = parts[1] if len(parts) > 1 else ""
                        labels[key] = value

        for key, value in labels.items():
            merged.labels.append(f"    {key} {value}")

        # Merge %files (concatenate, deduplicate exact lines)
        seen_files = set()
        for df in deffiles:
            for line in df.files.lines:
                stripped = line.strip()
                if stripped and stripped not in seen_files:
                    seen_files.add(stripped)
                    merged.files.append(line)

        # Merge %runscript (use last non-empty one, or concatenate with warning)
        runscripts = [df for df in deffiles if not df.runscript.is_empty()]
        if runscripts:
            if len(runscripts) > 1:
                merged.runscript.append("# WARNING: Multiple runscripts merged")
                for df in runscripts:
                    merged.runscript.append(f"# --- From: {df.source_path.name if df.source_path else 'unknown'} ---")
                    merged.runscript.extend(df.runscript.lines)
            else:
                merged.runscript = runscripts[0].runscript

        # Merge %startscript (same as runscript)
        startscripts = [df for df in deffiles if not df.startscript.is_empty()]
        if startscripts:
            if len(startscripts) > 1:
                merged.startscript.append("# WARNING: Multiple startscripts merged")
                for df in startscripts:
                    merged.startscript.extend(df.startscript.lines)
            else:
                merged.startscript = startscripts[0].startscript

        # Merge %test (concatenate, preserve flags)
        test_flags = None
        for df in deffiles:
            if not df.test.is_empty():
                if self.add_stage_comments and df.source_path:
                    merged.test.append(f"\n# --- Tests from: {df.source_path.name} ---")
                merged.test.extend(df.test.lines)
                # Use first non-empty flags, warn if conflicting
                if df.test.flags:
                    if test_flags is None:
                        test_flags = df.test.flags
                    elif test_flags != df.test.flags:
                        merged.test.append(f"# WARNING: Conflicting flags ignored: {df.test.flags}")
        if test_flags:
            merged.test.flags = test_flags

        # Merge %help (concatenate)
        for df in deffiles:
            if not df.help.is_empty():
                if self.add_stage_comments and df.source_path:
                    merged.help.append(f"\n=== From: {df.source_path.name} ===")
                merged.help.extend(df.help.lines)

        # Merge app sections
        for df in deffiles:
            for key, section in df.app_sections.items():
                if key not in merged.app_sections:
                    merged.app_sections[key] = DefSection()
                merged.app_sections[key].extend(section.lines)

        return merged


class DefWriter:
    """Write a DefFile to output."""

    def write(self, deffile: DefFile, output: Path):
        """Write definition file to path."""
        content = self.to_string(deffile)
        output.write_text(content)

    def to_string(self, deffile: DefFile) -> str:
        """Convert DefFile to string."""
        lines = []

        # Header
        if deffile.bootstrap:
            lines.append(f"Bootstrap: {deffile.bootstrap}")
        if deffile.from_image:
            lines.append(f"From: {deffile.from_image}")
        if deffile.stage:
            lines.append(f"Stage: {deffile.stage}")
        for header_line in deffile.header_lines:
            lines.append(header_line)

        # Sections in conventional order
        sections = [
            ("labels", deffile.labels),
            ("files", deffile.files),
            ("environment", deffile.environment),
            ("setup", deffile.setup),
            ("post", deffile.post),
            ("runscript", deffile.runscript),
            ("startscript", deffile.startscript),
            ("test", deffile.test),
            ("help", deffile.help),
        ]

        for name, section in sections:
            if not section.is_empty():
                if section.flags:
                    lines.append(f"\n%{name} {section.flags}")
                else:
                    lines.append(f"\n%{name}")
                lines.append(str(section))

        # App sections
        for key, section in sorted(deffile.app_sections.items()):
            if not section.is_empty():
                # Parse key back to section_name and app_name
                parts = key.split("_", 1)
                section_name = parts[0]
                app_name = parts[1] if len(parts) > 1 else ""
                lines.append(f"\n%{section_name} {app_name}")
                lines.append(str(section))

        return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(
        description="Merge multiple Singularity/Apptainer definition files",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s stage1.def stage2.def -o merged.def
  %(prog)s *.def -o merged.def --from nvidia/cuda:12.1.0-runtime-ubuntu22.04
  %(prog)s base.def app.def runtime.def -o final.def --no-comments

The files are processed in order: Bootstrap/From from the first file is used
unless overridden. %%post sections are concatenated in order. %%environment
and %%labels are deduplicated (last value wins for duplicates).
"""
    )

    parser.add_argument(
        "deffiles",
        nargs="+",
        type=Path,
        help="Definition files to merge (processed in order)"
    )
    parser.add_argument(
        "-o", "--output",
        type=Path,
        required=True,
        help="Output merged definition file"
    )
    parser.add_argument(
        "--bootstrap",
        type=str,
        help="Override Bootstrap directive (e.g., docker, library)"
    )
    parser.add_argument(
        "--from",
        dest="from_image",
        type=str,
        help="Override From directive (e.g., ubuntu:22.04)"
    )
    parser.add_argument(
        "--no-comments",
        action="store_true",
        help="Don't add stage marker comments in merged file"
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print merged output to stdout instead of writing file"
    )

    args = parser.parse_args()

    # Validate input files
    for deffile in args.deffiles:
        if not deffile.exists():
            print(f"Error: File not found: {deffile}", file=sys.stderr)
            sys.exit(1)

    # Parse all files
    parser_obj = DefParser()
    deffiles = []
    for path in args.deffiles:
        try:
            deffiles.append(parser_obj.parse(path))
            print(f"Parsed: {path}", file=sys.stderr)
        except Exception as e:
            print(f"Error parsing {path}: {e}", file=sys.stderr)
            sys.exit(1)

        # %arguments is recognised by the parser but DefFile has nowhere to put
        # it, so its contents are dropped. Silently losing build-arg defaults
        # turns every {{placeholder}} in that file into an unresolvable literal
        # at build time, a long way from the cause -- so say so.
        if re.search(r"^\s*%arguments\b", path.read_text(), re.M):
            print(f"WARNING: {path.name} has an %arguments section; it will NOT "
                  f"be merged. Supply those defaults in the output def instead.",
                  file=sys.stderr)

    # Merge
    merger = DefMerger(
        bootstrap_override=args.bootstrap,
        from_override=args.from_image,
        add_stage_comments=not args.no_comments,
    )
    merged = merger.merge(deffiles)

    # Output
    writer = DefWriter()
    if args.dry_run:
        print(writer.to_string(merged))
    else:
        writer.write(merged, args.output)
        print(f"\nMerged {len(deffiles)} files -> {args.output}", file=sys.stderr)


if __name__ == "__main__":
    main()
