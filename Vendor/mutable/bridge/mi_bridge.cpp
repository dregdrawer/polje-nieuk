#include <new>
#include <cstdlib>
// Thin C wrappers around the original module DSP. Copyright of the wrapped code: Emilie Gillet (MIT).
#include "mi_bridge.h"
#include <cstring>
#include <cmath>
#include <algorithm>

#include "clouds/dsp/granular_processor.h"
#include "rings/dsp/part.h"
#include "rings/dsp/strummer.h"
#include "plaits/dsp/voice.h"
#include "elements/dsp/part.h"
#include "warps/dsp/modulator.h"
#include "tides2/poly_slope_generator.h"
#include "marbles/random/t_generator.h"
#include "marbles/random/x_y_generator.h"
#include "marbles/random/random_generator.h"
#include "marbles/random/random_stream.h"
#include "marbles/ramp/ramp_extractor.h"
#include "stages/segment_generator.h"
#include "braids/macro_oscillator.h"
#include "beads/dsp/processor.h"
#include "stmlib/dsp/units.h"
#include "stmlib/utils/gate_flags.h"

namespace marbles { extern const Scale preset_scales[6]; }

static inline short toShort(float x) {
    float v = x * 32767.0f;
    if (!(v == v)) v = 0;                       // NaN guard
    return (short)std::max(-32768.0f, std::min(32767.0f, v));
}
static inline float clamp01(float x) { return x > 0 ? (x < 1 ? x : 1) : 0; }   // NaN → 0
// Hardware could never deliver values outside these ranges; the DSP indexes tables with them.
static inline float clampf(float x, float lo, float hi) { return (x == x) ? std::max(lo, std::min(hi, x)) : lo; }
static inline void clampAudio(float* d, const float* s, int n) { for (int i = 0; i < n; ++i) d[i] = clampf(s[i], -4.0f, 4.0f); }

// ------------------------------------------------------------------ texture
struct MITexture {
    clouds::GranularProcessor processor;
    uint8_t* large;
    uint8_t* small;
    int mode = -1, quality = -1;
};
static const size_t kTextureLarge = 118784, kTextureSmall = 65536 - 128;

MITexture* mi_texture_create(void) {
    MITexture* t = new MITexture();
    t->large = new uint8_t[kTextureLarge]();
    t->small = new uint8_t[kTextureSmall]();
    t->processor.Init(t->large, kTextureLarge, t->small, kTextureSmall);
    return t;
}
void mi_texture_destroy(MITexture* t) {
    if (!t) return;
    delete[] t->large; delete[] t->small; delete t;
}
void mi_texture_process(MITexture* t, const MITextureParams* q, const float* inL, const float* inR, float* outL, float* outR) {
    if (q->mode != t->mode) { t->mode = q->mode; t->processor.set_playback_mode((clouds::PlaybackMode)std::max(0, std::min(3, q->mode))); }
    if (q->quality != t->quality) { t->quality = q->quality; t->processor.set_quality(std::max(0, std::min(3, q->quality))); }
    clouds::Parameters* p = t->processor.mutable_parameters();
    p->position = clamp01(q->position);
    p->size = clamp01(q->size);
    p->pitch = clampf(q->pitch, -48.0f, 48.0f);
    p->density = clamp01(q->density);
    p->texture = clamp01(q->texture);
    p->dry_wet = clamp01(q->dry_wet);
    p->stereo_spread = clamp01(q->stereo_spread);
    p->feedback = clamp01(q->feedback);
    p->reverb = clamp01(q->reverb);
    p->freeze = q->freeze != 0;
    p->trigger = q->trigger != 0;
    p->gate = q->gate != 0;
    clouds::ShortFrame in[MI_TEXTURE_BLOCK], out[MI_TEXTURE_BLOCK];
    for (int i = 0; i < MI_TEXTURE_BLOCK; ++i) { in[i].l = toShort(inL[i]); in[i].r = toShort(inR[i]); }
    t->processor.Prepare();
    t->processor.Process(in, out, MI_TEXTURE_BLOCK);
    for (int i = 0; i < MI_TEXTURE_BLOCK; ++i) { outL[i] = out[i].l / 32768.0f; outR[i] = out[i].r / 32768.0f; }
}

