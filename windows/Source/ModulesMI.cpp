// Modules built on Emilie Gillet's open-source Eurorack DSP (MIT licence, Vendor/mutable) — ports of
// Instruments.swift and Modulators.swift. Each engine runs at its native rate through a RateBridge.
#include "Modules.h"
extern "C" {
#include "mi_bridge.h"
}

namespace pn {

class TextureNode : public DSPNode {
public:
    TextureNode(const ModuleSpec& s, double sr) : DSPNode(s, sr), dsp(mi_texture_create()),
        bridge(sr, MI_TEXTURE_RATE, MI_TEXTURE_BLOCK, 2, 2) {}
    ~TextureNode() override { mi_texture_destroy(dsp); }
    void process(int frames, const float* const* in, uint64_t con, ProcessContext&) override {
        const float* inL = in[0]; const float* inR = isConnected(con, 1) ? in[1] : in[0];
        if (isConnected(con, 2)) for (int i = 0; i < frames; ++i) if (trigEdge.rising(in[2][i])) trigPending = true;
        bool freezeIn = isConnected(con, 3) && in[3][frames - 1] > 0.2f;
        q.mode = clampIndex(params[0], 4);
        q.position = params[1]; q.size = params[2]; q.pitch = params[3]; q.density = params[4];
        q.texture = params[5]; q.dry_wet = params[6]; q.stereo_spread = params[7]; q.feedback = params[8]; q.reverb = params[9];
        q.freeze = (params[10] > 0.5f || freezeIn) ? 1 : 0;
        q.quality = clampIndex(params[11], 4);
        float* oL = out(0); float* oR = out(1);
        bridge.run(frames, [&](int c, int i) { return c == 0 ? inL[i] : inR[i]; }, [&] {
            q.trigger = trigPending ? 1 : 0; trigPending = false;
            mi_texture_process(dsp, &q, bridge.inChannel(0), bridge.inChannel(1), bridge.outChannel(0), bridge.outChannel(1));
        }, [&](int c, int i, float v) { (c == 0 ? oL : oR)[i] = v; });
        readouts[0] = float(q.freeze);
    }
private:
    MITexture* dsp; RateBridge bridge; MITextureParams q {}; EdgeDetector trigEdge; bool trigPending = false;
};

class ResonatorNode : public DSPNode {
public:
    ResonatorNode(const ModuleSpec& s, double sr) : DSPNode(s, sr), dsp(mi_resonator_create()),
        bridge(sr, MI_RESONATOR_RATE, MI_RESONATOR_BLOCK, 1, 2) {}
    ~ResonatorNode() override { mi_resonator_destroy(dsp); }
    void process(int frames, const float* const* in, uint64_t con, ProcessContext&) override {
        bool hasIn = isConnected(con, 0), hasPitch = isConnected(con, 1), hasStrum = isConnected(con, 2);
        if (hasStrum) for (int i = 0; i < frames; ++i) if (strumEdge.rising(in[2][i])) strumPending = true;
        static const int polys[] = { 1, 2, 4 };
        p.model = clampIndex(params[0], 6); p.polyphony = polys[clampIndex(params[1], 3)];
        p.tonic = 12 + params[2];
        p.note = hasPitch ? cvSemitones(in[1][frames - 1]) : 0;
        p.structure = params[3]; p.brightness = params[4]; p.damping = params[5]; p.position = params[6];
        p.fm = 0; p.internal_exciter = hasIn ? 0 : 1; p.internal_strum = hasStrum ? 0 : 1; p.internal_note = hasPitch ? 0 : 1;
        float* oL = out(0); float* oR = out(1);
        bridge.run(frames, [&](int, int i) { return in[0][i]; }, [&] {
            p.strum = strumPending ? 1 : 0; strumPending = false;
            mi_resonator_process(dsp, &p, bridge.inChannel(0), bridge.outChannel(0), bridge.outChannel(1));
        }, [&](int c, int i, float v) { (c == 0 ? oL : oR)[i] = v; });
    }
private:
    MIResonator* dsp; RateBridge bridge; MIResonatorParams p {}; EdgeDetector strumEdge; bool strumPending = false;
};

class MacroNode : public DSPNode {
public:
    MacroNode(const ModuleSpec& s, double sr) : DSPNode(s, sr) {
        for (int v = 0; v < kMaxVoices; ++v) voices.push_back(std::make_unique<Voice>(sr));
    }
    void process(int frames, const float* const* in, uint64_t con, ProcessContext&) override {
        bool hasPitch = isConnected(con, 0), hasTrig = isConnected(con, 1), hasLevel = isConnected(con, 2);
        const float* lv = in[2];
        float level = params[7], attackMs = params[8];
        float* oL = out(0); float* oR = out(1);
        std::fill(oL, oL + frames, 0.0f); std::fill(oR, oR + frames, 0.0f);
        // one voice per note arriving (a chord); a mono cable is one note
        int np = hasPitch ? inVoices[0] : 1, nt = hasTrig ? inVoices[1] : 1;
        for (int v = 0; v < std::max(np, nt); ++v) {
            const float* pitch = voice(in[0], std::min(v, np - 1));
            const float* tr = voice(in[1], std::min(v, nt - 1));
            auto& vc = *voices[size_t(v)];
            vc.p.engine = clampIndex(params[0], int(Layouts::macroEngines.size()));
            vc.p.note = 60 + params[1];
            vc.p.harmonics = params[2]; vc.p.timbre = params[3]; vc.p.morph = params[4];
            vc.p.decay = params[5]; vc.p.lpg_colour = params[6];
            vc.p.mod_note = hasPitch ? cvSemitones(pitch[frames - 1]) : 0;
            vc.p.trigger_patched = hasTrig ? 1 : 0; vc.p.level_patched = hasLevel ? 1 : 0;
            vc.p.mod_level = hasLevel ? std::clamp(lv[frames - 1], 0.0f, 1.0f) : 0;
            float rise = attackMs > 0.5f && hasTrig ? 1 / std::max(attackMs * 0.001f * float(sampleRate), 1.0f) : 1.0f;
            if (rise >= 1) vc.atk = 1;
            vc.bridge.run(frames, [&](int, int i) { return hasTrig ? tr[i] : 0.0f; }, [&] {
                float mx = 0; const float* t = vc.bridge.inChannel(0);
                for (int k = 0; k < vc.bridge.block; ++k) mx = std::max(mx, t[k]);
                vc.p.trigger = mx > 0.2f ? 1.0f : 0.0f;
                mi_macro_process(vc.dsp, &vc.p, vc.bridge.outChannel(0), vc.bridge.outChannel(1));
            }, [&](int c, int i, float y) {
                if (c == 0) {
                    if (rise < 1) { if (vc.trigEdge.rising(tr[i])) vc.atk = 0; vc.atk = std::min(vc.atk + rise, 1.0f); }
                    oL[i] += y * level * vc.atk;
                } else oR[i] += y * level * vc.atk;
            });
            if (v == 0) readouts[0] = float(mi_macro_active_engine(vc.dsp));
        }
    }
private:
    struct Voice {
        MIMacro* dsp; RateBridge bridge; MIMacroParams p {}; float atk = 1; EdgeDetector trigEdge;
        explicit Voice(double sr) : dsp(mi_macro_create()), bridge(sr, MI_MACRO_RATE, MI_MACRO_BLOCK, 1, 2) {}
        ~Voice() { mi_macro_destroy(dsp); }
    };
    std::vector<std::unique_ptr<Voice>> voices;
};

class ModalNode : public DSPNode {
public:
    ModalNode(const ModuleSpec& s, double sr) : DSPNode(s, sr), dsp(mi_modal_create()),
        bridge(sr, MI_MODAL_RATE, MI_MODAL_BLOCK, 3, 2) {}
    ~ModalNode() override { mi_modal_destroy(dsp); }
    void process(int frames, const float* const* in, uint64_t con, ProcessContext&) override {
        bool hasPitch = isConnected(con, 0), hasGate = isConnected(con, 1);
        p.model = clampIndex(params[0], 3);
        p.note = params[1] + (hasPitch ? cvSemitones(in[0][frames - 1]) : 0);
        p.strength = params[2]; p.envelope_shape = params[3];
        p.bow_level = params[4]; p.blow_level = params[5]; p.strike_level = params[6];
        p.bow_timbre = params[7]; p.blow_meta = params[8]; p.blow_timbre = params[9];
        p.strike_meta = params[10]; p.strike_timbre = params[11];
        p.geometry = params[12]; p.brightness = params[13]; p.damping = params[14]; p.position = params[15]; p.space = params[16];
        p.modulation = 0;
        float* oL = out(0); float* oR = out(1);
        bridge.run(frames, [&](int c, int i) { return c == 0 ? (hasGate ? in[1][i] : 0.0f) : (c == 1 ? in[2][i] : in[3][i]); }, [&] {
            float mx = 0; const float* g = bridge.inChannel(0);
            for (int k = 0; k < bridge.block; ++k) mx = std::max(mx, g[k]);
            p.gate = mx > 0.2f ? 1 : 0;
            mi_modal_process(dsp, &p, bridge.inChannel(1), bridge.inChannel(2), bridge.outChannel(0), bridge.outChannel(1));
        }, [&](int c, int i, float v) { (c == 0 ? oL : oR)[i] = v; });
    }
private:
    MIModal* dsp; RateBridge bridge; MIModalParams p {};
};

class XmodNode : public DSPNode {
public:
    XmodNode(const ModuleSpec& s, double sr) : DSPNode(s, sr), dsp(mi_xmod_create()), bridge(sr, MI_XMOD_RATE, MI_XMOD_BLOCK, 2, 2) {}
    ~XmodNode() override { mi_xmod_destroy(dsp); }
    void process(int frames, const float* const* in, uint64_t con, ProcessContext&) override {
        bool hasCar = isConnected(con, 0), hasPitch = isConnected(con, 2);
        q.algorithm = std::clamp(params[0], 0.0f, 8.0f) / 8;
        q.timbre = params[1]; q.level1 = params[2]; q.level2 = params[3];
        int osc = clampIndex(params[4], 4);
        q.carrier_shape = (osc == 0 && !hasCar) ? 1 : osc;
        q.note = 60 + params[5] + (hasPitch ? cvSemitones(in[2][frames - 1]) : 0);
        float* o = out(0); float* aux = out(1);
        bridge.run(frames, [&](int c, int i) { return c == 0 ? in[0][i] : in[1][i]; }, [&] {
            mi_xmod_process(dsp, &q, bridge.inChannel(0), bridge.inChannel(1), bridge.outChannel(0), bridge.outChannel(1));
        }, [&](int c, int i, float v) { (c == 0 ? o : aux)[i] = v; });
    }
private:
    MIXmod* dsp; RateBridge bridge; MIXmodParams q {};
};

class ChanceNode : public DSPNode {
public:
    ChanceNode(const ModuleSpec& s, double sr) : DSPNode(s, sr), dsp(mi_chance_create()), bridge(sr, MI_CHANCE_RATE, MI_CHANCE_BLOCK, 2, 7) {}
    ~ChanceNode() override { mi_chance_destroy(dsp); }
    void process(int frames, const float* const* in, uint64_t con, ProcessContext& ctx) override {
        bool hasT = isConnected(con, 0), hasX = isConnected(con, 1);
        bool sync = !hasT && params[14] > 0.5f;
        double div = Divisions::beats(params[15]);
        q.t_model = clampIndex(params[0], 7); q.t_range = clampIndex(params[1], 3);
        q.t_rate = params[2]; q.t_bias = params[3]; q.t_jitter = params[4]; q.t_pulse_width = params[5];
        q.deja_vu = params[6];
        q.deja_vu_length_knob = (float(clampIndex(params[7], 12)) + 0.5f) / 12;
        q.x_mode = clampIndex(params[8], 3); q.x_range = clampIndex(params[9], 3); q.x_scale = clampIndex(params[10], 6);
        q.x_spread = params[11]; q.x_bias = params[12]; q.x_steps = params[13];
        q.t_clock_patched = (hasT || sync) ? 1 : 0; q.x_clock_patched = hasX ? 1 : 0;
        bridge.run(frames, [&](int c, int i) -> float {
            if (c == 1) return in[1][i];
            if (hasT) return in[0][i];
            if (!sync) return 0;
            double pos = ctx.beat[i] / div;
            return pos - std::floor(pos) < 0.5 ? 1.0f : 0.0f;
        }, [&] {
            mi_chance_process(dsp, &q, bridge.inChannel(0), bridge.inChannel(1), bridge.outChannel(0), bridge.outChannel(1),
                              bridge.outChannel(2), bridge.outChannel(3), bridge.outChannel(4), bridge.outChannel(5), bridge.outChannel(6));
        }, [&](int c, int i, float v) { out(c)[i] = v; });
        for (int c = 0; c < 7; ++c) readouts[size_t(c)] = out(c)[frames - 1];
    }
private:
    MIChance* dsp; RateBridge bridge; MIChanceParams q {};
};

class ShapesNode : public DSPNode {
public:
    ShapesNode(const ModuleSpec& s, double sr) : DSPNode(s, sr) {
        for (int v = 0; v < kMaxVoices; ++v) voices.push_back(std::make_unique<Voice>(sr));
    }
    void process(int frames, const float* const* in, uint64_t con, ProcessContext&) override {
        int shape = clampIndex(params[0], int(Layouts::shapesNames.size()));
        float decayMs = params[4], level = params[5], attackMs = params[6];
        bool decays = decayMs > 0.5f;
        float mul = decays ? std::exp(std::log(1e-3f) / std::max(decayMs * 0.001f * float(sampleRate), 1.0f)) : 1.0f;
        float rise = attackMs > 0.5f ? 1 / std::max(attackMs * 0.001f * float(sampleRate), 1.0f) : 1.0f;
        float* o = out(0);
        std::fill(o, o + frames, 0.0f);
        bool hasPitch = isConnected(con, 0), hasTrig = isConnected(con, 1);
        int np = hasPitch ? inVoices[0] : 1, nt = hasTrig ? inVoices[1] : 1;
        for (int v = 0; v < std::max(np, nt); ++v) {
            const float* pitch = voice(in[0], std::min(v, np - 1));
            const float* tr = voice(in[1], std::min(v, nt - 1));
            auto& vc = *voices[size_t(v)];
            vc.q.shape = shape;
            vc.q.note = 60 + params[1] + (hasPitch ? cvSemitones(pitch[frames - 1]) : 0);
            vc.q.timbre = params[2]; vc.q.color = params[3];
            bool useEnv = hasTrig && (decays || attackMs > 0.5f);
            vc.bridge.run(frames, [&](int, int i) { return hasTrig ? tr[i] : 0.0f; }, [&] {
                float mx = 0; const float* t = vc.bridge.inChannel(0);
                for (int k = 0; k < vc.bridge.block; ++k) mx = std::max(mx, t[k]);
                vc.q.strike = (mx > 0.2f && !vc.strikeHeld) ? 1 : 0;
                vc.strikeHeld = mx > 0.2f;
                mi_shapes_process(vc.dsp, &vc.q, vc.bridge.outChannel(0));
            }, [&](int, int i, float y) {
                if (hasTrig && vc.trigEdge.rising(tr[i])) { if (rise < 1) { vc.env = 0; vc.rising = true; } else { vc.env = 1; vc.rising = false; } }
                o[i] += y * (useEnv ? vc.env : 1.0f) * level;
                if (useEnv) { if (vc.rising) { vc.env += rise; if (vc.env >= 1) { vc.env = 1; vc.rising = false; } } else vc.env *= mul; }
            });
        }
    }
private:
    struct Voice {
        MIShapes* dsp; RateBridge bridge; MIShapesParams q {}; float env = 1; bool rising = false, strikeHeld = false; EdgeDetector trigEdge;
        explicit Voice(double sr) : dsp(mi_shapes_create()), bridge(sr, MI_SHAPES_RATE, MI_SHAPES_BLOCK, 1, 1) {}
        ~Voice() { mi_shapes_destroy(dsp); }
    };
    std::vector<std::unique_ptr<Voice>> voices;
};

class HazeNode : public DSPNode {
public:
    HazeNode(const ModuleSpec& s, double sr) : DSPNode(s, sr), dsp(mi_haze_create()) {
        for (int m = 0; m < 3; ++m) bridges.push_back(std::make_unique<RateBridge>(sr, mi_haze_rate(m), mi_haze_block(m), 4, 2));
    }
    ~HazeNode() override { mi_haze_destroy(dsp); }
    void process(int frames, const float* const* in, uint64_t con, ProcessContext&) override {
        const float* inL = in[0]; const float* inR = isConnected(con, 1) ? in[1] : in[0];
        bool hasSeed = isConnected(con, 2), hasFrz = isConnected(con, 3);
        int media = clampIndex(params[0], 4);
        q.media = media;
        q.time = params[1]; q.size = params[2]; q.shape = params[3]; q.pitch = params[4];
        q.time_rand = params[5]; q.size_rand = params[6]; q.shape_rand = params[7]; q.pitch_rand = params[8];
        q.density = params[9]; q.feedback = params[10]; q.dry_wet = params[11]; q.reverb = params[12];
        q.seed_patched = hasSeed ? 1 : 0; q.seed_clock = params[14] > 0.5f ? 1 : 0;
        float frozen = params[13] > 0.5f ? 1.0f : 0.0f;
        auto& bridge = *bridges[size_t(media == 3 ? 1 : media)];
        float* oL = out(0); float* oR = out(1);
        bridge.run(frames, [&](int c, int i) -> float {
            switch (c) { case 0: return inL[i]; case 1: return inR[i]; case 2: return hasSeed ? in[2][i] : 0.0f;
                         default: return std::max(frozen, hasFrz ? in[3][i] : 0.0f); }
        }, [&] {
            mi_haze_process(dsp, &q, bridge.inChannel(0), bridge.inChannel(1), bridge.inChannel(2), bridge.inChannel(3),
                            bridge.outChannel(0), bridge.outChannel(1), bridge.block);
        }, [&](int c, int i, float v) { (c == 0 ? oL : oR)[i] = v; });
    }
private:
    MIHaze* dsp; std::vector<std::unique_ptr<RateBridge>> bridges; MIHazeParams q {};
};

Factory factoryMI(const std::string& k) {
    if (k == "texture") return make<TextureNode>();
    if (k == "resonator") return make<ResonatorNode>();
    if (k == "macro") return make<MacroNode>();
    if (k == "modal") return make<ModalNode>();
    if (k == "xmod") return make<XmodNode>();
    if (k == "chance") return make<ChanceNode>();
    if (k == "shapes") return make<ShapesNode>();
    if (k == "haze") return make<HazeNode>();
    return nullptr;
}

} // namespace pn
