// polje nieuk for Windows (and any JUCE platform): the audio engine.
// A C++ port of Sources/PoljeNieukCore (Swift). Same patch format, same module specs, same sound.
#pragma once
#include <JuceHeader.h>
#include <array>
#include <atomic>
#include <cmath>
#include <functional>
#include <map>
#include <memory>
#include <optional>
#include <set>
#include <string>
#include <vector>

namespace pn {

constexpr int kMaxBlock = 64;          // largest block a node processes (also the control rate)
constexpr int kParamPortBase = 1000;   // cable toPort ≥ this = a parameter (toPort - base)
constexpr int kMaxHardwareChannels = 32;
constexpr int kReadoutCount = 32;
constexpr int kMaxVoices = 4;           // notes one cable can carry (a chord)

// ---------------------------------------------------------------- small DSP helpers (DSPUtil.swift)

inline float dbToGain(float db) { return std::pow(10.0f, db / 20.0f); }
inline int clampIndex(float v, int count) {
    if (!std::isfinite(v) || count <= 0) return 0;
    float r = std::round(v);
    if (r <= 0) return 0;
    if (r >= float(count - 1)) return count - 1;
    return int(r);
}
inline int safeInt(double v, int lo = 0, int hi = 2147483647) {
    if (!std::isfinite(v)) return lo;
    if (v <= lo) return lo;
    if (v >= hi) return hi;
    return int(v);
}
/// the beat moved into a new multiple of `unit` (or jumped back); never below 0 (stopped transport)
inline bool crossed(double prev, double now, double unit) {
    return now >= 0 && (now < prev || std::floor(now / unit) != std::floor(prev / unit));
}
inline float readLinear(const float* buf, int len, double pos) {
    if (len <= 0) return 0;
    double p = pos;
    if (!(p >= 0 && p < double(len))) {
        if (!std::isfinite(p)) return 0;
        p = std::fmod(p, double(len));
        if (p < 0) p += len;
        if (p >= len) p = 0;
    }
    int i = std::min(int(p), len - 1);
    float f = float(p - i);
    float a = buf[i], b = buf[i + 1 >= len ? 0 : i + 1];
    return a + (b - a) * f;
}
inline double wrap(double p, double len) { double x = std::fmod(p, len); return x < 0 ? x + len : x; }
inline float softClip(float x) {
    float a = std::abs(x);
    if (a <= 0.8f) return x;
    float y = 0.8f + 0.2f * std::tanh((a - 0.8f) / 0.2f);
    return x < 0 ? -y : y;
}
/// 1 V/oct CV (0.1 = 1 octave) to semitones, limited to ±10 V
inline float cvSemitones(float v) { return std::isfinite(v) ? std::clamp(v, -1.0f, 1.0f) * 120.0f : 0.0f; }
inline float onePoleCoef(float ms, double sr) { return ms <= 0 ? 1.0f : 1.0f - std::exp(-1.0f / (ms * 0.001f * float(sr))); }

struct XorShift {
    uint32_t s;
    explicit XorShift(uint32_t seed = 0x9E3779B9u) : s(seed == 0 ? 1 : seed) {}
    float next() { s ^= s << 13; s ^= s >> 17; s ^= s << 5; return float(s) / float(UINT32_MAX); }
};
struct PeakMeter {
    float value = 0;
    float update(const float* b, int n, double sr) {
        float m = 0; for (int i = 0; i < n; ++i) m = std::max(m, std::abs(b[i]));
        return update(m, n, sr);
    }
    float update(float m, int n, double sr) {
        value = std::max(std::isfinite(m) ? m : 0.0f, value * std::pow(0.5f, float(n) / float(sr * 0.12)));
        return value;
    }
};
struct EdgeDetector {
    bool high = false;
    bool rising(float x) {
        if (!high && x > 0.2f) { high = true; return true; }
        if (high && x < 0.1f) high = false;
        return false;
    }
};
/// Zero-delay-feedback state-variable filter (Simper)
struct SVF {
    float ic1 = 0, ic2 = 0, a1 = 0, a2 = 0, a3 = 0, k = 1.414f;
    void set(float freq, float sr, float kk) {
        float g = std::tan(juce::MathConstants<float>::pi * std::clamp(freq, 5.0f, sr * 0.45f) / sr);
        k = kk; a1 = 1 / (1 + g * (g + k)); a2 = g * a1; a3 = g * a2;
    }
    struct Out { float low, band, high; };
    Out process(float x) {
        float v3 = x - ic2, v1 = a1 * ic1 + a2 * v3, v2 = ic2 + a2 * ic1 + a3 * v3;
        ic1 = 2 * v1 - ic1; ic2 = 2 * v2 - ic2;
        return { v2, v1, x - k * v1 - v2 };
    }
};
inline float lfoShape(int shape, double phase) {
    float p = float(phase - std::floor(phase));
    switch (shape) {
        case 0: return std::sin(2 * juce::MathConstants<float>::pi * p);
        case 1: return p < 0.5f ? 4 * p - 1 : 3 - 4 * p;
        case 2: return 2 * p - 1;
        default: return p < 0.5f ? 1.0f : -1.0f;
    }
}

namespace Divisions {
    extern const std::vector<std::string> names;
    double beats(float v);
    int index(const std::string& name);
}

// ---------------------------------------------------------------- module specs (ModuleSpec.swift)

enum class ParamKind { continuous, integer, toggle, choice, trigger };
enum class ParamCurve { linear, exponential, cubic };

struct ParamSpec {
    std::string key, name;
    float min = 0, max = 1, def = 0;
    std::string unit;
    ParamKind kind = ParamKind::continuous;
    ParamCurve curve = ParamCurve::linear;
    std::vector<std::string> options;   // choice
    std::vector<float> allowed;         // only these values (ascending), e.g. seq length 1…16, 32, 64