// ------------------------------------------------------------------ resonator
struct MIResonator {
    rings::Part part;
    rings::Strummer strummer;
    uint16_t reverb[32768];
};
MIResonator* mi_resonator_create(void) {
    MIResonator* r = new MIResonator();
    std::memset(r->reverb, 0, sizeof(r->reverb));
    r->part.Init(r->reverb);
    r->strummer.Init(0.01f, rings::kSampleRate / rings::kMaxBlockSize);
    return r;
}
void mi_resonator_destroy(MIResonator* r) { delete r; }
void mi_resonator_process(MIResonator* r, const MIResonatorParams* q, const float* in, float* out, float* aux) {
    rings::Patch patch;
    patch.structure = clamp01(q->structure);
    patch.brightness = clamp01(q->brightness);
    patch.damping = clamp01(q->damping);
    patch.position = clamp01(q->position);
    rings::PerformanceState ps;
    ps.note = clampf(q->note, -48.0f, 72.0f);
    ps.tonic = clampf(q->tonic, 0.0f, 84.0f);
    ps.fm = std::max(-48.0f, std::min(48.0f, q->fm));
    ps.internal_exciter = q->internal_exciter != 0;
    ps.internal_strum = q->internal_strum != 0;
    ps.internal_note = q->internal_note != 0;
    ps.strum = q->strum != 0;
    ps.chord = (int32_t)std::lround(clamp01(q->structure) * (rings::kNumChords - 1));
    int poly = q->polyphony >= 4 ? 4 : (q->polyphony >= 2 ? 2 : 1);
    r->part.set_polyphony(poly);
    r->part.set_model((rings::ResonatorModel)std::max(0, std::min(5, q->model)));
    float buf[MI_RESONATOR_BLOCK];
    clampAudio(buf, in, MI_RESONATOR_BLOCK);
    r->strummer.Process(ps.internal_exciter ? NULL : buf, MI_RESONATOR_BLOCK, &ps);
    r->part.Process(ps, patch, buf, out, aux, MI_RESONATOR_BLOCK);
}

// ------------------------------------------------------------------ macro oscillator
struct MIMacro {
    plaits::Voice voice;
    char shared[16384];
    stmlib::BufferAllocator allocator;
};
MIMacro* mi_macro_create(void) {
    MIMacro* m = new MIMacro();
    std::memset(m->shared, 0, sizeof(m->shared));
    m->allocator.Init(m->shared, sizeof(m->shared));
    m->voice.Init(&m->allocator);
    return m;
}
void mi_macro_destroy(MIMacro* m) { delete m; }
int mi_macro_active_engine(const MIMacro* m) { return m->voice.active_engine(); }
void mi_macro_process(MIMacro* m, const MIMacroParams* q, float* out, float* aux) {
    plaits::Patch patch;
    std::memset(&patch, 0, sizeof(patch));
    patch.engine = std::max(0, std::min(MI_MACRO_ENGINES - 1, q->engine));
    patch.note = clampf(q->note, 0.0f, 120.0f);
    patch.harmonics = clamp01(q->harmonics);
    patch.timbre = clamp01(q->timbre);
    patch.morph = clamp01(q->morph);
    patch.frequency_modulation_amount = std::max(-1.0f, std::min(1.0f, q->fm_amount));
    patch.timbre_modulation_amount = std::max(-1.0f, std::min(1.0f, q->timbre_amount));
    patch.morph_modulation_amount = std::max(-1.0f, std::min(1.0f, q->morph_amount));
    patch.decay = clamp01(q->decay);
    patch.lpg_colour = clamp01(q->lpg_colour);
    plaits::Modulations mod;
    std::memset(&mod, 0, sizeof(mod));
    mod.engine = 0;
    // base note + pitch CV stays in a musical range: far below it (Plaits allows −119) some engines'
    // oscillators stall and their waveshaper tables get indexed out of range
    patch.note = clampf(patch.note, 8.0f, 132.0f);
    mod.note = clampf(clampf(q->mod_note, -60.0f, 60.0f), 8.0f - patch.note, 132.0f - patch.note);
    mod.frequency = clampf(q->mod_frequency, -1.0f, 1.0f);
    mod.harmonics = clampf(q->mod_harmonics, -1.0f, 1.0f);
    mod.timbre = clampf(q->mod_timbre, -1.0f, 1.0f);
    mod.morph = clampf(q->mod_morph, -1.0f, 1.0f);
    mod.trigger = clampf(q->trigger, 0.0f, 1.0f);
    mod.level = clampf(q->mod_level, 0.0f, 1.0f);
    mod.frequency_patched = q->frequency_patched != 0;
    mod.timbre_patched = q->timbre_patched != 0;
    mod.morph_patched = q->morph_patched != 0;
    mod.trigger_patched = q->trigger_patched != 0;
    mod.level_patched = q->level_patched != 0;
    plaits::Voice::Frame frames[MI_MACRO_BLOCK];
    m->voice.Render(patch, mod, frames, MI_MACRO_BLOCK);
    for (int i = 0; i < MI_MACRO_BLOCK; ++i) { out[i] = frames[i].out / 32768.0f; aux[i] = frames[i].aux / 32768.0f; }
}

