// A small VST3 host for the plugin box (macOS): load one plugin from a .vst3 bundle, run it on the audio
// thread, save / restore its state, open its editor in a view. Built on Steinberg's VST3 interfaces (MIT).
#pragma once
#ifdef __cplusplus
extern "C" {
#endif

typedef struct PNVst3 PNVst3;

typedef struct {
    double tempo;          // bpm
    double beat;           // musical position (quarter notes) at the block start
    long long samplePos;   // samples since start
    int playing;
} PNVst3Time;

/// Main thread. Loads the first audio class in the bundle. NULL on failure (err gets why).
PNVst3* pnvst3_load(const char* bundlePath, double sampleRate, int maxBlock, char* err, int errCap);
/// Main thread (the audio thread must not be using it).
void pnvst3_free(PNVst3* p);

int pnvst3_is_instrument(PNVst3* p);
const char* pnvst3_name(PNVst3* p);
const char* pnvst3_vendor(PNVst3* p);

/// Automatable parameters (main thread).
int pnvst3_param_count(PNVst3* p);
void pnvst3_param_name(PNVst3* p, int index, char* out, int cap);
double pnvst3_param_value(PNVst3* p, int index);

// --- audio thread -------------------------------------------------------------------------
/// A note on / off at a sample offset in the coming block (velocity 0…1).
void pnvst3_note(PNVst3* p, int on, int pitch, float velocity, int offset);
/// Set an automatable parameter (normalized 0…1) for the coming block.
void pnvst3_param(PNVst3* p, int index, double value);
/// One block: stereo in (may be NULL for instruments), stereo out.
void pnvst3_process(PNVst3* p, const float* inL, const float* inR, float* outL, float* outR, int frames, const PNVst3Time* t);

// --- main thread --------------------------------------------------------------------------
/// Pass parameter changes made on the audio side on to the plugin's editor.
void pnvst3_idle(PNVst3* p);
/// The whole state (processor + editor). *data is malloc'ed: free() it.
int pnvst3_get_state(PNVst3* p, unsigned char** data, int* length);
int pnvst3_set_state(PNVst3* p, const unsigned char* data, int length);
int pnvst3_has_editor(PNVst3* p);
/// Attach the editor to an NSView. `resized` is called when the plugin asks for a new size.
int pnvst3_open_editor(PNVst3* p, void* parent, int* width, int* height, void (*resized)(void* ctx, int w, int h), void* ctx);
void pnvst3_close_editor(PNVst3* p);

#ifdef __cplusplus
}
#endif
