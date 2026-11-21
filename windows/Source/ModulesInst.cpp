// rack~, drumsynth~, wave~ — ports of Rack.swift, Instruments.swift (DrumSynthNode) and Wavetable.swift.
#include "Modules.h"
#include "ModulesShared.h"
#include <thread>
extern "C" {
#include "mi_bridge.h"
}

namespace pn {

// ---------------------------------------------------------------- rack~

namespace RackLayout {
const std::vector<std::string> kitNames = { "kick", "snare", "closed hat", "open hat", "clap", "rim", "low tom", "mid tom",
                                            "hi tom", "crash", "ride", "cowbell", "shaker", "clave", "808", "zap" };
}

struct SplitMix {
    uint64_t s;
    explicit SplitMix(uint64_t seed) : s(seed) {}
    uint64_t next() {
        s += 0x9E3779B97F4A7C15ull;
        uint64_t z = s;
        z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
        z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
        return z ^ (z >> 31);
    }
    float nextFloat() { return float(next() >> 40) / float(1 << 24); }
};

StereoAudio rackKit(int k, double sr) {
    SplitMix g(uint64_t(1000 + k));
    const double pi = juce::MathConstants<double>::pi;
    auto noise = [&] { return g.nextFloat() * 2 - 1; };
    auto render = [&](double seconds, const std::function<float(double)>& f) {
        int n = int(seconds * sr);
        std::vector<float> v(static_cast<size_t>(n));
        for (int i = 0; i < n; ++i) v[size_t(i)] = f(double(i) / sr);
        return v;
    };
    auto env = [](double t, double d) { return float(std::exp(-t / d)); };
    double phase = 0;
    auto sweep = [&](double t, double f0, double f1, double kk) {
        double f = f1 + (f0 - f1) * std::exp(-t / kk);
        phase += 2 * pi * f / sr;
        return float(std::sin(phase));
    };
    float hp = 0, lastIn = 0;
    auto highpass = [&](float x) { hp = 0.86f * (hp + x - lastIn); lastIn = x; return hp; };
    float bp1 = 0, bp2 = 0;
    auto band = [&](float x, double fc, float q) {
        float w = float(2 * std::sin(pi * std::min(fc, sr * 0.2) / sr));
        bp1 += w * bp2; float hpv = x - bp1 - q * bp2; bp2 += w * hpv;
        return bp2;
    };
    std::vector<float> mono;
    switch (k) {
        case 0: mono = render(0.5, [&](double t) { float a = sweep(t, 160, 46, 0.04) * env(t, 0.16) * 0.95f; return a + (t < 0.004 ? noise() * 0.3f : 0.0f); }); break;
        case 1: mono = render(0.35, [&](double t) { float a = float(std::sin(2 * pi * 185 * t)) * env(t, 0.06) * 0.5f; return a + band(noise(), 2400, 0.7f) * env(t, 0.11) * 0.9f; }); break;
        case 2: mono = render(0.12, [&](double t) { return highpass(noise()) * env(t, 0.02) * 0.7f; }); break;
        case 3: mono = render(0.6, [&](double t) { return highpass(noise()) * env(t, 0.18) * 0.6f; }); break;
        case 4: mono = render(0.4, [&](double t) {
            float bursts = (t < 0.01 || (t > 0.012 && t < 0.02) || (t > 0.024 && t < 0.032)) ? 1.0f : 0.0f;
            return band(noise(), 1500, 0.8f) * (bursts * 0.9f + env(t, 0.09) * 0.7f); }); break;
        case 5: mono = render(0.08, [&](double t) { float a = float(std::sin(2 * pi * 820 * t)) * env(t, 0.012) * 0.7f; return a + (t < 0.002 ? noise() * 0.5f : 0.0f); }); break;
        case 6: case 7: case 8: {
            double f = k == 6 ? 95.0 : k == 7 ? 135.0 : 190.0;
            mono = render(0.6, [&](double t) { return sweep(t, f * 1.6, f, 0.05) * env(t, 0.18) * 0.85f; }); break;
        }
        case 9: mono = render(1.8, [&](double t) {
            float metal = float(std::sin(2 * pi * 3220 * t) * std::sin(2 * pi * 4630 * t));
            return (highpass(noise()) * 0.7f + metal * 0.3f) * env(t, 0.55) * 0.6f; }); break;
        case 10: mono = render(1.4, [&](double t) {
            float m = float(std::sin(2 * pi * 2980 * t) + 0.6 * std::sin(2 * pi * 4410 * t) + 0.4 * std::sin(2 * pi * 6120 * t));
            float a = (m * 0.2f + highpass(noise()) * 0.15f) * env(t, 0.45);
            return a + float(std::sin(2 * pi * 3800 * t)) * env(t, 0.01) * 0.3f; }); break;
        case 11: mono = render(0.4, [&](double t) {
            float sq = float((std::sin(2 * pi * 540 * t) > 0 ? 1 : -1) + (std::sin(2 * pi * 800 * t) > 0 ? 1 : -1)) * 0.5f;
            return band(sq, 800, 0.6f) * env(t, 0.09) * 0.8f; }); break;
        case 12: mono = render(0.18, [&](double t) { return highpass(noise()) * float(std::min(t / 0.03, 1.0)) * env(t, 0.04) * 0.6f; }); break;
        case 13: mono = render(0.1, [&](double t) { return float(std::sin(2 * pi * 2500 * t)) * env(t, 0.018) * 0.7f; }); break;
        case 14: mono = render(1.6, [&](double t) { return sweep(t, 90, 50, 0.03) * env(t, 0.5) * 0.9f; }); break;
        default: mono = render(0.2, [&](double t) { return sweep(t, 2400, 90, 0.02) * env(t, 0.06) * 0.6f; });
    }
    return StereoAudio(mono);
}

std::vector<float> RackNode::starterBeat() {
    std::vector<float> h(size_t(RackLayout::pads * RackLayout::steps), 0.0f);
    for (int s : { 0, 8 }) h[size_t(0 * RackLayout::steps + s)] = 1;
    for (int s : { 4, 12 }) h[size_t(1 * RackLayout::steps + s)] = 1;
    for (int s = 0; s < 16; s += 2) h[size_t(2 * RackLayout::steps + s)] = 1;
    return h;
}

RackNode::RackNode(const ModuleSpec& s, double sr) : DSPNode(s, sr) {
    padL.resize(RackLayout::pads); padR.resize(RackLayout::pads);
    padNames = RackLayout::kitNames;
    for (auto& p : pending) p = -1;
    for (int k = 0; k < RackLayout::pads; ++k) install(k, rackKit(k, sr), RackLayout::kitNames[size_t(k)]);
    setData("hits", starterBeat());
}

void RackNode::setData(const std::string& key, const std::vector<float>& values) {
    if (key != "hits") return;
    for (int k = 0; k < RackLayout::pads * RackLayout::steps; ++k)
        hits[size_t(k)] = k < int(values.size()) && std::isfinite(values[size_t(k)]) ? values[size_t(k)] : 0.0f;
}

void RackNode::install(int k, const StereoAudio& a, const std::string& name) {
    padL[size_t(k)] = a.left; padR[size_t(k)] = a.right;
    size_t n = size_t(a.count());
    padL[size_t(k)].resize(n); padR[size_t(k)].resize(n);
    padNames[size_t(k)] = name;
    active[k] = false;
}

void RackNode::loadPad(int k, const StereoAudio& a, const std::string& name) {
    if (k < 0 || k >= RackLayout::pads) return;
    guardian.whileBusy([&] { install(k, a, name); });
    ++contentVersion;
}

void RackNode::resetPad(int k) {
    if (k < 0 || k >= RackLayout::pads) return;
    loadPad(k, rackKit(k, sampleRate), RackLayout::kitNames[size_t(k)]);
}

StereoAudio RackNode::sample(int k) const {
    if (k < 0 || k >= RackLayout::pads) return {};
    return StereoAudio(padL[size_t(k)], padR[size_t(k)]);
}

void RackNode::trigger(int k) {
    if (padL[size_t(k)].empty()) return;
    pos[k] = 0; env[k] = 0; attacking[k] = true; active[k] = true;
}

void RackNode::process(int frames, const float* const* in, uint64_t con, ProcessContext& ctx) {
    float* oL = out(0); float* oR = out(1);
    std::fill(oL, oL + frames, 0.0f); std::fill(oR, oR + frames, 0.0f);
    // a pad whose own outlet is patched plays there (mono) instead of in the L / R mix
    uint64_t own = patchedOutputs >> 2;
    for (int k = 0; k < RackLayout::pads; ++k) if ((own >> k) & 1u) std::fill(out(2 + k), out(2 + k) + frames, 0.0f);
    if (guardian.busy()) return;
    int len = clampIndex(params[0] - 1, RackLayout::steps) + 1;
    double div = Divisions::beats(params[1]);
    float swing = std::clamp(params[2], 0.0f, 0.5f), master = params[4];
    bool hasClock = isConnected(con, 0), hasReset = isConnected(con, 1);
    const float* ck = in[0]; const float* rs = in[1];
    bool anySolo = false;
    for (int k = 0; k < RackLayout::pads; ++k) if (params[size_t(RackLayout::base(k) + 6)] > 0.5f) anySolo = true;
    int a = audition.exchange(-1);
    if (a >= 0 && a < RackLayout::pads) trigger(a);
    float sr = float(sampleRate);
    if (ctx.stopPending) { extCount = -1; step = -1; }
    for (int i = 0; i < frames; ++i) {
        bool fired = false;
        if (hasReset && resetEdge.rising(rs[i])) { extCount = -1; step = -1; }
        if (hasClock) { if (clockEdge.rising(ck[i]) && ctx.running) { ++extCount; step = extCount % len; fired = true; } }
        else if (clock.tick(ctx.beat[i], div, ctx.samplesPerBeat, nullptr)) { step = safeInt(std::floor(ctx.beat[i] / div)) % len; fired = true; }
        if (fired && step >= 0) {
            int delay = step % 2 == 1 ? int(float(clock.stepSamples) * swing) : 0;
            for (int k = 0; k < RackLayout::pads; ++k)
                if (hits[size_t(k * RackLayout::steps + step)] > 0.5f) { if (delay == 0) trigger(k); else pending[k] = delay; }
        }
        float l = 0, r = 0;
        for (int k = 0; k < RackLayout::pads; ++k) {
            if (pending[k] >= 0) { if (pending[k] == 0) trigger(k); --pending[k]; }
            if (!active[k]) continue;
            auto& bl = padL[size_t(k)]; auto& br = padR[size_t(k)];
            int b = RackLayout::base(k), n = int(bl.size());
            double p = pos[k];
            int i0 = int(p);
            if (i0 >= n - 1) { active[k] = false; continue; }
            float f = float(p - i0);
            float xl = bl[size_t(i0)] + (bl[size_t(i0 + 1)] - bl[size_t(i0)]) * f;
            float xr = br[size_t(i0)] + (br[size_t(i0 + 1)] - br[size_t(i0)]) * f;
            if (attacking[k]) {
                float at = std::max(params[size_t(b + 1)], 0.0f) * 0.001f * sr;
                env[k] = at < 1 ? 1 : std::min(env[k] + 1 / at, 1.0f);
                if (env[k] >= 1) attacking[k] = false;
            } else {
                float d = std::max(params[size_t(b + 2)], 10.0f) * 0.001f * sr;
                env[k] *= std::exp(-6.9f / d);
                if (env[k] < 1e-4f) active[k] = false;
            }
            pos[k] = p + double(std::exp2(std::clamp(params[size_t(b)], -24.0f, 24.0f) / 12));
            bool audible = params[size_t(b + 5)] < 0.5f && (!anySolo || params[size_t(b + 6)] > 0.5f);
            if (!audible) continue;
            float gg = env[k] * params[size_t(b + 3)], pan = std::clamp(params[size_t(b + 4)], -1.0f, 1.0f);
            if ((own >> k) & 1u) { out(2 + k)[i] = (xl + xr) * 0.5f * gg * master; continue; }
            l += xl * gg * std::min(1.0f, 1 - pan); r += xr * gg * std::min(1.0f, 1 + pan);
        }
        oL[i] = l * master; oR[i] = r * master;
    }
    readouts[0] = float(step);
    for (int k = 0; k < RackLayout::pads; ++k) readouts[size_t(1 + k)] = active[k] ? env[k] : 0.0f;
}

// ---------------------------------------------------------------- drumsynth~

namespace DrumSynthLayout {
const std::vector<std::string> names = { "kick", "snare", "hi-hat", "perc" };
const std::vector<int> engines = { 21, 22, 23, 20 };
std::string label(int v, int engine) {
    return engine == engines[size_t(v)] ? names[size_t(v)] : Layouts::macroEngines[size_t(std::clamp(engine, 0, int(Layouts::macroEngines.size()) - 1))];
}
}

struct DrumSynthNode::Impl {
    static constexpr int V = DrumSynthLayout::voices;
    MIMacro* dsp[V];
    RateBridge bridge;
    MIMacroParams q[V] {};
    int gateLeft[V] = {}, pending[V] = { -1, -1, -1, -1 };
    float level[V] = {}, gl[V] = {}, gr[V] = {}, env[V] = { 1, 1, 1, 1 }, attackInc[V] = { 1, 1, 1, 1 }, decayMul[V] = { 1, 1, 1, 1 };
    bool aux[V] = {}, attacking[V] = {};
    int step = -1, extCount = -1;
    StepClock clock;
    EdgeDetector clockEdge, resetEdge;
    explicit Impl(double sr) : bridge(sr, MI_MACRO_RATE, MI_MACRO_BLOCK, V, V * 2) { for (auto& d : dsp) d = mi_macro_create(); }
    ~Impl() { for (auto& d : dsp) mi_macro_destroy(d); }
    void start(int v, int gate) { gateLeft[v] = gate; env[v] = attackInc[v] >= 1 ? 1.0f : 0.0f; attacking[v] = attackInc[v] < 1; }
};

std::vector<float> DrumSynthNode::starterBeat() {
    std::vector<float> h(size_t(DrumSynthLayout::voices * DrumSynthLayout::steps), 0.0f);
    for (int s : { 0, 8 }) h[size_t(s)] = 1;
    for (int s : { 4, 12 }) h[size_t(DrumSynthLayout::steps + s)] = 1;
    for (int s = 2; s < 16; s += 4) h[size_t(2 * DrumSynthLayout::steps + s)] = 1;
    return h;
}

DrumSynthNode::DrumSynthNode(const ModuleSpec& s, double sr) : DSPNode(s, sr), impl(std::make_unique<Impl>(sr)) {
    auto b = starterBeat();
    std::copy(b.begin(), b.end(), hits.begin());
}
DrumSynthNode::~DrumSynthNode() = default;

void DrumSynthNode::setData(const std::string& key, const std::vector<float>& values) {
    if (key != "hits") return;
    for (int k = 0; k < int(hits.size()); ++k) hits[size_t(k)] = k < int(values.size()) && std::isfinite(values[size_t(k)]) ? values[size_t(k)] : 0.0f;
}

void DrumSynthNode::process(int frames, const float* const* in, uint64_t con, ProcessContext& ctx) {
    static const float baseNotes[] = { 36, 50, 66, 60 };
    auto& m = *impl;
    const int V = Impl::V;
    int len = clampIndex(params[0] - 1, DrumSynthLayout::steps) + 1;
    double div = Divisions::beats(params[1]);
    float swing = std::clamp(params[2], 0.0f, 0.5f), master = params[4];
    bool hasClock = isConnected(con, 0), hasReset = isConnected(con, 1);
    const float* ck = in[0]; const float* rs = in[1];
    bool anySolo = false;
    for (int v = 0; v < V; ++v) if (params[size_t(DrumSynthLayout::base(v) + 13)] > 0.5f) anySolo = true;
    float sr = float(sampleRate);
    for (int v = 0; v < V; ++v) {
        int b = DrumSynthLayout::base(v);
        auto& q = m.q[v];
        q.engine = clampIndex(params[size_t(b)], int(Layouts::macroEngines.size()));
        q.note = baseNotes[v] + std::clamp(params[size_t(b + 1)], -48.0f, 48.0f);
        q.harmonics = params[size_t(b + 2)]; q.timbre = params[size_t(b + 3)]; q.morph = params[size_t(b + 4)];
        q.decay = params[size_t(b + 8)]; q.lpg_colour = params[size_t(b + 9)];
        q.trigger_patched = 1; q.level_patched = 0;
        float at = std::max(params[size_t(b + 6)], 0.0f) * 0.001f * sr;
        m.attackInc[v] = at < 1 ? 1 : 1 / at;
        m.decayMul[v] = std::exp(-6.9f / std::max(params[size_t(b + 7)] * 0.001f * sr, 1.0f));
    }
    int aud = audition.exchange(-1);
    if (aud >= 0 && aud < V) m.start(aud, int(sampleRate * 0.005));
    int gateLen = int(sampleRate * 0.005);
    for (int v = 0; v < V; ++v) {
        int b = DrumSynthLayout::base(v);
        bool audible = params[size_t(b + 12)] < 0.5f && (!anySolo || params[size_t(b + 13)] > 0.5f);
        float g = audible ? params[size_t(b + 10)] * master : 0;
        float pan = std::clamp(params[size_t(b + 11)], -1.0f, 1.0f);
        m.gl[v] = g * std::min(1.0f, 1 - pan); m.gr[v] = g * std::min(1.0f, 1 + pan);
        m.aux[v] = params[size_t(b + 5)] > 0.5f;
    }
    float* oL = out(0); float* oR = out(1);
    for (auto& l : m.level) l *= 0.9f;
    if (ctx.stopPending) { m.extCount = -1; m.step = -1; }
    m.bridge.run(frames, [&](int c, int i) -> float {
        if (c == 0) {
            bool fired = false;
            if (hasReset && m.resetEdge.rising(rs[i])) { m.extCount = -1; m.step = -1; }
            if (hasClock) { if (m.clockEdge.rising(ck[i]) && ctx.running) { ++m.extCount; m.step = m.extCount % len; fired = true; } }
            else if (m.clock.tick(ctx.beat[i], div, ctx.samplesPerBeat, nullptr)) { m.step = safeInt(std::floor(ctx.beat[i] / div)) % len; fired = true; }
            if (fired && m.step >= 0) {
                int delay = m.step % 2 == 1 ? int(float(m.clock.stepSamples) * swing) : 0;
                for (int v = 0; v < V; ++v)
                    if (hits[size_t(v * DrumSynthLayout::steps + m.step)] > 0.5f) { if (delay == 0) m.start(v, gateLen); else m.pending[v] = delay; }
            }
            for (int v = 0; v < V; ++v) if (m.pending[v] >= 0) { if (m.pending[v] == 0) m.start(v, gateLen); --m.pending[v]; }
        }
        bool on = m.gateLeft[c] > 0;
        if (c == V - 1) for (int v = 0; v < V; ++v) if (m.gateLeft[v] > 0) --m.gateLeft[v];
        return on ? 1.0f : 0.0f;
    }, [&] {
        for (int v = 0; v < V; ++v) {
            float mx = 0; const float* t = m.bridge.inChannel(v);
            for (int k = 0; k < m.bridge.block; ++k) mx = std::max(mx, t[k]);
            m.q[v].trigger = mx > 0.5f ? 1.0f : 0.0f;
            mi_macro_process(m.dsp[v], &m.q[v], m.bridge.outChannel(2 * v), m.bridge.outChannel(2 * v + 1));
        }
    }, [&](int c, int i, float x) {
        int v = c / 2;
        bool isAux = c % 2 == 1;
        if (isAux != m.aux[v]) return;
        if (v == 0) { oL[i] = 0; oR[i] = 0; }
        if (m.attacking[v]) { m.env[v] = std::min(m.env[v] + m.attackInc[v], 1.0f); if (m.env[v] >= 1) m.attacking[v] = false; }
        else m.env[v] *= m.decayMul[v];
        float y = x * m.env[v];
        oL[i] += y * m.gl[v]; oR[i] += y * m.gr[v];
        m.level[v] = std::max(m.level[v], std::abs(y));
    });
    readouts[0] = float(m.step);
    for (int v = 0; v < V; ++v) readouts[size_t(1 + v)] = std::min(m.level[v] * 2, 1.0f);
}

// ---------------------------------------------------------------- wave~

const std::vector<std::string> WavetableNode::presets = { "sine", "tri", "saw", "square", "pulse", "noise" };

std::vector<float> WavetableNode::shape(const std::string& name) {
    std::vector<float> v(points);
    juce::Random rnd;
    for (int i = 0; i < points; ++i) {
        float p = float(i) / float(points);
        if (name == "tri") v[size_t(i)] = p < 0.25f ? 4 * p : (p < 0.75f ? 2 - 4 * p : 4 * p - 4);
        else if (name == "saw") v[size_t(i)] = 1 - 2 * p;
        else if (name == "square") v[size_t(i)] = p < 0.5f ? 0.9f : -0.9f;
        else if (name == "pulse") v[size_t(i)] = p < 0.15f ? 0.9f : -0.9f;
        else if (name == "noise") v[size_t(i)] = rnd.nextFloat() * 1.8f - 0.9f;
        else v[size_t(i)] = std::sin(2 * juce::MathConstants<float>::pi * p);
    }
    return v;
}

std::vector<float> WavetableNode::starter() {
    std::vector<float> v;
    for (auto* n : { "sine", "tri", "saw", "square" }) { auto s = shape(n); v.insert(v.end(), s.begin(), s.end()); }
    return v;
}

WavetableNode::WavetableNode(const ModuleSpec& s, double sr) : DSPNode(s, sr) {
    drawn = starter();
    tables.assign(size_t(2 * bufferSize), 0.0f);
    rebuildAll();
}

void WavetableNode::setData(const std::string& key, const std::vector<float>& values) {
    if (key != "wave" || values.empty()) return;
    for (int k = 0; k < frames * points; ++k) {
        float v = k < int(values.size()) ? values[size_t(k)] : 0.0f;
        drawn[size_t(k)] = std::isfinite(v) ? std::clamp(v, -1.0f, 1.0f) : 0.0f;
    }
    rebuildAll();
}

static const std::vector<float>& cosT() {
    static const std::vector<float> t = [] { std::vector<float> v(WavetableNode::tableLen); for (int k = 0; k < WavetableNode::tableLen; ++k) v[size_t(k)] = std::cos(2 * juce::MathConstants<float>::pi * float(k) / float(WavetableNode::tableLen)); return v; }();
    return t;
}
static const std::vector<float>& sinT() {
    static const std::vector<float> t = [] { std::vector<float> v(WavetableNode::tableLen); for (int k = 0; k < WavetableNode::tableLen; ++k) v[size_t(k)] = std::sin(2 * juce::MathConstants<float>::pi * float(k) / float(WavetableNode::tableLen)); return v; }();
    return t;
}

void WavetableNode::swapIn(const std::vector<int>& changed) {
    int cur = activeBuf.load(std::memory_order_acquire), target = 1 - cur;
    int start = blocks.load(std::memory_order_relaxed), waited = 0;
    while (inUse.load(std::memory_order_acquire) == target && waited < 40) {
        std::this_thread::sleep_for(std::chrono::microseconds(100)); ++waited;
        if (waited == 20 && blocks.load(std::memory_order_relaxed) == start) break;
    }
    float* dst = tables.data() + target * bufferSize; const float* src = tables.data() + cur * bufferSize;
    for (int f = 0; f < frames; ++f)
        if (std::find(changed.begin(), changed.end(), f) == changed.end()) std::copy(src + f * frameSize, src + (f + 1) * frameSize, dst + f * frameSize);
    for (int f : changed) build(f, dst + f * frameSize);
    activeBuf.store(target, std::memory_order_release);
    ++version;
}

void WavetableNode::build(int f, float* outp) {
    const int N = points, H = harmonics, T = tableLen;
    const float* x = drawn.data() + f * N;
    auto& C = cosT(); auto& S = sinT();
    std::vector<float> a(size_t(H + 1), 0), b(size_t(H + 1), 0);
    for (int h = 1; h <= H; ++h) {
        float sa = 0, sb = 0;
        for (int n = 0; n < N; ++n) { int k = (h * n * (T / N)) % T; sa += x[n] * C[size_t(k)]; sb += x[n] * S[size_t(k)]; }
        float scale = h == H ? 1.0f / float(N) : 2.0f / float(N);
        a[size_t(h)] = sa * scale; b[size_t(h)] = sb * scale;
    }
    for (int L = 0; L < levels; ++L) {
        int top = std::max(H >> L, 1);
        float* t = outp + L * (T + 1);
        for (int k = 0; k < T; ++k) {
            float s = 0;
            for (int h = 1; h <= top; ++h) { int i = (h * k) % T; s += a[size_t(h)] * C[size_t(i)] + b[size_t(h)] * S[size_t(i)]; }
            t[k] = s;
        }
        t[T] = t[0];
    }
}

void WavetableNode::process(int nframes, const float* const* in, uint64_t con, ProcessContext&) {
    int buf = activeBuf.load(std::memory_order_acquire);
    inUse.store(buf, std::memory_order_release);
    blocks.fetch_add(1, std::memory_order_relaxed);
    const float* base = tables.data() + buf * bufferSize;
    float target = std::clamp(params[1], 0.0f, float(frames - 1));
    float attackMs = params[4], decayMs = params[5], gain = params[6];
    bool decays = decayMs > 0.5f;
    float mul = decays ? std::exp(std::log(1e-3f) / std::max(decayMs * 0.001f * float(sampleRate), 1.0f)) : 1.0f;
    float rise = attackMs > 0.5f ? 1 / std::max(attackMs * 0.001f * float(sampleRate), 1.0f) : 1.0f;
    float posC = 1 - std::exp(-1 / (0.005f * float(sampleRate)));
    const int T = tableLen; const double TL = T;
    float* o = out(0);
    std::fill(o, o + nframes, 0.0f);
    float p0 = pos;
    pos += (target - pos) * (1 - std::pow(1 - posC, float(nframes)));
    bool hasPitch = isConnected(con, 0), hasTrig = isConnected(con, 1);
    int np = hasPitch ? inVoices[0] : 1, nt = hasTrig ? inVoices[1] : 1;
    for (int v = 0; v < std::max(np, nt); ++v) {
        const float* pitch = voice(in[0], std::min(v, np - 1));
        const float* tr = voice(in[1], std::min(v, nt - 1));
        float semis = params[2] + params[3] / 100 + (hasPitch ? cvSemitones(pitch[nframes - 1]) : 0);
        double hz = 261.6256 * double(std::pow(2.0f, semis / 12)), inc = hz / sampleRate;
        double fit = std::max(sampleRate * 0.45 / std::max(hz, 1.0), 1.0);
        int level = std::clamp(int(std::ceil(std::log2(double(harmonics) / fit))), 0, levels - 1);
        bool useEnv = hasTrig && (decays || attackMs > 0.5f);
        double ph = phase[v]; float e = env[v]; bool up = rising[v]; auto& edge = trigEdge[v];
        float pp = p0;
        for (int i = 0; i < nframes; ++i) {
            pp += (target - pp) * posC;
            int f0 = std::min(int(pp), frames - 2); float t = pp - float(f0);
            const float* ta = base + f0 * frameSize + level * (T + 1);
            const float* tb = ta + frameSize;
            double p = ph * TL; int k = int(p); float fr = float(p - k);
            float va = ta[k] + (ta[k + 1] - ta[k]) * fr, vb = tb[k] + (tb[k + 1] - tb[k]) * fr;
            float y = va + (vb - va) * t;
            if (hasTrig && edge.rising(tr[i])) { if (rise < 1) { e = 0; up = true; } else { e = 1; up = false; } }
            if (useEnv) { y *= e; if (up) { e += rise; if (e >= 1) { e = 1; up = false; } } else e *= mul; }
            o[i] += y * gain;
            ph += inc; if (ph >= 1) ph -= std::floor(ph);
        }
        phase[v] = ph; env[v] = e; rising[v] = up;
    }
    readouts[0] = pos;
}

Factory factoryInst(const std::string& k) {
    if (k == "rack") return make<RackNode>();
    if (k == "drumsynth") return make<DrumSynthNode>();
    if (k == "wave") return make<WavetableNode>();
    return nullptr;
}

} // namespace pn