// ------------------------------------------------------------------ modal voice
struct MIModal {
    elements::Part part;
    uint16_t reverb[32768];
};
MIModal* mi_modal_create(void) {
    MIModal* m = new MIModal();
    std::memset(m->reverb, 0, sizeof(m->reverb));
    m->part.Init(m->reverb);
    uint32_t seed[3] = { 0x1234567u, 0x89abcdefu, 0x2468ace0u };
    m->part.Seed(seed, 3);
    return m;
}
void mi_modal_destroy(MIModal* m) { delete m; }
void mi_modal_process(MIModal* m, const MIModalParams* q, const float* blow_in, const float* strike_in, float* main_out, float* aux_out) {
    elements::Patch* p = m->part.mutable_patch();
    p->exciter_envelope_shape = clamp01(q->envelope_shape);
    p->exciter_bow_level = clamp01(q->bow_level);
    p->exciter_bow_timbre = clamp01(q->bow_timbre);
    p->exciter_blow_level = clamp01(q->blow_level);
    p->exciter_blow_meta = clamp01(q->blow_meta);
    p->exciter_blow_timbre = clamp01(q->blow_timbre);
    p->exciter_strike_level = clamp01(q->strike_level);
    p->exciter_strike_meta = clamp01(q->strike_meta);
    p->exciter_strike_timbre = clamp01(q->strike_timbre);
    p->exciter_signature = 0;
    p->resonator_geometry = clamp01(q->geometry);
    p->resonator_brightness = clamp01(q->brightness);
    p->resonator_damping = clamp01(q->damping);
    p->resonator_position = clamp01(q->position);
    p->resonator_modulation_frequency = 0;
    p->resonator_modulation_offset = 0;
    p->reverb_diffusion = 0.625f;
    p->reverb_lp = 0.7f;
    p->space = std::max(0.0f, std::min(2.0f, q->space * 2.0f));
    m->part.set_resonator_model((elements::ResonatorModel)std::max(0, std::min(2, q->model)));
    elements::PerformanceState ps;
    ps.gate = q->gate != 0;
    ps.note = clampf(q->note, 0.0f, 120.0f);
    ps.modulation = clampf(q->modulation, -1.0f, 1.0f);
    ps.strength = clamp01(q->strength);
    float blow[MI_MODAL_BLOCK], strike[MI_MODAL_BLOCK];
    clampAudio(blow, blow_in, MI_MODAL_BLOCK);
    clampAudio(strike, strike_in, MI_MODAL_BLOCK);
    m->part.Process(ps, blow, strike, main_out, aux_out, MI_MODAL_BLOCK);
}

// Some engines leave members uninitialised (they ran from zeroed static RAM on hardware):
// construct them in zeroed memory so a fresh instance never starts from garbage.
template<typename T> static T* zeroNew() { void* m = calloc(1, sizeof(T)); return new (m) T; }
template<typename T> static void zeroDelete(T* p) { if (p) { p->~T(); free(p); } }

