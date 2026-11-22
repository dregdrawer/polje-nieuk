// I/O, clock, mixer, LFO, controls and utilities — ports of IOClock.swift, Controls.swift, Utilities.swift.
#include "Modules.h"

namespace pn {

class HardwareInNode : public DSPNode {
public:
    using DSPNode::DSPNode;
    void process(int frames, const float* const*, uint64_t, ProcessContext& ctx) override {
        int n = std::min(ctx.inputCount, kMaxHardwareChannels);
        float decay = std::pow(0.5f, float(frames) / float(sampleRate * 0.12));
        for (int c = 0; c < n; ++c) {
            const float* src = ctx.inputs[c]; float* o = out(c); float m = 0;
            for (int i = 0; i < frames; ++i) { o[i] = src[i]; m = std::max(m, std::abs(src[i])); }
            peaks[size_t(c)] = std::max(m, peaks[size_t(c)] * decay);
            readouts[size_t(c)] = peaks[size_t(c)];
        }
        if (zeroedFrom != n) {
            for (int c = n; c < kMaxHardwareChannels; ++c) { std::fill(outputs[size_t(c)].begin(), outputs[size_t(c)].end(), 0.0f); readouts[size_t(c)] = 0; }
            zeroedFrom = n;
        }
    }
private:
    std::array<float, kMaxHardwareChannels> peaks {}; int zeroedFrom = 0;
};

class HardwareOutNode : public DSPNode {
public:
    using DSPNode::DSPNode;
    void process(int frames, const float* const* in, uint64_t con, ProcessContext& ctx) override {
        float g = params[0] <= -59.9f ? 0 : dbToGain(params[0]);
        int n = std::min(ctx.outputCount, kMaxHardwareChannels);
        float decay = std::pow(0.5f, float(frames) / float(sampleRate * 0.12));
        for (int c = 0; c < n; ++c) {
            if (!isConnected(con, c)) { peaks[size_t(c)] = 0; readouts[size_t(c)] = 0; continue; }
            float* o = ctx.outputs[c]; float m = 0;
            float gc = (cvChannels >> c) & 1u ? 1.0f : g;   // control voltages keep 1 V/oct
            for (int i = 0; i < frames; ++i) { float v = in[c][i] * gc; o[i] += v; m = std::max(m, std::abs(v)); }
            peaks[size_t(c)] = std::max(m, peaks[size_t(c)] * decay);
            readouts[size_t(c)] = peaks[size_t(c)];
        }
    }
private:
    std::array<float, kMaxHardwareChannels> peaks {};
};

/// clock : follows a clock from the modular (or runs internally) and drives every synced module's beat.
class ClockNode : public DSPNode {
public:
    using DSPNode::DSPNode;
    void process(int frames, const float* const* in, uint64_t, ProcessContext& ctx) override {
        static const double ppqnValues[] = { 1, 2, 4, 8, 24 }, outRates[] = { 0.25, 0.5, 1, 2, 4 };
        bool ext = params[0] < 0.5f;
        double bpm = params[1], ppqn = ppqnValues[clampIndex(params[2], 5)];
        float thr = params[3];
        double rate = outRates[clampIndex(params[4], 5)];
        const float* clk = in[0]; const float* rst = in[1];
        float* pulseOut = out(0); float* rampOut = out(1);
        int pulseLen = safeInt(sampleRate * 0.005);
        double minGap = sampleRate * 0.002;
        if (ctx.stopPending) { beat = -1e-6; prevBeat = beat; tick = -1; pendingReset = false; freewheel = false; }
        for (int i = 0; i < frames; ++i) {
            if (!ctx.running) {
                if (ext) { float x = clk[i]; if (x > thr) high = true; else if (x < thr * 0.5f) high = false; }
                sinceEdge = 1e12;
                ctx.beat[i] = beat; pulseOut[i] = 0;
                rampOut[i] = float(std::max(beat, 0.0) - std::floor(std::max(beat, 0.0)));
                prevBeat = beat;
                continue;
            }
            float r = rst[i];
            if (!resetHigh && r > thr) { resetHigh = true; pendingReset = true; }
            else if (resetHigh && r < thr * 0.5f) resetHigh = false;
            if (ext) {
                sinceEdge += 1;
                float x = clk[i];
                if (!high && x > thr) {
                    high = true;
                    if (sinceEdge >= minGap) {
                        if (sinceEdge < sampleRate * 4) {
                            if (period == 0 || std::abs(sinceEdge - period) > period * 0.15) period = sinceEdge;
                            else period += (sinceEdge - period) * 0.3;
                        }
                        sinceEdge = 0;
                        if (pendingReset) { tick = 0; pendingReset = false; }
                        else if (freewheel) tick = std::max(tick + 1, int(std::ceil(beat * ppqn - 1e-6)));
                        else ++tick;
                        freewheel = false;
                        beat = double(tick) / ppqn;
                    }
                } else if (high && x < thr * 0.5f) high = false;
                if (period > 0 && sinceEdge > 0 && sinceEdge < period * 2.5) {
                    double limit = double(tick + 1) / ppqn - 1e-7;
                    beat = std::min(beat + 1 / (period * ppqn), limit);
                } else if (sinceEdge > 0) {
                    freewheel = true;
                    double spb = period > 0 ? period * ppqn : sampleRate * 60 / std::max(bpm, 1.0);
                    beat += 1 / spb;
                }
            } else {
                if (pendingReset) { pendingReset = false; beat = 0; prevBeat = -1e-9; }
                beat += bpm / 60 / sampleRate;
            }
            ctx.beat[i] = beat;
            if (crossed(prevBeat, beat, rate)) pulseLeft = pulseLen;
            pulseOut[i] = pulseLeft > 0 ? 0.5f : 0.0f;
            if (pulseLeft > 0) --pulseLeft;
            rampOut[i] = float(beat - std::floor(beat));
            prevBeat = beat;
        }
        ctx.samplesPerBeat = (ext && period > 0) ? period * ppqn : sampleRate * 60 / std::max(bpm, 1.0);
        ctx.externalClock = ext;
        readouts[0] = float(60 * sampleRate / ctx.samplesPerBeat);
        readouts[1] = float(safeInt(std::floor(beat)) % 4);
        readouts[2] = ext ? ((period > 0 && sinceEdge < period * 2.5) ? 1.0f : 0.0f) : 1.0f;
        readouts[3] = ext ? 1.0f : 0.0f;
    }
private:
    bool high = false, resetHigh = false, pendingReset = false, freewheel = false;
    double sinceEdge = 1e12, period = 0, beat = 0, prevBeat = 0;
    int tick = -1, pulseLeft = 0;
};

class MixerNode : public DSPNode {
public:
    using DSPNode::DSPNode;
    void process(int frames, const float* const* in, uint64_t con, ProcessContext&) override {
        static const int choices[] = { 2, 4, 8, 16 };
        float* oL = out(0); float* oR = out(1);
        std::fill(oL, oL + frames, 0.0f); std::fill(oR, oR + frames, 0.0f);
        int n = choices[clampIndex(params[0], 4)];
        float master = params[33];
        for (int k = n; k < 16; ++k) readouts[size_t(8 + k)] = 0;
        for (int k = 0; k < n; ++k) {
            if (!isConnected(con, k)) { readouts[size_t(8 + k)] = 0; continue; }
            float g = params[size_t(1 + 2 * k)] * master;
            float pan = std::clamp(params[size_t(2 + 2 * k)], -1.0f, 1.0f);
            float th = (pan + 1) * juce::MathConstants<float>::pi / 4;
            float gl = std::cos(th) * 1.41421356f * g, gr = std::sin(th) * 1.41421356f * g, pk = 0;
            for (int i = 0; i < frames; ++i) { float x = in[k][i]; oL[i] += x * gl; oR[i] += x * gr; pk = std::max(pk, std::abs(x)); }
            readouts[size_t(8 + k)] = ch[size_t(k)].update(pk * std::abs(g), frames, sampleRate);
        }
        readouts[0] = mL.update(oL, frames, sampleRate);
        readouts[1] = mR.update(oR, frames, sampleRate);
    }
private:
    PeakMeter mL, mR; std::array<PeakMeter, 16> ch {};
};

class LFONode : public DSPNode {
public:
    using DSPNode::DSPNode;
    void process(int frames, const float* const* in, uint64_t con, ProcessContext& ctx) override {
        int shape = clampIndex(params[0], 6);
        bool sync = params[1] > 0.5f;
        double rate = params[2], div = Divisions::beats(params[3]);
        float depth = params[4], offset = params[5];
        float* o = out(0);
        bool hasClock = isConnected(con, 0), hasReset = isConnected(con, 1);
        if (ctx.stopPending) { pulses = -1; beatZero = 0; }
        for (int i = 0; i < frames; ++i) {
            if (hasReset && resetEdge.rising(in[1][i])) { pulses = -1; phase = 0; prevPhase = 0; beatZero = ctx.beat[i]; }
            if (hasClock) {
                // follow the patched clock: 1 pulse = 1/16 note, smooth between pulses
                samplesSincePulse++;
                if (clockEdge.rising(in[0][i]) && ctx.running) {
                    if (pulses >= 0 && samplesSincePulse > 16) pulsePeriod = samplesSincePulse;
                    pulses++; samplesSincePulse = 0;
                }
                if (pulses >= 0) {
                    double pos = double(pulses) + std::min(double(samplesSincePulse) / double(std::max(pulsePeriod, 1)), 0.999);
                    double p = pos * 0.25 / div; phase = p - std::floor(p);
                }
            } else if (sync) { double p = (ctx.beat[i] - beatZero) / div; phase = p - std::floor(p); }
            else { phase += rate / sampleRate; if (phase >= 1) phase -= 1; }
            if (phase < prevPhase) {
                prevHeld = held; held = rng.next() * 2 - 1;
                for (int k = 2; k < 9; ++k) readouts[size_t(k)] = readouts[size_t(k + 1)];
                readouts[9] = held;
            }
            prevPhase = phase;
            float p = float(phase), v;
            switch (shape) {
                case 0: v = std::sin(2 * juce::MathConstants<float>::pi * p); break;
                case 1: v = p < 0.5f ? 4 * p - 1 : 3 - 4 * p; break;
                case 2: v = 2 * p - 1; break;
                case 3: v = p < 0.5f ? 1.0f : -1.0f; break;
                case 4: { float k = (1 - std::cos(juce::MathConstants<float>::pi * p)) / 2; v = prevHeld + (held - prevHeld) * k; break; }
                default: v = held;          // square random: a new random value at each cycle, held
            }
            o[i] = v * depth + offset;
        }
        readouts[0] = o[frames - 1]; readouts[1] = float(phase);
    }
private:
    double phase = 0, prevPhase = 0; float held = 0, prevHeld = 0; XorShift rng { 0x12345678u };
    EdgeDetector clockEdge, resetEdge;
    int pulses = -1, samplesSincePulse = 0, pulsePeriod = 3000;
    double beatZero = 0;
};

/// slider / knob: 1–8 controls, each a CV outlet; patched into a parameter they set its position.
class ControlsNode : public DSPNode {
public:
    ControlsNode(const ModuleSpec& s, double sr) : DSPNode(s, sr), positions(8 * kMaxBlock, 0.5f) {}
    const float* position(int k) const { return k >= 0 && k < 8 ? positions.data() + k * kMaxBlock : nullptr; }
    void process(int frames, const float* const*, uint64_t, ProcessContext&) override {
        static const int counts[] = { 1, 2, 4, 8 };
        int n = counts[clampIndex(params[0], 4)], range = clampIndex(params[1], 5);
        float coef = onePoleCoef(params[2], sampleRate);
        for (int k = 0; k < 8; ++k) {
            float* o = out(k);
            float pos = params[size_t(3 + k)];
            float p01 = std::isfinite(pos) ? std::clamp(pos, 0.0f, 1.0f) : 0.0f;
            readouts[size_t(k)] = p01;
            if (k >= n) { std::fill(o, o + frames, 0.0f); continue; }
            float target = map(p01, range);
            float y = primed ? smoothed[size_t(k)] : target;
            for (int i = 0; i < frames; ++i) { y += (target - y) * coef; o[i] = y; }
            smoothed[size_t(k)] = y;
            float sp = primed ? smoothedPos[size_t(k)] : p01;
            sp += (p01 - sp) * (1 - std::pow(1 - coef, float(frames)));
            smoothedPos[size_t(k)] = sp;
            positions[size_t(k * kMaxBlock)] = sp;
        }
        primed = true;
    }
    static float map(float v, int range) {
        switch (range) { case 1: return v * 2 - 1; case 2: return v * 0.5f; case 3: return v - 0.5f; case 4: return v * 0.1f; default: return v; }
    }
private:
    std::array<float, 8> smoothed {}, smoothedPos {}; bool primed = false; std::vector<float> positions;
};

const float* controlPosition(DSPNode* node, int port) {
    if (auto* c = dynamic_cast<ControlsNode*>(node)) return c->position(port);
    return nullptr;
}

class UtilityNode : public DSPNode {
public:
    using DSPNode::DSPNode;
    void process(int frames, const float* const* in, uint64_t con, ProcessContext&) override {
        float target = (params[6] > 0.5f || params[0] <= -59.9f) ? 0 : dbToGain(params[0]);
        float pan = params[1], width = params[3] > 0.5f ? 0 : params[2];
        float invL = params[4] > 0.5f ? -1.0f : 1.0f, invR = params[5] > 0.5f ? -1.0f : 1.0f;
        bool dc = params[7] > 0.5f;
        float c = onePoleCoef(10, sampleRate), gl = std::min(1.0f, 1 - pan), gr = std::min(1.0f, 1 + pan);
        const float* inL = in[0]; const float* inR = isConnected(con, 1) ? in[1] : in[0];
        float* oL = out(0); float* oR = out(1);
        for (int i = 0; i < frames; ++i) {
            g += (target - g) * c;
            float l = inL[i] * invL, r = inR[i] * invR;
            if (dc) {
                float yl = l - dcXL + 0.9995f * dcYL; dcXL = l; dcYL = yl; l = yl;
                float yr = r - dcXR + 0.9995f * dcYR; dcXR = r; dcYR = yr; r = yr;
            }
            float m = (l + r) * 0.5f, s = (l - r) * 0.5f * width;
            oL[i] = (m + s) * gl * g; oR[i] = (m - s) * gr * g;
        }
        readouts[0] = mL.update(oL, frames, sampleRate); readouts[1] = mR.update(oR, frames, sampleRate);
    }
private:
    float g = 1, dcXL = 0, dcYL = 0, dcXR = 0, dcYR = 0; PeakMeter mL, mR;
};

class EnvelopeNode : public DSPNode {
public:
    using DSPNode::DSPNode;
    void process(int frames, const float* const* in, uint64_t, ProcessContext&) override {
        float att = onePoleCoef(params[0], sampleRate), rel = onePoleCoef(params[1], sampleRate);
        float sens = params[2], amt = params[3], off = params[4];
        float* o = out(0);
        for (int i = 0; i < frames; ++i) {
            float x = std::min(std::abs(in[0][i]) * sens, 1.0f);
            env += (x - env) * (x > env ? att : rel);
            o[i] = env * amt + off;
        }
        readouts[0] = env;
    }
private:
    float env = 0;
};

class AttenNode : public DSPNode {
public:
    using DSPNode::DSPNode;
    void process(int frames, const float* const* in, uint64_t, ProcessContext&) override {
        float amt = params[0], off = params[1], c = onePoleCoef(params[2], sampleRate);
        float* o = out(0);
        for (int i = 0; i < frames; ++i) { y += (in[0][i] * amt + off - y) * c; o[i] = y; }
        readouts[0] = y;
    }
private:
    float y = 0;
};

Factory factoryCore(const std::string& k) {
    if (k == "in") return make<HardwareInNode>();
    if (k == "out") return make<HardwareOutNode>();
    if (k == "clock") return make<ClockNode>();
    if (k == "mix") return make<MixerNode>();
    if (k == "lfo") return make<LFONode>();
    if (k == "slider" || k == "knob") return make<ControlsNode>();
    if (k == "gain") return make<UtilityNode>();
    if (k == "env") return make<EnvelopeNode>();
    if (k == "atten") return make<AttenNode>();
    if (k == "text") return make<DSPNode>();
    return nullptr;
}

Factory factoryFor(const std::string& kind) {
    if (auto f = factoryCore(kind)) return f;
    if (auto f = factoryMI(kind)) return f;
    if (auto f = factoryFX(kind)) return f;
    if (auto f = factoryFX2(kind)) return f;
    if (auto f = factoryBuffers(kind)) return f;
    if (auto f = factorySeq(kind)) return f;
    if (auto f = factoryInst(kind)) return f;
    if (auto f = factoryFM(kind)) return f;
    return nullptr;
}

} // namespace pn
