"""Prototype of the on-device tone checker (ported to Swift afterwards)."""
import numpy as np

SR = 16000
HOP = 160          # 10 ms
WIN = 512          # 32 ms
FMIN, FMAX = 70.0, 450.0


def yin(x):
    """Returns per-frame (f0 Hz or 0, rms) using YIN with parabolic interpolation."""
    tau_min, tau_max = int(SR / FMAX), int(SR / FMIN)
    n = 1 + max(0, (len(x) - WIN - tau_max) // HOP)
    f0 = np.zeros(n)
    rms = np.zeros(n)
    for i in range(n):
        s = i * HOP
        frame = x[s:s + WIN + tau_max]
        w = frame[:WIN]
        rms[i] = np.sqrt(np.mean(w * w))
        # difference function d(tau) = sum (x_j - x_{j+tau})^2
        e0 = np.dot(w, w)
        d = np.empty(tau_max + 1)
        d[0] = 0
        for tau in range(1, tau_max + 1):
            v = frame[tau:tau + WIN]
            d[tau] = e0 + np.dot(v, v) - 2 * np.dot(w, v)
        cmnd = np.ones_like(d)
        cs = np.cumsum(d[1:])
        cmnd[1:] = d[1:] * np.arange(1, tau_max + 1) / np.maximum(cs, 1e-12)
        tau = 0
        for t in range(tau_min, tau_max):
            if cmnd[t] < 0.15:
                while t + 1 < tau_max and cmnd[t + 1] < cmnd[t]:
                    t += 1
                tau = t
                break
        if tau == 0:
            continue
        a, b, c = cmnd[tau - 1], cmnd[tau], cmnd[tau + 1]
        den = a - 2 * b + c
        shift = 0.5 * (a - c) / den if abs(den) > 1e-12 else 0
        f0[i] = SR / (tau + shift)
    return f0, rms


def segment(voiced, energy_db, n_target):
    """Splits voiced frames into n_target syllables: merge across the shortest gaps, split at energy dips."""
    runs, start = [], None
    for i, v in enumerate(np.append(voiced, False)):
        if v and start is None:
            start = i
        elif not v and start is not None:
            if i - start >= 4:
                runs.append([start, i])
            start = None
    if not runs or n_target <= 0:
        return []
    while len(runs) > n_target:
        gaps = [runs[k + 1][0] - runs[k][1] for k in range(len(runs) - 1)]
        k = int(np.argmin(gaps))
        runs[k] = [runs[k][0], runs[k + 1][1]]
        del runs[k + 1]
    while len(runs) < n_target:
        k = int(np.argmax([r[1] - r[0] for r in runs]))
        a, b = runs[k]
        if b - a < 10:
            break
        lo, hi = a + (b - a) // 5, b - (b - a) // 5
        e = np.convolve(energy_db[a:b], np.ones(5) / 5, mode="same")
        cut = a + (lo - a) + int(np.argmin(e[lo - a:hi - a]))
        runs[k:k + 1] = [[a, cut], [cut, b]]
    return runs


# templates on a 1..5 pitch scale (speaker-normalized), 5 points across the syllable
TEMPLATES = [
    (1, np.array([4.3, 4.3, 4.3, 4.3, 4.3])),
    (2, np.array([2.8, 2.9, 3.4, 4.0, 4.6])),
    (3, np.array([2.4, 1.7, 1.2, 1.3, 2.2])),   # full dip
    (3, np.array([2.2, 1.7, 1.3, 1.2, 1.2])),   # half third (low, mid-sentence)
    (4, np.array([4.8, 4.3, 3.4, 2.5, 1.7])),
]


def classify(contour):
    """contour: 1..5 scale values. Returns (tone, margin)."""
    pts = np.interp(np.linspace(0, 1, 5), np.linspace(0, 1, len(contour)), contour)
    best = {}
    for tone, tmpl in TEMPLATES:
        dist = np.sqrt(np.mean((pts - tmpl) ** 2))
        best[tone] = min(best.get(tone, 9e9), dist)
    ranked = sorted(best.items(), key=lambda kv: kv[1])
    return ranked[0][0], ranked[1][1] - ranked[0][1]


def analyze(x, n_syll):
    f0, rms = yin(x)
    db = 20 * np.log10(rms + 1e-9)
    voiced = (f0 > 0) & (db > db.max() - 35)
    if voiced.sum() < 5:
        return []
    st = 12 * np.log2(np.where(voiced, f0, 1) / 100.0)
    lo, hi = np.percentile(st[voiced], 5), np.percentile(st[voiced], 95)
    span = max(hi - lo, 4.0)  # at least 4 semitones, so a monotone speaker isn't stretched
    mid = (lo + hi) / 2
    scale = 3 + (st - mid) / span * 4   # roughly 1..5
    out = []
    for a, b in segment(voiced, db, n_syll):
        idx = [i for i in range(a, b) if voiced[i]]
        k = len(idx)
        idx = idx[k // 10: k - k // 10] or idx  # skip onsets/offsets
        c = np.array([scale[i] for i in idx])
        if len(c) >= 5:
            c = np.array([np.median(c[max(0, j - 2):j + 3]) for j in range(len(c))])
        out.append(classify(c) if len(c) >= 3 else (0, 0.0))
    return out
