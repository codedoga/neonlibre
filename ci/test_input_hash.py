#!/usr/bin/env python3
"""Self-test for ci/input_hash.py: each change must alter exactly the hashes that depend on it."""
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from input_hash import input_hash  # noqa: E402

DOCKERFILE = """\
ARG BASE=debian:bookworm
FROM $BASE AS a
COPY x.txt /x
FROM a AS b
ARG V
RUN echo ${V:?} \\
    && echo b
FROM $BASE AS c
COPY patches/c-${V}.patch /p
COPY sub /sub
FROM $BASE
COPY --from=b /x /x
COPY --from=c /p /p
"""


def git(root, *args):
    subprocess.run(["git", "-C", str(root), *args], check=True, capture_output=True)


def main():
    with tempfile.TemporaryDirectory() as d:
        root = Path(d)
        git(root, "init", "-q")
        (root / "patches").mkdir()
        files = {"Dockerfile": DOCKERFILE, "x.txt": "x", "patches/c-18.patch": "c18",
                 "patches/c-17.patch": "c17", "ignored.txt": "i", ".dockerignore": "ignored.txt\n"}
        for p, t in files.items():
            (root / p).write_text(t)
        git(root, "add", ".")
        git(root, "update-index", "--add", "--cacheinfo", "160000," + "1" * 40 + ",sub")

        def hashes(sub=("sub",), v="18"):
            return {t: input_hash("Dockerfile", t, {"V": v}, list(sub), root) for t in ("a", "b", "c", "")}

        def changed(before, after):
            return {t for t in before if before[t] != after[t]}

        h0 = hashes()
        assert hashes() == h0, "not deterministic"

        def edit(path, text):
            (root / path).write_text(text)
            git(root, "add", path)

        edit("x.txt", "x2")
        h1 = hashes()
        assert changed(h0, h1) == {"a", "b", ""}, changed(h0, h1)

        edit("patches/c-17.patch", "c17b")  # not the version being built
        assert hashes() == h1, "an unused file changed the hash"
        edit("patches/c-18.patch", "c18b")
        h2 = hashes()
        assert changed(h1, h2) == {"c", ""}, changed(h1, h2)

        edit("ignored.txt", "i2")
        assert hashes() == h2, "a .dockerignore'd file changed the hash"
        assert input_hash("Dockerfile", "c", {"V": "18"}, ["sub"], root, ignore=["patches"]) != h2["c"], \
            "--ignore must drop the ignored path from the hash"

        assert changed(h2, hashes(sub=())) == {"c", ""}, "submodule checkout state not reflected"
        git(root, "update-index", "--cacheinfo", "160000," + "2" * 40 + ",sub")
        h3 = hashes()
        assert changed(h2, h3) == {"c", ""}, changed(h2, h3)

        assert changed(h3, hashes(v="17")) == {"a", "b", "c", ""}, "build args must change every hash"

        edit("Dockerfile", DOCKERFILE.replace("echo b", "echo B"))
        h4 = hashes()
        assert changed(h3, h4) == {"b", ""}, changed(h3, h4)
    print("input_hash self-test OK")


if __name__ == "__main__":
    main()
