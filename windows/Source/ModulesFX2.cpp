// stretch~, freqshift~, chorus~, phaser~, redux~, shift~, autopan~, repeat~, comp~, limit~, gate~, eq~, peq~, scope~
// — ports of Spectral.swift, Modulation.swift, Dynamics.swift, ParametricEQ.swift, Scope.swift.
#include "Modules.h"
#include "Buffers.h"
#include "ModulesShared.h"
#include <complex>

namespace pn {

// ---------------------------------------------------------------- small radix-2 FFT (no scaling)

class FFT {
public:
    void setSize(int n) {
        if (n == size) return;
        size = n; bits = 0; while ((1 << bits) < n) ++bits;
        tw.resize(size_t(n / 2));
        for (int k = 0; k < n / 2; ++k) tw[size_t(k)] = std::polar(1.0f, -2 * juce::MathConstants<float>::pi * float(k) / float(n));
        rev.resize(size_t(n));
        for (int i = 0; i < n; ++i) { int r = 0; for (int b = 0; b < bits; ++b) if (i & (1 << b)) r |= 1 << (bits - 1 - b); rev[size_t(i)] = r; }
    }
    void run(std::complex<float>* x, bool inverse) const {
        for (int i = 0; i < size; ++i) if (rev[size_t(i)] > i) std::swap(x[i], x[rev[size_t(i)]]);
        for (int len = 2; len <= size; len <<= 1) {
            int half = len / 2, step = size / len;
            for (int i = 0; i < size; i += len)
                for (int k = 0; k < half; ++k) {
                    auto w = tw[size_t(k * step)];
                    if (inverse) w = std::conj(w);
                    auto u = x[i + k], v = x[i + k + half] * w;
                    x[i + k] = u + v; x[i + k + half] = u - v;
                }
        }
    }
private:
    int size = 0, bits = 0;
    std::vector<std::complex<float>> tw;
    std::vector<int> rev;
};

// ---------------------------------------------------------------- stretch~

class PaulStretchNode : public DSPNode, public SampleBufferNode {
public:
    static constexpr int sizes[] = { 2048, 4096, 8192, 16384 };
    static constexpr int maxN = 16384;
    PaulStretchNode(const ModuleSpec& s, double sr) : DSPNode(s, sr) {
        cap = int(sr * 60);
        bufL.assign(size_t(cap), 0); bufR.assign(size_t(cap), 0);
        window.assign(maxN, 0); accL.assign(maxN, 0); accR.assign(maxN, 0);
        spec.assign(maxN, {}); mag.assign(maxN / 2 + 1, 0);
    }
    void process(int frames, const float* const* in, uint64_t con, ProcessContext&) override {
        float* oL = out(0); float* oR = out(1);
        if (guard.busy()) { std::fill(oL, oL + frames, 0.0f); std::fill(oR, oR + frames, 0.0f); return; }
        if (consumeTrigger(0)) { recording = true; recLen = 0; }
        if (consumeTrigger(1) && recording) finishRecording();
        if (consumeTrigger(2)) { length = 0; recording = false; ++version; }
        int size = sizes[clampIndex(params[4], 4)];
        if (size != n) configure(size);
        double stretch = params[3];
        double lo = std::clamp(params[5], 0.0f, 1.0f), hi = std::clamp(params[6], 0.0f, 1.0f);
        if (hi < lo) std::swap(lo, hi);
        float level = params[8]; bool monitor = params[9] > 0.5f;
        const float* inL = in[0]; const float* inR = isConnected(con, 1) ? in[1] : in[0];
        const float* recIn = in[2]; const float* frz = in[3];
        bool hasRec = isConnected(con, 2), hasFrz = isConnected(con, 3);
        int L = length;
        int rlo = int(lo * L), rhi = std::max(int(hi * L), std::min(rlo + n + 1, L));
        for (int i = 0; i < frames; ++i) {
            float xl = inL[i], xr = inR[i];
            if (hasRec && recGate.rising(recIn[i])) { if (recording) finishRecording(); else { recording = true; recLen = 0; } }
            if (recording) { if (recLen < cap) { bufL[size_t(recLen)] = xl; bufR[size_t(recLen)] = xr; ++recLen; } else finishRecording(); }
            if (outPos >= hop) {
                outPos = 0;
                bool frozen = params[7] > 0.5f || (hasFrz && frz[i] > 0.2f);
                if (L > n && !recording) nextFrame(rlo, rhi, stretch, frozen);
                else { std::fill(accL.begin(), accL.end(), 0.0f); std::fill(accR.begin(), accR.end(), 0.0f); }
            }
            float mon = (recording && monitor) ? 1.0f : 0.0f;
            oL[i] = accL[size_t(outPos)] * level + xl * mon;
            oR[i] = accR[size_t(outPos)] * level + xr * mon;
            ++outPos;
        }
        if (recording) ++version;
        readouts[0] = recording ? 1.0f : (L > 0 ? 2.0f : 0.0f);
        readouts[1] = float(double(recording ? recLen : L) / sampleRate);
        readouts[kPlayheadSlot] = (!recording && L > 0) ? float(readPos / double(L)) : -1.0f;
        for (int k = 1; k < 8; ++k) readouts[size_t(kPlayheadSlot + k)] = -1;
    }
    const float* waveBuffer() const override { return bufL.data(); }
    const float* waveBufferR() const override { return bufR.data(); }
    int waveLength() const override { return recording ? recLen : length; }
    int contentVersion() const override { return version; }
    bool waveRecording() const override { return recording; }
    int bufferCapacity() const override { return cap; }
    StereoAudio snapshot() const override {
        if (length <= 0) return {};
        return StereoAudio(std::vector<float>(bufL.begin(), bufL.begin() + length), std::vector<float>(bufR.begin(), bufR.begin() + length));
    }
    void load(const StereoAudio& a) override {
        guard.whileBusy([&] {
            int c = std::min(a.count(), cap);
            a.copyInto(bufL.data(), bufR.data(), c);
            length = c; recording = false; readPos = 0; ++version;
        });
    }
private:
    void configure(int size) {
        n = size; hop = size / 4;
        for (int i = 0; i < n; ++i) window[size_t(i)] = 0.5f - 0.5f * std::cos(2 * juce::MathConstants<float>::pi * float(i) / float(n));
        std::fill(accL.begin(), accL.end(), 0.0f); std::fill(accR.begin(), accR.end(), 0.0f);
        outPos = hop;
        fft.setSize(n);
    }
    void nextFrame(int lo, int hi, double stretch, bool frozen) {
        for (auto* acc : { &accL, &accR }) {
            std::copy(acc->begin() + hop, acc->begin() + n, acc->begin());
            std::fill(acc->begin() + (n - hop), acc->begin() + n, 0.0f);
        }
        int span = hi - lo;
        if (span <= 64) return;
        int p = int(readPos);
        if (p < lo || p >= hi) { p = lo; readPos = lo; }
        int half = n / 2;
        float scale = 1.0f / (float(n) * 1.5f);
        for (int ch = 0; ch < 2; ++ch) {
            auto& src = ch == 0 ? bufL : bufR;
            for (int i = 0; i < n; ++i) {
                int idx = p + i;
                while (idx >= hi) idx -= span;
                spec[size_t(i)] = { src[size_t(idx)] * window[size_t(i)], 0.0f };
            }
            fft.run(spec.data(), false);
            for (int k = 0; k <= half; ++k) mag[size_t(k)] = std::abs(spec[size_t(k)]);
            // random phases; no DC / Nyquist; Hermitian so the result is real
            spec[0] = 0; spec[size_t(half)] = 0;
            for (int k = 1; k < half; ++k) {
                float ph = rng.next() * 2 * juce::MathConstants<float>::pi;
                auto c = std::polar(mag[size_t(k)], ph);
                spec[size_t(k)] = c; spec[size_t(n - k)] = std::conj(c);
            }
            fft.run(spec.data(), true);
            auto& acc = ch == 0 ? accL : accR;
            for (int i = 0; i < n; ++i) acc[size_t(i)] += spec[size_t(i)].real() * scale * window[size_t(i)];
        }
        if (!frozen) {
            readPos += double(hop) / std::max(stretch, 1.0);
            if (readPos >= hi) readPos -= span;
        }
    }
    void finishRecording() { recording = false; length = recLen; readPos = 0; ++version; }
    int cap, length = 0, recLen = 0, version = 0, n = 0, hop = 0, outPos = 0;
    bool recording = false;
    std::vector<float> bufL, bufR, window, accL, accR, mag;
    std::vector<std::complex<float>> spec;
    FFT fft;
    LoadGuard guard;
    double readPos = 0;
    XorShift rng { 0x57E7C401u };
    EdgeDetector recGate;
};

// ---------------------------------------------------------------- freqshift~

class FreqShiftNode : public DSPNode {
public:
    using DSPNode::DSPNode;
    void process(int frames, const float* const* in, uint64_t con, ProcessContext&) override {
        static const float a[] = { 0.6923878f * 0.6923878f, 0.9360654322959f * 0.9360654322959f, 0.9882295226860f * 0.9882295226860f, 0.9987488452737f * 0.9987488452737f };
        static const float b[] = { 0.4021921162426f * 0.4021921162426f, 0.8561710882420f * 0.8561710882420f, 0.9722909545651f * 0.9722909545651f, 0.9952884791278f * 0.9952884791278f };
        double shift = params[0]; float fb = params[1], mix = params[2];
        const float* inL = in[0]; const float* inR = isConnected(con, 1) ? in[1] : in[0];
        double inc = shift / sampleRate;
        for (int i = 0; i < frames; ++i) {
            phase += inc; phase -= std::floor(phase);
            float c = float(std::cos(2 * juce::MathConstants<double>::pi * phase)), s = float(std::sin(2 * juce::MathConstants<double>::pi * phase));
            for (int ch = 0; ch < 2; ++ch) {
                float dry = ch == 0 ? inL[i] : inR[i];
                float x = dry + fbUp[ch] * fb;
                float iPath = run(pa[ch], a, x), qRaw = run(pb[ch], b, x);
                float qPath = bDelay[ch]; bDelay[ch] = qRaw;
                float u = iPath * c + qPath * s, d = iPath * c - qPath * s;
                fbUp[ch] = softClip(u);
                out(ch)[i] = dry * (1 - mix) + u * mix;
                out(2 + ch)[i] = dry * (1 - mix) + d * mix;
            }
        }
    }
private:
    struct AP { float x1 = 0, x2 = 0, y1 = 0, y2 = 0; };
    static float run(AP* chain, const float* coefs, float x) {
        float v = x;
        for (int k = 0; k < 4; ++k) {
            float y = coefs[k] * (v + chain[k].y2) - chain[k].x2;
            chain[k].x2 = chain[k].x1; chain[k].x1 = v; chain[k].y2 = chain[k].y1; chain[k].y1 = y;
            v = y;
        }
        return v;
    }
    AP pa[2][4], pb[2][4];
    float bDelay[2] = {}, fbUp[2] = {};
    double phase = 0;
};

// ---------------------------------------------------------------- modulation effects

struct DelayLine {
    std::vector<float> buf; int len = 4, w = 0;
    explicit DelayLine(int samples = 4) : buf(size_t(std::max(samples, 4)), 0.0f), len(std::max(samples, 4)) {}
    void write(float x) { buf[size_t(w)] = x; if (++w >= len) w = 0; }
    float read(double d) const {
        double p = double(w - 1) - d;
        if (p < 0) p += len;
        if (p < 0) p = 0;
        return readLinear(buf.data(), len, p);
    }
};

class ChorusNode : public DSPNode {
public:
    ChorusNode(const ModuleSpec& s, double sr) : DSPNode(s, sr), dl(int(sr * 0.1)), dr(int(sr * 0.1)) {}
    void process(int frames, const float* const* in, uint64_t con, ProcessContext&) override {
        int algo = clampIndex(params[6], 3);
        double rate = params[0], depth = double(params[1]) * 0.005 * sampleRate, base = double(params[2]) * 0.001 * sampleRate;
        float fb = params[3], width = params[4], mix = algo == 2 ? 1.0f : params[5];
        const float* inL = in[0]; const float* inR = isConnected(con, 1) ? in[1] : in[0];
        float* oL = out(0); float* oR = out(1);
        for (int i = 0; i < frames; ++i) {
            phase += rate / sampleRate; if (phase >= 1) phase -= 1;
            phase2 += rate * 6.3 / sampleRate; if (phase2 >= 1) phase2 -= 1;
            float yl = 0, yr = 0;
            if (algo == 1) {
                for (int v = 0; v < 3; ++v) {
                    double o = double(v) / 3;
                    double mL = 0.8 * lfoShape(0, phase + o) + 0.2 * lfoShape(0, phase2 + o);
                    double mR = 0.8 * lfoShape(0, phase + o + 0.5 * width) + 0.2 * lfoShape(0, phase2 + o + 0.25);
                    yl += dl.read(base + depth * (mL + 1) * 0.5) / 3 * 1.6f;
                    yr += dr.read(base + depth * (mR + 1) * 0.5) / 3 * 1.6f;
                }
            } else {
                double mL = lfoShape(0, phase), mR = lfoShape(0, phase + 0.25 + 0.25 * width);
                yl = dl.read(base + depth * (mL + 1) * 0.5);
                yr = dr.read(base + depth * (mR + 1) * 0.5);
            }
            float l = inL[i], r = inR[i];
            dl.write(softClip(l + yl * fb)); dr.write(softClip(r + yr * fb));
            float wl = yl * (0.5f + 0.5f * width) + yr * (0.5f - 0.5f * width);
            float wr = yr * (0.5f + 0.5f * width) + yl * (0.5f - 0.5f * width);
            oL[i] = l * (1 - mix) + wl * mix;
            oR[i] = r * (1 - mix) + wr * mix;
        }
    }
private:
    DelayLine dl, dr; double phase = 0, phase2 = 0;
};

class PhaserNode : public DSPNode {
public:
    PhaserNode(const ModuleSpec& s, double sr) : DSPNode(s, sr), dl(int(sr * 0.03)), dr(int(sr * 0.03)) {}
    void process(int frames, const float* const* in, uint64_t con, ProcessContext& ctx) override {
        bool flanger = params[0] > 0.5f, sync = params[2] > 0.5f;
        double hz = params[1], div = Divisions::beats(params[3]);
        float depth = params[4], center = params[5], fb = params[6], mix = params[8];
        int stages = clampIndex(params[7], 13) < 1 ? 1 : clampIndex(params[7], 13);
        const float* inL = in[0]; const float* inR = isConnected(con, 1) ? in[1] : in[0];
        float* oL = out(0); float* oR = out(1);
        float sr = float(sampleRate);
        for (int i = 0; i < frames; ++i) {
            double p = clock.advance(sync, hz, div, ctx.beat[i], sampleRate);
            float mL = lfoShape(1, p), mR = lfoShape(1, p + 0.25);
            float l = inL[i], r = inR[i], yl, yr;
            if (flanger) {
                float dms = 1000 / center;
                double dL = dms * (1 + 0.9f * depth * mL) * 0.001f * sr, dR = dms * (1 + 0.9f * depth * mR) * 0.001f * sr;
                yl = dl.read(std::max(dL, 1.0)); yr = dr.read(std::max(dR, 1.0));
                dl.write(softClip(l + yl * fb)); dr.write(softClip(r + yr * fb));
            } else {
                float fL = std::min(center * std::exp2(mL * depth * 2.5f), sr * 0.45f), fR = std::min(center * std::exp2(mR * depth * 2.5f), sr * 0.45f);
                float tL = std::tan(juce::MathConstants<float>::pi * fL / sr), tR = std::tan(juce::MathConstants<float>::pi * fR / sr);
                float aL = (tL - 1) / (tL + 1), aR = (tR - 1) / (tR + 1);
                float xl = l + fbL * fb, xr = r + fbR * fb;
                for (int s = 0; s < stages; ++s) {
                    float y1 = aL * xl + apL[s]; apL[s] = xl - aL * y1; xl = y1;
                    float y2 = aR * xr + apR[s]; apR[s] = xr - aR * y2; xr = y2;
                }
                fbL = softClip(xl); fbR = softClip(xr);
                yl = xl; yr = xr;
            }
            oL[i] = l * (1 - mix * 0.5f) + yl * mix * 0.5f;
            oR[i] = r * (1 - mix * 0.5f) + yr * mix * 0.5f;
        }
    }
private:
    float apL[13] = {}, apR[13] = {}, fbL = 0, fbR = 0;
    DelayLine dl, dr; PhaseClock clock;
};

class ReduxNode : public DSPNode {
public:
    using DSPNode::DSPNode;
    void process(int frames, const float* const* in, uint64_t con, ProcessContext&) override {
        float q = std::pow(2.0f, params[0] - 1), step = params[1] / float(sampleRate), mix = params[2];
        const float* inL = in[0]; const float* inR = isConnected(con, 1) ? in[1] : in[0];
        float* oL = out(0); float* oR = out(1);
        for (int i = 0; i < frames; ++i) {
            phase += step;
            if (phase >= 1) { phase -= std::floor(phase); hl = std::round(inL[i] * q) / q; hr = std::round(inR[i] * q) / q; }
            oL[i] = inL[i] * (1 - mix) + hl * mix;
            oR[i] = inR[i] * (1 - mix) + hr * mix;
        }
    }
private:
    float phase = 1, hl = 0, hr = 0;
};

class ShifterNode : public DSPNode {
public:
    ShifterNode(const ModuleSpec& s, double sr) : DSPNode(s, sr), dl(int(sr * 0.5)), dr(int(sr * 0.5)) {}
    void process(int frames, const float* const* in, uint64_t con, ProcessContext&) override {
        double ratio = std::exp2((params[0] + params[1] / 100) / 12), win = double(params[2]) * 0.001 * sampleRate;
        float fb = params[3], mix = params[4];
        double inc = (1 - ratio) / win;
        const float* inL = in[0]; const float* inR = isConnected(con, 1) ? in[1] : in[0];
        float* oL = out(0); float* oR = out(1);
        for (int i = 0; i < frames; ++i) {
            ph += inc; ph -= std::floor(ph);
            double p2 = ph + 0.5 - std::floor(ph + 0.5);
            float g1 = std::sin(juce::MathConstants<float>::pi * float(ph)), g2 = std::sin(juce::MathConstants<float>::pi * float(p2));
            float yl = dl.read(ph * win + 2) * g1 + dl.read(p2 * win + 2) * g2;
            float yr = dr.read(ph * win + 2) * g1 + dr.read(p2 * win + 2) * g2;
            float l = inL[i], r = inR[i];
            dl.write(softClip(l + yl * fb)); dr.write(softClip(r + yr * fb));
            oL[i] = l * (1 - mix) + yl * mix;
            oR[i] = r * (1 - mix) + yr * mix;
        }
    }
private:
    DelayLine dl, dr; double ph = 0;
};

class AutoPanNode : public DSPNode {
public:
    using DSPNode::DSPNode;
    void process(int frames, const float* const* in, uint64_t con, ProcessContext& ctx) override {
        bool sync = params[1] > 0.5f; double hz = params[0], div = Divisions::beats(params[2]);
        float amt = params[3]; int shape = clampIndex(params[4], 4); double off = double(params[5]) / 360;
        const float* inL = in[0]; const float* inR = isConnected(con, 1) ? in[1] : in[0];
        float* oL = out(0); float* oR = out(1);
        for (int i = 0; i < frames; ++i) {
            double p = clock.advance(sync, hz, div, ctx.beat[i], sampleRate);
            oL[i] = inL[i] * (1 - amt * (0.5f - 0.5f * lfoShape(shape, p)));
            oR[i] = inR[i] * (1 - amt * (0.5f - 0.5f * lfoShape(shape, p + off)));
        }
    }
private:
    PhaseClock clock;
};

class BeatRepeatNode : public DSPNode {
public:
    BeatRepeatNode(const ModuleSpec& s, double sr) : DSPNode(s, sr) {
        len = int(sr * 8); bufL.assign(size_t(len), 0); bufR.assign(size_t(len), 0);
    }
    void process(int frames, const float* const* in, uint64_t con, ProcessContext& ctx) override {
        static const double intervals[] = { 1, 2, 4, 8, 16 }, grids[] = { 0.125, 0.25, 0.5, 1, 2 };
        double interval = intervals[clampIndex(params[0], 5)], offset = double(params[1]) * 0.25, gate = params[2];
        double grid = grids[clampIndex(params[3], 5)];
        float chance = params[4], decay = params[5];
        int mode = clampIndex(params[6], 3);
        bool holdParam = params[7] > 0.5f, hasHold = isConnected(con, 2);
        const float* holdIn = in[2];
        const float* inL = in[0]; const float* inR = isConnected(con, 1) ? in[1] : in[0];
        float* oL = out(0); float* oR = out(1);
        double spb = ctx.samplesPerBeat;
        const int fade = 96;
        for (int i = 0; i < frames; ++i) {
            double b = ctx.beat[i];
            bool hold = holdParam || (hasHold && holdIn[i] > 0.2f);
            float l = inL[i], r = inR[i];
            bufL[size_t(w)] = l; bufR[size_t(w)] = r;
            if (hold && !repeating) start(spb, grid, gate, true);
            else if (!hold && repeating && remaining == INT32_MAX) repeating = false;
            else if (!repeating && crossed(prevBeat - offset, b - offset, interval) && b >= offset && rng.next() < chance) start(spb, grid, gate, false);
            prevBeat = b;
            float wl = 0, wr = 0;
            if (repeating) {
                int pos = elapsed % sliceLen;
                if (pos == 0 && elapsed > 0) level *= (1 - decay);
                int idx = sliceStart + pos; if (idx >= len) idx -= len;
                int edge = std::min(pos, sliceLen - 1 - pos);
                float env = edge < fade ? float(edge) / float(fade) : 1.0f;
                wl = bufL[size_t(idx)] * env * level; wr = bufR[size_t(idx)] * env * level;
                ++elapsed;
                if (remaining != INT32_MAX && --remaining <= 0) repeating = false;
            }
            switch (mode) {
                case 0: oL[i] = l + wl; oR[i] = r + wr; break;
                case 1: oL[i] = repeating ? wl : l; oR[i] = repeating ? wr : r; break;
                default: oL[i] = wl; oR[i] = wr;
            }
            if (++w >= len) w = 0;
        }
        readouts[0] = repeating ? 1.0f : 0.0f;
    }
private:
    void start(double spb, double gridBeats, double gate16, bool hold) {
        repeating = true; sliceStart = w; elapsed = 0;
        sliceLen = std::max(64, std::min(safeInt(gridBeats * spb), len / 2));
        remaining = hold ? INT32_MAX : std::max(64, safeInt(gate16 * 0.25 * spb));
        level = 1;
    }
    int len, w = 0, sliceStart = 0, elapsed = 0, sliceLen = 1, remaining = 0;
    std::vector<float> bufL, bufR;
    bool repeating = false; float level = 1; double prevBeat = 0;
    XorShift rng { 0xBEA70001u };
};

// ---------------------------------------------------------------- dynamics

class CompressorNode : public DSPNode {
public:
    using DSPNode::DSPNode;
    void process(int frames, const float* const* in, uint64_t con, ProcessContext&) override {
        int algo = clampIndex(params[4], 3);
        if (algo != 0) { processModel(algo, frames, in, con); return; }
        float peak = std::clamp(params[0], 0.0f, 1.0f), makeup = params[1], mix = params[3];
        bool limit = params[2] > 0.5f;
        float threshold = -2 - peak * 40, ratio = limit ? 12.0f : 3.0f, knee = limit ? 4.0f : 10.0f;
        float sr = float(sampleRate);
        float detAtt = 1 - std::exp(-1 / (0.0005f * sr)), detRel = 1 - std::exp(-1 / (0.02f * sr)), fastRel = 1 - std::exp(-1 / (0.06f * sr));
        float memUp = 1 / (5 * sr), memDown = 1 / (12 * sr);
        const float* inL = in[0]; const float* inR = isConnected(con, 1) ? in[1] : in[0];
        bool hasSC = isConnected(con, 2); const float* sc = in[2];
        float* oL = out(0); float* oR = out(1);
        float maxGR = 0, inPk = 0, outPk = 0;
        for (int i = 0; i < frames; ++i) {
            float l = inL[i], r = inR[i];
            float d = hasSC ? std::abs(sc[i]) : std::max(std::abs(l), std::abs(r));
            env += (d - env) * (d > env ? detAtt : detRel);
            float xdb = 20 * std::log10(env + 1e-9f), over = xdb - threshold, target;
            if (over <= -knee / 2) target = 0;
            else if (over < knee / 2) { float t = over + knee / 2; target = (1 - 1 / ratio) * t * t / (2 * knee); }
            else target = (1 - 1 / ratio) * over;
            float gr = fast + slow;
            if (target > gr) {
                float jump = target - gr, att = 1 - std::exp(-1 / ((0.010f / (1 + jump / 6)) * sr)), add = jump * att;
                fast += add * 0.7f; slow += add * 0.3f;
            } else {
                fast -= fast * fastRel;
                float slowTau = 0.5f + 4.5f * memory;
                slow -= slow * (1 - std::exp(-1 / (slowTau * sr)));
            }
            memory = gr > 1 ? std::min(memory + memUp * std::min(gr / 6, 2.0f), 1.0f) : std::max(memory - memDown, 0.0f);
            float g = dbToGain(makeup - (fast + slow));
            oL[i] = l * (1 - mix) + softClip(l * g) * mix;
            oR[i] = r * (1 - mix) + softClip(r * g) * mix;
            maxGR = std::max(maxGR, fast + slow);
            inPk = std::max({ inPk, std::abs(l), std::abs(r) }); outPk = std::max({ outPk, std::abs(oL[i]), std::abs(oR[i]) });
        }
        publish(maxGR, inPk, outPk, threshold, ratio, knee, makeup);
    }
private:
    void publish(float gr, float inPk, float outPk, float threshold, float ratio, float knee, float makeup) {
        readouts[0] = gr;
        readouts[1] = std::max(inPk, readouts[1] * 0.993f);
        readouts[2] = std::max(outPk, readouts[2] * 0.993f);
        readouts[3] = threshold; readouts[4] = ratio; readouts[5] = knee; readouts[6] = makeup;
    }
    void processModel(int algo, int frames, const float* const* in, uint64_t con) {
        float peak = std::clamp(params[0], 0.0f, 1.0f), makeup = params[1], mix = params[3];
        bool limit = params[2] > 0.5f, fet = algo == 1;
        float threshold = (fet ? -4.0f : -2.0f) - peak * 40;
        float ratio = fet ? (limit ? 20.0f : 4.0f) : (limit ? 10.0f : 4.0f), knee = fet ? 2.0f : 0.0f;
        float sr = float(sampleRate), att = 1 - std::exp(-1 / ((fet ? 0.0004f : 0.010f) * sr));
        const float* inL = in[0]; const float* inR = isConnected(con, 1) ? in[1] : in[0];
        bool hasSC = isConnected(con, 2); const float* sc = in[2];
        float* oL = out(0); float* oR = out(1);
        float maxGR = 0, inPk = 0, outPk = 0;
        for (int i = 0; i < frames; ++i) {
            float l = inL[i], r = inR[i];
            float d = hasSC ? std::abs(sc[i]) : std::max(std::abs(l), std::abs(r));
            float over = 20 * std::log10(d + 1e-9f) - threshold, target;
            if (knee > 0 && std::abs(over) < knee / 2) { float t = over + knee / 2; target = (1 - 1 / ratio) * t * t / (2 * knee); }
            else target = over > 0 ? (1 - 1 / ratio) * over : 0;
            float e = fet ? fetEnv : vcaEnv;
            if (target > e) e += (target - e) * att;
            else {
                float relS = fet ? 0.05f + 0.4f * std::min(e / 12, 1.0f) : 0.1f + 1.1f * std::min(e / 10, 1.0f);
                e -= e * (1 - std::exp(-1 / (relS * sr)));
            }
            (fet ? fetEnv : vcaEnv) = e;
            float g = dbToGain(makeup - e), yl = l * g, yr = r * g;
            if (fet) { yl = std::tanh(yl * 1.15f) / 1.15f; yr = std::tanh(yr * 1.15f) / 1.15f; }
            oL[i] = l * (1 - mix) + softClip(yl) * mix;
            oR[i] = r * (1 - mix) + softClip(yr) * mix;
            maxGR = std::max(maxGR, e);
            inPk = std::max({ inPk, std::abs(l), std::abs(r) }); outPk = std::max({ outPk, std::abs(oL[i]), std::abs(oR[i]) });
        }
        publish(maxGR, inPk, outPk, threshold, ratio, knee, makeup);
    }
    float env = 0, fast = 0, slow = 0, memory = 0, vcaEnv = 0, fetEnv = 0;
};

class LimiterNode : public DSPNode {
public:
    using DSPNode::DSPNode;
    void process(int frames, const float* const* in, uint64_t con, ProcessContext&) override {
        float pre = dbToGain(params[0]), ceil = dbToGain(params[1]);
        float rel = onePoleCoef(params[2], sampleRate), att = onePoleCoef(0.4f, sampleRate);
        const float* inL = in[0]; const float* inR = isConnected(con, 1) ? in[1] : in[0];
        float* oL = out(0); float* oR = out(1);
        float minG = 1;
        for (int i = 0; i < frames; ++i) {
            float l = inL[i] * pre, r = inR[i] * pre;
            peakHist[w] = std::max(std::abs(l), std::abs(r));
            float pk = 0; for (int k = 0; k < look; ++k) pk = std::max(pk, peakHist[k]);
            float need = pk > ceil ? ceil / pk : 1;
            g += (need - g) * (need < g ? att : rel);
            float dl = bufL[w], dr = bufR[w];
            bufL[w] = l; bufR[w] = r;
            if (++w >= look) w = 0;
            oL[i] = std::clamp(dl * g, -ceil, ceil); oR[i] = std::clamp(dr * g, -ceil, ceil);
            minG = std::min(minG, g);
        }
        readouts[0] = -20 * std::log10(minG);
    }
private:
    static constexpr int look = 64;
    float bufL[look] = {}, bufR[look] = {}, peakHist[look] = {}, g = 1; int w = 0;
};

class GateNode : public DSPNode {
public:
    using DSPNode::DSPNode;
    void process(int frames, const float* const* in, uint64_t con, ProcessContext&) override {
        float thr = dbToGain(params[0]), att = onePoleCoef(params[1], sampleRate), rel = onePoleCoef(params[3], sampleRate);
        int hold = safeInt(double(params[2]) * 0.001 * sampleRate);
        float flr = params[4] <= -79.9f ? 0 : dbToGain(params[4]);
        const float* inL = in[0]; const float* inR = isConnected(con, 1) ? in[1] : in[0];
        bool hasSC = isConnected(con, 2); const float* sc = in[2];
        float* oL = out(0); float* oR = out(1);
        for (int i = 0; i < frames; ++i) {
            float l = inL[i], r = inR[i];
            float det = hasSC ? std::abs(sc[i]) : std::max(std::abs(l), std::abs(r));
            if (det > thr) holdLeft = hold;
            bool open = holdLeft > 0;
            if (holdLeft > 0) --holdLeft;
            g += ((open ? 1 : flr) - g) * (open ? att : rel);
            oL[i] = l * g; oR[i] = r * g;
        }
        readouts[0] = g;
    }
private:
    float g = 0; int holdLeft = 0;
};

class EQ3Node : public DSPNode {
public:
    using DSPNode::DSPNode;
    void process(int frames, const float* const* in, uint64_t con, ProcessContext&) override {
        auto gain = [](float db) { return db <= -59.9f ? 0 : dbToGain(db); };
        float gl = gain(params[0]), gm = gain(params[1]), gh = gain(params[2]), sr = float(sampleRate);
        lowL.set(params[3], sr, 1.414f); lowR.set(params[3], sr, 1.414f);
        highL.set(params[4], sr, 1.414f); highR.set(params[4], sr, 1.414f);
        const float* inL = in[0]; const float* inR = isConnected(con, 1) ? in[1] : in[0];
        float* oL = out(0); float* oR = out(1);
        for (int i = 0; i < frames; ++i) {
            float l = inL[i], r = inR[i];
            float lo = lowL.process(l).low, hi = highL.process(l).high;
            float lo2 = lowR.process(r).low, hi2 = highR.process(r).high;
            oL[i] = lo * gl + (l - lo - hi) * gm + hi * gh;
            oR[i] = lo2 * gl + (r - lo2 - hi2) * gm + hi2 * gh;
        }
    }
private:
    SVF lowL, lowR, highL, highR;
};

// ---------------------------------------------------------------- peq~

namespace ParametricEQ {
int bandCount(float c) { static const int ch[] = { 3, 5, 8 }; return ch[clampIndex(c, 3)]; }
int shape(int band, int n) { return band == 0 ? 0 : (band == n - 1 ? 2 : 1); }   // 0 low shelf, 1 peak, 2 high shelf
std::array<float, 5> coefficients(int shape, float freq, float gainDB, float q, double sampleRate) {
    double f = std::clamp(double(freq), 10.0, sampleRate * 0.45), A = std::pow(10.0, double(gainDB) / 40);
    double w0 = 2 * juce::MathConstants<double>::pi * f / sampleRate, cw = std::cos(w0), sw = std::sin(w0);
    double alpha = sw / (2 * std::max(double(q), 0.05));
    double b0, b1, b2, a0, a1, a2;
    if (shape == 1) { b0 = 1 + alpha * A; b1 = -2 * cw; b2 = 1 - alpha * A; a0 = 1 + alpha / A; a1 = -2 * cw; a2 = 1 - alpha / A; }
    else if (shape == 0) {
        double s = 2 * std::sqrt(A) * alpha;
        b0 = A * ((A + 1) - (A - 1) * cw + s); b1 = 2 * A * ((A - 1) - (A + 1) * cw); b2 = A * ((A + 1) - (A - 1) * cw - s);
        a0 = (A + 1) + (A - 1) * cw + s; a1 = -2 * ((A - 1) + (A + 1) * cw); a2 = (A + 1) + (A - 1) * cw - s;
    } else {
        double s = 2 * std::sqrt(A) * alpha;
        b0 = A * ((A + 1) + (A - 1) * cw + s); b1 = -2 * A * ((A - 1) + (A + 1) * cw); b2 = A * ((A + 1) + (A - 1) * cw - s);
        a0 = (A + 1) - (A - 1) * cw + s; a1 = 2 * ((A - 1) - (A + 1) * cw); a2 = (A + 1) - (A - 1) * cw - s;
    }
    return { float(b0 / a0), float(b1 / a0), float(b2 / a0), float(a1 / a0), float(a2 / a0) };
}
double responseDB(const std::function<float(int)>& p, double freq, double sampleRate) {
    int n = bandCount(p(0));
    double db = p(1), w = 2 * juce::MathConstants<double>::pi * freq / sampleRate;
    double c1 = std::cos(w), s1 = std::sin(w), c2 = std::cos(2 * w), s2 = std::sin(2 * w);
    for (int b = 0; b < n; ++b) {
        auto c = coefficients(shape(b, n), p(2 + 3 * b), p(3 + 3 * b), p(4 + 3 * b), sampleRate);
        double nr = c[0] + c[1] * c1 + c[2] * c2, ni = -(c[1] * s1 + c[2] * s2);
        double dr = 1 + c[3] * c1 + c[4] * c2, di = -(c[3] * s1 + c[4] * s2);
        db += 20 * std::log10(std::max(std::sqrt((nr * nr + ni * ni) / std::max(dr * dr + di * di, 1e-30)), 1e-9));
    }
    return db;
}
std::vector<float> defaultFrequencies(int n) {
    std::vector<float> v;
    for (int k = 0; k < n; ++k) v.push_back(80 * std::pow(10000.0f / 80, float(k) / float(std::max(n - 1, 1))));
    return v;
}
}

class ParametricEQNode : public DSPNode, public SpectrumSource {
public:
    static constexpr int ringSize = 8192;
    ParametricEQNode(const ModuleSpec& s, double sr) : DSPNode(s, sr) {
        ring.assign(ringSize, 0); last.assign(size_t(2 + 3 * 8), NAN);
    }
    void copyRecent(float* o, int count) const override {
        int n = std::min(count, ringSize), r = ringW - n;
        if (r < 0) r += ringSize;
        for (int i = 0; i < n; ++i) { o[i] = ring[size_t(r)]; if (++r >= ringSize) r = 0; }
    }
    void process(int frames, const float* const* in, uint64_t con, ProcessContext&) override {
        int n = ParametricEQ::bandCount(params[0]);
        bool changed = false;
        for (int k = 0; k < paramCount; ++k) if (!(last[size_t(k)] == params[size_t(k)])) { changed = true; last[size_t(k)] = params[size_t(k)]; }
        if (changed)
            for (int b = 0; b < n; ++b) {
                auto c = ParametricEQ::coefficients(ParametricEQ::shape(b, n), params[size_t(2 + 3 * b)], params[size_t(3 + 3 * b)], params[size_t(4 + 3 * b)], sampleRate);
                bands[b].b0 = c[0]; bands[b].b1 = c[1]; bands[b].b2 = c[2]; bands[b].a1 = c[3]; bands[b].a2 = c[4];
            }
        float g = dbToGain(params[1]);
        const float* inL = in[0]; const float* inR = isConnected(con, 1) ? in[1] : in[0];
        float* oL = out(0); float* oR = out(1);
        for (int i = 0; i < frames; ++i) {
            float l = inL[i], r = inR[i];
            for (int b = 0; b < n; ++b) {
                auto& q = bands[b];
                float yl = q.b0 * l + q.zL1; q.zL1 = q.b1 * l - q.a1 * yl + q.zL2; q.zL2 = q.b2 * l - q.a2 * yl;
                float yr = q.b0 * r + q.zR1; q.zR1 = q.b1 * r - q.a1 * yr + q.zR2; q.zR2 = q.b2 * r - q.a2 * yr;
                l = yl; r = yr;
            }
            oL[i] = l * g; oR[i] = r * g;
            ring[size_t(ringW)] = (l + r) * 0.5f * g;
            if (++ringW >= ringSize) ringW = 0;
        }
        for (int b = 0; b < n; ++b)
            if (!(std::isfinite(bands[b].zL1) && std::isfinite(bands[b].zR1))) { bands[b].zL1 = bands[b].zL2 = bands[b].zR1 = bands[b].zR2 = 0; }
    }
private:
    struct Biquad { float b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0, zL1 = 0, zL2 = 0, zR1 = 0, zR2 = 0; };
    Biquad bands[8];
    std::vector<float> ring, last;
    int ringW = 0;
};

// ---------------------------------------------------------------- scope~

class ScopeNodeImpl : public ScopeNode {
public:
    ScopeNodeImpl(const ModuleSpec& s, double sr) : ScopeNode(s, sr) {
        curMin.assign(2 * points, 0); curMax.assign(2 * points, 0);
    }
    void process(int frames, const float* const* in, uint64_t con, ProcessContext& ctx) override {
        double windowMs = std::clamp(double(params[0]), 1.0, 10000.0);
        int perPoint = std::max(1, int(windowMs * 0.001 * sampleRate / points));
        int mode = clampIndex(params[1], 3);
        bool hold = params[3] > 0.5f;
        const float* a = in[0]; const float* b = isConnected(con, 1) ? in[1] : in[0];
        std::copy(in[0], in[0] + frames, out(0));
        std::copy(in[1], in[1] + frames, out(1));
        float dcC = float(1 - std::exp(-1 / (0.5 * sampleRate)));
        for (int i = 0; i < frames; ++i) {
            float xa = std::isfinite(a[i]) ? a[i] : 0, xb = std::isfinite(b[i]) ? b[i] : 0;
            for (int c = 0; c < 2; ++c) {
                float v = c == 0 ? xa : xb;
                dc[c] += (v - dc[c]) * dcC;
                float h = std::max(0.002f, (hi[c] - lo[c]) * 0.05f);
                sinceRise[c] += 1;
                if (!above[c] && v > dc[c] + h) {
                    above[c] = true;
                    double p = sinceRise[c];
                    if (p > 2 && p < sampleRate * 20)
                        period[c] = period[c] == 0 || std::abs(p - period[c]) > period[c] * 0.1 ? p : period[c] + (p - period[c]) * 0.2;
                    sinceRise[c] = 0;
                } else if (above[c] && v < dc[c] - h) above[c] = false;
                if (sinceRise[c] > sampleRate * 20) period[c] = 0;
            }
            if (armed) {
                ++waited;
                bool fire = mode == 1 ? sinceRise[0] == 0 : mode == 2 ? crossed(prevBeat, ctx.beat[i], 4) : true;
                prevBeat = ctx.beat[i];
                if (fire || waited > perPoint * points * 2) { armed = false; waited = 0; } else continue;
            } else prevBeat = ctx.beat[i];
            for (int c = 0; c < 2; ++c) {
                float v = c == 0 ? xa : xb;
                size_t k = size_t(c * points + point);
                if (inPoint == 0) { curMin[k] = v; curMax[k] = v; } else { curMin[k] = std::min(curMin[k], v); curMax[k] = std::max(curMax[k], v); }
                acc[c] += v;
            }
            ++accN;
            if (++inPoint >= perPoint) {
                inPoint = 0;
                if (++point >= points) {
                    point = 0;
                    for (int c = 0; c < 2; ++c) {
                        float l = INFINITY, u = -INFINITY;
                        for (int p = 0; p < points; ++p) { l = std::min(l, curMin[size_t(c * points + p)]); u = std::max(u, curMax[size_t(c * points + p)]); }
                        lo[c] = l; hi[c] = u;
                        readouts[size_t(c * 4)] = float(acc[c] / double(std::max(accN, 1)));
                        readouts[size_t(c * 4 + 1)] = l; readouts[size_t(c * 4 + 2)] = u;
                        readouts[size_t(c * 4 + 3)] = period[c] > 0 ? float(sampleRate / period[c]) : 0.0f;
                        acc[c] = 0;
                    }
                    accN = 0;
                    if (!hold) {
                        std::copy(curMin.begin(), curMin.end(), shownMin.begin());
                        std::copy(curMax.begin(), curMax.end(), shownMax.begin());
                        ++version;
                    }
                    armed = mode != 0;
                }
            }
        }
    }
private:
    std::vector<float> curMin, curMax;
    int point = 0, inPoint = 0, waited = 0, accN = 0;
    bool armed = false, above[2] = {};
    double acc[2] = {}, sinceRise[2] = {}, period[2] = {}, prevBeat = 0;
    float lo[2] = {}, hi[2] = {}, dc[2] = {};
};

Factory factoryFX2(const std::string& k) {
    if (k == "stretch") return make<PaulStretchNode>();
    if (k == "freqshift") return make<FreqShiftNode>();
    if (k == "chorus") return make<ChorusNode>();
    if (k == "phaser") return make<PhaserNode>();
    if (k == "redux") return make<ReduxNode>();
    if (k == "shift") return make<ShifterNode>();
    if (k == "autopan") return make<AutoPanNode>();
    if (k == "repeat") return make<BeatRepeatNode>();
    if (k == "comp") return make<CompressorNode>();
    if (k == "limit") return make<LimiterNode>();
    if (k == "gate") return make<GateNode>();
    if (k == "eq") return make<EQ3Node>();
    if (k == "peq") return make<ParametricEQNode>();
    if (k == "scope") return make<ScopeNodeImpl>();
    return nullptr;
}

} // namespace pn
