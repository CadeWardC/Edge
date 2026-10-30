import numpy as np, sys, time
from tone import analyze, SR

rng = np.random.default_rng(int(sys.argv[1]) if len(sys.argv) > 1 else 0)

# pitch shapes in semitones relative to the speaker's mid pitch
def contour(tone, n, position_last):
    t = np.linspace(0, 1, n)
    if tone == 1: c = 4 + 0 * t
    if tone == 2: c = -1 + 6 * t ** 1.5
    if tone == 3: c = (-2 - 4 * np.sin(np.pi * t * 0.8)) if position_last else (-2 - 4 * np.minimum(t * 2, 1))
    if tone == 4: c = 6 - 9 * t
    return c + rng.normal(0, 0.3, n)

def synth(tones, base_hz):
    out = []
    phase = 0.0
    for k, tone in enumerate(tones):
        dur = rng.uniform(0.18, 0.32)
        n = int(dur * SR)
        st = contour(tone, n, k == len(tones) - 1) * rng.uniform(0.8, 1.2)
        f0 = base_hz * 2 ** (st / 12)
        ph = phase + 2 * np.pi * np.cumsum(f0) / SR
        phase = ph[-1]
        sig = sum((0.7 ** h) * np.sin(h * ph) for h in range(1, 12))
        env = np.sin(np.pi * np.linspace(0, 1, n)) ** 0.6
        sig = sig * env
        if k > 0 and rng.random() < 0.5:   # consonant: unvoiced noise between syllables
            out.append(rng.normal(0, 0.15, int(rng.uniform(0.04, 0.09) * SR)))
        out.append(sig)
    x = np.concatenate([np.zeros(SR // 5)] + out + [np.zeros(SR // 5)])
    return x + rng.normal(0, 0.01, len(x))

total = correct = confident = conf_correct = 0
t0 = time.time()
for trial in range(40):
    n = int(rng.integers(3, 8))
    tones = list(rng.integers(1, 5, n))
    base = rng.choice([110.0, 210.0])
    res = analyze(synth(tones, base), n)
    for i, tone in enumerate(tones):
        total += 1
        if i < len(res):
            got, margin = res[i]
            correct += got == tone
            if margin > 0.35:
                confident += 1
                conf_correct += got == tone
print(f"accuracy {correct/total:.0%} on {total} syllables; confident {confident/total:.0%} of them at {conf_correct/max(confident,1):.0%}; {time.time()-t0:.1f}s")
