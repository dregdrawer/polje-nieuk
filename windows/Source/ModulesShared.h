// Node types and helpers the UI reads (displays) — shared between module files and UI.
#pragma once
#include "Engine.h"
#include "Buffers.h"

namespace pn {

/// Modules that can feed a spectrum display (peq).
class SpectrumSource {
public:
    virtual ~SpectrumSource() = default;
    virtual void copyRecent(float* out, int count) const = 0;
    /// eq: what goes in, too (the display draws both)
    virtual bool copyRecentInput(float*, int) const { return false; }
};

/// scope: the last finished sweep per channel (points × min / max).
class ScopeNode : public DSPNode {
public:
    static constexpr int points = 256;
    ScopeNode(const ModuleSpec& s, double sr) : DSPNode(s, sr), shownMin(2 * points, 0.0f), shownMax(2 * points, 0.0f) {}
    std::vector<float> shownMin, shownMax;
    int version = 0;
};

namespace ParametricEQ {
    int bandCount(float choice);
    int shape(int band, int n);
    std::array<float, 5> coefficients(int shape, float freq, float gainDB, float q, double sampleRate);
    double responseDB(const std::function<float(int)>& p, double freq, double sampleRate);
    std::vector<float> defaultFrequencies(int n);
    inline int freqIndex(int b) { return 2 + 3 * b; }
    inline int gainIndex(int b) { return 3 + 3 * b; }
    inline int qIndex(int b) { return 4 + 3 * b; }
}


constexpr float kGateHigh = 0.5f;
inline float pitchCV(float semis) { return semis / 120; }

namespace Scales {
    extern const std::vector<std::string> names;
    float quantize(float semis, int scale);
}

/// Advances a step on its own clock inlet or on the global clock at a division (Sequencing.swift StepClock).
struct StepClock {
    double prevBeat = 0;
    EdgeDetector edge, resetEdge;
    int samplesSinceStep = 0, stepSamples = 12000;
    bool primed = false;
    int pulses = -1, samplesSincePulse = 0, pulsePeriod = 3000;
    double prevPulsePos = -1;
    void restart() { pulses = -1; prevPulsePos = -1; }
    bool tick(double beat, double div, double spb, const float* clockIn, bool running = true) {
        ++samplesSinceStep;
        bool fire = false;
        if (clockIn && !running) { edge.rising(*clockIn); return false; }
        if (clockIn) {
            ++samplesSincePulse;
            if (edge.rising(*clockIn)) {
                if (pulses >= 0 && samplesSincePulse > 16) pulsePeriod = samplesSincePulse;
                ++pulses; samplesSincePulse = 0;
            }
            if (pulses >= 0) {
                double r = std::max(div / 0.25, 1e-3);
                double pos = double(pulses) + std::min(double(samplesSincePulse) / double(std::max(pulsePeriod, 1)), 0.999);
                fire = std::floor(pos / r) != std::floor(prevPulsePos / r);
                prevPulsePos = pos;
                stepSamples = std::max(16, safeInt(r * double(pulsePeriod)));
            }
        } else {
            fire = !primed || crossed(prevBeat, beat, div);
            primed = true;
            stepSamples = std::max(16, safeInt(div * spb));
        }
        prevBeat = beat;
        if (fire) samplesSinceStep = 0;
        return fire;
    }
};

class KeysNode : public DSPNode {
public:
    static constexpr int keyCount = 25;
    static inline const std::string laneKey = "auto.keys";
    KeysNode(const ModuleSpec& s, double sr);
    void process(int frames, const float* const* in, uint64_t con, ProcessContext& ctx) override;
    std::map<std::string, std::vector<float>> defaultData() const override { return { { laneKey, std::vector<float>(autoSlots, -1.0f) } }; }
    void setData(const std::string& key, const std::vector<float>& values) override;
    void toggleLatched(int k);
    void clearLatched() { for (auto& l : latched) l = 0; }
    std::atomic<int> touchNote { -1 }, pressCount { 0 }, pressNote { -1 };
    std::array<float, keyCount> latched {};
    std::array<float, autoSlots> keyLane {};
    bool keyLaneOn = false;
    std::atomic<bool> recordingKeys { false }, recordedKeys { false };
private:
    int seenPress = 0, holdLeft = 0, orderCounter = 0, note = -1, gateLeft = 0, dip = 0, arpIndex = -1, arpDir = 1, lastTouch = -1;
    int recLast = -1, laneKeyPrev = -1;
    bool anyHeldBefore = false, gateOn = false, recStarted = false;
    std::array<int, keyCount> order {};
    std::array<int, keyCount * 3> scratch {};
    float pitchNow = 0;
    StepClock clock;
    XorShift rng { 0xA4B917E3u };
};

class SeqNode : public DSPNode {
public:
    static constexpr int steps = 64;
    static int length(float v) {
        if (!std::isfinite(v)) return 8;
        if (v <= 16) return std::clamp(int(std::round(v)), 1, 16);
        return v < 48 ? 32 : 64;
    }
    using DSPNode::DSPNode;
    void process(int frames, const float* const* in, uint64_t con, ProcessContext& ctx) override;
    std::map<std::string, std::vector<float>> defaultData() const override {
        return { { "pitch", std::vector<float>(steps, 0.0f) }, { "gate", std::vector<float>(steps, 1.0f) } };
    }
    void setData(const std::string& key, const std::vector<float>& values) override;
    std::array<float, steps> pitches {}, gates { [] { std::array<float, steps> a; a.fill(1); return a; }() };
private:
    int step = -1, heldStep = -1, dir = 1, gateLeft = 0;
    StepClock clock;
    XorShift rng { 0x5E90001u };
};

class TuringNode : public DSPNode {
public:
    static constexpr int historyLength = 16, maxLength = 64;
    static int length(float v) {
        if (!std::isfinite(v)) return 8;
        if (v <= 16) return std::clamp(int(std::round(v)), 2, 16);
        return v < 48 ? 32 : 64;
    }
    static bool plays(uint64_t r, float density) { return density >= 1 || float(((r * 0x9E3779B1ull) >> 24) & 0xFF) / 256 < density; }
    using DSPNode::DSPNode;
    void process(int frames, const float* const* in, uint64_t con, ProcessContext& ctx) override;
    std::atomic<uint64_t> regNow { 0x3B916E2DA5C3ull }, playsBits { 0 };
    std::array<float, maxLength> loopNotes {};
private:
    static constexpr uint64_t seed = 0x3B916E2DA5C3ull;
    uint64_t reg = seed;
    int displayCountdown = 0, gateLeft = 0, head = 0;
    StepClock clock;
    XorShift rng { 0x7E571A9Bu };
    float cvNow = 0, noteNow = 0;
};

/// Step patterns (samplerack, drumsynth, drums, roll): kept at 128 steps per lane; the length goes 1 ... 32, 64, 128.
namespace StepPattern {
    constexpr int steps = 128, legacySteps = 32;
    /// a pattern saved at 32 steps per lane, spread onto 128 (the same steps, the rest empty)
    inline std::vector<float> widen(const std::vector<float>& v, int lanes) {
        if (int(v.size()) != lanes * legacySteps) return v;
        std::vector<float> out(size_t(lanes * steps), 0.0f);
        for (int l = 0; l < lanes; ++l) for (int s = 0; s < legacySteps; ++s) out[size_t(l * steps + s)] = v[size_t(l * legacySteps + s)];
        return out;
    }
}

class RollNode : public DSPNode {
public:
    // every note it can play: 7 octaves, row 0 = `lowest` (C-3); 2 octaves on screen, scroll for the rest
    static constexpr int steps = StepPattern::steps, rows = 84, shown = 24, lowest = -36, voices = kMaxVoices;
    using DSPNode::DSPNode;
    void process(int frames, const float* const* in, uint64_t con, ProcessContext& ctx) override;
    std::map<std::string, std::vector<float>> defaultData() const override { return { { "grid", std::vector<float>(steps * rows, 0.0f) } }; }
    // grid: 0 nothing, 1 a note starts, 2 the note from the step before carries on; vel: each note's velocity
    static constexpr float defaultVelocity = 100.0f / 127;      // velocities are shown 0 … 127
    RollNode(const ModuleSpec& s, double sr) : DSPNode(s, sr) { vel.fill(defaultVelocity); }
    void setData(const std::string& key, const std::vector<float>& values) override {
        if (key == "vel") {
            for (int k = 0; k < steps * rows; ++k) vel[size_t(k)] = k < int(values.size()) && std::isfinite(values[size_t(k)]) ? std::clamp(values[size_t(k)], 0.0f, 1.0f) : defaultVelocity;
            return;
        }
        if (key != "grid") return;
        auto v = StepPattern::widen(values, rows);              // a 32-step pattern from before
        for (int k = 0; k < steps * rows; ++k) {
            float x = k < int(v.size()) && std::isfinite(v[size_t(k)]) ? v[size_t(k)] : 0.0f;
            grid[size_t(k)] = x > 1.5f ? 2.0f : (x > 0.5f ? 1.0f : 0.0f);
        }
    }
    bool isOn(int step, int row) const { return grid[size_t(row * steps + step)] > 0.5f; }
    bool starts(int step, int row) const { float x = grid[size_t(row * steps + step)]; return x > 0.5f && x < 1.5f; }
    bool carries(int step, int row) const { return grid[size_t(row * steps + step)] > 1.5f; }
    std::optional<int> noteStart(int step, int row) const {
        if (!isOn(step, row)) return std::nullopt;
        int s = step; while (s > 0 && carries(s, row)) --s;
        return s;
    }
    int noteLength(int start, int row) const { int n = 1; while (start + n < steps && carries(start + n, row)) ++n; return n; }
    std::array<float, steps * rows> grid {}, vel {};
private:
    int step = -1;
    StepClock clock;
    float held[voices] = {}, noteVel[voices] = { defaultVelocity, defaultVelocity, defaultVelocity, defaultVelocity };
    bool on[voices] = {}, taken[voices] = {};
    int gateLeft[voices] = {}, gap[voices] = {};
};

class DrumsNode : public DSPNode {
public:
    static constexpr int steps = StepPattern::steps, lanes = 8;
    using DSPNode::DSPNode;
    void process(int frames, const float* const* in, uint64_t con, ProcessContext& ctx) override;
    std::map<std::string, std::vector<float>> defaultData() const override { return { { "hits", std::vector<float>(steps * lanes, 0.0f) } }; }
    void setData(const std::string& key, const std::vector<float>& values) override {
        if (key != "hits") return;
        auto v = StepPattern::widen(values, lanes);             // a 32-step pattern from before
        for (int k = 0; k < std::min(int(v.size()), steps * lanes); ++k) hits[size_t(k)] = std::isfinite(v[size_t(k)]) ? v[size_t(k)] : 0.0f;
    }
    std::array<float, steps * lanes> hits {};
private:
    int step = -1;
    int left[lanes] = {};
    StepClock clock;
};

namespace Chords {
    extern const std::vector<std::string> keys, scales, degrees, sizes, types, spreads, directions;
    struct Built { std::vector<float> notes; int root, quality; };
    Built build(int mode, int key, int scale, int degree, int size, int type, int voices, int inversion, int spread,
                int octave, float shift, const std::vector<float>* previous);
}


namespace RackLayout {
    constexpr int pads = 16, steps = StepPattern::steps, perPad = 7, globals = 5;
    inline int base(int pad) { return globals + pad * perPad; }
    extern const std::vector<std::string> kitNames;
}
StereoAudio rackKit(int k, double sampleRate);

class RackNode : public DSPNode {
public:
    RackNode(const ModuleSpec& s, double sr);
    void process(int frames, const float* const* in, uint64_t con, ProcessContext& ctx) override;
    std::map<std::string, std::vector<float>> defaultData() const override { return { { "hits", starterBeat() } }; }
    void setData(const std::string& key, const std::vector<float>& values) override;
    static std::vector<float> starterBeat();
    void loadPad(int k, const StereoAudio& audio, const std::string& name);
    void resetPad(int k);
    StereoAudio sample(int k) const;
    int padLength(int k) const { return k >= 0 && k < RackLayout::pads ? int(padL[size_t(k)].size()) : 0; }
    std::array<float, RackLayout::pads * RackLayout::steps> hits {};
    std::vector<std::string> padNames;
    int contentVersion = 0;
    std::atomic<int> audition { -1 };
    std::array<int, RackLayout::pads> hitCount {};     // hits per pad (the display flashes the pad on each)
private:
    void install(int k, const StereoAudio& audio, const std::string& name);
    void trigger(int k);
    std::vector<std::vector<float>> padL, padR;
    LoadGuard guardian;
    double pos[RackLayout::pads] = {};
    float env[RackLayout::pads] = {};
    bool attacking[RackLayout::pads] = {}, active[RackLayout::pads] = {};
    int pending[RackLayout::pads];
    int step = -1, extCount = -1;
    StepClock clock;
    EdgeDetector clockEdge, resetEdge;
};

namespace DrumSynthLayout {
    constexpr int voices = 4, steps = StepPattern::steps, perVoice = 14, shown = 12, globals = 5;
    inline int base(int v) { return globals + v * perVoice; }
    extern const std::vector<std::string> names;
    extern const std::vector<int> engines;
    std::string label(int v, int engine);
}

class DrumSynthNode : public DSPNode {
public:
    DrumSynthNode(const ModuleSpec& s, double sr);
    ~DrumSynthNode() override;
    void process(int frames, const float* const* in, uint64_t con, ProcessContext& ctx) override;
    static std::vector<float> starterBeat();
    std::map<std::string, std::vector<float>> defaultData() const override { return { { "hits", starterBeat() } }; }
    void setData(const std::string& key, const std::vector<float>& values) override;
    std::array<float, DrumSynthLayout::voices * DrumSynthLayout::steps> hits {};
    std::atomic<int> audition { -1 };
    int hitCount(int v) const;                         // hits per voice (the display flashes its pad on each)
private:
    struct Impl;
    std::unique_ptr<Impl> impl;
};

class WavetableNode : public DSPNode {
public:
    static constexpr int frames = 4, points = 256, harmonics = points / 2, tableLen = 2048, levels = 8;
    static constexpr int frameSize = levels * (tableLen + 1), bufferSize = frames * frameSize;
    WavetableNode(const ModuleSpec& s, double sr);
    void process(int nframes, const float* const* in, uint64_t con, ProcessContext& ctx) override;
    std::map<std::string, std::vector<float>> defaultData() const override { return { { "wave", starter() } }; }
    void setData(const std::string& key, const std::vector<float>& values) override;
    static std::vector<float> starter();
    static std::vector<float> shape(const std::string& name);
    static const std::vector<std::string> presets;
    std::vector<float> waveData() const { return drawn; }
    void rebuild(int frame) { swapIn({ frame }); }
    void rebuildAll() { swapIn({ 0, 1, 2, 3 }); }
    std::vector<float> drawn;     // frames × points
    int version = 0;
private:
    void swapIn(const std::vector<int>& changed);
    void build(int f, float* out);
    std::vector<float> tables;
    std::atomic<int> activeBuf { 0 }, inUse { 0 }, blocks { 0 };
    double phase[kMaxVoices] = {};
    float pos = 0, env[kMaxVoices] = { 1, 1, 1, 1 };
    bool rising[kMaxVoices] = {};
    EdgeDetector trigEdge[kMaxVoices];
};

// sampler helpers for the UI
void samplerAnalyze(DSPNode* n);
void samplerAudition(DSPNode* n, int slice);
int samplerSliceAt(DSPNode* n, double x);

} // namespace pn
