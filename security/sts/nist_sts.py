#!/usr/bin/env python3
"""
NIST SP 800-22 Rev. 1a statistical test suite, implemented for this project.

All fifteen tests of the specification are here. The suite is implemented
rather than installed because NIST's `assess` reference binary is not packaged
for this machine, and the repository's convention is that the tooling behind a
number lives next to the number (see ../../flow/ and ../../software/bench/).

Being a from-scratch implementation, it is validated before it is trusted --
see validate_sts.py, which runs it on streams whose verdict is known in advance
(os.urandom must pass; a counter, a constant, an LCG and the 1-round SipCon64
permutation must fail) and checks that p-values on genuinely random input are
themselves uniform. SECURITY-RESULTS.md quotes that validation.

Bit order: bytes are expanded most-significant-bit first (np.unpackbits),
which is what the NIST reference reads from a binary input file.

Usage:
    python3 nist_sts.py <stream.bin> --seqs 128 --bits 1000000 \
            --label ctstream --detail detail.csv --summary summary.csv
"""

import argparse
import math
import os
import sys
from concurrent.futures import ProcessPoolExecutor

import numpy as np
from scipy.special import gammaincc, erfc
from scipy.stats import norm, binom, poisson

ALPHA = 0.01  # per-sequence significance level, NIST's default

# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------


def _igamc(a, x):
    """Regularised upper incomplete gamma Q(a,x), NIST's igamc()."""
    return float(gammaincc(a, x))


def _rolling_values(bits, m, wrap=False):
    """Integer value of every length-m window, MSB-first within the window."""
    n = len(bits)
    if wrap:
        ext = np.concatenate([bits, bits[: m - 1]])
        count = n
    else:
        ext = bits
        count = n - m + 1
    v = np.zeros(count, dtype=np.int64)
    for j in range(m):
        v = (v << 1) | ext[j : j + count]
    return v


# --------------------------------------------------------------------------
# the fifteen tests -- each returns a list of (subtest_label, p_value)
# --------------------------------------------------------------------------


def t01_frequency(b):
    n = len(b)
    s = int(np.sum(2 * b.astype(np.int64) - 1))
    return [("frequency", float(erfc(abs(s) / math.sqrt(n) / math.sqrt(2))))]


def t02_block_frequency(b, M=128):
    n = len(b)
    N = n // M
    if N < 1:
        return []
    blocks = b[: N * M].reshape(N, M).astype(np.float64)
    pi = blocks.mean(axis=1)
    chi2 = 4.0 * M * float(np.sum((pi - 0.5) ** 2))
    return [("block-frequency", _igamc(N / 2.0, chi2 / 2.0))]


def t03_runs(b):
    n = len(b)
    pi = float(np.mean(b))
    if abs(pi - 0.5) >= 2.0 / math.sqrt(n):
        # NIST: the frequency test is a precondition; report a definite fail
        return [("runs", 0.0)]
    v = 1 + int(np.count_nonzero(b[1:] != b[:-1]))
    num = abs(v - 2.0 * n * pi * (1 - pi))
    den = 2.0 * math.sqrt(2.0 * n) * pi * (1 - pi)
    return [("runs", float(erfc(num / den)))]


# (min n, M, K, N, probabilities, vmin) -- SP 800-22 section 2.4
_LONGEST_RUN_PARAMS = [
    (750000, 10000, 6, 75,
     [0.0882, 0.2092, 0.2483, 0.1933, 0.1208, 0.0675, 0.0727], 10),
    (6272, 128, 5, 49, [0.1174, 0.2430, 0.2493, 0.1752, 0.1027, 0.1124], 4),
    (128, 8, 3, 16, [0.2148, 0.3672, 0.2305, 0.1875], 1),
]


