// Every module the Mac / iPad app has, with identical keys, ranges and port names (ModuleRegistry.swift),
// so patches move between platforms unchanged.
#include "Engine.h"
#include "Modules.h"
#include <algorithm>
#include "BinaryData.h"

namespace pn {

using P = ParamSpec;
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

// The specs themselves come from the Mac / iPad app (selftest --dump-specs → specs.json, embedded at build
// time), so every key, range, name and port is identical on every platform.
static std::vector<ModuleSpec> build() {
    std::vector<ModuleSpec> v;
    auto root = juce::JSON::parse(juce::String::fromUTF8(BinaryData::specs_json, BinaryData::specs_jsonSize));
    auto strings = [](const juce::var& a) {
        std::vector<std::string> out;
        if (auto* arr = a.getArray()) for (auto& x : *arr) out.push_back(x.toString().toStdString());
        return out;
    };
    if (auto* mods = root["modules"].getArray()) {
        for (auto& m : *mods) {
            ModuleSpec s;
            s.kind = m["kind"].toString().toStdString();
            s.name = m["name"].toString().toStdString();
            s.category = m["category"].toString().toStdString();
            s.summary = m["summary"].toString().toStdString();
            s.aliases = strings(m["aliases"]);
            s.inputs = strings(m["inputs"]);
            s.outputs = strings(m["outputs"]);
            s.outputsAreCV = bool(m["outputsAreCV"]);
            if (auto* po = m["polyOutputs"].getArray()) for (auto& x : *po) s.polyOutputs.push_back(int(x));
            if (auto* ps = m["params"].getArray()) {
                for (auto& pv : *ps) {
                    P p;
                    p.key = pv["key"].toString().toStdString();
                    p.name = pv["name"].toString().toStdString();
                    p.min = float(double(pv["min"])); p.max = float(double(pv["max"])); p.def = float(double(pv["def"]));
                    p.unit = pv["unit"].toString().toStdString();
                    auto k = pv["kind"].toString();
                    p.kind = k == "integer" ? ParamKind::integer : k == "toggle" ? ParamKind::toggle
                           : k == "choice" ? ParamKind::choice : k == "trigger" ? ParamKind::trigger : ParamKind::continuous;
                    auto c = pv["curve"].toString();
                    p.curve = c == "exponential" ? ParamCurve::exponential : c == "cubic" ? ParamCurve::cubic : ParamCurve::linear;
                    p.options = strings(pv["options"]);
                    if (auto* al = pv["allowed"].getArray()) for (auto& x : *al) p.allowed.push_back(float(double(x)));
                    s.params.push_back(std::move(p));
                }
            }
            v.push_back(std::move(s));
        }
    }
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
