#!/usr/bin/env python3
import argparse
from pathlib import Path


def cask_line(token: str) -> str:
    return f'cask "{token}" do\n'


def update_cask(
    text: str,
    token: str,
    app_name: str,
    version: str,
    repository: str,
    arm_sha256: str,
    intel_sha256: str,
) -> str:
    lines = text.splitlines(keepends=True)
    output: list[str] = []
    inserted_arch = False
    saw_version = False
    saw_sha256 = False
    saw_url = False
    i = 0

    while i < len(lines):
        line = lines[i]

        if line.startswith("cask ") and line.rstrip().endswith(" do"):
            output.append(line)
            output.append('  arch arm: "arm64", intel: "x86_64"\n')
            output.append("\n")
            inserted_arch = True
            i += 1
            while i < len(lines) and (lines[i].startswith("  arch ") or lines[i].strip() == ""):
                i += 1
            continue

        if line.startswith("  version "):
            output.append(f'  version "{version}"\n')
            saw_version = True
            i += 1
            continue

        if line.startswith("  sha256 "):
            output.append(f'  sha256 arm:   "{arm_sha256}",\n')
            output.append(f'         intel: "{intel_sha256}"\n')
            saw_sha256 = True
            i += 1
            while i < len(lines) and (
                lines[i].lstrip().startswith("arm:")
                or lines[i].lstrip().startswith("intel:")
                or lines[i].startswith("         ")
            ):
                i += 1
            continue

        if line.startswith("  url "):
            output.append(
                f'  url "https://github.com/{repository}/releases/download/v#{{version}}/{app_name}-#{{version}}-#{{arch}}.dmg"\n'
            )
            saw_url = True
            i += 1
            continue

        output.append(line)
        i += 1

    if not inserted_arch:
        output.insert(1, '  arch arm: "arm64", intel: "x86_64"\n')
        output.insert(2, "\n")

    insertion_index = 1
    while insertion_index < len(output) and (
        output[insertion_index].startswith("  arch ") or output[insertion_index].strip() == ""
    ):
        insertion_index += 1

    missing: list[str] = []
    if not saw_version:
        missing.append(f'  version "{version}"\n')
    if not saw_sha256:
        missing.extend(
            [
                f'  sha256 arm:   "{arm_sha256}",\n',
                f'         intel: "{intel_sha256}"\n',
            ]
        )
    if not saw_url:
        missing.append(
            f'  url "https://github.com/{repository}/releases/download/v#{{version}}/{app_name}-#{{version}}-#{{arch}}.dmg"\n'
        )

    if missing:
        output[insertion_index:insertion_index] = missing + ["\n"]

    return "".join(output)


def main() -> int:
    parser = argparse.ArgumentParser(description="Update a Homebrew cask for arch-specific macOS DMGs.")
    parser.add_argument("--cask", required=True, type=Path)
    parser.add_argument("--token", required=True)
    parser.add_argument("--app-name", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--arm-sha256", required=True)
    parser.add_argument("--intel-sha256", required=True)
    args = parser.parse_args()

    if not args.cask.exists():
        args.cask.parent.mkdir(parents=True, exist_ok=True)
        args.cask.write_text(cask_line(args.token) + "end\n", encoding="utf-8")

    original = args.cask.read_text(encoding="utf-8")
    updated = update_cask(
        original,
        token=args.token,
        app_name=args.app_name,
        version=args.version,
        repository=args.repository,
        arm_sha256=args.arm_sha256,
        intel_sha256=args.intel_sha256,
    )
    args.cask.write_text(updated, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