    static ParamSpec cont(std::string k, std::string n, float lo, float hi, float d, std::string unit = "",
                          ParamCurve c = ParamCurve::linear) {
        ParamSpec p; p.key = k; p.name = n; p.min = lo; p.max = hi; p.def = d; p.unit = unit; p.curve = c; return p;
    }
    static ParamSpec choice(std::string k, std::string n, std::vector<std::string> opts, int def) {
        ParamSpec p; p.key = k; p.name = n; p.min = 0; p.max = float(opts.size() - 1); p.def = float(def);
        p.kind = ParamKind::choice; p.options = std::move(opts); return p;
    }
    static ParamSpec toggle(std::string k, std::string n, bool on) {
        ParamSpec p; p.key = k; p.name = n; p.def = on ? 1.0f : 0.0f; p.kind = ParamKind::toggle; return p;
    }
    static ParamSpec trigger(std::string k, std::string n) {
        ParamSpec p; p.key = k; p.name = n; p.kind = ParamKind::trigger; return p;
    }
    static ParamSpec integer(std::string k, std::string n, int lo, int hi, int d) {
        ParamSpec p; p.key = k; p.name = n; p.min = float(lo); p.max = float(hi); p.def = float(d);
        p.kind = ParamKind::integer; return p;
    }
    bool isTrigger() const { return kind == ParamKind::trigger; }
    float snapped(float v) const;
    float normalized(float v) const;
    float valueFromNormalized(float n) const;
    std::string display(float v) const;
};

enum class BypassMode { through, silent, none };

class DSPNode;
struct ModuleSpec;
using Factory = std::function<std::unique_ptr<DSPNode>(const ModuleSpec&, double)>;

struct ModuleSpec {
    std::string kind, name, category, summary;
    std::vector<std::string> aliases, inputs, outputs;
    std::vector<ParamSpec> params;
    std::vector<int> polyOutputs;   // outlets that can carry a chord
    bool outputsAreCV = false;
    Factory factory;          // null: not ported to Windows yet (box shows, stays silent)
    int paramIndex(const std::string& key) const;
    BypassMode bypass() const;
    std::vector<int> bypassRouting() const;
};

// ---------------------------------------------------------------- per-block context and the node base

struct ProcessContext {
    double sampleRate;
    int frames = 0;
    static constexpr int maxChannels = 64;
    float* inputs[maxChannels];
    int inputCount = 0;
    float* outputs[maxChannels];
    int outputCount = 0;
    double beat[kMaxBlock];
    double samplesPerBeat;
    bool externalClock = false;
    bool running = true;
    bool stopPending = false;
    double lastBeat = 0;
    float dummy[kMaxBlock] = {};
    explicit ProcessContext(double sr) : sampleRate(sr), samplesPerBeat(sr * 0.5) {
        for (int i = 0; i < maxChannels; ++i) { inputs[i] = dummy; outputs[i] = dummy; }
        std::fill(std::begin(beat), std::end(beat), 0.0);
    }
    double bpm() const { return 60 * sampleRate / samplesPerBeat; }
};

struct ParamRT { float min, max; bool exp, cubic, round, trigger, semis; };

struct PatchNode;

class DSPNode {
public:
    static constexpr double autoBeats = 16;
    static constexpr int autoSlots = 256;

    DSPNode(const ModuleSpec& spec, double sampleRate);
    virtual ~DSPNode() = default;

    virtual void process(int frames, const float* const* inputs, uint64_t connected, ProcessContext& ctx) {
        juce::ignoreUnused(frames, inputs, connected, ctx);
    }
    virtual void setData(const std::string& key, const std::vector<float>& values) { juce::ignoreUnused(key, values); }
    virtual std::map<std::string, std::vector<float>> defaultData() const { return {}; }