// ------------------------------------------------------------------ xmod
struct MIXmod { warps::Modulator modulator; int lastShape; };
MIXmod* mi_xmod_create(void) {
    MIXmod* x = zeroNew<MIXmod>();
    x->modulator.Init(96000.0f);
    return x;
}
void mi_xmod_destroy(MIXmod* x) { zeroDelete(x); }
void mi_xmod_process(MIXmod* x, const MIXmodParams* q, const float* carrier, const float* modulator, float* out, float* aux) {
    warps::Parameters* p = x->modulator.mutable_parameters();
    p->channel_drive[0] = clamp01(q->level1);
    p->channel_drive[1] = clamp01(q->level2);
    p->modulation_algorithm = clamp01(q->algorithm);
    p->modulation_parameter = clamp01(q->timbre);
    p->frequency_shift_pot = 0; p->frequency_shift_cv = 0; p->phase_shift = 0;
    p->note = clampf(q->note, 0.0f, 120.0f);
    p->carrier_shape = std::max(0, std::min(3, q->carrier_shape));
    // the oscillators share state between shapes; a stale integrator can run away after a switch
    if (p->carrier_shape != x->lastShape) {
        warps::Parameters keep = *p;
        x->modulator.Init(96000.0f);
        *x->modulator.mutable_parameters() = keep;
        x->lastShape = p->carrier_shape;
    }
    warps::ShortFrame in[MI_XMOD_BLOCK], o[MI_XMOD_BLOCK];
    // With the internal oscillator the carrier jack becomes phase modulation, which can run the
    // triangle's integrator away on extreme input; the app drives that oscillator by pitch instead.
    const bool internal = p->carrier_shape != 0;
    for (int i = 0; i < MI_XMOD_BLOCK; ++i) { in[i].l = internal ? 0 : toShort(carrier[i]); in[i].r = toShort(modulator[i]); }
    x->modulator.Process(in, o, MI_XMOD_BLOCK);
    for (int i = 0; i < MI_XMOD_BLOCK; ++i) { out[i] = o[i].l / 32768.0f; aux[i] = o[i].r / 32768.0f; }
}

// ------------------------------------------------------------------ slopes
struct MISlopes {
    tides::PolySlopeGenerator generator;
    stmlib::GateFlags previous = stmlib::GATE_FLAG_LOW;
    int last_output_mode = -1;
};
static const float kSlopesRoot[3] = { 0.125f / 62500.0f, 2.0f / 62500.0f, 130.81f / 62500.0f };
MISlopes* mi_slopes_create(void) {
    MISlopes* s = zeroNew<MISlopes>();
    s->generator.Init();
    return s;
}
void mi_slopes_destroy(MISlopes* s) { zeroDelete(s); }
void mi_slopes_process(MISlopes* s, const MISlopesParams* q, const float* gate, float* out0, float* out1, float* out2, float* out3) {
    int range = std::max(0, std::min(2, q->range));
    int om = std::max(0, std::min(3, q->output_mode));
    if (om != s->last_output_mode) { s->generator.Reset(); s->last_output_mode = om; }
    float frequency = kSlopesRoot[range] * stmlib::SemitonesToRatio(clampf(q->frequency, -96.0f, 96.0f));
    stmlib::GateFlags flags[MI_SLOPES_BLOCK], none[MI_SLOPES_BLOCK];
    for (int i = 0; i < MI_SLOPES_BLOCK; ++i) {
        s->previous = stmlib::ExtractGateFlags(s->previous, gate[i] > 0.2f);
        flags[i] = s->previous;
        none[i] = stmlib::GATE_FLAG_LOW;
    }
    tides::PolySlopeGenerator::OutputSample out[MI_SLOPES_BLOCK];
    s->generator.Render(tides::RampMode(std::max(0, std::min(2, q->ramp_mode))), tides::OutputMode(om),
                        range == 2 ? tides::RANGE_AUDIO : tides::RANGE_CONTROL, frequency,
                        clamp01(q->slope), clamp01(q->shape), clamp01(q->smoothness), clamp01(q->shift),
                        q->gate_patched ? flags : none, NULL, out, MI_SLOPES_BLOCK);
    for (int i = 0; i < MI_SLOPES_BLOCK; ++i) {
        out0[i] = out[i].channel[0] * 0.1f; out1[i] = out[i].channel[1] * 0.1f;
        out2[i] = out[i].channel[2] * 0.1f; out3[i] = out[i].channel[3] * 0.1f;
    }
}

