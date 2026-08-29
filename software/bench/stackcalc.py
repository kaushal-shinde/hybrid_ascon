#!/usr/bin/env python3
"""Static worst-case stack depth per algorithm: parse GCC's -fstack-usage
(.su) per-function frame sizes, build a call graph from objdump -dr call
relocations across that algorithm's .o files, and DFS from the entry point
for the deepest cumulative call chain. This is the standard way embedded/LWC
papers report stack usage (a static bound), and is far more robust here than
a runtime high-water-mark, which on this native x86_64 box turned out to be
dominated by ~6.3KB of pthread/dlopen floor that swamped the real signal.
"""
import glob
import os
import re
import subprocess
import sys
import json

HERE = os.path.dirname(os.path.abspath(__file__))
BUILD = os.path.join(HERE, "build")

ALGOS = {
    "ascon": ("bench_encrypt",),
    "hybrid_r128": ("bench_encrypt",),
    "hybrid_r64": ("bench_encrypt",),
    "tinyjambu": ("bench_encrypt",),
    "xoodyak": ("bench_encrypt",),
    "giftcofb": ("bench_encrypt",),
    "grain": ("bench_encrypt",),
    "sparkle": ("bench_encrypt",),
    "elephant": ("bench_encrypt",),
    "isap": ("bench_encrypt",),
    "photonbeetle": ("bench_encrypt",),
    "romulus": ("bench_encrypt",),
}


def parse_su(su_dir):
    """function name -> static frame bytes (0 if 'dynamic' with no bound)."""
    frames = {}
    for path in glob.glob(os.path.join(su_dir, "*.su")):
        for line in open(path, encoding="utf-8", errors="replace"):
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 3:
                continue
            loc, size, kind = parts[0], parts[1], parts[2]
            # loc = "file:line:col:funcname"
            m = re.search(r":(\w+)$", loc)
            if not m:
                continue
            fn = m.group(1)
            try:
                sz = int(size)
            except ValueError:
                continue
            # Keep the largest if a name repeats (static overload-ish cases).
            frames[fn] = max(frames.get(fn, 0), sz)
    return frames


def parse_callgraph(su_dir):
    """caller name -> set of callee names, from objdump -dr on every .o.

    Two distinct cases, both needed: (1) calls to functions in ANOTHER
    translation unit are unresolved at this stage and show up as a
    relocation record on the following line; (2) calls to a function
    already defined earlier in the SAME file are resolved directly by the
    assembler and never get a relocation at all -- they appear inline in
    the disassembly as `call <addr> <funcname>` (or `<funcname+offset>`
    for a call into the middle of a function GCC merged with an
    identical-code neighbour). Relying on relocations alone silently
    drops every same-file call, which is most of them.
    """
    graph = {}
    cur_fn = None
    label_re = re.compile(r"^[0-9a-f]+ <([A-Za-z_.][A-Za-z0-9_.]*)>:$")
    reloc_re = re.compile(r"R_X86_64_(?:PLT32|PC32)\s+([A-Za-z_.][A-Za-z0-9_.]*)")
    inline_call_re = re.compile(r"\bcallq?\s+[0-9a-f]+\s+<([A-Za-z_.][A-Za-z0-9_.]*)")
    for obj in glob.glob(os.path.join(su_dir, "*.o")):
        try:
            out = subprocess.run(["objdump", "-dr", obj], capture_output=True,
                                  text=True, check=True).stdout
        except subprocess.CalledProcessError:
            continue
        for line in out.splitlines():
            lm = label_re.match(line)
            if lm:
                cur_fn = lm.group(1)
                graph.setdefault(cur_fn, set())
                continue
            if cur_fn is None:
                continue
            rm = reloc_re.search(line)
            if rm:
                graph[cur_fn].add(rm.group(1).split("@")[0])
                continue
            im = inline_call_re.search(line)
            if im:
                graph[cur_fn].add(im.group(1).split("+")[0])
    return graph


def deepest_chain(entry, frames, graph, memo=None, stack_trail=None):
    """Max cumulative static-frame depth on any call path starting at
    `entry`. Cycle-safe (recursion counted once, not unrolled) since real
    call CHAINS here are shallow and non-recursive; a cycle only means we
    stop extending that branch rather than looping forever."""
    if stack_trail is None:
        stack_trail = set()
    if entry in stack_trail:
        return 0  # recursion guard: don't double count a repeated frame
    stack_trail = stack_trail | {entry}
    own = frames.get(entry, 0)
    callees = graph.get(entry, set())
    best_child = 0
    for c in callees:
        if c in frames or c in graph:  # only follow edges into known local code
            best_child = max(best_child, deepest_chain(c, frames, graph, memo, stack_trail))
    return own + best_child


def main():
    results = {}
    for label, entries in ALGOS.items():
        su_dir = os.path.join(BUILD, f"su_{label}")
        frames = parse_su(su_dir)
        graph = parse_callgraph(su_dir)
        depth = max(deepest_chain(e, frames, graph) for e in entries)
        results[label] = {
            "static_stack_bytes": depth,
            "n_functions": len(frames),
            "entry_frame": frames.get(entries[0], 0),
        }
        print(f"{label:14s} static_stack={depth:6d} B  "
              f"(entry frame {frames.get(entries[0],0)} B, {len(frames)} functions analyzed)")

    with open(os.path.join(HERE, "stack_results.json"), "w") as f:
        json.dump(results, f, indent=2)


if __name__ == "__main__":
    main()
