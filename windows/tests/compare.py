# Compares the JUCE engine's render (pnrender) with the Mac engine's (selftest --render): every outlet's level
# must match within 2 %. Usage: python compare.py mac.txt juce.txt
import sys
def load(f):
    d = {}
    for l in open(f):
        p = l.split()
        if len(p) >= 2: d[int(p[0])] = (p[1], [float(x) for x in p[2:]])
    return d
a, b = load(sys.argv[1]), load(sys.argv[2])
bad = 0
for i in sorted(a):
    k, x = a[i]; y = b.get(i, (k, []))[1]
    if len(x) != len(y) or any(abs(p - q) > max(0.02 * max(abs(p), abs(q)), 0.002) for p, q in zip(x, y)):
        bad += 1; print("differs:", i, k, x, y)
print(f"{len(a) - bad} of {len(a)} modules match the Mac engine")
sys.exit(1 if bad else 0)
