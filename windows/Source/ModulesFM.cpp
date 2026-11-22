// fm — a line-for-line port of FM.swift (the Mac / iPad engine), so both play the same.
#include "ModulesFM.h"
#include <BinaryData.h>

namespace pn {

namespace FMLayout {
    const std::vector<int> shownGlobals { sel, algo, fb, transpose, level, lfs, lpmd, lamd, lfw, lpms };
    const std::vector<int> shownOp { OL, OM, FC, FF, DT, R, R + 1, R + 2, R + 3, L, L + 1, L + 2, L + 3, KVS, RS };
}

const std::vector<FMAlgorithm>& fmAlgorithms() {
    static const std::vector<FMAlgorithm> all = [] {
        const char* text[32] = {
            "6>5 5>4 4>3 2>1|1 3|6>6", "6>5 5>4 4>3 2>1|1 3|2>2", "6>5 5>4 3>2 2>1|1 4|6>6", "6>5 5>4 3>2 2>1|1 4|4>6",
            "6>5 4>3 2>1|1 3 5|6>6", "6>5 4>3 2>1|1 3 5|5>6", "6>5 5>3 4>3 2>1|1 3|6>6", "6>5 5>3 4>3 2>1|1 3|4>4",
            "6>5 5>3 4>3 2>1|1 3|2>2", "3>2 2>1 5>4 6>4|1 4|3>3", "3>2 2>1 5>4 6>4|1 4|6>6", "2>1 4>3 5>3 6>3|1 3|2>2",
            "2>1 4>3 5>3 6>3|1 3|6>6", "2>1 4>3 5>4 6>4|1 3|6>6", "2>1 4>3 5>4 6>4|1 3|2>2", "2>1 4>3 3>1 6>5 5>1|1|6>6",
            "2>1 4>3 3>1 6>5 5>1|1|2>2", "2>1 3>1 6>5 5>4 4>1|1|3>3", "3>2 2>1 6>4 6>5|1 4 5|6>6", "3>1 3>2 5>4 6>4|1 2 4|3>3",
            "3>1 3>2 6>4 6>5|1 2 4 5|3>3", "2>1 6>3 6>4 6>5|1 3 4 5|6>6", "3>2 6>4 6>5|1 2 4 5|6>6", "6>3 6>4 6>5|1 2 3 4 5|6>6",
            "6>4 6>5|1 2 3 4 5|6>6", "3>2 5>4 6>4|1 2 4|6>6", "3>2 5>4 6>4|1 2 4|3>3", "2>1 4>3 5>4|1 3 6|5>5",
            "4>3 6>5|1 2 3 5|6>6", "4>3 5>4|1 2 3 6|5>5", "6>5|1 2 3 4 5|6>6", "|1 2 3 4 5 6|6>6" };
        std::vector<FMAlgorithm> v;
        for (auto* t : text) {
            auto parts = juce::StringArray::fromTokens(t, "|", "");
            FMAlgorithm a; a.mods.resize(6);
            for (auto& e : juce::StringArray::fromTokens(parts[0], " ", "")) {
                auto ab = juce::StringArray::fromTokens(e, ">", "");
                if (ab.size() == 2) a.mods[size_t(ab[1].getIntValue() - 1)].push_back(ab[0].getIntValue() - 1);
            }
            for (auto& c : juce::StringArray::fromTokens(parts[1], " ", "")) if (c.isNotEmpty()) a.carriers.push_back(c.getIntValue() - 1);
            auto fb = juce::StringArray::fromTokens(parts[2], ">", "");
            a.fbSource = fb[0].getIntValue() - 1; a.fbTarget = fb[1].getIntValue() - 1;
            v.push_back(a);
        }
        return v;
    }();
    return all;
}

namespace FMVoice {
Bytes unpack(const Bytes& p) {
    if (p.size() < 128) return {};
    Bytes v(155, 0);
    for (int o = 0; o < 6; ++o) {
        int s = o * 17, d = o * 21;
        for (int k = 0; k < 11; ++k) v[size_t(d + k)] = p[size_t(s + k)];
        v[size_t(d + 11)] = p[size_t(s + 11)] & 3; v[size_t(d + 12)] = (p[size_t(s + 11)] >> 2) & 3;
        v[size_t(d + 13)] = p[size_t(s + 12)] & 7; v[size_t(d + 20)] = (p[size_t(s + 12)] >> 3) & 15;
        v[size_t(d + 14)] = p[size_t(s + 13)] & 3; v[size_t(d + 15)] = (p[size_t(s + 13)] >> 2) & 7;
        v[size_t(d + 16)] = p[size_t(s + 14)];
        v[size_t(d + 17)] = p[size_t(s + 15)] & 1; v[size_t(d + 18)] = (p[size_t(s + 15)] >> 1) & 31;
        v[size_t(d + 19)] = p[size_t(s + 16)];
    }
    for (int k = 0; k < 8; ++k) v[size_t(126 + k)] = p[size_t(102 + k)];
    v[134] = p[110] & 31;
    v[135] = p[111] & 7; v[136] = (p[111] >> 3) & 1;
    for (int k = 0; k < 4; ++k) v[size_t(137 + k)] = p[size_t(112 + k)];
    v[141] = p[116] & 1; v[142] = (p[116] >> 1) & 7; v[143] = (p[116] >> 4) & 7;
    v[144] = p[117];
    for (int k = 0; k < 10; ++k) v[size_t(145 + k)] = p[size_t(118 + k)];
    return v;
}
std::string name(const Bytes& v) {
    if (v.size() < 155) return {};
    std::string s;
    for (int k = 145; k < 155; ++k) s += (v[size_t(k)] >= 32 && v[size_t(k)] < 127) ? char(v[size_t(k)]) : ' ';
    return juce::String(s).trim().toStdString();
}
std::vector<float> toParams(const Bytes& v) {
    std::vector<float> p(size_t(FMLayout::count), 0.0f);
    if (v.size() < 155) return p;
    auto c = [](uint8_t x, int hi) { return float(std::min(int(x), hi)); };
    using namespace FMLayout;
    for (int o = 0; o < 6; ++o) {
        int s = (5 - o) * 21, b = base(o);
        for (int k = 0; k < 8; ++k) p[size_t(b + k)] = c(v[size_t(s + k)], 99);
        p[size_t(b + BP)] = c(v[size_t(s + 8)], 99); p[size_t(b + LD)] = c(v[size_t(s + 9)], 99); p[size_t(b + RD)] = c(v[size_t(s + 10)], 99);
        p[size_t(b + LC)] = c(v[size_t(s + 11)], 3); p[size_t(b + RC)] = c(v[size_t(s + 12)], 3);
        p[size_t(b + RS)] = c(v[size_t(s + 13)], 7); p[size_t(b + AMS)] = c(v[size_t(s + 14)], 3); p[size_t(b + KVS)] = c(v[size_t(s + 15)], 7);
        p[size_t(b + OL)] = c(v[size_t(s + 16)], 99); p[size_t(b + OM)] = c(v[size_t(s + 17)], 1);
        p[size_t(b + FC)] = c(v[size_t(s + 18)], 31); p[size_t(b + FF)] = c(v[size_t(s + 19)], 99);
        p[size_t(b + DT)] = c(v[size_t(s + 20)], 14) - 7;
    }
    for (int k = 0; k < 4; ++k) { p[size_t(pr + k)] = c(v[size_t(126 + k)], 99); p[size_t(pl + k)] = c(v[size_t(130 + k)], 99); }
    p[algo] = c(v[134], 31) + 1; p[fb] = c(v[135], 7); p[oks] = c(v[136], 1);
    p[lfs] = c(v[137], 99); p[lfd] = c(v[138], 99); p[lpmd] = c(v[139], 99); p[lamd] = c(v[140], 99);
    p[lks] = c(v[141], 1); p[lfw] = c(v[142], 5); p[lpms] = c(v[143], 7);
    p[transpose] = c(v[144], 48) - 24;
    p[level] = 0.8f;
    return p;
}
std::vector<Bytes> parseSysex(const Bytes& d) {
    if (d.size() >= 163 && d[0] == 0xF0 && d[1] == 0x43 && d[3] == 0x00 && d[4] == 0x01 && d[5] == 0x1B)
        return { Bytes(d.begin() + 6, d.begin() + 161) };
    const uint8_t* body = nullptr;
    auto start = std::find(d.begin(), d.end(), uint8_t(0xF0));
    if (start != d.end()) {
        size_t s = size_t(start - d.begin());
        if (s + 6 + 4096 <= d.size() && d[s + 1] == 0x43 && d[s + 3] == 0x09) body = d.data() + s + 6;
    }
    if (!body && d.size() == 4096) body = d.data();
    if (!body) return {};
    std::vector<Bytes> out;
    for (int k = 0; k < 32; ++k) out.push_back(unpack(Bytes(body + k * 128, body + k * 128 + 128)));
    return out;
}
} // namespace FMVoice

const std::vector<FMPreset>& fmPresets() {
    static const std::vector<FMPreset> all = [] {
        std::vector<FMPreset> v;
        auto* data = reinterpret_cast<const uint8_t*>(BinaryData::fmpresets_bin);
        int n = BinaryData::fmpresets_binSize / 155;
        for (int k = 0; k < n; ++k) {
            FMVoice::Bytes b(data + k * 155, data + k * 155 + 155);
            v.push_back({ FMVoice::name(b), b });
        }
        return v;
    }();
    return all;
}

// ---------------------------------------------------------------- the engine

static inline float fmAmp(float db) { return db <= -95 ? 0.0f : std::exp2(db / 6.0206f); }
static inline float fmLevelDB(float l) { return l <= 0 ? -96.0f : (std::min(l, 99.0f) - 99) * 0.75f; }
static inline float fmRateDB(float r, float scale) { return 0.2f * std::exp2(std::min(r * 41 / 64 + scale, 63.0f) / 4); }
static const float pmsTable[8] = { 0, 0.1f, 0.2f, 0.35f, 0.6f, 1.2f, 2.4f, 12 };
static const float amsTable[4] = { 0, 0.25f, 0.5f, 1 };

void FMNode::keyOn(int v, float velocity, bool oksOn, bool lksOn) {
    using namespace FMLayout;
    if (!active[v] || oksOn) for (int op = 0; op < 6; ++op) phase[v * 6 + op] = 0;
    if (!active[v]) {
        for (int op = 0; op < 6; ++op) eg[v * 6 + op] = fmLevelDB(params[size_t(FMLayout::base(op) + L + 3)]);
        peg[v] = params[size_t(pl + 3)];
        fb1[v] = 0; fb2[v] = 0;
    }
    for (int op = 0; op < 6; ++op) {
        stage[v * 6 + op] = 0;
        if (eg[v * 6 + op] < -40 && fmLevelDB(params[size_t(FMLayout::base(op) + L)]) > -40) eg[v * 6 + op] = -40;
    }
    pStage[v] = 0;
    active[v] = true; gate[v] = true; vel[v] = velocity;
    if (lksOn) lfoPhase = 0;
    lfoDelay = 0;
}
void FMNode::keyOff(int v) {
    gate[v] = false;
    for (int op = 0; op < 6; ++op) stage[v * 6 + op] = 3;
    pStage[v] = 3;
}

void FMNode::process(int frames, const float* const* in, uint64_t con, ProcessContext&) {
    using namespace FMLayout;
    if (!primed) { for (int k = 0; k < V * 6; ++k) { stage[k] = 4; eg[k] = -96; } for (auto& t : target) t = -96; primed = true; }
    float* o = out(0);
    std::fill(o, o + frames, 0.0f);
    const float sr = float(sampleRate);
    const float pi = juce::MathConstants<float>::pi;
    auto& alg = fmAlgorithms()[size_t(std::clamp(int(std::round(params[algo])) - 1, 0, 31))];
    float fbN = std::clamp(std::round(params[fb]), 0.0f, 7.0f);
    float fbScale = fbN < 0.5f ? 0.0f : 0.5f * std::exp2(fbN - 7);
    bool oksOn = params[oks] > 0.5f, lksOn = params[lks] > 0.5f;
    float gain = params[level] * 0.5f / std::sqrt(float(alg.carriers.size()));
    float trn = std::round(params[transpose]);
    for (int op = 0; op < 6; ++op) {
        int b = FMLayout::base(op);
        ol[op] = fmLevelDB(params[size_t(b + OL)]);
        for (int k = 0; k < 4; ++k) target[op * 4 + k] = fmLevelDB(params[size_t(b + L + k)]);
        float fc = std::clamp(std::round(params[size_t(b + FC)]), 0.0f, 31.0f), ff = std::clamp(std::round(params[size_t(b + FF)]), 0.0f, 99.0f);
        fixed[op] = params[size_t(b + OM)] > 0.5f;
        ratio[op] = fixed[op] ? std::pow(10.0f, float(int(fc) % 4) + ff / 100)
                              : (fc < 0.5f ? 0.5f : fc) * (1 + ff / 100) * std::exp2(std::round(params[size_t(b + DT)]) * 1.5f / 1200);
        amsD[op] = amsTable[std::clamp(int(std::round(params[size_t(b + AMS)])), 0, 3)] * 48;
        velD[op] = params[size_t(b + KVS)] / 7 * 24;
        carrier[op] = std::find(alg.carriers.begin(), alg.carriers.end(), op) != alg.carriers.end();
    }
    double lfoHz = double(0.062f * std::exp2(params[lfs] * 0.1f));
    float dl = params[lfd] / 99;
    float lfoDelayStep = dl <= 0.001f ? 1.0f : 1 / std::max(dl * dl * 5 * sr, 1.0f);
    float pmd = params[lpmd] / 99 * pmsTable[std::clamp(int(std::round(params[lpms])), 0, 7)];
    float amd = params[lamd] / 99;
    int wave = std::clamp(int(std::round(params[lfw])), 0, 5);
    for (int i = 0; i < frames; ++i) {
        lfoPhase += lfoHz / sampleRate;
        if (lfoPhase >= 1) { lfoPhase -= 1; lfoSH = rng.next() * 2 - 1; }
        float p = float(lfoPhase), y;
        switch (wave) {
            case 0: y = p < 0.5f ? 4 * p - 1 : 3 - 4 * p; break;
            case 1: y = 1 - 2 * p; break;
            case 2: y = 2 * p - 1; break;
            case 3: y = p < 0.5f ? 1.0f : -1.0f; break;
            case 4: y = std::sin(2 * pi * p); break;
            default: y = lfoSH;
        }
        lfoDelay = std::min(lfoDelay + lfoDelayStep, 1.0f);
        lfo[i] = y * lfoDelay;
    }
    bool hasPitch = isConnected(con, 0), hasGate = isConnected(con, 1), hasVel = isConnected(con, 2);
    int np = hasPitch ? inVoices[0] : 1, ng = hasGate ? inVoices[1] : 1, nv = hasVel ? inVoices[2] : 1;
    int count = std::max(np, ng);
    for (int v = 0; v < count; ++v) {
        const float* pin = voice(in[0], std::min(v, np - 1));
        const float* gin = voice(in[1], std::min(v, ng - 1));
        const float* vin = voice(in[2], std::min(v, nv - 1));
        int w = v * 6;
        float midi = 60 + (hasPitch ? cvSemitones(pin[frames - 1]) : 0) + trn;
        for (int op = 0; op < 6; ++op) {
            int b = FMLayout::base(op);
            float rs = params[size_t(b + RS)] * std::max(midi - 21, 0.0f) / 24;
            for (int k = 0; k < 4; ++k) rate[(w + op) * 4 + k] = fmRateDB(params[size_t(b + R + k)], rs) / sr;
            float d = midi - (params[size_t(b + BP)] + 21);
            float depth = d > 0 ? params[size_t(b + RD)] : params[size_t(b + LD)];
            int curve = int(std::round(d > 0 ? params[size_t(b + RC)] : params[size_t(b + LC)]));
            float x = std::abs(d) / 12;
            float shape = curve == 1 || curve == 2 ? std::min((std::exp2(x) - 1) / 15, 1.0f) : std::min(x / 4, 1.0f);
            att[w + op] = depth * 0.75f * shape * (curve >= 2 ? -1.0f : 1.0f);
        }
        for (int i = 0; i < frames; ++i) {
            if (hasGate) {
                float g = gin[i];
                if (edges[v].rising(g)) keyOn(v, hasVel ? std::clamp(vin[i], 0.0f, 1.0f) : 0.8f, oksOn, lksOn);
                else if (gate[v] && g < 0.1f) keyOff(v);
            } else if (!active[v]) keyOn(v, 0.8f, oksOn, lksOn);
            if (!active[v]) continue;
            int pk = pStage[v];
            if (pk < 3 || (pk == 3 && !gate[v])) {
                float tgt = params[size_t(pl + pk)], r = fmRateDB(params[size_t(pr + pk)], 0) / 0.75f / sr;
                if (peg[v] < tgt) peg[v] = std::min(peg[v] + r, tgt); else peg[v] = std::max(peg[v] - r, tgt);
                if (peg[v] == tgt && pk < 3) pStage[v] = pk == 2 ? 4 : pk + 1;
            }
            float semis = (hasPitch ? cvSemitones(pin[i]) : 0) + trn + (peg[v] - 50) / 50 * 48 + lfo[i] * pmd;
            float hz = 261.6256f * std::exp2(semis / 12);
            float lfoAmp = (1 - lfo[i]) / 2 * amd;
            float sum = 0; bool heard = false;
            for (int op = 5; op >= 0; --op) {
                int j = w + op;
                int k = stage[j];
                if (k < 4) {
                    float t = target[op * 4 + k], r = rate[j * 4 + k];
                    if (eg[j] < t) eg[j] = std::min(eg[j] + r * 2, t); else eg[j] = std::max(eg[j] - r, t);
                    if (eg[j] == t && k < 3) stage[j] = k == 2 ? 4 : k + 1;
                }
                float a = fmAmp(std::min(eg[j] + ol[op] - att[j] - velD[op] * (1 - vel[v]) - lfoAmp * amsD[op], 0.0f));
                if (a > 0 && carrier[op]) heard = true;
                float mod = 0;
                for (int m : alg.mods[size_t(op)]) mod += out_[w + m];
                mod *= 2;
                if (op == alg.fbTarget) mod += fbScale * (fb1[v] + fb2[v]) * 0.5f;
                float y = a * std::sin(2 * pi * float(phase[j] + double(mod)));
                out_[j] = y;
                phase[j] += double((fixed[op] ? ratio[op] : hz * ratio[op]) / sr);
                if (phase[j] >= 1) phase[j] -= std::floor(phase[j]);
                if (carrier[op]) sum += y;
            }
            fb2[v] = fb1[v]; fb1[v] = out_[w + alg.fbSource];
            o[i] += sum * gain * (hasVel ? vel[v] : 1.0f);   // a patched velocity also sets the loudness (0 = silent)
            if (!gate[v] && !heard) {
                active[v] = false;
                for (int op = 0; op < 6; ++op) { eg[w + op] = -96; stage[w + op] = 4; out_[w + op] = 0; }
            }
        }
    }
    if (count < V) for (int v = count; v < V; ++v) if (gate[v]) keyOff(v);
    for (int op = 0; op < 6; ++op) {
        float m = 0;
        for (int v = 0; v < V; ++v) if (active[v]) m = std::max(m, fmAmp(eg[v * 6 + op]));
        readouts[size_t(op)] = m;
    }
}

Factory factoryFM(const std::string& k) {
    if (k == "fm") return make<FMNode>();
    return nullptr;
}

} // namespace pn
