"""Map image recipes (Makefile targets) to the files they are built from.

Usage:
  changed_recipes.py --changed-since <rev> print the recipes whose inputs differ
                                           between <rev> and the working tree
  changed_recipes.py --inputs <recipe>     print everything the recipe's image
                                           depends on in this repository, for
                                           hashing into a build cache key

A recipe is affected when it is new, or when anything its image is built from
differs: its Makefile target block (and its helper target's), the Makefile's
shared variables and macros (comments, blank lines and the .PHONY list
excluded), or the git blobs of the overlays and scripts the target references.
"""

import re
import subprocess
import sys
import tempfile
from pathlib import Path

# Targets that are not images.
NOT_RECIPES = {"help", "check_clean", "clean", "lint", "install-dev", "update-actions"}

TARGET = re.compile(r"^([A-Za-z0-9_-]+):(?!=)(.*)$")
PATHS = re.compile(r"\$\(WORKDIR\)/((?:overlays|scripts)/[^\s,;]*)")


def recipes(makefile: str) -> dict[str, set[str]]:
    """Map each image target to the overlay and script paths it references."""
    result: dict[str, set[str]] = {}
    aliases: dict[str, str] = {}
    current = None

    for line in makefile.splitlines():
        match = TARGET.match(line)

        if match:
            current = match.group(1)

            if current in NOT_RECIPES:
                current = None
                continue

            # `minirouter: _minirouter_img` builds through a helper target.
            for dep in match.group(2).split("#")[0].split():
                aliases[dep] = current

            result.setdefault(current, set())
            continue

        if current and line.startswith("\t"):
            for path in PATHS.findall(line):
                result[current].add(path.rstrip("/"))

    # Fold helper targets into the target that depends on them.
    for helper, target in aliases.items():
        if helper in result:
            result[target] |= result.pop(helper)

    return result


def recipe_inputs(makefile: str, recipe: str, cwd: str | None = None) -> str:
    """The text a recipe's image depends on: the Makefile's shared variables and
    macros, the recipe's own target block (and its helper's), and the git blob
    ids of the overlays and scripts it references."""
    lines = makefile.splitlines()
    header = []

    for line in lines:
        if TARGET.match(line):
            break

        # Comments, blank lines and the .PHONY list change no build, so they do
        # not mark every recipe as changed.
        stripped = line.strip()
        if not stripped or stripped.startswith(("#", ".PHONY")):
            continue

        header.append(line)

    targets = recipes(makefile)

    if recipe not in targets:
        raise SystemExit(f"unknown recipe {recipe!r}")

    blocks = []
    current = None

    for line in lines:
        match = TARGET.match(line)

        if match:
            name = match.group(1)
            current = name if name == recipe or name == f"_{recipe}_img" else None
        elif not line.strip():
            current = None

        if current:
            blocks.append(line)

    paths = sorted(targets[recipe])
    blobs = ""

    if paths:
        blobs = subprocess.run(
            ["git", "ls-files", "-s", "--", *paths],
            check=True,
            capture_output=True,
            text=True,
            cwd=cwd,
        ).stdout

    return "\n".join([*header, "", *blocks, "", blobs])


def changed_since(rev: str) -> list[str]:
    """Recipes that are new since rev or whose inputs differ from rev's."""
    makefile = Path("Makefile").read_text(encoding="utf-8")
    head = recipes(makefile)

    with tempfile.TemporaryDirectory() as tmp:
        subprocess.run(
            ["git", "worktree", "add", "--detach", tmp, rev],
            check=True,
            capture_output=True,
        )

        try:
            base_makefile = (Path(tmp) / "Makefile").read_text(encoding="utf-8")
            base = recipes(base_makefile)

            return [
                name
                for name in sorted(head)
                if name not in base
                or recipe_inputs(makefile, name)
                != recipe_inputs(base_makefile, name, cwd=tmp)
            ]
        finally:
            subprocess.run(
                ["git", "worktree", "remove", "--force", tmp],
                check=False,
                capture_output=True,
            )


def main() -> None:
    makefile = Path("Makefile").read_text(encoding="utf-8")

    if len(sys.argv) == 3 and sys.argv[1] == "--changed-since":
        print(" ".join(changed_since(sys.argv[2])))

        return

    if len(sys.argv) == 3 and sys.argv[1] == "--inputs":
        print(recipe_inputs(makefile, sys.argv[2]))

        return

    raise SystemExit(__doc__)


if __name__ == "__main__":
    main()