    void syncTo(const PatchNode& n);
    void loadAutomation(const std::map<std::string, std::vector<float>>& data);
    void setAutomation(int i, const std::vector<float>* values);
    static std::string autoKey(const std::string& k) { return "auto." + k; }

    // audio thread
    void syncParams();
    void applyAutomation(double beat);
    void applyMod(int i, float mod, float position = NAN);
    bool isConnected(uint64_t mask, int i) const { return (mask >> i) & 1u; }
    bool consumeTrigger(int i) { if (params[size_t(i)] > 0.5f) { params[size_t(i)] = 0; return true; } return false; }

    const double sampleRate;
    const ModuleSpec& spec;
    const int paramCount;
    std::vector<float> base, params;     // knob positions (UI) / effective values (audio)
    std::array<float, kReadoutCount> readouts {};
    std::vector<std::vector<float>> outputs;   // one kMaxBlock buffer per outlet
    std::vector<float> outLevel;               // UI: activity per outlet
    std::atomic<bool> bypassed { false };
    float bypassMix = 0;
    std::vector<int> routing;
    std::vector<float> autoLane;               // paramCount × autoSlots
    std::vector<char> autoOn, autoHold;
    int autoCount = 0;
    double autoPosition = 0;
    int nonFinite = 0;
    float* out(int k) { return outputs[size_t(k)].data(); }
    std::vector<int> outVoices, inVoices;      // notes per outlet / inlet this block
    static const float* voice(const float* input, int v) { return input + v * kMaxBlock; }
    float* outVoice(int k, int v) { return outputs[size_t(k)].data() + v * kMaxBlock; }
    uint64_t cvChannels = 0;                   // out: channels fed only by control voltages
    uint64_t patchedOutputs = 0;               // bit k: outlet k has a cable (rack sends a pad to its own outlet)
    virtual void clearState() {}

private:
    std::vector<ParamRT> rt;
    std::vector<float> modPrev;
};

/// Streams audio between the host rate and a module's native rate (Instruments.swift RateBridge).
class RateBridge {
public:
    RateBridge(double hostRate, double nativeRate, int block, int chIn, int chOut);
    float* inChannel(int c) { return inBuf.data() + c * block; }
    float* outChannel(int c) { return outBlock.data() + c * block; }
    template <class In, class Render, class Out>
    void run(int frames, In input, Render render, Out output) {
        for (int i = 0; i < frames; ++i) {
            for (int c = 0; c < chIn; ++c) {
                float x = input(c, i);
                if (filtered && ratio < 1) { x = aaIn[size_t(c)].process(x).low; x = aaIn2[size_t(c)].process(x).low; }
                cur[size_t(c)] = x;
            }
            while (pin <= 1) {
                float f = float(pin);
                for (int c = 0; c < chIn; ++c) inBuf[size_t(c * block + inCount)] = prev[size_t(c)] + (cur[size_t(c)] - prev[size_t(c)]) * f;
                ++inCount;
                pin += step;
                if (inCount == block) {
                    render();
                    for (int c = 0; c < chOut; ++c) {
                        const float* src = outChannel(c); float* dst = ring.data() + c * cap;
                        for (int k = 0; k < block; ++k) dst[(written + k) % cap] = src[k];
                    }
                    written += block;
                    inCount = 0;
                }
            }
            pin -= 1;
            for (int c = 0; c < chIn; ++c) prev[size_t(c)] = cur[size_t(c)];
            double r = readPos;
            for (int c = 0; c < chOut; ++c) {
                float y = 0;
                if (r >= 0) {
                    const float* b = ring.data() + c * cap;
                    long i0 = long(r); float f = float(r - double(i0));
                    float a = b[i0 % cap], bb = b[(i0 + 1) % cap];
                    y = a + (bb - a) * f;
                }
                if (filtered && ratio < 1) { y = aaOut[size_t(c)].process(y).low; y = aaOut2[size_t(c)].process(y).low; }
                output(c, i, y);
            }
            readPos += ratio;
            double lag = double(written) - readPos;
            if (lag > double(cap - block * 2) || lag < 2) readPos = double(written) - double(block + 4);
        }
    }
    const int block, chIn, chOut;
private:
    double ratio, step;
    bool filtered;
    std::vector<float> inBuf, outBlock, prev, cur, ring;
    int cap, inCount = 0;
    long written = 0;
    double pin = 0, readPos;
    std::vector<SVF> aaIn, aaIn2, aaOut, aaOut2;
};

// ---------------------------------------------------------------- registry

namespace Registry {
    const std::vector<ModuleSpec>& all();
    const ModuleSpec* spec(const std::string& kind);
    extern const std::vector<std::string> categories;
    std::vector<const ModuleSpec*> search(const std::string& query);
}

// ---------------------------------------------------------------- patch (Patch.swift) — same JSON

struct PatchNode {
    juce::String id;                    // UUID, as in the Mac / iPad files
    std::string kind;
    double x = 0, y = 0;
    std::map<std::string, float> params;
    bool collapsed = false, bypassed = false;
    std::map<std::string, std::vector<float>> data;
    std::optional<double> w, dh, z;
    std::optional<juce::String> text;
    std::optional<juce::String> highlight;   // a coloured frame around the box ("#rrggbb")
    std::optional<std::array<double, 2>> pin; // locked to the screen: where it sits in the canvas view
    bool hideIn = false, hideOut = false;     // don't draw the cables going in / out (they still work)
};
struct PatchCable {
    juce::String id, fromNode, toNode;
    int fromPort = 0, toPort = 0;
};
struct PatchGroup {
    juce::String id, name;
    std::vector<juce::String> members;
};
struct Patch {
    static constexpr int currentVersion = 14;
    int version = currentVersion;
    std::vector<PatchNode> nodes;
    std::vector<PatchCable> cables;
    std::optional<double> tempo;
    std::vector<PatchGroup> groups;
    int index(const juce::String& id) const;
    static juce::String newID();

