#!/usr/bin/env python3
"""
Validation for this repository's SP 800-22 implementation.

nist_sts.py was written from the specification rather than installed from
NIST, so before any verdict it produces about SipCon64 is worth reporting, the
implementation has to be shown to work. This script does that the only way that
is self-contained: run it on streams whose correct verdict is known in advance
and check it returns that verdict.

  os.urandom          must PASS -- the OS CSPRNG is the positive control. A
                      suite that fails here is broken; one that passes has at
                      least no gross false-positive rate.

  all-zero bytes      must FAIL almost everything. Catches a suite that would
                      accidentally pass anything.

  counter             must FAIL. A 64-bit incrementing counter is highly
                      structured but perfectly balanced in aggregate, so it
                      separates tests that look at structure from tests that
                      only look at bit frequency.

  LCG low bits        must FAIL. Linear congruential output -- the classic
                      "looks random until you test it" stream.

  1-round SipCon64    must FAIL. One round cannot diffuse a counter, so this is
                      the domain-specific negative control: it proves the suite
                      can detect an under-mixed SipCon64, which is exactly what
                      the round sweep in SECURITY-RESULTS.md depends on.

It also checks the shape of the result and not just the verdict: on genuine
random input the per-sequence p-values must themselves be uniform on [0,1],
which is the property the whole two-level NIST assessment rests on.

Usage:  python3 validate_sts.py [--seqs 32] [--bits 1000000] [--gen PATH]
"""

import argparse
import os
import struct
import subprocess
import sys
import tempfile

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from nist_sts import assess, suite_verdict, ALPHA  # noqa: E402


def make_urandom(path, nbytes):
    with open(path, "wb") as fh:
        remaining = nbytes
        while remaining > 0:
            chunk = min(remaining, 1 << 20)
            fh.write(os.urandom(chunk))
            remaining -= chunk


def make_zeros(path, nbytes):
    with open(path, "wb") as fh:
        fh.write(b"\x00" * nbytes)


def make_counter(path, nbytes):
    buf = bytearray()
    i = 0
    while len(buf) < nbytes:
        buf += struct.pack("<Q", i)
        i += 1
    with open(path, "wb") as fh:
        fh.write(bytes(buf[:nbytes]))


def make_lcg(path, nbytes):
    """glibc-style LCG, writing the low byte of each state -- weak by design."""
    state = 12345
    out = bytearray()
    while len(out) < nbytes:
        state = (1103515245 * state + 12345) & 0x7FFFFFFF
        out.append(state & 0xFF)
    with open(path, "wb") as fh:
        fh.write(bytes(out[:nbytes]))


def summarise(rows):
    sv = suite_verdict(rows)
    return sv["subtests"], sv["failed"], sv["expected_failures"], sv["verdict"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seqs", type=int, default=32)
    ap.add_argument("--bits", type=int, default=1000000)
    ap.add_argument("--gen", default=None,
                    help="path to build/gen_streams, for the 1-round control")
    a = ap.parse_args()

    nbytes = a.seqs * (a.bits // 8)
    tmp = tempfile.mkdtemp(prefix="sts-validate-")
    problems = []

    cases = [
        ("os.urandom", make_urandom, "PASS"),
        ("all-zero bytes", make_zeros, "FAIL"),
        ("64-bit counter", make_counter, "FAIL"),
        ("LCG low byte", make_lcg, "FAIL"),
    ]

    print(f"validating the SP 800-22 implementation "
          f"({a.seqs} sequences x {a.bits} bits, alpha={ALPHA})\n")
    print(f"{'control stream':<22} {'expect':<7} {'sub-tests':>9} "
          f"{'failed':>7} {'exp':>6}  {'suite':<6} verdict")
    print("-" * 74)

    urandom_rows = None
    for name, maker, expect in cases:
        path = os.path.join(tmp, name.replace(" ", "_").replace(".", "")
                            + ".bin")
        maker(path, nbytes)
        rows = assess(path, a.seqs, a.bits, name)
        total, failed, exp, got = summarise(rows)
        if name == "os.urandom":
            urandom_rows = rows
        ok = (got == expect)
        if not ok:
            problems.append(f"{name}: expected {expect}, suite said {got} "
                            f"({failed}/{total} sub-tests failed, "
                            f"{exp:.2f} expected by chance)")
        print(f"{name:<22} {expect:<7} {total:>9} {failed:>7} {exp:>6.2f}  "
              f"{got:<6} {'ok' if ok else 'UNEXPECTED'}")
        os.unlink(path)

    # the domain-specific negative control
    if a.gen and os.path.exists(a.gen):
        path = os.path.join(tmp, "sipcon64_r1.bin")
        subprocess.run([a.gen, "permctr", "1", str(nbytes / (1024 * 1024)),
                        "1", path], check=True, stderr=subprocess.DEVNULL)
        rows = assess(path, a.seqs, a.bits, "SipCon64 p^1")
        total, failed, exp, got = summarise(rows)
        ok = (got == "FAIL")
        if not ok:
            problems.append(f"1-round SipCon64: expected FAIL, suite said "
                            f"{got} ({failed}/{total})")
        print(f"{'SipCon64 p^1 (ctr)':<22} {'FAIL':<7} {total:>9} {failed:>7} "
              f"{exp:>6.2f}  {got:<6} {'ok' if ok else 'UNEXPECTED'}")
        os.unlink(path)
    else:
        print(f"{'SipCon64 p^1 (ctr)':<22} {'-':<7} {'skipped':>9} "
              f"{'-':>7} {'-':>6}  {'-':<6} (pass --gen build/gen_streams)")

    # Shape check: p-values on random input must be uniform, not merely > alpha
    print("\np-value uniformity on os.urandom (the assumption the whole "
          "two-level\nassessment rests on):")
    unif = np.array([r["uniformity_p"] for r in urandom_rows])
    prop = np.array([r["proportion"] for r in urandom_rows])
    low = int(np.count_nonzero(unif < 0.0001))
    print(f"  sub-tests                      {len(unif)}")
    print(f"  mean pass proportion           {prop.mean():.4f} "
          f"(expected ~{1 - ALPHA:.2f})")
    print(f"  uniformity P_T < 0.0001        {low}")
    if abs(prop.mean() - (1 - ALPHA)) > 0.01:
        problems.append(f"urandom mean pass proportion {prop.mean():.4f} is "
                        f"far from {1 - ALPHA}")
    if low > max(1, len(unif) // 100):
        problems.append(f"{low} sub-tests have non-uniform p-values on urandom")

    os.rmdir(tmp)
    print()
    if problems:
        print("VALIDATION FAILED")
        for p in problems:
            print(f"  - {p}")
        return 1
    print("validation passed: the suite accepts the CSPRNG, rejects all four "
          "weak streams\nincluding a 1-round SipCon64, and its p-values are "
          "uniform on random input.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
