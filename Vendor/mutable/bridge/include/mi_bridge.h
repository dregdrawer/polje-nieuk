// C interface to the open-source DSP of four Eurorack modules by Emilie Gillet (MIT licence,
// see ../../stmlib/LICENSE and the headers of every source file). Each object processes one
// fixed-size block at the module's native sample rate; the Swift side handles rate conversion.
#ifndef MI_BRIDGE_H
#define MI_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

// ---- texture: granular / stretch / looping delay / spectral (native 32 kHz, 32-frame blocks)
enum { MI_TEXTURE_RATE = 32000, MI_TEXTURE_BLOCK = 32 };
typedef struct MITexture MITexture;
typedef struct {
    float position, size, pitch /* semitones */, density, texture, dry_wet, stereo_spread, feedback, reverb;
    int freeze, trigger, gate, mode /* 0 granular 1 stretch 2 looping delay 3 spectral */, quality /* 0..3 */;
} MITextureParams;
MITexture* mi_texture_create(void);
void mi_texture_destroy(MITexture*);
void mi_texture_process(MITexture*, const MITextureParams*, const float* inL, const float* inR, float* outL, float* outR);

// ---- resonator: modal / sympathetic strings / string / FM / quantized / string+reverb (48 kHz, 24)
enum { MI_RESONATOR_RATE = 48000, MI_RESONATOR_BLOCK = 24 };
typedef struct MIResonator MIResonator;
typedef struct {
    float structure, brightness, damping, position;
    float note /* semitones from pitch CV */, tonic /* semitones, frequency knob */, fm /* semitones */;
    int model /* 0..5 */, polyphony /* 1, 2 or 4 */, strum, internal_exciter, internal_strum, internal_note;
} MIResonatorParams;
MIResonator* mi_resonator_create(void);
void mi_resonator_destroy(MIResonator*);
void mi_resonator_process(MIResonator*, const MIResonatorParams*, const float* in, float* out, float* aux);

// ---- macro oscillator: 24 synthesis engines (48 kHz, 12)
enum { MI_MACRO_RATE = 48000, MI_MACRO_BLOCK = 12, MI_MACRO_ENGINES = 24 };
typedef struct MIMacro MIMacro;
typedef struct {
    int engine;
    float note /* semitones */, harmonics, timbre, morph, decay, lpg_colour;
    float fm_amount, timbre_amount, morph_amount;
    // modulation inputs
    float mod_note /* semitones */, mod_frequency, mod_harmonics, mod_timbre, mod_morph, mod_level;
    float trigger /* gate level */;
    int trigger_patched, level_patched, timbre_patched, morph_patched, frequency_patched;
} MIMacroParams;
MIMacro* mi_macro_create(void);
void mi_macro_destroy(MIMacro*);
void mi_macro_process(MIMacro*, const MIMacroParams*, float* out, float* aux);
int mi_macro_active_engine(const MIMacro*);

// ---- modal voice: bow / blow / strike exciters into a resonator, with reverb (32 kHz, 16)
enum { MI_MODAL_RATE = 32000, MI_MODAL_BLOCK = 16 };
typedef struct MIModal MIModal;
typedef struct {
    int gate, model /* 0 modal 1 string 2 strings */;
    float note /* semitones */, strength, modulation;
    float envelope_shape, bow_level, bow_timbre, blow_level, blow_meta, blow_timbre;
    float strike_level, strike_meta, strike_timbre;
    float geometry, brightness, damping, position, space;
} MIModalParams;
MIModal* mi_modal_create(void);
void mi_modal_destroy(MIModal*);
void mi_modal_process(MIModal*, const MIModalParams*, const float* blow_in, const float* strike_in, float* main_out, float* aux_out);

// ---- xmod: cross-modulator / meta-modulator (96 kHz, 60)
enum { MI_XMOD_RATE = 96000, MI_XMOD_BLOCK = 60 };
typedef struct MIXmod MIXmod;
typedef struct {
    float level1, level2, algorithm /* 0..1 */, timbre /* 0..1 */, note /* semitones, internal carrier */;
    int carrier_shape /* 0 external, 1 sine, 2 triangle, 3 saw */;
} MIXmodParams;
MIXmod* mi_xmod_create(void);
void mi_xmod_destroy(MIXmod*);
void mi_xmod_process(MIXmod*, const MIXmodParams*, const float* carrier, const float* modulator, float* out, float* aux);