    static std::optional<Patch> fromJSON(const juce::String& json);
    Patch migrated() const;
    std::optional<std::pair<Patch, juce::String>> replacing(const juce::String& id, const std::string& kind) const;
    std::pair<Patch, std::map<juce::String, juce::String>> withFreshIDs() const;
    bool operator==(const Patch& o) const { return toJSON() == o.toJSON(); }
    bool operator!=(const Patch& o) const { return !(*this == o); }
    juce::String toJSON() const;
};

// ---------------------------------------------------------------- the graph host (GraphHost.swift)

class CompiledGraph;

class GraphHost {
public:
    explicit GraphHost(double sampleRate = 48000);
    ~GraphHost();
    /// main thread: nodes or cables changed
    void load(const Patch& patch);
    void setSampleRate(double sr);
    DSPNode* node(const juce::String& id);
    void transport(int t);        // 0 play, 1 pause, 2 stop
    void renew(const juce::String& id, const Patch& patch);
    void clearReadouts();
    double currentBeat() const { return ctx.lastBeat; }
    bool isPlaying() const { return ctx.running; }
    double clockBPM() const { return ctx.bpm(); }
    bool externalClock() const { return ctx.externalClock; }
    double defaultBPM = 120;
    double sampleRate;
    /// audio thread
    void process(int frames, const float* const* inputs, int inputCount, float* const* outputs, int outputCount);
private:
    std::shared_ptr<CompiledGraph> compile(const Patch& patch);
    std::map<juce::String, std::unique_ptr<DSPNode>> nodes;
    std::vector<std::unique_ptr<DSPNode>> retiredNodes;
    ProcessContext ctx;
    std::shared_ptr<CompiledGraph> live;
    std::atomic<CompiledGraph*> slot { nullptr };
    std::vector<std::pair<std::shared_ptr<CompiledGraph>, juce::uint32>> retired;
    std::vector<std::pair<std::unique_ptr<DSPNode>, juce::uint32>> retiredOwned;
    std::vector<float> zero;
    Patch lastPatch;
    void purge();
    bool isCV(const juce::String& id, int port, const std::vector<PatchCable>& cables, int depth);
};

/// Undo / redo: whole-patch snapshots (UndoHistory.swift)
struct UndoHistory {
    Patch committed;
    std::vector<Patch> undoStack, redoStack;
    size_t limit = 200;
    bool canUndo() const { return !undoStack.empty(); }
    bool canRedo() const { return !redoStack.empty(); }
    void commit(const Patch& cur) {
        if (cur == committed) return;
        undoStack.push_back(committed);
        if (undoStack.size() > limit) undoStack.erase(undoStack.begin(), undoStack.begin() + long(undoStack.size() - limit));
        redoStack.clear(); committed = cur;
    }
    std::optional<Patch> undo() {
        if (undoStack.empty()) return std::nullopt;
        redoStack.push_back(committed); committed = undoStack.back(); undoStack.pop_back(); return committed;
    }
    std::optional<Patch> redo() {
        if (redoStack.empty()) return std::nullopt;
        undoStack.push_back(committed); committed = redoStack.back(); redoStack.pop_back(); return committed;
    }
    void reset(const Patch& p, bool keep) { committed = p; if (!keep) { undoStack.clear(); redoStack.clear(); } }
};

} // namespace pn
