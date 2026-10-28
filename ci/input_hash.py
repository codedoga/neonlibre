#!/usr/bin/env python3
"""Hash of everything a Dockerfile target is built from.

The hash covers the text of every stage the target depends on (through FROM and
COPY --from), the git object ids of the local files those stages COPY/ADD
(after .dockerignore), the build args, and the commits of the submodules that
are checked out for the build. A change anywhere else leaves it unchanged, so
CI can tag images with it and skip building an image that already exists.

    ci/input_hash.py <dockerfile> <target> [--arg NAME=VALUE]... [--submodule PATH]... [--ignore PATH]...

<target> is a stage name, or "" for the final stage. Paths are relative to the
repository root, which is the build context. Submodules not passed with
--submodule are treated as empty directories, as they are in a CI checkout that
did not initialise them. --ignore drops paths that are in the context but that
the build provably does not read (e.g. compute/ for the storage image, whose
`COPY . .` would otherwise make every compute change look like a storage change).
"""
import argparse
import fnmatch
import hashlib
import re
import subprocess
import sys
from pathlib import Path

INSTRUCTION = re.compile(r"^\s*([A-Za-z]+)\s+(.*)$", re.S)
VAR = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)(?::[-?+][^}]*)?\}|\$([A-Za-z_][A-Za-z0-9_]*)")


def instructions(text):
    """Yield (keyword, arguments, original text) with line continuations joined."""
    buf = []
    for line in text.splitlines():
        if not buf and (not line.strip() or line.lstrip().startswith("#")):
            continue
        if buf and (not line.strip() or line.lstrip().startswith("#")):
            continue  # Docker drops empty and comment lines inside a continuation too
        if line.rstrip().endswith("\\"):
            buf.append(line.rstrip()[:-1])
            continue
        buf.append(line)
        joined = "\n".join(buf)
        buf = []
        m = INSTRUCTION.match(joined)
        if m:
            yield m.group(1).upper(), m.group(2), joined


def parse(text):
    """Return (global lines, {stage: {'parent', 'lines', 'copies', 'froms'}}, last stage)."""
    glob, stages, cur, last = [], {}, None, None
    for kw, args, raw in instructions(text):
        if kw == "FROM":
            words = [w for w in args.split() if not w.startswith("--")]
            name = words[2] if len(words) >= 3 and words[1].upper() == "AS" else f"<stage{len(stages)}>"
            cur = stages[name] = {"parent": words[0], "lines": [raw], "copies": [], "froms": []}
            last = name
        elif cur is None:
            glob.append(raw)
        else:
            cur["lines"].append(raw)
            if kw in ("COPY", "ADD"):
                opts = re.findall(r"--([a-z-]+)(?:=(\S+))?", args)
                frm = dict(opts).get("from")
                if frm:
                    cur["froms"].append(frm)
                else:
                    cur["copies"].append(re.sub(r"--[a-z-]+(=\S+)?", "", args).split()[:-1])
            elif kw == "RUN":
                cur["froms"] += re.findall(r"--mount=[^ ]*\bfrom=([^, ]+)", args)
    return glob, stages, last


def substitute(s, env):
    return VAR.sub(lambda m: env.get(m.group(1) or m.group(2), ""), s)


def dockerignore_filter(paths, root):
    rules = []
    ignore = root / ".dockerignore"
    for line in ignore.read_text().splitlines() if ignore.exists() else []:
        line = line.strip()
        if line and not line.startswith("#"):
            neg = line.startswith("!")
            pat = line[1:] if neg else line
            pat = pat.strip("/")
            rx = re.escape(pat).replace(r"\*\*", ".*").replace(r"\*", "[^/]*").replace(r"\?", "[^/]")
            rules.append((neg, re.compile(rx + r"(/.*)?$")))
    keep = []
    for p in paths:
        excluded = False
        for neg, rx in rules:
            if rx.match(p):
                excluded = not neg
        if not excluded:
            keep.append(p)
    return keep


def context_entries(root, submodules, ignore=()):
    """{path: 'mode sha'} for every file in the build context."""
    out = subprocess.run(["git", "-C", str(root), "ls-files", "-s"], check=True,
                         capture_output=True, text=True).stdout
    entries = {}
    for line in out.splitlines():
        meta, path = line.split("\t", 1)
        mode, sha, _ = meta.split()
        if mode == "160000" and path not in submodules:
            continue  # not checked out: an empty directory in the context
        entries[path] = f"{mode} {sha}"
    keep = set(dockerignore_filter(list(entries), root))
    ignore = tuple(i.strip("/") + "/" for i in ignore)
    return {p: v for p, v in entries.items() if p in keep and not (p + "/").startswith(ignore)}


def matching(entries, src):
    src = src.strip("/") if src not in (".", "./") else ""
    if not src:
        return sorted(entries)
    if any(c in src for c in "*?["):
        return sorted(p for p in entries if fnmatch.fnmatchcase(p, src) or
                      any(fnmatch.fnmatchcase(p[: i], src) for i in range(len(p)) if p[i] == "/"))
    return sorted(p for p in entries if p == src or p.startswith(src + "/"))


def input_hash(dockerfile, target, args, submodules, root=Path("."), ignore=()):
    text = (root / dockerfile).read_text()
    glob, stages, last = parse(text)
    env = {}
    for line in glob:
        m = re.match(r"ARG\s+([A-Za-z_][A-Za-z0-9_]*)(?:=(.*))?$", line.strip())
        if m:
            env[m.group(1)] = substitute(m.group(2) or "", env).strip('"')
    env.update(args)
    entries = context_entries(root, set(submodules), ignore)

    h = hashlib.sha256()
    for k in sorted(args):
        h.update(f"arg {k}={args[k]}\n".encode())
    h.update("\n".join(glob).encode())
    seen, todo = set(), [target or last]
    while todo:
        name = todo.pop()
        if name in seen:
            continue
        seen.add(name)
        st = stages.get(name)
        if st is None:
            h.update(f"image {substitute(name, env)}\n".encode())  # an external image
            continue
        h.update(f"stage {name}\n".encode())
        h.update("\n".join(st["lines"]).encode())
        todo.append(substitute(st["parent"], env))
        todo += [substitute(f, env) for f in st["froms"]]
        for srcs in st["copies"]:
            for src in srcs:
                for p in matching(entries, substitute(src, env)):
                    h.update(f"file {p} {entries[p]}\n".encode())
    return h.hexdigest()[:16]


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("dockerfile")
    ap.add_argument("target")
    ap.add_argument("--arg", action="append", default=[])
    ap.add_argument("--submodule", action="append", default=[])
    ap.add_argument("--ignore", action="append", default=[])
    a = ap.parse_args()
    args = dict(kv.split("=", 1) for kv in a.arg)
    print(input_hash(a.dockerfile, a.target, args, a.submodule, ignore=a.ignore))


if __name__ == "__main__":
    sys.exit(main())