// ---- slopes: function generator, 4 outputs (62.5 kHz, 8)
enum { MI_SLOPES_RATE = 62500, MI_SLOPES_BLOCK = 8 };
typedef struct MISlopes MISlopes;
typedef struct {
    int ramp_mode /* 0 AD, 1 looping, 2 AR */, output_mode /* 0 gates 1 amplitude 2 phase 3 frequency */, range /* 0 low 1 mid 2 high */;
    float frequency /* semitones */, slope, shape, smoothness, shift;
    int gate_patched;
} MISlopesParams;
MISlopes* mi_slopes_create(void);
void mi_slopes_destroy(MISlopes*);
/// out: 4 channels × 8 frames, in volts / 10 (i.e. ±1 = ±10 V)
void mi_slopes_process(MISlopes*, const MISlopesParams*, const float* gate, float* out0, float* out1, float* out2, float* out3);

// ---- chance: random gates (T) and voltages (X, Y) (32 kHz, 5)
enum { MI_CHANCE_RATE = 32000, MI_CHANCE_BLOCK = 5 };
typedef struct MIChance MIChance;
typedef struct {
    int t_model /* 0..6 */, t_range /* 0..2 */;
    float t_rate /* semitones -60..60 */, t_bias, t_jitter, t_pulse_width;
    float deja_vu, deja_vu_length_knob /* 0..1 */;
    int x_mode /* identical, bump, tilt */, x_range /* narrow, positive, full */, x_scale /* 0..5 */;
    float x_spread, x_bias, x_steps;
    int t_clock_patched, x_clock_patched;
} MIChanceParams;
MIChance* mi_chance_create(void);
void mi_chance_destroy(MIChance*);
/// gates out 0/1; voltages in volts / 10
void mi_chance_process(MIChance*, const MIChanceParams*, const float* t_clock, const float* x_clock,
                       float* t1, float* t2, float* t3, float* x1, float* x2, float* x3, float* y);

// ---- segments: chainable envelope / LFO / step segments (31.25 kHz, 8)
enum { MI_SEGMENTS_RATE = 31250, MI_SEGMENTS_BLOCK = 8, MI_SEGMENTS_MAX = 6 };
typedef struct MISegments MISegments;
typedef struct {
    int count;                       /* 1..6 */
    int type[6];                     /* 0 ramp, 1 step, 2 hold */
    int loop[6];
    float primary[6], secondary[6];  /* 0..1 */
    int gate_patched;
} MISegmentsParams;
MISegments* mi_segments_create(void);
void mi_segments_destroy(MISegments*);
/// out: value in volts / 10; active: index of the running segment
void mi_segments_process(MISegments*, const MISegmentsParams*, const float* gate, float* out, float* active);

// ---- shapes: macro oscillator, 47 shapes (96 kHz, 24)
enum { MI_SHAPES_RATE = 96000, MI_SHAPES_BLOCK = 24, MI_SHAPES_COUNT = 47 };
typedef struct MIShapes MIShapes;
typedef struct { int shape; float note /* MIDI */, timbre, color /* 0..1 */; int strike; } MIShapesParams;
MIShapes* mi_shapes_create(void);
void mi_shapes_destroy(MIShapes*);
void mi_shapes_process(MIShapes*, const MIShapesParams*, float* out);

// ---- haze: granular texture / delay with four "media" (rate depends on media: 24, 48, 32 or 48 kHz)
enum { MI_HAZE_BLOCK_MAX = 12 };
typedef struct MIHaze MIHaze;
typedef struct {
    int media;                                      /* 0 dirty tape, 1 clean tape, 2 vintage digital, 3 digital */
    float time, size, shape, pitch;                 /* 0..1 */
    float time_rand, size_rand, shape_rand, pitch_rand;   /* -1..1: >0 random walk, <0 per-grain randomness */
    float density, feedback, dry_wet, reverb;       /* 0..1 */
    int seed_patched;
    int seed_clock;   /* with seed patched: 0 = gate opens the grain stream, 1 = clock (grains on divisions) */
} MIHazeParams;
int mi_haze_rate(int media);
int mi_haze_block(int media);
MIHaze* mi_haze_create(void);
void mi_haze_destroy(MIHaze*);
/// n must be mi_haze_block(media)
void mi_haze_process(MIHaze*, const MIHazeParams*, const float* inL, const float* inR, const float* seed,
                     const float* freeze, float* outL, float* outR, int n);

#ifdef __cplusplus
}
#endif
#endif
