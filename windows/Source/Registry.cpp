// Every module the Mac / iPad app has, with identical keys, ranges and port names (ModuleRegistry.swift),
// so patches move between platforms unchanged. Modules not ported yet have no factory: their box,
// rows and ports show, they're saved back as they were, and they stay silent.
#include "Engine.h"
#include "Modules.h"
#include <algorithm>

namespace pn {

using P = ParamSpec;
static const auto E = ParamCurve::exponential;
static const auto C = ParamCurve::cubic;

static std::vector<std::string> numbered(int from, int to) {
    std::vector<std::string> v;
    for (int k = from; k <= to; ++k) v.push_back(std::to_string(k));
    return v;
}
static std::vector<std::string> join(std::vector<std::string> a, const std::vector<std::string>& b) {
    a.insert(a.end(), b.begin(), b.end()); return a;
}
static int idx(const std::vector<std::string>& v, const std::string& s) {
    auto it = std::find(v.begin(), v.end(), s); return it == v.end() ? 0 : int(it - v.begin());
}

const std::vector<std::string> Layouts::gridNames = { "off", "1/32", "1/16", "1/8", "1/4", "1/2", "1 bar" };
const std::vector<std::string> Layouts::scaleNames = { "chromatic", "major", "minor", "dorian", "phrygian", "mixolydian",
                                                       "pentatonic maj", "pentatonic min", "blues", "whole tone" };
const std::vector<std::string> Layouts::macroEngines = { "va + filter", "phase distortion", "6-op fm 1", "6-op fm 2", "6-op fm 3",
    "wave terrain", "string machine", "chiptune", "virtual analog", "waveshaper", "2-op fm", "formant/grain", "additive",
    "wavetable", "chords", "speech", "swarm", "filtered noise", "particles", "inharmonic string", "modal", "kick", "snare", "hi-hat" };
const std::vector<std::string> Layouts::shapesNames = { "csaw", "morph", "saw/square", "sine/triangle", "buzz", "square sub", "saw sub",
    "square sync", "saw sync", "triple saw", "triple square", "triple triangle", "triple sine", "triple ring", "saw swarm",
    "saw comb", "toy", "lp filter", "peak filter", "bp filter", "hp filter", "vosim", "vowel", "vowel fof", "harmonics", "fm",
    "feedback fm", "chaotic fm", "plucked", "bowed", "blown", "fluted", "bell", "drum", "kick", "cymbal", "snare",
    "wavetables", "wave map", "wave line", "paraphonic", "filtered noise", "twin peaks", "clocked noise", "granular cloud",
    "particle noise", "digital mod" };
const std::vector<std::string> Layouts::chanceModels = { "coin toss", "clusters", "drums", "independent", "divider", "three states", "markov" };
const std::vector<std::string> Layouts::chanceScales = { "major", "minor", "pentatonic", "pelog", "bhairav", "shri" };
const std::vector<std::string> Layouts::chanceLengths = { "1", "2", "3", "4", "5", "6", "7", "8", "10", "12", "14", "16" };
const std::vector<std::string> Layouts::drumVoices = { "kick", "snare", "hi-hat", "perc" };
const std::vector<int> Layouts::drumEngines = { 21, 22, 23, 20 };

std::vector<std::string> Layouts::dividerRatioNames() {
    std::vector<std::string> v;
    for (int m : { 16, 12, 8, 6, 4, 3, 2 }) v.push_back("×" + std::to_string(m));
    v.push_back("×1");
    for (int d = 2; d <= 64; ++d) v.push_back("÷" + std::to_string(d));
    return v;
}
int Layouts::dividerRatioIndex(int r) {
    static const int mult[] = { 16, 12, 8, 6, 4, 3, 2 };
    if (r < 0) { for (int i = 0; i < 7; ++i) if (mult[i] == -r) return i; return 7; }
    return 7 + std::max(r, 1) - 1;
}

static std::vector<P> dividerParams() {
    auto baseNames = join({ "1/64" }, Divisions::names);
    std::vector<P> p { P::choice("mode", "output", { "pulse", "50% gate" }, 0),
                       P::choice("base", "int clock", baseNames, idx(baseNames, "1/16")),
                       P::integer("offset", "offset", 0, 63, 0) };
    static const int defaults[] = { -4, -2, 1, 2, 3, 4, 8, 16 };
    for (int k = 1; k <= 8; ++k)
        p.push_back(P::choice("d" + std::to_string(k), "out " + std::to_string(k), Layouts::dividerRatioNames(),
                              Layouts::dividerRatioIndex(defaults[k - 1])));
    return p;
}
static std::vector<P> mixerParams() {
    std::vector<P> p { P::choice("chans", "channels", { "2", "4", "8", "16" }, 1) };
    for (int k = 1; k <= 16; ++k) {
        p.push_back(P::cont("g" + std::to_string(k), std::to_string(k) + " level", 0, 1.5f, 1, "%"));
        p.push_back(P::cont("p" + std::to_string(k), std::to_string(k) + " pan", -1, 1, 0));
    }
    p.push_back(P::cont("master", "master", 0, 1.5f, 1, "%"));
    p.push_back(P::toggle("pans", "show pans", false));
    return p;
}
static std::vector<P> controlsParams() {
    std::vector<P> p { P::choice("count", "controls", { "1", "2", "4", "8" }, 2),
                       P::choice("range", "range", { "0…10 V", "±10 V", "0…5 V", "±5 V", "0…1 V" }, 0),
                       P::cont("slew", "smoothing", 0, 2000, 10, "ms", E) };
    for (int k = 1; k <= 8; ++k) p.push_back(P::cont("v" + std::to_string(k), std::to_string(k), 0, 1, 0.5f, "%"));
    return p;
}
static std::vector<P> segmentsParams() {
    std::vector<P> p { P::choice("count", "segments", numbered(1, 6), 1) };
    const int defTypes[] = { 0, 0, 2, 0, 0, 0 };
    const float defPrimary[] = { 0.25f, 0.45f, 0.6f, 0.4f, 0.4f, 0.4f };
    for (int k = 1; k <= 6; ++k) {
        auto s = std::to_string(k);
        p.push_back(P::choice("t" + s, s + " type", { "ramp", "step", "hold" }, defTypes[k - 1]));
        p.push_back(P::cont("a" + s, s + " time/level", 0, 1, defPrimary[k - 1], "%"));
        p.push_back(P::cont("b" + s, s + " shape/time", 0, 1, 0.5f, "%"));
        p.push_back(P::toggle("l" + s, s + " loop", false));
    }
    return p;
}
static std::vector<P> rackParams() {
    std::vector<P> p { P::integer("len", "length", 1, 32, 16),
                       P::choice("div", "division", Divisions::names, Divisions::index("1/16")),
                       P::cont("swing", "swing", 0, 0.5f, 0, "%"),
                       P::choice("sel", "pad", numbered(1, 16), 0),
                       P::cont("master", "master", 0, 1.5f, 0.9f, "%") };
    for (int k = 1; k <= 16; ++k) {
        auto s = std::to_string(k);
        p.push_back(P::cont("t" + s, s + " tune", -24, 24, 0, "st"));
        p.push_back(P::cont("a" + s, s + " attack", 0, 200, 0, "ms", C));
        p.push_back(P::cont("d" + s, s + " decay", 10, 4000, 4000, "ms", E));
        p.push_back(P::cont("v" + s, s + " level", 0, 1.5f, 0.8f, "%"));
        p.push_back(P::cont("p" + s, s + " pan", -1, 1, 0));
        p.push_back(P::toggle("m" + s, s + " mute", false));
        p.push_back(P::toggle("s" + s, s + " solo", false));
    }
    return p;
}
static std::vector<P> drumSynthParams() {
    std::vector<P> p { P::integer("len", "length", 1, 32, 16),
                       P::choice("div", "division", Divisions::names, Divisions::index("1/16")),
                       P::cont("swing", "swing", 0, 0.5f, 0, "%"),
                       P::choice("sel", "voice", Layouts::drumVoices, 0),
                       P::cont("master", "master", 0, 1.5f, 0.9f, "%") };
    const float d[4][3] = { { 0.5f, 0.45f, 0.55f }, { 0.5f, 0.5f, 0.45f }, { 0.5f, 0.65f, 0.3f }, { 0.6f, 0.6f, 0.35f } };
    for (int k = 0; k < 4; ++k) {
        auto s = std::to_string(k + 1), n = Layouts::drumVoices[size_t(k)];
        p.push_back(P::choice("e" + s, n + " engine", Layouts::macroEngines, Layouts::drumEngines[size_t(k)]));
        p.push_back(P::cont("t" + s, n + " tune", -48, 48, 0, "st"));
        p.push_back(P::cont("h" + s, n + " harmonics", 0, 1, d[k][0], "%"));
        p.push_back(P::cont("b" + s, n + " timbre", 0, 1, d[k][1], "%"));
        p.push_back(P::cont("o" + s, n + " morph", 0, 1, d[k][2], "%"));
        p.push_back(P::choice("c" + s, n + " model", { "analog", "synthetic" }, 0));
        p.push_back(P::cont("a" + s, n + " attack", 0, 200, 0, "ms", C));
        p.push_back(P::cont("d" + s, n + " decay", 10, 4000, 4000, "ms", E));
        p.push_back(P::cont("l" + s, n + " lpg decay", 0, 1, 0.5f, "%"));
        p.push_back(P::cont("k" + s, n + " lpg colour", 0, 1, 0.5f, "%"));
        p.push_back(P::cont("v" + s, n + " level", 0, 1.5f, 0.8f, "%"));
        p.push_back(P::cont("p" + s, n + " pan", -1, 1, 0));
        p.push_back(P::toggle("m" + s, n + " mute", false));
        p.push_back(P::toggle("s" + s, n + " solo", false));
    }
    return p;
}
static std::vector<P> peqParams() {
    std::vector<P> ps { P::choice("bands", "bands", { "3 band", "5 band", "8 band" }, 0),
                        P::cont("out", "output", -24, 24, 0, "dB") };
    float defaults[8];
    for (int k = 0; k < 3; ++k) defaults[k] = 80 * std::pow(10000.0f / 80, float(k) / 2);
    const float more[] = { 2500, 5000, 8000, 12000, 15000 };
    for (int k = 0; k < 5; ++k) defaults[3 + k] = more[k];
    for (int b = 0; b < 8; ++b) {
        auto s = std::to_string(b + 1);
        ps.push_back(P::cont("f" + s, s + " freq", 20, 20000, defaults[b], "Hz", E));
        ps.push_back(P::cont("g" + s, s + " gain", -18, 18, 0, "dB"));
        ps.push_back(P::cont("q" + s, s + " Q", 0.3f, 10, (b == 0 || b == 2) ? 0.7f : 1.0f, "", E));
    }
    return ps;
}

static std::vector<ModuleSpec> build() {
    auto D = Divisions::names;
    auto di = [](const char* n) { return Divisions::index(n); };
    std::vector<ModuleSpec> v;
    auto add = [&](std::string kind, std::string name, std::string cat, std::string summary,
                   std::vector<std::string> aliases, std::vector<std::string> ins, std::vector<std::string> outs,
                   std::vector<P> params) {
        ModuleSpec s; s.kind = kind; s.name = name; s.category = cat; s.summary = summary;
        s.aliases = aliases; s.inputs = ins; s.outputs = outs; s.params = params;
        v.push_back(std::move(s));
    };
    add("in", "in~", "I/O", "All hardware inputs (disting NT USB channels) — one outlet each",
        { "adc", "input", "inputs", "hardware" }, {}, numbered(1, kMaxHardwareChannels), {});
    add("out", "out~", "I/O", "All hardware outputs — one inlet each", { "dac", "output", "outputs" },
        numbered(1, kMaxHardwareChannels), {}, { P::cont("gain", "gain", -60, 12, 0, "dB") });
    add("rec", "rec~", "I/O", "Record to a stereo WAV file", { "record", "recorder", "sfrecord" }, { "L", "R" }, {},
        { P::toggle("rec", "record", false) });
    add("clock", "clock", "Clock", "Follow the modular's clock (or run internally)", { "sync", "tempo", "bpm" },
        { "clock", "reset" }, { "pulse", "ramp" },
        { P::choice("source", "source", { "external", "internal" }, 1), P::cont("bpm", "int bpm", 20, 300, 120, "bpm"),
          P::choice("ppqn", "ppqn", { "1", "2", "4", "8", "24" }, 0), P::cont("thresh", "threshold", 0.02f, 1, 0.15f),
          P::choice("out", "pulse out", { "1/16", "1/8", "1/4", "1/2", "1 bar" }, 2) });
    add("div", "div~", "Clock", "Clock divider / multiplier: one clock in, 8 clocks out, each ×16 … ÷64",
        { "divider", "clock divider", "division", "subdivide", "pulse", "ratchet" }, { "clock", "reset" }, numbered(1, 8),
        dividerParams());
    add("looper", "looper~", "Loop & Grain", "Clock-synced looper with overdub", { "loop" }, { "L", "R", "rec", "stop" },
        { "L", "R" },
        { P::trigger("rec", "REC"), P::trigger("play", "PLAY"), P::trigger("stop", "STOP"), P::trigger("clear", "CLR"),
          P::choice("length", "length", { "free", "1 beat", "2 beats", "1 bar", "2 bars", "4 bars", "8 bars" }, 3),
          P::toggle("quant", "quantize", true), P::cont("rate", "speed", 0.25f, 4, 1, "x", E), P::toggle("rev", "reverse", false),
          P::cont("keep", "overdub keep", 0, 1, 1, "%"), P::cont("level", "loop level", 0, 1.5f, 1, "%"),
          P::cont("dry", "dry", 0, 1, 0, "%"), P::toggle("mon", "monitor rec", true), P::cont("start", "loop start", 0, 1, 0, "%"),
          P::cont("end", "loop end", 0, 1, 1, "%"), P::choice("grid", "grid", Layouts::gridNames, 0) });
    add("grain", "grain~", "Loop & Grain", "Live granulator, free or clock-triggered", { "granular", "granulator", "cloud" },
        { "L", "R", "trig", "freeze", "pos" }, { "L", "R" },
        { P::cont("pos", "position", 0, 1, 0.15f, "%"), P::cont("size", "size", 10, 1000, 120, "ms", E),
          P::cont("density", "density", 0.5f, 100, 12, "/s", E), P::toggle("sync", "sync", false),
          P::choice("div", "division", D, di("1/16")), P::cont("pitch", "pitch", -24, 24, 0, "st"),
          P::cont("jitter", "pitch jitter", 0, 12, 0, "st"), P::cont("spray", "spray", 0, 1, 0.15f, "%"),
          P::cont("spread", "stereo", 0, 1, 0.6f, "%"), P::cont("reverse", "reverse", 0, 1, 0, "%"),
          P::toggle("freeze", "freeze", false), P::cont("mix", "mix", 0, 1, 0.6f, "%"), P::cont("level", "level", 0, 2, 1, "%") });
    add("delay", "delay~", "Effects", "Stereo delay: digital, tape, analog BBD; clock-synced", { "echo", "tapin", "tapout", "tape", "bbd" },
        { "L", "R" }, { "L", "R" },
        { P::toggle("sync", "sync", true), P::choice("div", "division", D, di("1/8D")),
          P::cont("time", "free time", 1, 2000, 375, "ms", E), P::cont("fb", "feedback", 0, 1.1f, 0.45f, "%"),
          P::cont("tone", "tone", 300, 18000, 6000, "Hz", E), P::toggle("pp", "ping-pong", false),
          P::cont("mix", "mix", 0, 1, 0.4f, "%"), P::choice("algo", "type", { "digital", "tape", "analog bbd" }, 0) });
    add("reverb", "reverb~", "Effects", "Stereo reverb: room, plate, hall, spring — with freeze", { "verb", "freeverb", "space" },
        { "L", "R" }, { "L", "R" },
        { P::cont("size", "size", 0, 1, 0.75f, "%"), P::cont("damp", "damping", 0, 1, 0.45f, "%"),
          P::cont("width", "width", 0, 1, 1, "%"), P::cont("mix", "mix", 0, 1, 0.35f, "%"), P::toggle("freeze", "freeze", false),
          P::choice("algo", "type", { "room", "plate", "hall", "spring" }, 0) });
    add("filter", "filter~", "Effects", "Stereo filter: clean SVF, Moog ladder, MS-20 screamer",
        { "svf", "lop", "hip", "lowpass", "highpass", "bandpass", "ladder", "moog", "ms20" }, { "L", "R", "cv" }, { "L", "R" },
        { P::choice("mode", "mode", { "lowpass", "bandpass", "highpass", "notch" }, 0),
          P::cont("cutoff", "cutoff", 20, 18000, 1200, "Hz", E), P::cont("reso", "resonance", 0, 1, 0.2f, "%"),
          P::cont("cvamt", "cv amount", -1, 1, 1), P::choice("algo", "type", { "svf clean", "ladder", "ms-20" }, 0) });
    add("drive", "drive~", "Effects", "Saturation: soft, tube, hard, fold, fuzz, rectify",
        { "distortion", "saturate", "overdrive", "tanh", "fuzz", "fold", "wavefolder", "tube" }, { "L", "R" }, { "L", "R" },
        { P::cont("drive", "drive", 0, 36, 12, "dB"), P::cont("tone", "tone", 300, 18000, 7000, "Hz", E),
          P::cont("mix", "mix", 0, 1, 1, "%"), P::cont("out", "output", -36, 6, -6, "dB"),
          P::choice("algo", "type", { "soft", "tube", "hard clip", "wavefold", "fuzz", "rectify" }, 0) });
    add("repeat", "repeat~", "Loop & Grain", "Beat repeat / stutter, locked to the clock", { "beatrepeat", "stutter", "glitch" },
        { "L", "R", "hold" }, { "L", "R" },
        { P::choice("interval", "interval", { "1/4", "1/2", "1 bar", "2 bars", "4 bars" }, 2), P::integer("offset", "offset 16th", 0, 15, 8),
          P::integer("gate", "gate 16ths", 1, 64, 4), P::choice("grid", "grid", { "1/32", "1/16", "1/8", "1/4", "1/2" }, 1),
          P::cont("chance", "chance", 0, 1, 1, "%"), P::cont("decay", "decay", 0, 1, 0, "%"),
          P::choice("mode", "mode", { "mix", "insert", "gate" }, 1), P::toggle("hold", "repeat now", false) });
    add("sampler", "sampler~", "Instruments", "Slice sampler: transients/equal chops, ADSR, gate/clock/CV playback",
        { "simpler", "slicer", "chop", "drums", "sample", "breaks" }, { "L", "R", "trig", "rec", "play" }, { "L", "R" },
        { P::trigger("rec", "REC"), P::trigger("stop", "STOP"), P::trigger("clear", "CLR"),
          P::choice("chop", "chop", { "transients", "4 slices", "8 slices", "16 slices", "32 slices", "whole", "grid" }, 0),
          P::cont("sens", "sensitivity", 0, 1, 0.5f, "%"),
          P::choice("order", "order", { "forward", "reverse", "random", "ping-pong", "slice cv" }, 0),
          P::cont("slice", "slice select", 0, 1, 0, "%"),
          P::choice("auto", "clock trig", { "off", "1/32", "1/16", "1/8", "1/4", "1/2", "1 bar" }, 0),
          P::choice("dir", "direction", { "forward", "reverse", "random" }, 0), P::choice("mode", "trigger", { "one-shot", "gate" }, 0),
          P::choice("voices", "voices", { "mono", "poly" }, 0), P::cont("pitch", "pitch", -24, 24, 0, "st"),
          P::cont("att", "attack", 0.1f, 2000, 1, "ms", E), P::cont("dec", "decay", 1, 5000, 300, "ms", E),
          P::cont("sus", "sustain", 0, 1, 1, "%"), P::cont("rel", "release", 1, 5000, 30, "ms", E),
          P::cont("start", "start", 0, 1, 0, "%"), P::cont("end", "end", 0, 1, 1, "%"), P::cont("level", "level", 0, 2, 1, "%"),
          P::toggle("mon", "monitor rec", true), P::choice("grid", "grid", Layouts::gridNames, 0), P::trigger("play", "PLAY"),
          P::toggle("loop", "loop", true), P::toggle("sync", "sync to clock", false),
          P::choice("synclen", "sync length", { "auto", "1 beat", "2 beats", "1 bar", "2 bars", "4 bars", "8 bars" }, 0) });
    add("stretch", "stretch~", "Effects", "Paulstretch-style extreme time stretch / drone",
        { "paulstretch", "paul", "drone", "timestretch", "freeze" }, { "L", "R", "rec", "freeze" }, { "L", "R" },
        { P::trigger("rec", "REC"), P::trigger("stop", "STOP"), P::trigger("clear", "CLR"),
          P::cont("stretch", "stretch", 1, 1000, 8, "x", E), P::choice("win", "window", { "43ms", "85ms", "170ms", "340ms" }, 2),
          P::cont("start", "start", 0, 1, 0, "%"), P::cont("end", "end", 0, 1, 1, "%"), P::toggle("freeze", "freeze", false),
          P::cont("level", "level", 0, 2, 1, "%"), P::toggle("mon", "monitor rec", true) });
    add("freqshift", "freqshift~", "Effects", "Frequency shifter (Bode-style, up & down outs)",
        { "frequency", "shifter", "bode", "ring", "inharmonic" }, { "L", "R" }, { "up L", "up R", "down L", "down R" },
        { P::cont("shift", "shift", -5000, 5000, 50, "Hz", C), P::cont("fb", "feedback", 0, 0.95f, 0, "%"),
          P::cont("mix", "mix", 0, 1, 1, "%") });
    add("peq", "eq~", "Dynamics", "Parametric EQ — 3, 5 or 8 bands", { "parametric", "eq8", "eq5", "eqeight", "equalizer", "bands" },
        { "L", "R" }, { "L", "R" }, peqParams());
    add("keys", "keys~", "Sequencing", "Two-octave keyboard with arpeggiator and latch",
        { "keyboard", "piano", "arp", "arpeggiator", "notes" }, {}, { "pitch", "gate", "vel" },
        { P::integer("oct", "octave", -3, 3, 0), P::cont("glide", "glide", 0, 1000, 0, "ms"),
          P::choice("arp", "arp", { "off", "up", "down", "up-down", "random", "as played" }, 0),
          P::choice("rate", "arp rate", D, di("1/16")), P::cont("gatelen", "gate length", 0.05f, 1, 0.5f, "%"),
          P::integer("octs", "arp octaves", 1, 3, 1), P::toggle("latch", "latch", false) });
    add("seq", "seq~", "Sequencing", "16-step pitch + gate sequencer", { "sequencer", "step", "steps", "pattern" },
        { "clock", "reset" }, { "pitch", "gate" },
        { P::integer("len", "length", 1, 16, 8), P::choice("div", "division", D, di("1/16")),
          P::choice("dir", "direction", { "forward", "backward", "ping-pong", "random" }, 0),
          P::cont("gatelen", "gate length", 0.05f, 1, 0.5f, "%"), P::choice("scale", "scale", Layouts::scaleNames, 0),
          P::integer("transpose", "transpose", -24, 24, 0) });
    add("turing", "turing~", "Sequencing", "Looping random sequencer (shift register): lock it or let it mutate",
        { "turing", "machine", "shift", "random", "generative" }, { "clock", "reset" }, { "pitch", "gate", "cv" },
        { P::cont("change", "change", 0, 1, 0.15f, "%"), P::integer("len", "length", 2, 16, 8), P::integer("range", "range oct", 1, 4, 2),
          P::choice("scale", "scale", Layouts::scaleNames, 7), P::choice("div", "division", D, di("1/16")),
          P::cont("gatelen", "gate length", 0.05f, 1, 0.5f, "%"), P::integer("oct", "octave", -3, 3, 0),
          P::cont("notes", "notes", 0, 1, 0.5f, "%") });
    add("drumsynth", "drumsynth~", "Instruments", "Synth drum machine: kick, snare, hi-hat and perc voices with a drum roll",
        { "drum machine", "drum synth", "drums", "kick", "snare", "hat", "808", "909", "beat", "pads" }, { "clock", "reset" },
        { "L", "R" }, drumSynthParams());
    add("rack", "rack~", "Instruments", "Sampling drum machine: 16 pads with a drum roll, starter kit, drop your own samples",
        { "drum rack", "drum machine", "drums", "pads", "808", "909", "kit", "beat", "sampler" }, { "clock", "reset" },
        { "L", "R" }, rackParams());
    add("roll", "roll~", "Sequencing", "Piano roll: 2 octaves × 32 steps", { "pianoroll", "piano roll", "melody", "notes", "midi" },
        {}, { "pitch", "gate", "vel" },
        { P::integer("len", "length", 1, 32, 16), P::choice("div", "division", D, di("1/16")),
          P::integer("low", "lowest note", -36, 24, -12), P::cont("gatelen", "gate length", 0.05f, 1, 0.8f, "%") });
    add("drums", "drums~", "Sequencing", "Drum roll: 8 lanes × 32 steps of triggers",
        { "drumroll", "drum roll", "beats", "rhythm", "trigger", "808" }, {}, numbered(1, 8),
        { P::integer("len", "length", 1, 32, 16), P::choice("div", "division", D, di("1/16")),
          P::cont("trig", "trigger length", 1, 100, 10, "ms") });
    add("haze", "haze~", "Loop & Grain", "Granular texture / delay with tape and digital media, random walks, freeze and reverb",
        { "granular", "grains", "texture", "delay", "tape", "cloud", "beads", "freeze", "ambient" }, { "L", "R", "seed", "freeze" },
        { "L", "R" },
        { P::choice("media", "quality", { "dirty tape", "clean tape", "vintage digital", "digital" }, 3),
          P::cont("time", "time", 0, 1, 0.5f, "%"), P::cont("size", "size", 0, 1, 0.5f, "%"), P::cont("shape", "shape", 0, 1, 0.5f, "%"),
          P::cont("pitch", "pitch", 0, 1, 0.5f, "%"), P::cont("trand", "time random", -1, 1, 0), P::cont("srand", "size random", -1, 1, 0),
          P::cont("shrand", "shape random", -1, 1, 0), P::cont("prand", "pitch random", -1, 1, 0),
          P::cont("density", "density", 0, 1, 0.7f, "%"), P::cont("fb", "feedback", 0, 1, 0, "%"), P::cont("mix", "dry/wet", 0, 1, 0.5f, "%"),
          P::cont("reverb", "reverb", 0, 1, 0.2f, "%"), P::toggle("freeze", "freeze", false),
          P::choice("seedmode", "seed input", { "gate", "clock" }, 0) });
    add("texture", "texture~", "Instruments", "Granular texture processor: grains, stretch, looping delay, spectral",
        { "granular", "texture", "freeze", "grains", "spectral", "cloud" }, { "L", "R", "trig", "freeze" }, { "L", "R" },
        { P::choice("mode", "mode", { "granular", "stretch", "looping delay", "spectral" }, 0), P::cont("pos", "position", 0, 1, 0.5f, "%"),
          P::cont("size", "size", 0, 1, 0.5f, "%"), P::cont("pitch", "pitch", -48, 48, 0, "st"), P::cont("density", "density", 0, 1, 0.7f, "%"),
          P::cont("texture", "texture", 0, 1, 0.5f, "%"), P::cont("mix", "dry/wet", 0, 1, 0.5f, "%"), P::cont("spread", "stereo", 0, 1, 0.5f, "%"),
          P::cont("fb", "feedback", 0, 1, 0, "%"), P::cont("reverb", "reverb", 0, 1, 0.2f, "%"), P::toggle("freeze", "freeze", false),
          P::choice("quality", "quality", { "hi-fi stereo", "hi-fi mono", "lo-fi stereo", "lo-fi mono" }, 0) });
    add("resonator", "resonator~", "Instruments", "Modal / string resonator: excite with audio, strum with gates",
        { "modal", "string", "strings", "physical", "resonate", "karplus" }, { "in", "pitch", "strum" }, { "L", "R" },
        { P::choice("model", "model", { "modal", "sympathetic", "string", "fm voice", "sympathetic quant.", "string + reverb" }, 0),
          P::choice("poly", "polyphony", { "1", "2", "4" }, 0), P::cont("note", "frequency", 0, 60, 24, "st"),
          P::cont("structure", "structure", 0, 1, 0.4f, "%"), P::cont("bright", "brightness", 0, 1, 0.5f, "%"),
          P::cont("damp", "damping", 0, 1, 0.5f, "%"), P::cont("position", "position", 0, 1, 0.5f, "%") });
    add("macro", "macro~", "Instruments", "Macro oscillator: 24 synthesis engines, trig + pitch CV",
        { "oscillator", "voice", "synth", "fm", "wavetable", "drum", "speech", "chords" }, { "pitch", "trig", "level" }, { "out", "aux" },
        { P::choice("engine", "engine", Layouts::macroEngines, 8), P::cont("note", "frequency", -48, 48, 0, "st"),
          P::cont("harm", "harmonics", 0, 1, 0.5f, "%"), P::cont("timbre", "timbre", 0, 1, 0.5f, "%"), P::cont("morph", "morph", 0, 1, 0.5f, "%"),
          P::cont("decay", "decay", 0, 1, 0.5f, "%"), P::cont("colour", "lpg colour", 0, 1, 0.5f, "%"),
          P::cont("level", "level", 0, 1.5f, 0.8f, "%"), P::cont("attack", "attack", 0, 2000, 0, "ms", C) });
    add("modal", "modal~", "Instruments", "Modal voice: bow / blow / strike exciters into a resonator",
        { "physical", "bow", "blow", "strike", "mallet", "elements" }, { "pitch", "gate", "blow", "strike" }, { "L", "R" },
        { P::choice("model", "model", { "modal", "string", "strings" }, 0), P::cont("note", "frequency", 12, 96, 48, "st"),
          P::cont("strength", "strength", 0, 1, 0.8f, "%"), P::cont("contour", "contour", 0, 1, 0.2f, "%"), P::cont("bow", "bow", 0, 1, 0, "%"),
          P::cont("blow", "blow", 0, 1, 0, "%"), P::cont("strike", "strike", 0, 1, 0.8f, "%"), P::cont("bowt", "bow timbre", 0, 1, 0.5f, "%"),
          P::cont("flow", "flow", 0, 1, 0.5f, "%"), P::cont("blowt", "blow timbre", 0, 1, 0.5f, "%"), P::cont("mallet", "mallet", 0, 1, 0.5f, "%"),
          P::cont("striket", "strike timbre", 0, 1, 0.5f, "%"), P::cont("geometry", "geometry", 0, 1, 0.4f, "%"),
          P::cont("bright", "brightness", 0, 1, 0.6f, "%"), P::cont("damp", "damping", 0, 1, 0.5f, "%"),
          P::cont("position", "position", 0, 1, 0.3f, "%"), P::cont("space", "space", 0, 1, 0.3f, "%") });
    add("xmod", "xmod~", "Effects", "Cross-modulator: carrier × modulator through 9 morphing algorithms, vocoder",
        { "ring", "ringmod", "cross", "vocoder", "xor", "fold", "modulator", "warp" }, { "carrier", "mod", "pitch" }, { "out", "aux" },
        { P::cont("alg", "algorithm", 0, 8, 2), P::cont("timbre", "timbre", 0, 1, 0.5f, "%"), P::cont("lvl1", "carrier level", 0, 1, 0.7f, "%"),
          P::cont("lvl2", "mod level", 0, 1, 0.7f, "%"), P::choice("osc", "carrier", { "external", "sine", "triangle", "saw" }, 0),
          P::cont("note", "osc frequency", -48, 48, 0, "st") });
    add("shapes", "shapes~", "Instruments", "Macro oscillator: 47 shapes (analog, sync, FM, vowels, physical models, drums, noise)",
        { "oscillator", "vco", "voice", "synth", "wavetable", "vowel", "fm", "pluck", "drum", "braid" }, { "pitch", "trig" }, { "out" },
        { P::choice("shape", "shape", Layouts::shapesNames, 0), P::cont("note", "frequency", -48, 48, 0, "st"),
          P::cont("timbre", "timbre", 0, 1, 0.5f, "%"), P::cont("colour", "colour", 0, 1, 0.5f, "%"),
          P::cont("decay", "decay (0 = drone)", 0, 4000, 0, "ms", C), P::cont("level", "level", 0, 1.5f, 0.8f, "%"),
          P::cont("attack", "attack", 0, 2000, 0, "ms", C) });
    add("chorus", "chorus~", "Effects", "Stereo chorus / ensemble", { "ensemble", "dimension" }, { "L", "R" }, { "L", "R" },
        { P::cont("rate", "rate", 0.05f, 8, 0.6f, "Hz", E), P::cont("depth", "depth", 0, 1, 0.5f, "%"), P::cont("delay", "delay", 1, 30, 12, "ms"),
          P::cont("fb", "feedback", 0, 0.9f, 0, "%"), P::cont("width", "width", 0, 1, 1, "%"), P::cont("mix", "mix", 0, 1, 0.5f, "%"),
          P::choice("algo", "type", { "chorus", "ensemble", "vibrato" }, 0) });
    add("phaser", "phaser~", "Effects", "Phaser / flanger, free or clock-synced", { "flanger", "phase" }, { "L", "R" }, { "L", "R" },
        { P::choice("mode", "mode", { "phaser", "flanger" }, 0), P::cont("rate", "rate", 0.02f, 10, 0.3f, "Hz", E),
          P::toggle("sync", "sync", false), P::choice("div", "division", D, di("1 bar")), P::cont("depth", "depth", 0, 1, 0.7f, "%"),
          P::cont("freq", "freq", 100, 5000, 800, "Hz", E), P::cont("fb", "feedback", -0.95f, 0.95f, 0.5f),
          P::integer("stages", "stages", 2, 12, 6), P::cont("mix", "mix", 0, 1, 1, "%") });
    add("autopan", "autopan~", "Effects", "Tremolo / auto-pan, free or clock-synced", { "tremolo", "pan" }, { "L", "R" }, { "L", "R" },
        { P::cont("rate", "rate", 0.05f, 20, 2, "Hz", E), P::toggle("sync", "sync", true), P::choice("div", "division", D, di("1/8")),
          P::cont("amount", "amount", 0, 1, 0.8f, "%"), P::choice("shape", "shape", { "sine", "triangle", "saw", "square" }, 0),
          P::cont("phase", "phase", 0, 360, 180, "°") });
    add("redux", "redux~", "Effects", "Bitcrusher / sample-rate reducer", { "bitcrush", "crush", "decimate", "lofi" }, { "L", "R" },
        { "L", "R" },
        { P::cont("bits", "bits", 1, 16, 8, "bit"), P::cont("rate", "rate", 100, 48000, 8000, "Hz", E), P::cont("mix", "mix", 0, 1, 1, "%") });
    add("shift", "shift~", "Effects", "Pitch shifter", { "pitch", "shifter", "transpose", "harmonizer" }, { "L", "R" }, { "L", "R" },
        { P::cont("pitch", "pitch", -24, 24, 7, "st"), P::cont("fine", "fine", -100, 100, 0, "ct"), P::cont("window", "window", 20, 200, 70, "ms"),
          P::cont("fb", "feedback", 0, 0.95f, 0, "%"), P::cont("mix", "mix", 0, 1, 1, "%") });
    add("eq", "eq3~", "Dynamics", "Three-band EQ with kills", { "eq3", "equalizer", "tone" }, { "L", "R" }, { "L", "R" },
        { P::cont("low", "low", -60, 6, 0, "dB"), P::cont("mid", "mid", -60, 6, 0, "dB"), P::cont("high", "high", -60, 6, 0, "dB"),
          P::cont("fl", "low freq", 50, 1000, 250, "Hz", E), P::cont("fh", "high freq", 1000, 12000, 2500, "Hz", E) });
    add("comp", "comp~", "Dynamics", "Compressor: LA-3A opto, 1176 FET, VCA bus",
        { "compressor", "la3a", "la2a", "opto", "leveler", "sidechain", "1176", "fet", "ssl", "vca", "bus" }, { "L", "R", "sc" }, { "L", "R" },
        { P::cont("peak", "peak reduction", 0, 1, 0.4f, "%"), P::cont("gain", "gain", 0, 30, 4, "dB"),
          P::choice("mode", "mode", { "compress", "limit" }, 0), P::cont("mix", "dry/wet", 0, 1, 1, "%"),
          P::choice("algo", "type", { "opto LA-3A", "FET 1176", "VCA bus" }, 0) });
    add("limit", "limit~", "Dynamics", "Lookahead limiter", { "limiter", "ceiling", "maximizer" }, { "L", "R" }, { "L", "R" },
        { P::cont("gain", "gain", 0, 24, 0, "dB"), P::cont("ceil", "ceiling", -24, 0, -0.3f, "dB"), P::cont("rel", "release", 10, 1000, 80, "ms", E) });
    add("gate", "gate~", "Dynamics", "Noise gate with sidechain", { "noisegate", "expander" }, { "L", "R", "sc" }, { "L", "R" },
        { P::cont("thr", "threshold", -80, 0, -40, "dB"), P::cont("att", "attack", 0.1f, 50, 1, "ms", E), P::cont("hold", "hold", 0, 500, 20, "ms"),
          P::cont("rel", "release", 5, 2000, 120, "ms", E), P::cont("floor", "floor", -80, 0, -80, "dB") });
    add("env", "env~", "Modulation", "Envelope follower → control signal", { "envelope", "follower", "envfollow" }, { "in" }, { "out" },
        { P::cont("att", "attack", 0.1f, 500, 5, "ms", E), P::cont("rel", "release", 1, 2000, 150, "ms", E), P::cont("sens", "sensitivity", 0, 8, 1, "x"),
          P::cont("amt", "amount", -1, 1, 1), P::cont("off", "offset", -1, 1, 0) });
    add("rand", "rand~", "Modulation", "Random / sample & hold, smoothable", { "random", "s&h", "sh", "noise", "chaos" }, { "trig" }, { "out" },
        { P::cont("rate", "rate", 0.05f, 50, 2, "Hz", E), P::toggle("sync", "sync", false), P::choice("div", "division", D, di("1/4")),
          P::cont("smooth", "smooth", 0, 1, 0, "%"), P::cont("depth", "depth", 0, 1, 0.5f, "%"), P::cont("off", "offset", -1, 1, 0),
          P::choice("pol", "polarity", { "bipolar", "unipolar" }, 0) });
    add("atten", "atten~", "Modulation", "Attenuverter, offset & slew (a constant when unpatched)",
        { "scale", "offset", "slew", "lag", "cv", "constant", "attenuverter" }, { "in" }, { "out" },
        { P::cont("amt", "amount", -2, 2, 1, "x"), P::cont("off", "offset", -1, 1, 0), P::cont("slew", "slew", 0, 2000, 0, "ms") });
    add("gain", "gain~", "Utility", "Utility: gain, balance, width, mono, invert, mute",
        { "utility", "volume", "vca", "trim", "width", "balance" }, { "L", "R" }, { "L", "R" },
        { P::cont("gain", "gain", -60, 24, 0, "dB"), P::cont("bal", "balance", -1, 1, 0), P::cont("width", "width", 0, 2, 1, "%"),
          P::toggle("mono", "mono", false), P::toggle("invL", "invert L", false), P::toggle("invR", "invert R", false),
          P::toggle("mute", "mute", false), P::toggle("dc", "dc block", false) });
    add("text", "text", "Utility", "A note on the canvas: type anything (labels, reminders, how the patch works)",
        { "text", "note", "comment", "label", "notes", "write", "annotation" }, {}, {}, {});
    add("mix", "mix~", "Utility", "Stereo mixer: 2–16 channels with level & pan", { "mixer", "sum", "pan" }, numbered(1, 16),
        { "L", "R" }, mixerParams());
    add("slider", "slider~", "Modulation", "1–8 faders, each a CV outlet — patch them into anything for live playing",
        { "fader", "faders", "slider", "control", "cv", "macro", "live", "jam", "manual" }, {}, numbered(1, 8), controlsParams());
    add("knob", "knob~", "Modulation", "1–8 knobs, each a CV outlet — patch them into anything for live playing",
        { "knob", "knobs", "pot", "dial", "control", "cv", "macro", "live", "jam", "manual" }, {}, numbered(1, 8), controlsParams());
    add("segments", "segments~", "Modulation", "Chain 1–6 ramp / step / hold segments: envelopes, looping LFOs, sequences, S&H",
        { "envelope", "adsr", "multistage", "segment", "stages", "lfo", "function", "step" }, { "gate" }, { "out" }, segmentsParams());
    add("slopes", "slopes~", "Modulation", "Function generator: 4 related slopes (envelope, LFO or oscillator), clock-sync",
        { "function", "envelope", "lfo", "slope", "ramp", "tides", "ad", "ar", "polyphase" }, { "pitch", "gate" }, { "1", "2", "3", "4" },
        { P::choice("ramp", "ramp", { "AD", "looping", "AR" }, 1), P::choice("out", "outputs", { "gates", "amplitude", "phase", "frequency" }, 2),
          P::choice("range", "range", { "low", "mid", "audio" }, 1), P::cont("freq", "frequency", -48, 48, 0, "st"),
          P::cont("slope", "slope", 0, 1, 0.5f, "%"), P::cont("shape", "shape", 0, 1, 0.5f, "%"), P::cont("smooth", "smoothness", 0, 1, 0.5f, "%"),
          P::cont("shift", "shift", 0, 1, 0.75f, "%"), P::toggle("sync", "sync", false), P::choice("div", "division", D, di("1 bar")) });
    add("chance", "chance~", "Modulation", "Random gates T1–T3 and quantised voltages X1–X3 + Y, with déjà vu looping",
        { "random", "generative", "probability", "quantizer", "marbles", "dice", "bernoulli" }, { "t clk", "x clk" },
        { "t1", "t2", "t3", "x1", "x2", "x3", "y" },
        { P::choice("model", "t model", Layouts::chanceModels, 0), P::choice("trange", "t range", { "÷4", "×1", "×4" }, 1),
          P::cont("rate", "rate", -48, 48, 0, "st"), P::cont("tbias", "t bias", 0, 1, 0.5f, "%"), P::cont("jitter", "jitter", 0, 1, 0, "%"),
          P::cont("pw", "gate length", 0, 1, 0.5f, "%"), P::cont("dejavu", "déjà vu", 0, 1, 0, "%"),
          P::choice("len", "loop length", Layouts::chanceLengths, 7), P::choice("xmode", "x mode", { "identical", "bump", "tilt" }, 0),
          P::choice("xrange", "x range", { "narrow", "positive", "full" }, 1), P::choice("scale", "scale", Layouts::chanceScales, 0),
          P::cont("spread", "spread", 0, 1, 0.5f, "%"), P::cont("xbias", "x bias", 0, 1, 0.5f, "%"), P::cont("steps", "steps", 0, 1, 0.5f, "%"),
          P::toggle("sync", "sync", true), P::choice("div", "division", D, di("1/16")) });
    add("lfo", "lfo~", "Modulation", "LFO, free or clock-synced (try it as CV out)", { "osc", "modulation", "phasor" }, {}, { "out" },
        { P::choice("shape", "shape", { "sine", "triangle", "saw", "square", "s&h", "random" }, 0), P::toggle("sync", "sync", false),
          P::cont("rate", "rate", 0.01f, 20, 0.5f, "Hz", E), P::choice("div", "division", D, di("1 bar")),
          P::cont("depth", "depth", 0, 1, 0.5f, "%"), P::cont("offset", "offset", -1, 1, 0) });
    for (auto& s : v) s.factory = factoryFor(s.kind);
    return v;
}

namespace Registry {
const std::vector<std::string> categories = { "I/O", "Clock", "Sequencing", "Loop & Grain", "Instruments", "Effects",
                                              "Dynamics", "Modulation", "Utility" };
const std::vector<ModuleSpec>& all() { static const auto v = build(); return v; }
const ModuleSpec* spec(const std::string& kind) {
    for (auto& s : all()) if (s.kind == kind) return &s;
    return nullptr;
}
std::vector<const ModuleSpec*> search(const std::string& query) {
    auto q = juce::String(query).toLowerCase().removeCharacters("~").trim().toStdString();
    std::vector<const ModuleSpec*> prefix, other;
    for (auto& s : all()) {
        std::vector<std::string> names { s.kind, juce::String(s.name).removeCharacters("~").toStdString() };
        names.insert(names.end(), s.aliases.begin(), s.aliases.end());
        if (q.empty()) { prefix.push_back(&s); continue; }
        bool pre = false, any = false;
        for (auto& n : names) { if (n.rfind(q, 0) == 0) pre = true; if (n.find(q) != std::string::npos) any = true; }
        if (pre) prefix.push_back(&s);
        else if (any || juce::String(s.summary).toLowerCase().contains(juce::String(q))) other.push_back(&s);
    }
    prefix.insert(prefix.end(), other.begin(), other.end());
    return prefix;
}
}

} // namespace pn
