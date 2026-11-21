// fm: a six-operator FM synth in the style of the DX7 (FM.swift / FMPresets.swift). Our own implementation.
#pragma once
#include "Modules.h"
#include <array>

namespace pn {

namespace FMLayout {
    constexpr int ops = 6, perOp = 21, globals = 21;
    constexpr int sel = 0, algo = 1, fb = 2, transpose = 3, level = 4, oks = 5;
    constexpr int lfs = 6, lfd = 7, lpmd = 8, lamd = 9, lks = 10, lfw = 11, lpms = 12, pr = 13, pl = 17;
    constexpr int R = 0, L = 4, BP = 8, LD = 9, RD = 10, LC = 11, RC = 12, RS = 13, AMS = 14, KVS = 15;
    constexpr int OL = 16, OM = 17, FC = 18, FF = 19, DT = 20;
    constexpr int base(int op) { return globals + op * perOp; }
    constexpr int count = globals + ops * perOp;
    extern const std::vector<int> shownGlobals, shownOp;
}

struct FMAlgorithm { std::vector<std::vector<int>> mods; std::vector<int> carriers; int fbSource = 5, fbTarget = 5; };
const std::vector<FMAlgorithm>& fmAlgorithms();

namespace FMVoice {
    using Bytes = std::vector<uint8_t>;
    Bytes unpack(const Bytes& packed);
    std::string name(const Bytes& vced);
    std::vector<float> toParams(const Bytes& vced);
    std::vector<Bytes> parseSysex(const Bytes& data);
}

struct FMPreset { std::string name; FMVoice::Bytes vced; };
/// the 32 built-in voices (made by the Mac app: selftest --dump-specs writes them next to specs.json)
const std::vector<FMPreset>& fmPresets();

class FMNode : public DSPNode {
public:
    static constexpr int V = kMaxVoices;
    using DSPNode::DSPNode;
    void process(int frames, const float* const* in, uint64_t con, ProcessContext& ctx) override;
private:
    void keyOn(int v, float velocity, bool oksOn, bool lksOn);
    void keyOff(int v);
    bool active[V] = {}, gate[V] = {};
    EdgeDetector edges[V];
    float vel[V] = { 0.8f, 0.8f, 0.8f, 0.8f };
    int pStage[V] = { 4, 4, 4, 4 }; float peg[V] = { 50, 50, 50, 50 };
    float fb1[V] = {}, fb2[V] = {};
    double phase[V * 6] = {};
    int stage[V * 6];
    float eg[V * 6], out_[V * 6] = {}, rate[V * 24] = {}, att[V * 6] = {};
    float target[24], ol[6] = {}, ratio[6] = {}, amsD[6] = {}, velD[6] = {};
    bool fixed[6] = {}, carrier[6] = {};
    float lfo[kMaxBlock] = {};
    double lfoPhase = 0; float lfoSH = 0, lfoDelay = 1;
    XorShift rng { 0x0F00D00Du };
    bool primed = false;
};

} // namespace pn