// ------------------------------------------------------------------ chance
static const int kLoopLengths[] = { 1, 2, 3, 4, 5, 6, 7, 8, 10, 12, 14, 16 };
struct MIChance {
    marbles::RandomGenerator rng;
    marbles::RandomStream stream;
    marbles::TGenerator t;
    marbles::XYGenerator xy;
    stmlib::GateFlags tPrev = stmlib::GATE_FLAG_LOW, xPrev = stmlib::GATE_FLAG_LOW;
    float ramp[MI_CHANCE_BLOCK * 4];
    bool gates[MI_CHANCE_BLOCK * 2];
    float volts[MI_CHANCE_BLOCK * 4];
};
MIChance* mi_chance_create(void) {
    MIChance* c = zeroNew<MIChance>();
    c->rng.Init(0x5EED);
    c->stream.Init(&c->rng);
    c->t.Init(&c->stream, 32000.0f);
    c->xy.Init(&c->stream, 32000.0f);
    for (int i = 0; i < 6; ++i) c->xy.LoadScale(i, marbles::preset_scales[i]);
    return c;
}
void mi_chance_destroy(MIChance* c) { zeroDelete(c); }
void mi_chance_process(MIChance* c, const MIChanceParams* q, const float* t_clock, const float* x_clock,
                       float* t1, float* t2, float* t3, float* x1, float* x2, float* x3, float* y) {
    stmlib::GateFlags tf[MI_CHANCE_BLOCK], xf[MI_CHANCE_BLOCK];
    for (int i = 0; i < MI_CHANCE_BLOCK; ++i) {
        c->tPrev = stmlib::ExtractGateFlags(c->tPrev, t_clock[i] > 0.2f); tf[i] = c->tPrev;
        c->xPrev = stmlib::ExtractGateFlags(c->xPrev, x_clock[i] > 0.2f); xf[i] = c->xPrev;
    }
    marbles::Ramps ramps;
    ramps.master = &c->ramp[0];
    ramps.external = &c->ramp[MI_CHANCE_BLOCK];
    ramps.slave[0] = &c->ramp[MI_CHANCE_BLOCK * 2];
    ramps.slave[1] = &c->ramp[MI_CHANCE_BLOCK * 3];
    int len = kLoopLengths[std::max(0, std::min(11, (int)(clamp01(q->deja_vu_length_knob) * 11.99f)))];
    float dv = clamp01(q->deja_vu);
    c->t.set_model(marbles::TGeneratorModel(std::max(0, std::min(6, q->t_model))));
    c->t.set_range(marbles::TGeneratorRange(std::max(0, std::min(2, q->t_range))));
    c->t.set_rate(clampf(q->t_rate, -60.0f, 60.0f));
    c->t.set_bias(clamp01(q->t_bias));
    c->t.set_jitter(clamp01(q->t_jitter));
    c->t.set_deja_vu(dv);
    c->t.set_length(len);
    c->t.set_pulse_width_mean(clamp01(q->t_pulse_width));
    c->t.set_pulse_width_std(0.0f);
    c->t.Process(q->t_clock_patched != 0, tf, ramps, c->gates, MI_CHANCE_BLOCK);

    marbles::GroupSettings x, yy;
    x.control_mode = marbles::ControlMode(std::max(0, std::min(2, q->x_mode)));
    x.voltage_range = marbles::VoltageRange(std::max(0, std::min(2, q->x_range)));
    x.register_mode = false; x.register_value = 0;
    x.spread = clamp01(q->x_spread); x.bias = clamp01(q->x_bias); x.steps = clamp01(q->x_steps);
    x.deja_vu = dv; x.length = len; x.scale_index = std::max(0, std::min(5, q->x_scale));
    x.ratio.p = 1; x.ratio.q = 1;
    yy = x;
    yy.control_mode = marbles::CONTROL_MODE_IDENTICAL; yy.voltage_range = marbles::VOLTAGE_RANGE_FULL;
    yy.spread = 0.5f; yy.bias = 0.5f; yy.steps = 0.5f; yy.deja_vu = 0; yy.length = 1;
    yy.ratio.p = 1; yy.ratio.q = 4;
    c->xy.Process(q->x_clock_patched ? marbles::CLOCK_SOURCE_EXTERNAL : marbles::CLOCK_SOURCE_INTERNAL_T1_T2_T3,
                  x, yy, xf, ramps, c->volts, MI_CHANCE_BLOCK);
    for (int i = 0; i < MI_CHANCE_BLOCK; ++i) {
        t1[i] = c->gates[2 * i] ? 1.0f : 0.0f;
        t2[i] = ramps.master[i] < 0.5f ? 1.0f : 0.0f;
        t3[i] = c->gates[2 * i + 1] ? 1.0f : 0.0f;
        x1[i] = c->volts[4 * i] * 0.1f; x2[i] = c->volts[4 * i + 1] * 0.1f;
        x3[i] = c->volts[4 * i + 2] * 0.1f; y[i] = c->volts[4 * i + 3] * 0.1f;
    }
}

