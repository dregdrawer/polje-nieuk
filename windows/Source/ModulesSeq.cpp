// keys~, seq~, turing~, roll~, drums~, div~, chord~ — ports of Sequencing.swift and Chords.swift.
#include "Modules.h"
#include "ModulesShared.h"

namespace pn {

namespace Scales {
const std::vector<std::string> names = { "chromatic", "major", "minor", "dorian", "phrygian", "mixolydian",
                                         "pentatonic maj", "pentatonic min", "blues", "whole tone" };
static const std::vector<std::vector<int>> degrees = { { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 }, { 0, 2, 4, 5, 7, 9, 11 }, { 0, 2, 3, 5, 7, 8, 10 },
    { 0, 2, 3, 5, 7, 9, 10 }, { 0, 1, 3, 5, 7, 8, 10 }, { 0, 2, 4, 5, 7, 9, 10 }, { 0, 2, 4, 7, 9 }, { 0, 3, 5, 7, 10 },
    { 0, 3, 5, 6, 7, 10 }, { 0, 2, 4, 6, 8, 10 } };
float quantize(float semis, int scale) {
    auto& d = degrees[size_t(std::clamp(scale, 0, int(degrees.size()) - 1))];
    float n = std::round(semis), oct = std::floor(n / 12), within = n - oct * 12;
    float best = float(d[0]), bestDist = 99;
    for (int deg : d)
        for (int o = -12; o <= 12; o += 12) {
            float c = float(deg + o), dist = std::abs(c - within);
            if (dist < bestDist) { bestDist = dist; best = c; }
        }
    return oct * 12 + best;
}
}

// ---------------------------------------------------------------- keys~

KeysNode::KeysNode(const ModuleSpec& s, double sr) : DSPNode(s, sr) { keyLane.fill(-1); }

void KeysNode::setData(const std::string& key, const std::vector<float>& values) {
    if (key != laneKey) return;
    bool any = false;
    for (int k = 0; k < autoSlots; ++k) {
        float v = k < int(values.size()) && std::isfinite(values[size_t(k)]) ? values[size_t(k)] : -1.0f;
        keyLane[size_t(k)] = v;
        if (v >= 0) any = true;
    }
    keyLaneOn = any;
}

void KeysNode::toggleLatched(int k) {
    if (k < 0 || k >= keyCount) return;
    if (latched[size_t(k)] > 0.5f) latched[size_t(k)] = 0;
    else { order[size_t(k)] = ++orderCounter; latched[size_t(k)] = 1; }
}

void KeysNode::process(int frames, const float* const*, uint64_t, ProcessContext& ctx) {
    float baseNote = std::round(params[0]) * 12 - 12;
    float glide = onePoleCoef(params[1], sampleRate);
    int mode = clampIndex(params[2], 6);
    double div = Divisions::beats(params[3]);
    float gateLen = std::clamp(params[4], 0.05f, 1.0f);
    int octs = clampIndex(params[5] - 1, 3) + 1;
    bool latch = params[6] > 0.5f;
    float* pOut = out(0); float* gOut = out(1); float* vOut = out(2);
    int touch = touchNote.load(), pc = pressCount.load(), pn = pressNote.load();
    bool newPress = pc != seenPress && pn >= 0 && pn < keyCount;
    seenPress = pc;
    int slot = std::clamp(int(autoPosition), 0, autoSlots - 1);
    if (recordingKeys.load()) {
        int k = touch >= 0 ? touch : (newPress ? pn : -1);
        if (!recStarted && k >= 0) { recStarted = true; recLast = (slot + autoSlots - 1) % autoSlots; }
        if (recStarted) {
            int s = recLast, n = 0;
            while (s != slot && n < autoSlots) { s = (s + 1) % autoSlots; keyLane[size_t(s)] = float(k); ++n; }
            if (newPress) keyLane[size_t(slot)] = float(pn);
            recLast = slot; recordedKeys = true; keyLaneOn = true;
        }
    } else recStarted = false;
    int laneKeyNow = -1;
    if (keyLaneOn && !recordingKeys.load() && ctx.running && touch < 0) {
        int v = int(keyLane[size_t(slot)]);
        laneKeyNow = v >= 0 && v < keyCount ? v : -1;
    }
    if (laneKeyNow >= 0) {
        touch = laneKeyNow;
        if (laneKeyNow != laneKeyPrev && !newPress) { newPress = true; pn = laneKeyNow; }
    }
    laneKeyPrev = laneKeyNow;
    int count = 0;
    if (latch) for (int k = 0; k < keyCount; ++k) if (latched[size_t(k)] > 0.5f) scratch[size_t(count++)] = k;
    if (touch >= 0 && !(latch && latched[size_t(touch)] > 0.5f)) scratch[size_t(count++)] = touch;
    if (mode == 5)
        for (int a = 0; a < count; ++a)
            for (int b = a + 1; b < count; ++b)
                if (order[size_t(scratch[size_t(b)])] < order[size_t(scratch[size_t(a)])]) std::swap(scratch[size_t(a)], scratch[size_t(b)]);
    int total = 0;
    for (int o = 0; o < octs; ++o)
        for (int k = 0; k < count; ++k) { scratch[size_t(keyCount + total)] = scratch[size_t(k)] + o * 12; if (++total >= keyCount * 2) break; }
    int minHold = int(sampleRate * 0.08);
    for (int i = 0; i < frames; ++i) {
        if (mode == 0) {
            if (newPress && i == 0) { if (gateOn && pn != note) dip = 48; note = pn; holdLeft = minHold; }
            int held = touch >= 0 ? touch : (holdLeft > 0 ? note : (latch && count > 0 ? scratch[size_t(count - 1)] : -1));
            if (holdLeft > 0) --holdLeft;
            if (held >= 0) note = held;
            if (touch >= 0 && lastTouch >= 0 && touch != lastTouch) dip = 48;
            gateOn = held >= 0 && dip == 0;
            if (dip > 0) --dip;
        } else {
            bool fire = clock.tick(ctx.beat[i], div, ctx.samplesPerBeat, nullptr);
            if (newPress && i == 0 && !anyHeldBefore) {
                note = pn; arpIndex = -1;
                gateLeft = std::max(int(sampleRate * 0.08), int(float(clock.stepSamples) * gateLen));
            }
            if (fire && total > 0) {
                switch (mode) {
                    case 1: arpIndex = (arpIndex + 1) % total; break;
                    case 2: arpIndex = arpIndex <= 0 ? total - 1 : arpIndex - 1; break;
                    case 3:
                        if (total == 1) arpIndex = 0;
                        else { if (arpIndex + arpDir >= total || arpIndex + arpDir < 0) arpDir = -arpDir; arpIndex = std::clamp(arpIndex + arpDir, 0, total - 1); }
                        break;
                    case 4: arpIndex = std::min(int(rng.next() * float(total)), total - 1); break;
                    default: arpIndex = (arpIndex + 1) % total;
                }
                note = scratch[size_t(keyCount + std::min(arpIndex, total - 1))];
                gateLeft = std::max(16, int(float(clock.stepSamples) * gateLen));
            }
            if (total == 0) arpIndex = -1;
            gateOn = false;
        }
        lastTouch = touch;
        float target = baseNote + float(std::max(note, 0));
        pitchNow += (target - pitchNow) * glide;
        pOut[i] = pitchCV(pitchNow);
        gOut[i] = (mode == 0 ? gateOn : gateLeft > 0) ? kGateHigh : 0.0f;
        if (gateLeft > 0) --gateLeft;
        vOut[i] = note >= 0 ? 0.8f : 0.0f;
    }
    anyHeldBefore = total > 0;
    readouts[0] = float(gOut[frames - 1] > 0 ? note : -1);
}

// ---------------------------------------------------------------- seq~

void SeqNode::setData(const std::string& key, const std::vector<float>& values) {
    auto* dst = key == "pitch" ? &pitches : (key == "gate" ? &gates : nullptr);
    if (!dst || values.empty()) return;
    for (int k = 0; k < steps; ++k) { float v = values[size_t(k) % values.size()]; (*dst)[size_t(k)] = std::isfinite(v) ? v : 0.0f; }
}

void SeqNode::process(int frames, const float* const* in, uint64_t con, ProcessContext& ctx) {
    int len = length(params[0]);
    double div = Divisions::beats(params[1]);
    int direction = clampIndex(params[2], 4);
    float gateLen = std::clamp(params[3], 0.05f, 1.0f);
    int scale = clampIndex(params[4], int(Scales::names.size()));
    float transpose = std::round(params[5]);
    bool hasClock = isConnected(con, 0), hasReset = isConnected(con, 1);
    const float* ck = in[0]; const float* rs = in[1];
    float* pOut = out(0); float* gOut = out(1);
    if (ctx.stopPending) { step = -1; dir = 1; clock.restart(); }
    int cvStep = -2; float cv = 0;
    for (int i = 0; i < frames; ++i) {
        if (hasReset && clock.resetEdge.rising(rs[i])) { step = -1; dir = 1; clock.restart(); }
        if (clock.tick(ctx.beat[i], div, ctx.samplesPerBeat, hasClock ? &ck[i] : nullptr, ctx.running)) {
            switch (direction) {
                case 1: step = step <= 0 ? len - 1 : step - 1; break;
                case 2:
                    if (len == 1) step = 0;
                    else { if (step + dir >= len || step + dir < 0) dir = -dir; step = std::clamp(step + dir, 0, len - 1); }
                    break;
                case 3: step = std::min(int(rng.next() * float(len)), len - 1); break;
                default: step = (step + 1) % len;
            }
            if (!hasClock && direction == 0) step = safeInt(std::floor(ctx.beat[i] / div)) % len;
            gateLeft = gates[size_t(step)] > 0.5f ? std::max(16, int(float(clock.stepSamples) * gateLen)) : 0;
            if (gates[size_t(step)] > 0.5f) heldStep = step;
        }
        int s = heldStep >= 0 ? heldStep : std::max(step, 0);
        if (s != cvStep) { cvStep = s; cv = pitchCV(Scales::quantize(pitches[size_t(s)] + transpose, scale)); }
        pOut[i] = cv;
        gOut[i] = gateLeft > 0 ? kGateHigh : 0.0f;
        if (gateLeft > 0) --gateLeft;
    }
    readouts[0] = float(step);
}

// ---------------------------------------------------------------- turing~

void TuringNode::process(int frames, const float* const* in, uint64_t con, ProcessContext& ctx) {
    float change = std::clamp(params[0], 0.0f, 1.0f);
    uint64_t len = uint64_t(length(params[1]));
    float range = float(clampIndex(params[2] - 1, 4) + 1);
    int scale = clampIndex(params[3], int(Scales::names.size()));
    double div = Divisions::beats(params[4]);
    float gateLen = std::clamp(params[5], 0.05f, 1.0f);
    float octave = float(clampIndex(params[6] + 3, 7) - 3) * 12;
    float density = std::clamp(params[7], 0.0f, 1.0f);
    bool hasClock = isConnected(con, 0), hasReset = isConnected(con, 1);
    const float* ck = in[0]; const float* rs = in[1];
    float* pOut = out(0); float* gOut = out(1); float* cOut = out(2);
    uint64_t mask = len >= 64 ? ~uint64_t(0) : (uint64_t(1) << len) - 1;
    if (ctx.stopPending) clock.restart();
    for (int i = 0; i < frames; ++i) {
        if (hasReset && clock.resetEdge.rising(rs[i])) { reg = seed; clock.restart(); }
        if (clock.tick(ctx.beat[i], div, ctx.samplesPerBeat, hasClock ? &ck[i] : nullptr, ctx.running)) {
            uint64_t bit = (reg >> (len - 1)) & 1;
            if (rng.next() < change) bit ^= 1;
            reg = ((reg << 1) | bit) & mask;
            cvNow = float(reg & 0xFF) / 255;
            bool p = plays(reg, density);
            gateLeft = p ? std::max(16, int(float(clock.stepSamples) * gateLen)) : 0;
            if (p) noteNow = Scales::quantize(cvNow * range * 12, scale) + octave;
            head = (head + 1) % historyLength;
        }
        pOut[i] = pitchCV(noteNow);
        gOut[i] = gateLeft > 0 ? kGateHigh : 0.0f;
        cOut[i] = cvNow;
        if (gateLeft > 0) --gateLeft;
    }
    readouts[0] = float(reg & 0xFFFF); readouts[1] = float(len); readouts[2] = cvNow;
    readouts[3] = float((reg >> 16) & 0xFFFF); readouts[5] = range;
    readouts[6] = float((reg >> 32) & 0xFFFF); readouts[7] = float((reg >> 48) & 0xFFFF);
    regNow = reg & mask;
    if (--displayCountdown <= 0) {
        displayCountdown = 4;
        uint64_t st = reg & mask, bits = 0;
        for (int k = 0; k < int(len); ++k) {
            if (plays(st, density)) bits |= uint64_t(1) << k;
            loopNotes[size_t(k)] = Scales::quantize(float(st & 0xFF) / 255 * range * 12, scale) + octave;
            st = ((st << 1) | ((st >> (len - 1)) & 1)) & mask;
        }
        playsBits = bits;
        uint32_t h = uint32_t(bits ^ (bits >> 32));
        for (int k = 0; k < int(len); ++k) h = h * 31u + uint32_t(int32_t(loopNotes[size_t(k)]));
        readouts[4] = float(h & 0xFFFFFF);
    }
}

// ---------------------------------------------------------------- roll~

void RollNode::process(int frames, const float* const*, uint64_t, ProcessContext& ctx) {
    int len = clampIndex(params[0] - 1, steps) + 1;
    double div = Divisions::beats(params[1]);
    float low = std::round(params[2]);
    float gateLen = std::clamp(params[3], 0.05f, 1.0f);
    int V = 1;
    for (int s = 0; s < len; ++s) {
        int c = 0;
        for (int r = 0; r < rows; ++r) if (grid[size_t(r * steps + s)] > 0.5f) ++c;
        V = std::max(V, c);
    }
    V = std::min(V, int(voices));
    for (int k = 0; k < 3; ++k) outVoices[size_t(k)] = V;
    for (int i = 0; i < frames; ++i) {
        if (clock.tick(ctx.beat[i], div, ctx.samplesPerBeat, nullptr)) {
            step = safeInt(std::floor(ctx.beat[i] / div)) % len;
            int v = 0;
            for (int r = 0; r < rows && v < voices; ++r) if (grid[size_t(r * steps + step)] > 0.5f) { held[v] = float(r); on[v] = true; ++v; }
            for (int k = v; k < voices; ++k) on[k] = false;
            gateLeft = v > 0 ? std::max(16, int(float(clock.stepSamples) * gateLen)) : 0;
        }
        for (int v = 0; v < V; ++v) {
            bool g = gateLeft > 0 && on[v];
            outVoice(0, v)[i] = pitchCV(low + held[v]);
            outVoice(1, v)[i] = g ? kGateHigh : 0.0f;
            outVoice(2, v)[i] = g ? 0.8f : 0.0f;
        }
        if (gateLeft > 0) --gateLeft;
    }
    readouts[0] = float(step);
}

// ---------------------------------------------------------------- drums~

void DrumsNode::process(int frames, const float* const*, uint64_t, ProcessContext& ctx) {
    int len = clampIndex(params[0] - 1, steps) + 1;
    double div = Divisions::beats(params[1]);
    int trig = std::max(16, safeInt(double(params[2]) * 0.001 * sampleRate));
    for (int i = 0; i < frames; ++i) {
        if (clock.tick(ctx.beat[i], div, ctx.samplesPerBeat, nullptr)) {
            step = safeInt(std::floor(ctx.beat[i] / div)) % len;
            for (int l = 0; l < lanes; ++l) if (hits[size_t(l * steps + step)] > 0.5f) left[l] = trig;
        }
        for (int l = 0; l < lanes; ++l) { out(l)[i] = left[l] > 0 ? kGateHigh : 0.0f; if (left[l] > 0) --left[l]; }
    }
    readouts[0] = float(step);
}

// ---------------------------------------------------------------- div~

class DividerNode : public DSPNode {
public:
    using DSPNode::DSPNode;
    static double baseBeats(float v) { int i = clampIndex(v, 17); return i == 0 ? 0.0625 : Divisions::beats(float(i - 1)); }
    static int ratio(float v) {
        static const int mult[] = { 16, 12, 8, 6, 4, 3, 2 };
        int i = clampIndex(v, 7 + 64);
        return i < 7 ? -mult[i] : i - 7 + 1;
    }
    void process(int frames, const float* const* in, uint64_t con, ProcessContext& ctx) override {
        bool hasClock = isConnected(con, 0), hasReset = isConnected(con, 1);
        const float* clk = in[0]; const float* rst = in[1];
        bool square = params[0] > 0.5f;
        double base = baseBeats(params[1]);
        int offset = std::max(std::isfinite(params[2]) ? int(std::round(params[2])) : 0, 0);
        int d[8];
        for (int k = 0; k < 8; ++k) d[k] = ratio(params[size_t(3 + k)]);
        double internalPeriod = std::max(base * ctx.samplesPerBeat, 1.0);
        if (ctx.stopPending) count = -1;
        if (!ctx.running) {
            for (int i = 0; i < frames; ++i) clockEdge.rising(hasClock ? clk[i] : 0);
            for (int k = 0; k < 8; ++k) std::fill(out(k), out(k) + frames, 0.0f);
            readouts[0] = float(count);
            return;
        }
        for (int i = 0; i < frames; ++i) {
            if (hasReset && resetEdge.rising(rst[i])) count = -1;
            float c; double phase;
            if (hasClock) { c = clk[i]; ++sinceEdge; phase = std::min(double(sinceEdge) / double(std::max(period, 1)), 0.999); }
            else { double pos = ctx.beat[i] / base; phase = pos - std::floor(pos); c = phase < 0.5 ? 1.0f : 0.0f; period = int(internalPeriod); }
            if (clockEdge.rising(c)) {
                ++count;
                if (hasClock) { if (sinceEdge > 16 && count > 0) period = sinceEdge; sinceEdge = 0; phase = 0; }
            }
            bool clockHigh = clockEdge.high;
            for (int k = 0; k < 8; ++k) {
                float* o = out(k);
                if (count < 0) { o[i] = 0; continue; }
                int n = d[k];
                if (n < 0) {
                    double m = -n, sub = phase * m, f = sub - std::floor(sub);
                    double width = square ? 0.5 : std::min(0.5, 0.005 * sampleRate * m / double(std::max(period, 1)));
                    o[i] = f < width ? kGateHigh : 0.0f;
                    continue;
                }
                int pos = (count + offset) % n;
                bool on = square ? (n == 1 ? clockHigh : pos < (n + 1) / 2) : (pos == 0 && clockHigh);
                o[i] = on ? kGateHigh : 0.0f;
            }
        }
        readouts[0] = float(count);
    }
private:
    EdgeDetector clockEdge, resetEdge;
    int count = -1, sinceEdge = 0, period = 12000;
};

// ---------------------------------------------------------------- chord~

namespace Chords {
const std::vector<std::string> keys = { "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" };
const std::vector<std::string> scales = { "major", "minor", "dorian", "phrygian", "lydian", "mixolydian", "harmonic minor", "melodic minor" };
static const std::vector<std::vector<int>> scaleSteps = { { 0, 2, 4, 5, 7, 9, 11 }, { 0, 2, 3, 5, 7, 8, 10 }, { 0, 2, 3, 5, 7, 9, 10 }, { 0, 1, 3, 5, 7, 8, 10 },
    { 0, 2, 4, 6, 7, 9, 11 }, { 0, 2, 4, 5, 7, 9, 10 }, { 0, 2, 3, 5, 7, 8, 11 }, { 0, 2, 3, 5, 7, 9, 11 } };
const std::vector<std::string> degrees = { "I", "II", "III", "IV", "V", "VI", "VII" };
const std::vector<std::string> sizes = { "triad", "seventh", "ninth", "sus2", "sus4" };
const std::vector<std::string> types = { "maj", "min", "7", "maj7", "m7", "sus2", "sus4", "dim", "aug", "6", "m6", "add9", "9", "m9",
                                         "m7\xe2\x99\xad" "5", "dim7" };
static const std::vector<std::vector<int>> typeIntervals = { { 0, 4, 7 }, { 0, 3, 7 }, { 0, 4, 7, 10 }, { 0, 4, 7, 11 }, { 0, 3, 7, 10 }, { 0, 2, 7 }, { 0, 5, 7 },
    { 0, 3, 6 }, { 0, 4, 8 }, { 0, 4, 7, 9 }, { 0, 3, 7, 9 }, { 0, 4, 7, 14 }, { 0, 4, 10, 14 }, { 0, 3, 10, 14 }, { 0, 3, 6, 10 }, { 0, 3, 6, 9 } };
const std::vector<std::string> spreads = { "close", "open", "drop 2", "wide" };
const std::vector<std::string> directions = { "up", "down", "alternate" };

Built build(int mode, int key, int scale, int degree, int size, int type, int voices, int inversion, int spread,
            int octave, float shift, const std::vector<float>* previous) {
    std::vector<int> iv; int root, quality;
    if (mode == 0) {
        auto& st = scaleSteps[size_t(scale)];
        auto note = [&](int k) { return st[size_t(((k % 7) + 7) % 7)] + 12 * int(std::floor(double(k) / 7)); };
        std::vector<int> picks;
        switch (size) { case 1: picks = { 0, 2, 4, 6 }; break; case 2: picks = { 0, 2, 4, 6, 8 }; break;
                        case 3: picks = { 0, 1, 4 }; break; case 4: picks = { 0, 3, 4 }; break; default: picks = { 0, 2, 4 }; }
        int base = note(degree);
        for (int p : picks) iv.push_back(note(degree + p) - base);
        root = (key + base) % 12;
        auto find = [&](const std::vector<int>& v) { for (size_t t = 0; t < typeIntervals.size(); ++t) if (typeIntervals[t] == v) return int(t); return -1; };
        quality = find(iv);
        if (quality < 0) quality = find(std::vector<int>(iv.begin(), iv.begin() + std::min<size_t>(4, iv.size())));
        for (auto& x : iv) x += base;
    } else { iv = typeIntervals[size_t(type)]; root = key; quality = type; }
    std::vector<int> n = iv;
    while (int(n.size()) > voices) {
        int five = -1;
        for (size_t k = 1; k < n.size(); ++k) if ((n[k] - n[0]) % 12 == 7) { five = int(k); break; }
        if (five < 0) { if (n.size() > 1) five = 1; else break; }
        n.erase(n.begin() + five);
    }
    while (int(n.size()) < voices) n.push_back(n[0] + 12 * (1 + (int(n.size()) - 1) / 3));
    std::sort(n.begin(), n.end());
    float center = float(key + 12 * octave) + shift;
    auto voiced = [&](int inv, int oct) {
        std::vector<int> v = n;
        for (int k = 0; k < inv; ++k) { int lo = v.front(); v.erase(v.begin()); v.push_back(lo + 12); }
        switch (spread) {
            case 1: if (v.size() > 1) v[1] += 12; break;
            case 2: if (v.size() > 2) v[v.size() - 2] -= 12; break;
            case 3: if (v.size() > 1) v[1] += 12; if (v.size() > 3) v[3] += 12; break;
            default: break;
        }
        std::vector<float> r;
        for (int x : v) r.push_back(float(x + 12 * oct) + center);
        std::sort(r.begin(), r.end());
        return r;
    };
    auto best = voiced(inversion % std::max(int(n.size()), 1), 0);
    if (previous && previous->size() == n.size()) {
        float score = INFINITY;
        for (int inv = 0; inv < int(n.size()); ++inv)
            for (int oct = -1; oct <= 1; ++oct) {
                auto c = voiced(inv, oct);
                float d = 0;
                for (size_t k = 0; k < c.size(); ++k) d += std::abs(c[k] - (*previous)[k]);
                if (d < score) { score = d; best = c; }
            }
    }
    return { best, root, quality };
}
}

class ChordNode : public DSPNode {
public:
    static constexpr int maxVoices = kMaxVoices;
    using DSPNode::DSPNode;
    void process(int frames, const float* const* in, uint64_t con, ProcessContext&) override {
        int mode = clampIndex(params[0], 2), key = clampIndex(params[1], 12), scale = clampIndex(params[2], 8);
        int degree = clampIndex(params[3], 7), size = clampIndex(params[4], 5), type = clampIndex(params[5], 16);
        int voices = clampIndex(params[6], 2) + 3, inversion = clampIndex(params[7], 4), spread = clampIndex(params[8], 4);
        bool leading = params[9] > 0.5f; int octave = clampIndex(params[10] + 3, 7) - 3;
        int strum = std::max(0, int(params[11] * 0.001f * float(sampleRate)));
        int dir = clampIndex(params[12], 3);
        bool hasRoot = isConnected(con, 0), hasGate = isConnected(con, 1);
        float shift = hasRoot ? std::round(cvSemitones(in[0][frames - 1])) : 0.0f;
        unsigned long long h = (unsigned long long)mode;
        for (long long v : { (long long)key, (long long)scale, (long long)degree, (long long)size, (long long)type, (long long)voices, (long long)inversion, (long long)spread,
                        (long long)(leading ? 1 : 0), (long long)octave, (long long)shift }) h = h * 31 + (unsigned long long)v;
        bool changed = false;
        if (h != sig) {
            sig = h;
            auto c = Chords::build(mode, key, scale, degree, size, type, voices, inversion, spread, octave, shift,
                                   leading && int(last.size()) == voices ? &last : nullptr);
            for (int k = 0; k < maxVoices; ++k) notes[k] = k < int(c.notes.size()) ? c.notes[size_t(k)] : (c.notes.empty() ? 0 : c.notes.back());
            changed = c.notes != last;
            last = c.notes; count = int(c.notes.size());
            chordRoot = c.root; quality = c.quality;
        }
        auto order = [&](int k) { return dir == 1 ? count - 1 - k : dir == 2 ? (alternate ? count - 1 - k : k) : k; };
        auto strike = [&] {
            for (int k = 0; k < count; ++k) { startIn[k] = order(k) * strum; on[k] = false; }
            if (dir == 2) alternate = !alternate;
        };
        if (!hasGate && changed) { for (auto& o : on) o = false; retrig = std::max(16, int(0.003 * sampleRate)); }
        const float* g = in[1];
        outVoices[0] = count; outVoices[1] = count;
        for (int i = 0; i < frames; ++i) {
            if (hasGate) {
                if (gateEdge.rising(g[i])) { gateHigh = true; strike(); }
                else if (gateHigh && g[i] < 0.1f) { gateHigh = false; for (int k = 0; k < maxVoices; ++k) { on[k] = false; startIn[k] = -1; } }
            } else if (retrig > 0) { if (--retrig == 0) strike(); }
            else if (!on[0] && startIn[0] < 0 && sig != 0x8000000000000000ull) strike();
            for (int k = 0; k < maxVoices; ++k) {
                if (startIn[k] >= 0) { if (startIn[k] == 0) on[k] = true; --startIn[k]; }
                if (k >= count) continue;
                outVoice(0, k)[i] = pitchCV(notes[k]);
                outVoice(1, k)[i] = on[k] ? kGateHigh : 0.0f;
            }
        }
        for (int k = 0; k < maxVoices; ++k) readouts[size_t(k)] = notes[k];
        readouts[4] = float(count); readouts[5] = float(chordRoot); readouts[6] = float(quality);
    }
private:
    float notes[maxVoices] = {};
    int count = 3, retrig = 0, chordRoot = 0, quality = 0;
    std::vector<float> last;
    unsigned long long sig = 0x8000000000000000ull;
    EdgeDetector gateEdge;
    bool gateHigh = false, alternate = false, on[maxVoices] = {};
    int startIn[maxVoices] = { -1, -1, -1, -1 };
};

Factory factorySeq(const std::string& k) {
    if (k == "keys") return make<KeysNode>();
    if (k == "seq") return make<SeqNode>();
    if (k == "turing") return make<TuringNode>();
    if (k == "roll") return make<RollNode>();
    if (k == "drums") return make<DrumsNode>();
    if (k == "div") return make<DividerNode>();
    if (k == "chord") return make<ChordNode>();
    return nullptr;
}

} // namespace pn