def t04_longest_run(b):
    n = len(b)
    for need, M, K, N, probs, vmin in _LONGEST_RUN_PARAMS:
        if n >= need:
            break
    else:
        return []
    blocks = b[: N * M].reshape(N, M)
    # Longest run of ones per block, vectorised. A zero column is appended to
    # each block first, so no run can straddle a block boundary and the whole
    # thing reduces to one run-length encoding of the flattened array.
    padded = np.concatenate([blocks, np.zeros((N, 1), dtype=blocks.dtype)],
                            axis=1).reshape(-1)
    W = M + 1
    d = np.diff(np.concatenate([[0], padded, [0]]).astype(np.int8))
    starts = np.flatnonzero(d == 1)
    ends = np.flatnonzero(d == -1)
    best = np.zeros(N, dtype=np.int64)
    if starts.size:
        np.maximum.at(best, starts // W, ends - starts)
    counts = np.bincount(np.clip(best - vmin, 0, K), minlength=K + 1)[: K + 1]
    chi2 = 0.0
    for i in range(K + 1):
        e = N * probs[i]
        chi2 += (counts[i] - e) ** 2 / e
    return [("longest-run", _igamc(K / 2.0, chi2 / 2.0))]


def _gf2_ranks(packed, nrows, ncols):
    """GF(2) ranks of many matrices at once.

    `packed` is (N, nrows) with each entry holding one row as a bit-packed
    int. All N matrices are eliminated in lockstep: the per-matrix pivot row
    counter lives in `rank`, so a matrix that skips a column simply does not
    advance. A Python-level elimination per matrix would be ~2.5 M interpreter
    operations per sequence; this keeps the test at well under a second.
    """
    rows = packed.copy()
    N = rows.shape[0]
    rank = np.zeros(N, dtype=np.int64)
    ar = np.arange(nrows)
    idx = np.arange(N)
    for col in range(ncols - 1, -1, -1):
        bit = ((rows >> col) & 1).astype(bool)
        cand = bit & (ar[None, :] >= rank[:, None])
        has = cand.any(axis=1)
        if not has.any():
            continue
        first = cand.argmax(axis=1)
        r0 = np.minimum(rank, nrows - 1)
        hi = idx[has]
        a, bsel = r0[has], first[has]
        tmp = rows[hi, a].copy()
        rows[hi, a] = rows[hi, bsel]
        rows[hi, bsel] = tmp
        pivot = rows[idx, r0]
        elim = ((rows >> col) & 1).astype(bool)
        elim &= ar[None, :] != r0[:, None]
        elim &= has[:, None]
        rows ^= np.where(elim, pivot[:, None], 0)
        rank += has
    return rank


def t05_matrix_rank(b, M=32, Q=32):
    n = len(b)
    N = n // (M * Q)
    if N < 38:  # NIST wants at least 38 matrices
        return []
    used = b[: N * M * Q].reshape(N, M, Q)
    weights = (1 << np.arange(Q - 1, -1, -1)).astype(np.int64)
    packed = used.astype(np.int64) @ weights  # (N, M)
    ranks = _gf2_ranks(packed, M, Q)
    f_full = int(np.count_nonzero(ranks == M))
    f_one = int(np.count_nonzero(ranks == M - 1))
    f_rest = N - f_full - f_one
    p_full, p_one, p_rest = 0.2888, 0.5776, 0.1336
    chi2 = ((f_full - p_full * N) ** 2 / (p_full * N)
            + (f_one - p_one * N) ** 2 / (p_one * N)
            + (f_rest - p_rest * N) ** 2 / (p_rest * N))
    return [("matrix-rank", float(math.exp(-chi2 / 2.0)))]


def t06_dft(b):
    n = len(b)
    x = 2.0 * b.astype(np.float64) - 1.0
    s = np.abs(np.fft.rfft(x)[: n // 2])
    thresh = math.sqrt(math.log(1.0 / 0.05) * n)
    n0 = 0.95 * n / 2.0
    n1 = float(np.count_nonzero(s < thresh))
    d = (n1 - n0) / math.sqrt(n * 0.95 * 0.05 / 4.0)
    return [("dft-spectral", float(erfc(abs(d) / math.sqrt(2))))]


def _aperiodic_templates(m):
    """All bifix-free (unbordered) m-bit words -- NIST's aperiodic templates.
    For m = 9 this yields the 148 templates the reference suite uses."""
    out = []
    for v in range(1 << m):
        bits = [(v >> (m - 1 - i)) & 1 for i in range(m)]
        ok = True
        for k in range(1, m):
            if bits[:k] == bits[m - k:]:
                ok = False
                break
        if ok:
            out.append(v)
    return out


_TEMPLATES_9 = None


def t07_non_overlapping(b, m=9, N=8):
    global _TEMPLATES_9
    if _TEMPLATES_9 is None:
        _TEMPLATES_9 = _aperiodic_templates(m)
    n = len(b)
    M = n // N
    if M < m:
        return []
    mu = (M - m + 1) / float(1 << m)
    var = M * (1.0 / (1 << m) - (2.0 * m - 1.0) / float(1 << (2 * m)))
    results = []
    vals = _rolling_values(b, m)
    lut = np.zeros(1 << m, dtype=bool)
    lut[_TEMPLATES_9] = True
    cand = np.flatnonzero(lut[vals])
    cand_vals = vals[cand]
    order = np.argsort(cand_vals, kind="stable")
    cand = cand[order]
    cand_vals = cand_vals[order]
    bounds = np.append(np.searchsorted(cand_vals, _TEMPLATES_9),
                       len(cand_vals))
    for ti, tmpl in enumerate(_TEMPLATES_9):
        pos = cand[bounds[ti] : bounds[ti + 1]]
        w = np.zeros(N, dtype=np.int64)
        last_end = -1
        cur_blk = -1
        for p in pos.tolist():
            blk = p // M
            if blk >= N:
                break
            if p - blk * M > M - m:
                continue            # window would cross the block boundary
            if blk != cur_blk:      # each block is scanned independently
                cur_blk = blk
                last_end = -1
            if p < last_end:
                continue            # overlaps the previous match in this block
            w[blk] += 1
            last_end = p + m
        chi2 = float(np.sum((w - mu) ** 2)) / var
        results.append((f"non-overlapping[{tmpl:03d}]",
                        _igamc(N / 2.0, chi2 / 2.0)))
    return results


def t08_overlapping(b, m=9, M=1032, K=5):
    n = len(b)
    N = n // M
    if N < 1:
        return []
    probs = [0.364091, 0.185659, 0.139381, 0.100571, 0.070432, 0.139865]
    vals = _rolling_values(b, m)
    hit = (vals == (1 << m) - 1)
    counts = np.zeros(K + 1, dtype=np.int64)
    for j in range(N):
        lo = j * M
        hi = lo + M - m + 1
        if hi > len(hit):
            break
        counts[min(int(np.count_nonzero(hit[lo:hi])), K)] += 1
    total = int(counts.sum())
    chi2 = 0.0
    for i in range(K + 1):
        e = total * probs[i]
        chi2 += (counts[i] - e) ** 2 / e
    return [("overlapping", _igamc(K / 2.0, chi2 / 2.0))]


_UNIVERSAL_EV = {6: 5.2177052, 7: 6.1962507, 8: 7.1836656, 9: 8.1764248,
                 10: 9.1723243, 11: 10.170032, 12: 11.168765, 13: 12.168070,
                 14: 13.167693, 15: 14.167488, 16: 15.167379}
_UNIVERSAL_VAR = {6: 2.954, 7: 3.125, 8: 3.238, 9: 3.311, 10: 3.356,
                  11: 3.384, 12: 3.401, 13: 3.410, 14: 3.416, 15: 3.419,
                  16: 3.421}


def t09_universal(b):
    n = len(b)
    thresholds = [(904960, 7), (2068480, 8), (4654080, 9), (10342400, 10),
                  (22753280, 11), (49643520, 12), (107560960, 13),
                  (231669760, 14), (496435200, 15), (1059061760, 16)]
    L = 6
    for need, ll in thresholds:
        if n >= need:
            L = ll
    if n < 387840:
        return []
    Q = 10 * (1 << L)
    nblocks = n // L
    K = nblocks - Q
    if K <= 0:
        return []
    v = np.zeros(nblocks, dtype=np.int64)
    flat = b[: nblocks * L].reshape(nblocks, L)
    for j in range(L):
        v = (v << 1) | flat[:, j]
    # Distance to the previous occurrence of the same value, blocks 1-indexed.
    # Grouping by value and differencing positions gives the same answer as
    # NIST's sequential table scan, vectorised.
    total = 0.0
    order = np.argsort(v, kind="stable")
    sorted_v = v[order]
    starts = np.searchsorted(sorted_v, np.arange(1 << L), side="left")
    ends = np.searchsorted(sorted_v, np.arange(1 << L), side="right")
    for val in range(1 << L):
        pos = order[starts[val] : ends[val]]
        if pos.size == 0:
            continue
        pos1 = pos + 1
        prev = np.concatenate([[0], pos1[:-1]])
        dist = pos1 - prev
        sel = pos1 > Q            # only the test segment contributes
        if np.any(sel):
            total += float(np.sum(np.log2(dist[sel])))
    fn = total / K
    ev, var = _UNIVERSAL_EV[L], _UNIVERSAL_VAR[L]
    c = 0.7 - 0.8 / L + (4.0 + 32.0 / L) * (K ** (-3.0 / L)) / 15.0
    sigma = c * math.sqrt(var / K)
    return [("universal", float(erfc(abs((fn - ev) / (math.sqrt(2) * sigma)))))]


def _berlekamp_massey(bitlist):
    """Linear complexity of a GF(2) sequence, via big-int bit tricks.

    `r` is a reversed window whose bit i is s[N-i], so the discrepancy is one
    AND plus a parity -- which keeps this O(n) big-int ops instead of the
    O(n*L) element-wise loop the textbook form implies."""
    n = len(bitlist)
    c = 1
    bpoly = 1
    ll = 0
    mm = -1
    r = 0
    for nn in range(n):
        r = (r << 1) | bitlist[nn]
        if (c & r).bit_count() & 1:
            t = c
            c ^= bpoly << (nn - mm)
            if 2 * ll <= nn:
                ll = nn + 1 - ll
                bpoly = t
                mm = nn
    return ll


def t10_linear_complexity(b, M=500, K=6):
    n = len(b)
    N = n // M
    if N < 200:
        return []
    probs = [0.010417, 0.03125, 0.125, 0.5, 0.25, 0.0625, 0.020833]
    mu = (M / 2.0 + (9.0 + (-1) ** (M + 1)) / 36.0
          - (M / 3.0 + 2.0 / 9.0) / float(1 << M))
    counts = np.zeros(K + 1, dtype=np.int64)
    blocks = b[: N * M].reshape(N, M)
    sign = 1.0 if M % 2 == 0 else -1.0
    bounds = [-2.5, -1.5, -0.5, 0.5, 1.5, 2.5]
    for row in blocks:
        ti = sign * (_berlekamp_massey(row.tolist()) - mu) + 2.0 / 9.0
        idx = K
        for q, bd in enumerate(bounds):
            if ti <= bd:
                idx = q
                break
        counts[idx] += 1
    chi2 = 0.0
    for i in range(K + 1):
        e = N * probs[i]
        chi2 += (counts[i] - e) ** 2 / e
    return [("linear-complexity", _igamc(K / 2.0, chi2 / 2.0))]


def _psi2(b, m):
    if m <= 0:
        return 0.0
    n = len(b)
    v = _rolling_values(b, m, wrap=True)
    counts = np.bincount(v, minlength=1 << m).astype(np.float64)
    return float((1 << m) / n * np.sum(counts ** 2) - n)


def t11_serial(b, m=16):
    n = len(b)
    if m >= int(math.log2(n)) - 2:
        m = int(math.log2(n)) - 3
    p0, p1, p2 = _psi2(b, m), _psi2(b, m - 1), _psi2(b, m - 2)
    d1 = p0 - p1
    d2 = p0 - 2.0 * p1 + p2
    return [("serial-1", _igamc(1 << (m - 2), d1 / 2.0)),
            ("serial-2", _igamc(1 << (m - 3), d2 / 2.0))]


def t12_approximate_entropy(b, m=10):
    n = len(b)
    if m + 1 >= int(math.log2(n)) - 5:
        m = max(2, int(math.log2(n)) - 6)

    def phi(mm):
        v = _rolling_values(b, mm, wrap=True)
        c = np.bincount(v, minlength=1 << mm).astype(np.float64) / n
        nz = c[c > 0]
        return float(np.sum(nz * np.log(nz)))

    apen = phi(m) - phi(m + 1)
    chi2 = 2.0 * n * (math.log(2) - apen)
    return [("approximate-entropy", _igamc(1 << (m - 1), chi2 / 2.0))]


def t13_cumulative_sums(b):
    n = len(b)
    x = 2 * b.astype(np.int64) - 1
    out = []
    for label, series in (("cusum-forward", x), ("cusum-backward", x[::-1])):
        s = np.cumsum(series)
        z = int(np.max(np.abs(s)))
        if z == 0:
            out.append((label, 1.0))
            continue
        sq = math.sqrt(n)
        k1 = np.arange(int((-n / z + 1) / 4), int((n / z - 1) / 4) + 1)
        term1 = np.sum(norm.cdf((4 * k1 + 1) * z / sq)
                       - norm.cdf((4 * k1 - 1) * z / sq))
        k2 = np.arange(int((-n / z - 3) / 4), int((n / z - 1) / 4) + 1)
        term2 = np.sum(norm.cdf((4 * k2 + 3) * z / sq)
                       - norm.cdf((4 * k2 + 1) * z / sq))
        p = 1.0 - term1 + term2
        out.append((label, float(min(max(p, 0.0), 1.0))))
    return out


def _excursion_cycles(b):
    x = 2 * b.astype(np.int64) - 1
    s = np.concatenate([[0], np.cumsum(x), [0]])
    return s, np.flatnonzero(s == 0)


def t14_random_excursions(b):
    n = len(b)
    s, zeros = _excursion_cycles(b)
    J = len(zeros) - 1
    if J < max(0.005 * math.sqrt(n), 500):
        return []
    cyc = np.zeros(len(s), dtype=np.int64)
    cyc[zeros[:-1]] = 1
    cyc = np.clip(np.cumsum(cyc) - 1, 0, J - 1)
    out = []
    for xstate in [-4, -3, -2, -1, 1, 2, 3, 4]:
        mask = s == xstate
        counts = (np.bincount(cyc[mask], minlength=J) if np.any(mask)
                  else np.zeros(J, dtype=np.int64))
        binned = np.bincount(np.clip(counts, 0, 5), minlength=6)
        ax = abs(xstate)
        pi = [1.0 - 1.0 / (2.0 * ax)]
        for k in range(1, 5):
            pi.append((1.0 / (4.0 * xstate * xstate))
                      * (1.0 - 1.0 / (2.0 * ax)) ** (k - 1))
        pi.append((1.0 / (2.0 * ax)) * (1.0 - 1.0 / (2.0 * ax)) ** 4)
        chi2 = sum((binned[k] - J * pi[k]) ** 2 / (J * pi[k])
                   for k in range(6))
        out.append((f"random-excursions[{xstate:+d}]", _igamc(2.5, chi2 / 2.0)))
    return out


def t15_random_excursions_variant(b):
    n = len(b)
    s, zeros = _excursion_cycles(b)
    J = len(zeros) - 1
    if J < max(0.005 * math.sqrt(n), 500):
        return []
    out = []
    for xstate in list(range(-9, 0)) + list(range(1, 10)):
        xi = int(np.count_nonzero(s == xstate))
        den = math.sqrt(2.0 * J * (4.0 * abs(xstate) - 2.0))
        out.append((f"random-excursions-variant[{xstate:+d}]",
                    float(erfc(abs(xi - J) / den))))
    return out


ALL_TESTS = [t01_frequency, t02_block_frequency, t03_runs, t04_longest_run,
             t05_matrix_rank, t06_dft, t07_non_overlapping, t08_overlapping,
             t09_universal, t10_linear_complexity, t11_serial,
             t12_approximate_entropy, t13_cumulative_sums,
             t14_random_excursions, t15_random_excursions_variant]


def run_sequence(bits):
    """All tests on one sequence -> dict subtest_label -> p-value."""
    res = {}
    for fn in ALL_TESTS:
        try:
            for label, p in fn(bits):
                res[label] = p
        except Exception as exc:  # a test that blows up must not pass silently
            res[f"ERROR:{fn.__name__}"] = float("nan")
            print(f"    ! {fn.__name__}: {exc}", file=sys.stderr)
    return res


def _worker(args):
    path, offset, nbytes = args
    with open(path, "rb") as fh:
        fh.seek(offset)
        raw = fh.read(nbytes)
    return run_sequence(np.unpackbits(np.frombuffer(raw, dtype=np.uint8)))


def assess(path, nseq, nbits, label, workers=None):
    nbytes = nbits // 8
    need = nseq * nbytes
    have = os.path.getsize(path)
    if have < need:
        raise SystemExit(f"{path}: need {need} bytes for {nseq}x{nbits} bits, "
                         f"have {have}")
    jobs = [(path, i * nbytes, nbytes) for i in range(nseq)]
    workers = workers or min(os.cpu_count() or 1, 8)
    with ProcessPoolExecutor(max_workers=workers) as ex:
        results = list(ex.map(_worker, jobs, chunksize=1))

    rows = []
    for lab in sorted({k for r in results for k in r}):
        ps = [r[lab] for r in results if lab in r]
        ps = [p for p in ps if not math.isnan(p)]
        if not ps:
            continue
        m = len(ps)
        passed = sum(1 for p in ps if p >= ALPHA)
        prop = passed / m
        sigma = math.sqrt(ALPHA * (1 - ALPHA) / m)
        lo = (1 - ALPHA) - 3 * sigma
        hi = (1 - ALPHA) + 3 * sigma
        hist = np.histogram(np.clip(ps, 0, 1), bins=10, range=(0, 1))[0]
        chi2 = float(np.sum((hist - m / 10.0) ** 2) / (m / 10.0))
        unif = _igamc(4.5, chi2 / 2.0)
        ok = (prop >= lo) and (unif >= 0.0001)
        # How often this sub-test rejects a *perfect* generator. The proportion
        # band is a 3-sigma normal approximation applied to a discrete binomial
        # count, so its true false-rejection rate is not 0.0027 and is not even
        # constant across sub-tests -- it depends on how m interacts with the
        # discreteness. Computing it exactly is what makes the suite-level
        # verdict below meaningful rather than a guess.
        k_min = math.ceil(lo * m - 1e-12)
        q = float(binom.cdf(k_min - 1, m, 1.0 - ALPHA)) + 0.0001
        rows.append(dict(label=label, subtest=lab, sequences=m, passed=passed,
                         proportion=prop, prop_min=lo, prop_max=min(hi, 1.0),
                         uniformity_p=unif, false_reject_prob=q,
                         verdict="PASS" if ok else "FAIL"))
    return rows


def suite_verdict(rows):
    """Aggregate sub-test results into one verdict for the stream.

    With ~190 sub-tests run at alpha = 0.01, a perfect generator is *expected*
    to fail a few of them; reporting "3 sub-tests failed" without saying how
    many were expected says nothing. This sums each sub-test's exact
    false-rejection probability to get the expected number of failures under
    the null hypothesis, then asks how surprising the observed count is.

    The sub-tests share sequences and so are not independent, which makes the
    Poisson tail an approximation rather than an exact level. It is used only
    to separate "a handful of failures, as expected" from "this stream is
    structured", which is a wide enough gap for the approximation to carry.
    """
    if not rows:
        return dict(subtests=0, failed=0, expected_failures=0.0,
                    p_suite=float("nan"), verdict="NO DATA")
    f = sum(1 for r in rows if r["verdict"] == "FAIL")
    e = sum(r["false_reject_prob"] for r in rows)
    p = float(poisson.sf(f - 1, e)) if f > 0 else 1.0
    return dict(subtests=len(rows), failed=f, expected_failures=e,
                p_suite=p, verdict="PASS" if p >= 0.01 else "FAIL")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("stream")
    ap.add_argument("--seqs", type=int, default=128)
    ap.add_argument("--bits", type=int, default=1000000)
    ap.add_argument("--label", default=None)
    ap.add_argument("--detail", default=None)
    ap.add_argument("--summary", default=None)
    ap.add_argument("--workers", type=int, default=None)
    a = ap.parse_args()
    label = a.label or os.path.basename(a.stream)

    rows = assess(a.stream, a.seqs, a.bits, label, a.workers)
    if not rows:
        raise SystemExit(f"{label}: no test produced a p-value")
    sv = suite_verdict(rows)
    worst = min(r["proportion"] for r in rows)
    print(f"{label}: {sv['subtests']} sub-tests, {sv['failed']} failed "
          f"(expected {sv['expected_failures']:.2f} by chance), "
          f"suite p={sv['p_suite']:.4g}, min proportion {worst:.4f} "
          f"-> {sv['verdict']}")
    for r in rows:
        if r["verdict"] == "FAIL":
            print(f"    fail {r['subtest']:<40s} prop={r['proportion']:.4f} "
                  f"(min {r['prop_min']:.4f})  unif={r['uniformity_p']:.6f}")

    import csv
    if a.detail:
        newfile = not os.path.exists(a.detail)
        with open(a.detail, "a", newline="") as fh:
            w = csv.DictWriter(fh, fieldnames=list(rows[0].keys()))
            if newfile:
                w.writeheader()
            w.writerows(rows)
    if a.summary:
        row = dict(label=label, **sv)
        newfile = not os.path.exists(a.summary)
        with open(a.summary, "a", newline="") as fh:
            w = csv.DictWriter(fh, fieldnames=list(row.keys()))
            if newfile:
                w.writeheader()
            w.writerow(row)
    return 0 if sv["verdict"] == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