// ------------------------------------------------------------------ segments
struct MISegments {
    stages::SegmentGenerator gen;
    stmlib::HysteresisQuantizer2 quantizer;
    stmlib::GateFlags previous;
    int lastConfig;
};
MISegments* mi_segments_create(void) {
    MISegments* s = zeroNew<MISegments>();
    s->quantizer.Init(13, 0.03f, false);
    s->gen.Init(&s->quantizer);
    s->previous = stmlib::GATE_FLAG_LOW;
    s->lastConfig = -1;
    return s;
}
void mi_segments_destroy(MISegments* s) { zeroDelete(s); }
void mi_segments_process(MISegments* s, const MISegmentsParams* q, const float* gate, float* out, float* active) {
    int n = std::max(1, std::min(6, q->count));
    stages::segment::Configuration cfg[6];
    int key = n * 2 + (q->gate_patched ? 1 : 0);
    for (int i = 0; i < n; ++i) {
        int t = std::max(0, std::min(2, q->type[i]));
        cfg[i].type = t == 0 ? stages::segment::TYPE_RAMP : (t == 1 ? stages::segment::TYPE_STEP : stages::segment::TYPE_HOLD);
        cfg[i].loop = q->loop[i] != 0;
        key = key * 7 + t * 2 + (cfg[i].loop ? 1 : 0);
    }
    if (key != s->lastConfig) { s->gen.Configure(q->gate_patched != 0, cfg, n); s->lastConfig = key; }
    for (int i = 0; i < n; ++i) s->gen.set_segment_parameters(i, clamp01(q->primary[i]), clamp01(q->secondary[i]));
    stmlib::GateFlags flags[MI_SEGMENTS_BLOCK];
    for (int i = 0; i < MI_SEGMENTS_BLOCK; ++i) {
        s->previous = stmlib::ExtractGateFlags(s->previous, q->gate_patched && gate[i] > 0.2f);
        flags[i] = s->previous;
    }
    stages::SegmentGenerator::Output o[MI_SEGMENTS_BLOCK];
    s->gen.Process(flags, o, MI_SEGMENTS_BLOCK);
    for (int i = 0; i < MI_SEGMENTS_BLOCK; ++i) {
        float v = o[i].value;
        out[i] = (v == v) ? clampf(v, -1.25f, 1.25f) * 0.8f : 0.0f;    // 1.0 = 8 V
        active[i] = float(o[i].segment);
    }
}

// ------------------------------------------------------------------ shapes
struct MIShapes { braids::MacroOscillator osc; uint8_t sync[MI_SHAPES_BLOCK]; int16_t buf[MI_SHAPES_BLOCK]; int lastShape; };
MIShapes* mi_shapes_create(void) {
    MIShapes* s = zeroNew<MIShapes>();
    s->osc.Init();
    s->lastShape = -1;
    return s;
}
void mi_shapes_destroy(MIShapes* s) { zeroDelete(s); }
void mi_shapes_process(MIShapes* s, const MIShapesParams* q, float* out) {
    int shape = std::max(0, std::min(MI_SHAPES_COUNT - 1, q->shape));
    if (shape != s->lastShape) { s->osc.set_shape(braids::MacroOscillatorShape(shape)); s->lastShape = shape; }
    float note = clampf(q->note, 0.0f, 127.0f);
    s->osc.set_pitch(int16_t(note * 128.0f));
    s->osc.set_parameters(int16_t(clamp01(q->timbre) * 32767.0f), int16_t(clamp01(q->color) * 32767.0f));
    if (q->strike) s->osc.Strike();
    std::memset(s->sync, 0, sizeof(s->sync));
    s->osc.Render(s->sync, s->buf, MI_SHAPES_BLOCK);
    for (int i = 0; i < MI_SHAPES_BLOCK; ++i) out[i] = s->buf[i] / 32768.0f;
}

// ------------------------------------------------------------------ haze
static const int kHazeRates[4] = { 24000, 48000, 32000, 48000 };
int mi_haze_rate(int media) { return kHazeRates[std::max(0, std::min(3, media))]; }
int mi_haze_block(int media) { return mi_haze_rate(media) / 4000; }
struct MIHaze {
    beads::Processor processor;
    uint8_t* delay1;      // 512 KB
    uint8_t* delay2;      // 256 KB
    uint16_t* reverb;     // 32768 words
    int media;
    stmlib::GateFlags previous;
};
MIHaze* mi_haze_create(void) {
    MIHaze* h = zeroNew<MIHaze>();
    h->delay1 = (uint8_t*)calloc(512 * 1024, 1);
    h->delay2 = (uint8_t*)calloc(256 * 1024, 1);
    h->reverb = (uint16_t*)calloc(32768, sizeof(uint16_t));
    uint8_t* buffers[3] = { h->delay1, h->delay1 + 256 * 1024, h->delay2 };
    h->processor.Init(buffers, h->reverb);
    h->media = 3;
    h->processor.Configure(beads::Processor::MEDIA_DIGITAL, false);
    h->previous = stmlib::GATE_FLAG_LOW;
    return h;
}
void mi_haze_destroy(MIHaze* h) {
    if (!h) return;
    free(h->delay1); free(h->delay2); free(h->reverb);
    zeroDelete(h);
}
static inline void hazeParam(beads::RandomizedParameter* p, float base, float rnd) {
    p->base = clamp01(base);
    p->attenuverter = clampf(rnd, -1.0f, 1.0f);
    p->cv = 0.0f;
    p->has_cv = false;
}
void mi_haze_process(MIHaze* h, const MIHazeParams* q, const float* inL, const float* inR, const float* seed,
                     const float* freeze, float* outL, float* outR, int n) {
    int media = std::max(0, std::min(3, q->media));
    if (media != h->media) { h->processor.Configure(beads::Processor::Media(media), false); h->media = media; }
    n = std::max(1, std::min((int)MI_HAZE_BLOCK_MAX, n));
    beads::FloatFrame in[MI_HAZE_BLOCK_MAX], out[MI_HAZE_BLOCK_MAX];
    bool frz[MI_HAZE_BLOCK_MAX];
    stmlib::GateFlags sd[MI_HAZE_BLOCK_MAX];
    for (int i = 0; i < n; ++i) {
        in[i].l = clampf(inL[i], -1.0f, 1.0f);
        in[i].r = clampf(inR[i], -1.0f, 1.0f);
        frz[i] = freeze[i] > 0.2f;
        h->previous = stmlib::ExtractGateFlags(h->previous, seed[i] > 0.2f);
        sd[i] = h->previous;
    }
    beads::Parameters p;
    hazeParam(&p.time, q->time, q->time_rand);
    hazeParam(&p.size, q->size, q->size_rand);
    hazeParam(&p.shape, q->shape, q->shape_rand);
    hazeParam(&p.pitch, q->pitch, q->pitch_rand);
    p.monophonic_mode = false;
    beads::ModulatedParameter d;
    d.base = clamp01(q->density);
    d.cv = 0.0f;
    beads::Processor::MixParameters m;
    m.feedback = clamp01(q->feedback);
    m.dry_wet = clamp01(q->dry_wet);
    m.reverb_amount = clamp01(q->reverb);
    m.output_gate = false;
    // Hardware: grains run while SEED is held or latched. Unpatched = latched (free-running);
    // patched = the input gates the stream, or (latched + input) divides an incoming clock.
    beads::SeedButtonState seedState = !q->seed_patched || q->seed_clock
        ? beads::SEED_BUTTON_STATE_LOCKED : beads::SEED_BUTTON_STATE_OFF;
    h->processor.Process(seedState, q->seed_patched ? sd : NULL, frz, d, p, m, in, out, n);
    for (int i = 0; i < n; ++i) {
        outL[i] = (out[i].l == out[i].l) ? clampf(out[i].l, -1.0f, 1.0f) : 0.0f;
        outR[i] = (out[i].r == out[i].r) ? clampf(out[i].r, -1.0f, 1.0f) : 0.0f;
    }
}
