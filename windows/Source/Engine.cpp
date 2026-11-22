#include "Engine.h"
#include <algorithm>
#include <deque>
#include <set>

namespace pn {

// ---------------------------------------------------------------- Divisions

namespace Divisions {
const std::vector<std::string> names = { "1/32", "1/16T", "1/16", "1/8T", "1/16D", "1/8", "1/4T", "1/8D",
                                         "1/4", "1/2T", "1/4D", "1/2", "1/2D", "1 bar", "2 bars", "4 bars" };
static const double beatValues[] = { 0.125, 1.0 / 6, 0.25, 1.0 / 3, 0.375, 0.5, 2.0 / 3, 0.75,
                                     1, 4.0 / 3, 1.5, 2, 3, 4, 8, 16, 32, 64 };   // the last two: lfo only (8 / 16 bars)
double beats(float v) { return beatValues[clampIndex(v, 18)]; }
int index(const std::string& n) {
    auto it = std::find(names.begin(), names.end(), n);
    return it == names.end() ? 0 : int(it - names.begin());
}
}

// ---------------------------------------------------------------- ParamSpec

float ParamSpec::snapped(float v) const {
    if (allowed.empty() || !std::isfinite(v)) return v;
    float best = allowed[0];
    for (float a : allowed) if (std::abs(a - v) < std::abs(best - v)) best = a;
    return best;
}

float ParamSpec::normalized(float v) const {
    if (!std::isfinite(v)) return 0;
    if (allowed.size() > 1) {
        float s = snapped(v);
        auto it = std::find(allowed.begin(), allowed.end(), s);
        return float(it - allowed.begin()) / float(allowed.size() - 1);
    }
    float n;
    switch (curve) {
        case ParamCurve::linear: n = (v - min) / (max - min); break;
        case ParamCurve::exponential: n = std::log(std::max(v, min) / min) / std::log(max / min); break;
        case ParamCurve::cubic:
            if (min >= 0) n = max > 0 ? std::cbrt(std::max(v, 0.0f) / max) : 0;
            else { float a = std::max(std::abs(min), std::abs(max)); n = (std::cbrt(v / a) + 1) / 2; }
            break;
    }
    return std::isfinite(n) ? std::clamp(n, 0.0f, 1.0f) : 0.0f;
}

float ParamSpec::valueFromNormalized(float n) const {
    float c = std::isfinite(n) ? std::clamp(n, 0.0f, 1.0f) : 0.0f, v;
    if (allowed.size() > 1) return allowed[std::min(size_t(std::round(c * float(allowed.size() - 1))), allowed.size() - 1)];
    switch (curve) {
        case ParamCurve::linear: v = min + (max - min) * c; break;
        case ParamCurve::exponential: v = min * std::pow(max / min, c); break;
        case ParamCurve::cubic:
            if (min >= 0) v = max * c * c * c;
            else { float a = std::max(std::abs(min), std::abs(max)), x = 2 * c - 1; v = a * x * x * x; }
            break;
    }
    if (kind != ParamKind::continuous) v = std::round(v);
    return std::clamp(v, min, max);
}

static std::string fmt(const char* f, double v) { char b[64]; std::snprintf(b, sizeof b, f, v); return b; }

std::string ParamSpec::display(float v) const {
    if (!std::isfinite(v)) return "-";
    switch (kind) {
        case ParamKind::toggle: return v > 0.5f ? "on" : "off";
        case ParamKind::trigger: return "";
        case ParamKind::choice: return options.empty() ? "" : options[size_t(clampIndex(v, int(options.size())))];
        case ParamKind::integer: return std::to_string(int(std::round(std::clamp(v, -1e9f, 1e9f))));
        case ParamKind::continuous: break;
    }
    if (unit == "Hz") {
        if (v < 0) return "-" + display(-v);
        if (v >= 1000) return fmt("%.1fk", v / 1000);
        if (v >= 100) return fmt("%.0f", v);
        if (v >= 10) return fmt("%.1f", v);
        return fmt("%.2f", v);
    }
    if (unit == "ms") {
        if (v >= 1000) return fmt("%.2fs", v / 1000);
        if (v >= 10) return fmt("%.0fms", v);
        return fmt("%.1fms", v);
    }
    if (unit == "%") return fmt("%.0f%%", v * 100);
    if (unit == "dB") return (v <= min + 0.05f && min <= -59) ? "-inf" : fmt("%+.1fdB", v);
    if (unit == "st") return fmt("%+.1fst", v);
    if (unit == "/s") return fmt("%.1f/s", v);
    if (unit == "bpm") return fmt("%.1f", v);
    if (unit == ":1") return fmt("%.1f:1", v);
    if (unit == "°") return fmt("%.0f°", v);
    if (unit == "x") return fmt("%.2fx", v);
    if (unit == "bit") return fmt("%.1f bit", v);
    if (unit == "ct") return fmt("%+.0fct", v);
    return fmt("%.2f", v);
}

// ---------------------------------------------------------------- ModuleSpec

int ModuleSpec::paramIndex(const std::string& key) const {
    for (size_t i = 0; i < params.size(); ++i) if (params[i].key == key) return int(i);
    return -1;
}

BypassMode ModuleSpec::bypass() const {
    static const std::set<std::string> none { "in", "out", "clock", "rec", "mix", "text", "scope" };
    static const std::set<std::string> silent { "macro", "modal", "shapes", "rack", "drumsynth", "wave",
                                                "keys", "seq", "turing", "roll", "drums", "slider", "knob", "chord" };
    if (none.count(kind)) return BypassMode::none;
    if (kind == "atten") return BypassMode::through;
    if (silent.count(kind)) return BypassMode::silent;
    return category == "Modulation" ? BypassMode::silent : BypassMode::through;
}

std::vector<int> ModuleSpec::bypassRouting() const {
    std::vector<int> r;
    auto find = [&](const char* n) { auto it = std::find(inputs.begin(), inputs.end(), n); return it == inputs.end() ? -1 : int(it - inputs.begin()); };
    for (auto& o : outputs) {
        if (bypass() != BypassMode::through || inputs.empty()) { r.push_back(-1); continue; }
        auto ends = [&](char c) { return !o.empty() && o.back() == c; };
        if (ends('R') && find("R") >= 0) r.push_back(find("R"));
        else if (ends('L') && find("L") >= 0) r.push_back(find("L"));
        else r.push_back(0);
    }
    return r;
}

// ---------------------------------------------------------------- DSPNode

DSPNode::DSPNode(const ModuleSpec& s, double sr)
    : sampleRate(sr), spec(s), paramCount(int(s.params.size())) {
    size_t pc = size_t(std::max(1, paramCount));
    base.assign(pc, 0); params.assign(pc, 0); modPrev.assign(pc, 0);
    rt.assign(pc, ParamRT { 0, 1, false, false, false, false, false });
    for (int i = 0; i < paramCount; ++i) {
        auto& p = s.params[size_t(i)];
        base[size_t(i)] = p.isTrigger() ? 0 : p.def;
        params[size_t(i)] = base[size_t(i)];
        rt[size_t(i)] = { p.min, p.max, p.curve == ParamCurve::exponential, p.curve == ParamCurve::cubic,
                          p.kind != ParamKind::continuous, p.isTrigger(), p.unit == "st" };
    }
    autoLane.assign(pc * autoSlots, 0);
    autoOn.assign(pc, 0); autoHold.assign(pc, 0);
    outputs.clear();
    for (size_t k = 0; k < s.outputs.size(); ++k) {
        bool poly = std::find(s.polyOutputs.begin(), s.polyOutputs.end(), int(k)) != s.polyOutputs.end();
        outputs.emplace_back(size_t(kMaxBlock * (poly ? kMaxVoices : 1)), 0.0f);
    }
    outVoices.assign(std::max<size_t>(s.outputs.size(), 1), 1);
    inVoices.assign(std::max<size_t>(s.inputs.size(), 1), 1);
    outLevel.assign(std::max<size_t>(s.outputs.size(), 1), 0.0f);
    routing = s.bypassRouting();
}

void DSPNode::syncTo(const PatchNode& n) {
    for (int i = 0; i < paramCount; ++i) {
        auto& p = spec.params[size_t(i)];
        if (p.isTrigger()) continue;
        auto it = n.params.find(p.key);
        float v = it == n.params.end() ? p.def : it->second;
        if (base[size_t(i)] != v) base[size_t(i)] = v;
    }
    for (auto& [key, start] : defaultData()) {
        auto it = n.data.find(key);
        setData(key, it == n.data.end() ? start : it->second);
    }
    loadAutomation(n.data);
}

void DSPNode::setAutomation(int i, const std::vector<float>* values) {
    if (i < 0 || i >= paramCount) return;
    if (values && int(values->size()) == autoSlots) {
        float* lane = autoLane.data() + i * autoSlots;
        for (int k = 0; k < autoSlots; ++k) lane[k] = std::isfinite((*values)[size_t(k)]) ? (*values)[size_t(k)] : rt[size_t(i)].min;
        autoOn[size_t(i)] = 1;
    } else autoOn[size_t(i)] = 0;
    autoCount = 0;
    for (int k = 0; k < paramCount; ++k) autoCount += autoOn[size_t(k)];
}

void DSPNode::loadAutomation(const std::map<std::string, std::vector<float>>& data) {
    for (int i = 0; i < paramCount; ++i) {
        if (autoHold[size_t(i)]) continue;
        auto it = data.find(autoKey(spec.params[size_t(i)].key));
        if (it != data.end() || autoOn[size_t(i)]) setAutomation(i, it == data.end() ? nullptr : &it->second);
    }
}

void DSPNode::syncParams() {
    for (int i = 0; i < paramCount; ++i) {
        auto& r = rt[size_t(i)];
        if (r.trigger) {
            if (base[size_t(i)] > 0.5f) { base[size_t(i)] = 0; params[size_t(i)] = 1; }
        } else {
            float b = base[size_t(i)];
            params[size_t(i)] = std::isfinite(b) ? std::clamp(b, r.min, r.max) : r.min;
        }
    }
}

void DSPNode::applyAutomation(double beat) {
    double p = std::isfinite(beat) ? std::fmod(beat, autoBeats) : 0;
    if (p < 0) p += autoBeats;
    double pos = p / autoBeats * autoSlots;
    autoPosition = pos;
    if (autoCount == 0) return;
    int i0 = std::min(int(pos), autoSlots - 1), i1 = (i0 + 1) % autoSlots;
    float f = float(pos - i0);
    for (int i = 0; i < paramCount; ++i) {
        if (!autoOn[size_t(i)] || autoHold[size_t(i)] || rt[size_t(i)].trigger) continue;
        const float* lane = autoLane.data() + i * autoSlots;
        float v = rt[size_t(i)].round ? lane[i0] : lane[i0] + (lane[i1] - lane[i0]) * f;
        if (!std::isfinite(v)) continue;
        if (rt[size_t(i)].round) v = std::round(v);
        params[size_t(i)] = std::clamp(v, rt[size_t(i)].min, rt[size_t(i)].max);
    }
}

void DSPNode::applyMod(int i, float mod, float position) {
    auto& r = rt[size_t(i)];
    float m = std::isfinite(mod) ? std::clamp(mod, -4.0f, 4.0f) : 0.0f;
    if (r.trigger) {
        float mm = std::isnan(position) ? m : m + position;
        if (mm > 0.5f && modPrev[size_t(i)] <= 0.5f) params[size_t(i)] = 1;
        modPrev[size_t(i)] = mm;
        return;
    }
    float src = autoOn[size_t(i)] && !autoHold[size_t(i)] ? params[size_t(i)] : base[size_t(i)];
    float b = std::isfinite(src) ? src : r.min;
    if (r.semis && std::isnan(position)) {   // pitch CV into a semitone row: 1 V/oct
        float v = std::clamp(b + m * 120, r.min, r.max);
        if (r.round) v = std::round(v);
        params[size_t(i)] = v;
        return;
    }
    float a = std::max(std::abs(r.min), std::abs(r.max));
    bool uni = r.min >= 0;
    float n = r.exp ? std::log(std::max(b, r.min) / r.min) / std::log(r.max / r.min)
            : r.cubic ? (uni ? std::cbrt(std::max(b, 0.0f) / std::max(r.max, 1e-9f)) : (std::cbrt(b / a) + 1) / 2)
            : (b - r.min) / (r.max - r.min);
    if (!std::isnan(position)) n = std::isfinite(position) ? std::clamp(position, 0.0f, 1.0f) : 0.0f;
    n = std::isfinite(n) ? std::clamp(n + m, 0.0f, 1.0f) : 0.0f;
    float v;
    if (r.exp) v = r.min * std::pow(r.max / r.min, n);
    else if (r.cubic) { if (uni) v = r.max * n * n * n; else { float x = 2 * n - 1; v = a * x * x * x; } }
    else v = r.min + (r.max - r.min) * n;
    if (r.round) v = std::round(v);
    params[size_t(i)] = v;
}

// ---------------------------------------------------------------- RateBridge

RateBridge::RateBridge(double hostRate, double nativeRate, int b, int ci, int co)
    : block(b), chIn(std::max(ci, 1)), chOut(co) {
    ratio = nativeRate / hostRate;
    step = hostRate / nativeRate;
    filtered = std::abs(ratio - 1) > 1e-6;
    inBuf.assign(size_t(chIn * block), 0); outBlock.assign(size_t(chOut * block), 0);
    prev.assign(size_t(chIn), 0); cur.assign(size_t(chIn), 0);
    cap = block * 16;
    ring.assign(size_t(chOut * cap), 0);
    readPos = -double(block + 4);
    float fc = float(std::min(hostRate, nativeRate) * 0.45);
    auto make = [&](double sr, float k) { SVF f; f.set(fc, float(sr), k); return f; };
    for (int c = 0; c < chIn; ++c) { aaIn.push_back(make(hostRate, 1.848f)); aaIn2.push_back(make(hostRate, 0.765f)); }
    for (int c = 0; c < chOut; ++c) { aaOut.push_back(make(hostRate, 1.848f)); aaOut2.push_back(make(hostRate, 0.765f)); }
}

// ---------------------------------------------------------------- Patch JSON (same as the Mac / iPad files)

int Patch::index(const juce::String& id) const {
    for (size_t i = 0; i < nodes.size(); ++i) if (nodes[i].id == id) return int(i);
    return -1;
}

juce::String Patch::newID() { return juce::Uuid().toDashedString().toUpperCase(); }

static std::vector<float> floats(const juce::var& v) {
    std::vector<float> out;
    if (auto* a = v.getArray()) for (auto& x : *a) out.push_back(float(double(x)));
    return out;
}

std::optional<Patch> Patch::fromJSON(const juce::String& json) {
    auto root = juce::JSON::parse(json);
    auto* o = root.getDynamicObject();
    if (!o) return std::nullopt;
    Patch p;
    p.version = int(o->getProperty("version"));
    if (o->hasProperty("tempo")) p.tempo = double(o->getProperty("tempo"));
    if (auto* ns = o->getProperty("nodes").getArray()) {
        for (auto& nv : *ns) {
            auto* no = nv.getDynamicObject();
            if (!no) continue;
            PatchNode n;
            n.id = no->getProperty("id").toString();
            n.kind = no->getProperty("kind").toString().toStdString();
            n.x = double(no->getProperty("x")); n.y = double(no->getProperty("y"));
            if (auto* ps = no->getProperty("params").getDynamicObject())
                for (auto& kv : ps->getProperties()) n.params[kv.name.toString().toStdString()] = float(double(kv.value));
            n.collapsed = bool(no->getProperty("collapsed"));
            n.bypassed = bool(no->getProperty("bypassed"));
            if (auto* ds = no->getProperty("data").getDynamicObject())
                for (auto& kv : ds->getProperties()) n.data[kv.name.toString().toStdString()] = floats(kv.value);
            if (no->hasProperty("w")) n.w = double(no->getProperty("w"));
            if (no->hasProperty("dh")) n.dh = double(no->getProperty("dh"));
            if (no->hasProperty("z")) n.z = double(no->getProperty("z"));
            if (no->hasProperty("text")) n.text = no->getProperty("text").toString();
            if (no->hasProperty("highlight")) n.highlight = no->getProperty("highlight").toString();
            if (auto* pa = no->getProperty("pin").getArray(); pa && pa->size() == 2) n.pin = std::array<double, 2> { double((*pa)[0]), double((*pa)[1]) };
            n.hideIn = bool(no->getProperty("hideIn")); n.hideOut = bool(no->getProperty("hideOut"));
            p.nodes.push_back(std::move(n));
        }
    }
    if (auto* cs = o->getProperty("cables").getArray()) {
        for (auto& cv : *cs) {
            auto* co = cv.getDynamicObject();
            if (!co) continue;
            PatchCable c;
            c.id = co->getProperty("id").toString();
            c.fromNode = co->getProperty("fromNode").toString(); c.toNode = co->getProperty("toNode").toString();
            c.fromPort = int(co->getProperty("fromPort")); c.toPort = int(co->getProperty("toPort"));
            p.cables.push_back(c);
        }
    }
    if (auto* gs = o->getProperty("groups").getArray()) {
        for (auto& gv : *gs) {
            auto* go = gv.getDynamicObject();
            if (!go) continue;
            PatchGroup g;
            g.id = go->getProperty("id").toString(); g.name = go->getProperty("name").toString();
            if (auto* ms = go->getProperty("members").getArray()) for (auto& m : *ms) g.members.push_back(m.toString());
            p.groups.push_back(g);
        }
    }
    return p;
}

juce::String Patch::toJSON() const {
    auto* root = new juce::DynamicObject();
    root->setProperty("version", version);
    if (tempo) root->setProperty("tempo", *tempo);
    juce::Array<juce::var> ns;
    for (auto& n : nodes) {
        auto* o = new juce::DynamicObject();
        o->setProperty("id", n.id); o->setProperty("kind", juce::String(n.kind));
        o->setProperty("x", n.x); o->setProperty("y", n.y);
        auto* ps = new juce::DynamicObject();
        for (auto& [k, v] : n.params) ps->setProperty(juce::Identifier(juce::String(k)), double(v));
        o->setProperty("params", juce::var(ps));
        o->setProperty("collapsed", n.collapsed); o->setProperty("bypassed", n.bypassed);
        auto* ds = new juce::DynamicObject();
        for (auto& [k, v] : n.data) {
            juce::Array<juce::var> a;
            for (float x : v) a.add(double(x));
            ds->setProperty(juce::Identifier(juce::String(k)), a);
        }
        o->setProperty("data", juce::var(ds));
        if (n.w) o->setProperty("w", *n.w);
        if (n.dh) o->setProperty("dh", *n.dh);
        if (n.z) o->setProperty("z", *n.z);
        if (n.text) o->setProperty("text", *n.text);
        if (n.highlight) o->setProperty("highlight", *n.highlight);
        if (n.pin) { juce::Array<juce::var> pa; pa.add((*n.pin)[0]); pa.add((*n.pin)[1]); o->setProperty("pin", pa); }
        if (n.hideIn) o->setProperty("hideIn", true);
        if (n.hideOut) o->setProperty("hideOut", true);
        ns.add(juce::var(o));
    }
    root->setProperty("nodes", ns);
    juce::Array<juce::var> cs;
    for (auto& c : cables) {
        auto* o = new juce::DynamicObject();
        o->setProperty("id", c.id); o->setProperty("fromNode", c.fromNode); o->setProperty("fromPort", c.fromPort);
        o->setProperty("toNode", c.toNode); o->setProperty("toPort", c.toPort);
        cs.add(juce::var(o));
    }
    root->setProperty("cables", cs);
    if (!groups.empty()) {
        juce::Array<juce::var> gs;
        for (auto& g : groups) {
            auto* o = new juce::DynamicObject();
            o->setProperty("id", g.id); o->setProperty("name", g.name);
            juce::Array<juce::var> ms;
            for (auto& m : g.members) ms.add(m);
            o->setProperty("members", ms);
            gs.add(juce::var(o));
        }
        root->setProperty("groups", gs);
    }
    return juce::JSON::toString(juce::var(root));
}


// ---------------------------------------------------------------- migrations, replace, copy (Patch.swift)

static int divRatioIndex(int r) {
    static const int mult[] = { 16, 12, 8, 6, 4, 3, 2 };
    if (r < 0) { for (int i = 0; i < 7; ++i) if (mult[i] == -r) return i; return 7; }
    return 7 + std::max(r, 1) - 1;
}

Patch Patch::migrated() const {
    if (version >= currentVersion) return *this;
    Patch p = *this;
    auto kindsOf = [&]() { std::map<juce::String, std::string> k; for (auto& n : p.nodes) k.emplace(n.id, n.kind); return k; };
    auto rnd = [](float v, float d) { return std::isfinite(v) ? std::round(v) : d; };
    if (version < 2) {
        for (auto& n : p.nodes) {
            if (n.kind == "in" && n.params.count("ch")) {
                int port = std::max(int(std::round(n.params["ch"])) - 1, 0);
                for (auto& c : p.cables) if (c.fromNode == n.id && c.fromPort == 0) c.fromPort = port;
                n.params.clear();
            } else if (n.kind == "out" && (n.params.count("chL") || n.params.count("chR"))) {
                int l = std::max(int(std::round(n.params.count("chL") ? n.params["chL"] : 1.0f)) - 1, 0);
                int r = std::max(int(std::round(n.params.count("chR") ? n.params["chR"] : 2.0f)) - 1, 0);
                for (auto& c : p.cables) if (c.toNode == n.id) { if (c.toPort == 0) c.toPort = l; else if (c.toPort == 1) c.toPort = r; }
                std::map<std::string, float> keep;
                if (n.params.count("gain")) keep["gain"] = n.params["gain"];
                n.params = keep;
            }
        }
    }
    if (version < 3) {
        static const float oldSpeeds[] = { -2, -1, -0.5f, 0.5f, 1, 2 };
        for (auto& n : p.nodes) {
            if (n.kind != "looper") continue;
            if (n.params.count("speed")) {
                float v = oldSpeeds[std::clamp(int(rnd(n.params["speed"], 4)), 0, 5)];
                n.params["rate"] = std::abs(v); n.params["rev"] = v < 0 ? 1.0f : 0.0f; n.params.erase("speed");
            }
            for (auto& c : p.cables) if (c.toNode == n.id && c.toPort >= kParamPortBase + 7) c.toPort += 1;
        }
    }
    if (version < 4) {
        for (auto& n : p.nodes) if (n.kind == "comp") {
            n.params.clear();
            auto id = n.id;
            p.cables.erase(std::remove_if(p.cables.begin(), p.cables.end(), [&](auto& c) { return c.toNode == id && c.toPort >= kParamPortBase; }), p.cables.end());
        }
    }
    if (version < 5) {
        static const std::set<std::string> shifted { "looper", "sampler", "stretch", "grain", "filter" };
        auto kinds = kindsOf();
        for (auto& c : p.cables) {
            auto k = kinds.count(c.toNode) ? kinds[c.toNode] : "";
            if (shifted.count(k) && c.toPort >= 1 && c.toPort < kParamPortBase) c.toPort += 1;
            if (kinds.count(c.fromNode) && kinds[c.fromNode] == "freqshift" && c.fromPort == 1) c.fromPort = 2;
        }
        static const std::set<std::string> nowStereo { "looper", "filter", "drive" };
        for (auto& n : p.nodes) {
            if (!nowStereo.count(n.kind)) continue;
            std::vector<size_t> toOut;
            for (size_t i = 0; i < p.cables.size(); ++i)
                if (p.cables[i].fromNode == n.id && p.cables[i].fromPort == 0 && kinds.count(p.cables[i].toNode) && kinds[p.cables[i].toNode] == "out") toOut.push_back(i);
            std::sort(toOut.begin(), toOut.end(), [&](size_t a, size_t b) { return p.cables[a].toPort < p.cables[b].toPort; });
            if (toOut.size() >= 2) p.cables[toOut[1]].fromPort = 1;
        }
    }
    if (version < 6) {
        auto kinds = kindsOf();
        for (auto& c : p.cables) {
            if (!kinds.count(c.toNode) || kinds[c.toNode] != "mix" || c.toPort < kParamPortBase) continue;
            int old = c.toPort - kParamPortBase;
            c.toPort = kParamPortBase + (old < 4 ? 1 + 2 * old : 33);
        }
        for (auto& n : p.nodes) {
            if (n.kind != "mix") continue;
            std::vector<size_t> toOut;
            for (size_t i = 0; i < p.cables.size(); ++i)
                if (p.cables[i].fromNode == n.id && p.cables[i].fromPort == 0 && kinds.count(p.cables[i].toNode) && kinds[p.cables[i].toNode] == "out") toOut.push_back(i);
            std::sort(toOut.begin(), toOut.end(), [&](size_t a, size_t b) { return p.cables[a].toPort < p.cables[b].toPort; });
            if (toOut.size() >= 2) p.cables[toOut[1]].fromPort = 1;
        }
    }
    p.version = currentVersion;
    if (version < 7) {
        std::map<std::string, std::map<int, int>> remap { { "modal", { { 0, 1 }, { 1, 0 } } }, { "macro", { { 0, 1 }, { 1, 0 } } },
            { "shapes", { { 0, 1 }, { 1, 0 } } }, { "slopes", { { 0, 1 }, { 1, 0 } } }, { "resonator", { { 1, 2 }, { 2, 1 } } } };
        auto kinds = kindsOf();
        for (auto& c : p.cables) {
            if (c.toPort >= kParamPortBase || !kinds.count(c.toNode)) continue;
            auto it = remap.find(kinds[c.toNode]);
            if (it == remap.end()) continue;
            auto t = it->second.find(c.toPort);
            if (t != it->second.end()) c.toPort = t->second;
        }
    }
    if (version < 8)
        for (auto& n : p.nodes) if (n.kind == "div" && n.params.count("base")) n.params["base"] += 1;
    if (version < 10)
        for (auto& n : p.nodes) if (n.kind == "clock" && !n.params.count("source"))
            for (auto& c : p.cables) if (c.toNode == n.id && c.toPort == 0) { n.params["source"] = 0; break; }
    if (version < 11)
        for (auto& n : p.nodes) {
            if (n.kind != "roll") continue;
            if (n.data.count("notes") && !n.data.count("grid")) {
                // straight onto the full 7-octave grid (v14), at the notes they played
                const int steps = 128, rows = 84, shown = 24, lowest = -36;
                int low = n.params.count("low") ? int(std::round(n.params["low"])) : -12;
                std::vector<float> g(size_t(steps * rows), 0.0f);
                auto& old = n.data["notes"];
                for (int s = 0; s < std::min(int(old.size()), steps); ++s) {
                    float r = old[size_t(s)];
                    if (!std::isfinite(r) || r < 0 || int(r) >= shown) continue;
                    int row = int(r) + low - lowest;
                    if (row >= 0 && row < rows) g[size_t(row * steps + s)] = 1;
                }
                n.data["grid"] = g;
            }
            n.data.erase("notes");
        }
    if (version < 12) {
        auto kinds = kindsOf();
        auto kind = [&](const juce::String& id) { return kinds.count(id) ? kinds[id] : std::string(); };
        p.cables.erase(std::remove_if(p.cables.begin(), p.cables.end(), [&](const PatchCable& c) {
            auto f = kind(c.fromNode);
            if (f == "roll" && c.fromPort >= 3) return true;
            if (f == "chord" && c.fromPort >= 2) return true;
            auto t = kind(c.toNode);
            if (t == "wave" || t == "shapes") return (c.toPort >= 2 && c.toPort < kParamPortBase) || c.toPort == kParamPortBase + 7;
            if (t == "macro") return (c.toPort >= 3 && c.toPort < kParamPortBase) || c.toPort == kParamPortBase + 9;
            return false;
        }), p.cables.end());
        for (auto& n : p.nodes) if (n.kind == "wave" || n.kind == "shapes" || n.kind == "macro") n.params.erase("voices");
    }
    if (version < 14)   // roll holds notes over its whole range (7 octaves) and scrolls; the old 2-octave grid moves to the notes it played
        for (auto& n : p.nodes) {
            if (n.kind != "roll" || !n.data.count("grid") || n.data["grid"].size() != size_t(32 * 24)) continue;
            int low = n.params.count("low") ? int(std::round(n.params["low"])) : -12;
            auto old = n.data["grid"];
            std::vector<float> g(size_t(128 * 84), 0.0f);
            for (int r = 0; r < 24; ++r) {
                int row = r + low + 36;
                if (row < 0 || row >= 84) continue;
                for (int s = 0; s < 32; ++s) if (old[size_t(r * 32 + s)] > 0.5f) g[size_t(row * 128 + s)] = 1;
            }
            n.data["grid"] = g;
        }
    if (version < 15)   // step patterns go up to 128 steps (stored 128 per lane, was 32): the same steps, spread out
        for (auto& n : p.nodes) {
            std::string key; int lanes = 0;
            if (n.kind == "rack") { key = "hits"; lanes = 16; }
            else if (n.kind == "drumsynth") { key = "hits"; lanes = 4; }
            else if (n.kind == "drums") { key = "hits"; lanes = 8; }
            else if (n.kind == "roll") { key = "grid"; lanes = 84; }
            else continue;
            if (!n.data.count(key)) continue;
            auto& v = n.data[key];
            if (int(v.size()) != lanes * 32) continue;
            std::vector<float> out(size_t(lanes * 128), 0.0f);
            for (int l = 0; l < lanes; ++l) for (int s = 0; s < 32; ++s) out[size_t(l * 128 + s)] = v[size_t(l * 32 + s)];
            v = out;
        }
    if (version < 13)   // lfo lost its s&h shape; s&h (4) and random (5) both become random (now 4)
        for (auto& n : p.nodes)
            if (n.kind == "lfo" && n.params.count("shape") && std::isfinite(n.params["shape"]) && n.params["shape"] >= 3.5f) n.params["shape"] = 4;
    if (version < 13) {   // rand, slopes and segments are gone (lfo covers them): their boxes and cables go too
        std::set<juce::String> gone;
        for (auto& n : p.nodes) if (n.kind == "rand" || n.kind == "slopes" || n.kind == "segments") gone.insert(n.id);
        if (!gone.empty()) {
            p.nodes.erase(std::remove_if(p.nodes.begin(), p.nodes.end(), [&](const PatchNode& n) { return gone.count(n.id) > 0; }), p.nodes.end());
            p.cables.erase(std::remove_if(p.cables.begin(), p.cables.end(), [&](const PatchCable& c) { return gone.count(c.fromNode) || gone.count(c.toNode); }), p.cables.end());
            for (auto& g : p.groups) g.members.erase(std::remove_if(g.members.begin(), g.members.end(), [&](const juce::String& m) { return gone.count(m) > 0; }), g.members.end());
            p.groups.erase(std::remove_if(p.groups.begin(), p.groups.end(), [](const PatchGroup& g) { return g.members.empty(); }), p.groups.end());
        }
    }
    if (version < 9)
        for (auto& n : p.nodes) {
            if (n.kind != "div") continue;
            for (int k = 1; k <= 8; ++k) {
                auto key = "d" + std::to_string(k);
                float old = n.params.count(key) ? n.params[key] : float(k);
                int v = std::isfinite(old) ? std::clamp(int(std::round(old)), 1, 64) : k;
                n.params[key] = float(divRatioIndex(v));
            }
        }
    return p;
}

std::optional<std::pair<Patch, juce::String>> Patch::replacing(const juce::String& id, const std::string& kind) const {
    int i = index(id);
    if (i < 0) return std::nullopt;
    auto* oldSpec = Registry::spec(nodes[size_t(i)].kind);
    auto* newSpec = Registry::spec(kind);
    if (!oldSpec || !newSpec) return std::nullopt;
    const PatchNode& old = nodes[size_t(i)];
    PatchNode n; n.id = newID(); n.kind = kind; n.x = old.x; n.y = old.y; n.collapsed = old.collapsed;
    for (auto& ps : newSpec->params) {
        if (ps.isTrigger()) continue;
        auto it = old.params.find(ps.key);
        if (it != old.params.end()) n.params[ps.key] = std::clamp(it->second, ps.min, ps.max);
    }
    Patch p = *this;
    p.nodes[size_t(i)] = n;
    auto mapPort = [&](int port, bool input) -> int {
        if (port >= kParamPortBase) {
            int k = port - kParamPortBase;
            if (k >= int(oldSpec->params.size())) return -1;
            int j = newSpec->paramIndex(oldSpec->params[size_t(k)].key);
            return j < 0 ? -1 : kParamPortBase + j;
        }
        auto& on = input ? oldSpec->inputs : oldSpec->outputs;
        auto& nn = input ? newSpec->inputs : newSpec->outputs;
        if (port < int(on.size())) {
            auto it = std::find(nn.begin(), nn.end(), on[size_t(port)]);
            if (it != nn.end()) return int(it - nn.begin());
        }
        return port < int(nn.size()) ? port : -1;
    };
    std::vector<PatchCable> cables;
    for (auto c : p.cables) {
        if (c.toNode == id) { int t = mapPort(c.toPort, true); if (t < 0) continue; c.toNode = n.id; c.toPort = t; }
        if (c.fromNode == id) { int f = mapPort(c.fromPort, false); if (f < 0) continue; c.fromNode = n.id; c.fromPort = f; }
        bool dup = false;
        for (auto& d : cables) if (d.fromNode == c.fromNode && d.fromPort == c.fromPort && d.toNode == c.toNode && d.toPort == c.toPort) dup = true;
        if (!dup) cables.push_back(c);
    }
    p.cables = cables;
    for (auto& g : p.groups) for (auto& m : g.members) if (m == id) m = n.id;
    return std::make_pair(p, n.id);
}

std::pair<Patch, std::map<juce::String, juce::String>> Patch::withFreshIDs() const {
    Patch p = *this;
    std::map<juce::String, juce::String> map;
    for (auto& n : p.nodes) { auto nid = newID(); map[n.id] = nid; n.id = nid; }
    std::vector<PatchCable> cs;
    for (auto& c : p.cables) {
        if (!map.count(c.fromNode) || !map.count(c.toNode)) continue;
        PatchCable d = c; d.id = newID(); d.fromNode = map[c.fromNode]; d.toNode = map[c.toNode];
        cs.push_back(d);
    }
    p.cables = cs;
    for (auto& g : p.groups) {
        g.id = newID();
        std::vector<juce::String> ms;
        for (auto& m : g.members) if (map.count(m)) ms.push_back(map[m]);
        g.members = ms;
    }
    return { p, map };
}

// ---------------------------------------------------------------- the compiled graph

class CompiledGraph {
public:
    struct Sum { float* dest; std::vector<const float*> sources; };
    struct Mod { int index; std::vector<const float*> sources, absolute; };
    struct Entry {
        DSPNode* node;
        std::vector<const float*> inputs;
        std::vector<Sum> sums;
        std::vector<Mod> mods;
        uint64_t connected = 0;
        std::vector<std::pair<int, const int*>> polyIn;
    };
    std::vector<Entry> entries;
    bool hasClock = false;
    std::vector<std::vector<float>> owned;

    void process(int frames, ProcessContext& ctx) {
        for (auto& e : entries) {
            for (auto& s : e.sums) {
                std::copy(s.sources[0], s.sources[0] + frames, s.dest);
                for (size_t k = 1; k < s.sources.size(); ++k)
                    for (int i = 0; i < frames; ++i) s.dest[i] += s.sources[k][i];
            }
            DSPNode& node = *e.node;
            std::fill(node.inVoices.begin(), node.inVoices.end(), 1);
            for (auto& [port, count] : e.polyIn) node.inVoices[size_t(port)] = std::clamp(*count, 1, kMaxVoices);
            float target = node.bypassed.load() && node.spec.bypass() != BypassMode::none ? 1.0f : 0.0f;
            float start = node.bypassMix;
            if (!(start == 1 && target == 1)) {
                node.syncParams();
                node.applyAutomation(ctx.beat[0]);
                for (auto& m : e.mods) {
                    float v = 0;
                    for (auto* s : m.sources) v += s[0];
                    if (m.absolute.empty()) node.applyMod(m.index, v);
                    else { float pos = 0; for (auto* s : m.absolute) pos += s[0]; node.applyMod(m.index, v, pos); }
                }
                node.process(frames, e.inputs.data(), e.connected, ctx);
            }
            if (start > 0 || target > 0) {
                float step = (target - start) / float(frames);
                for (size_t k = 0; k < node.outputs.size(); ++k) {
                    int r = k < node.routing.size() ? node.routing[k] : -1;
                    const float* src = nullptr;
                    if (r >= 0) {
                        int ri = (r > 0 && !((e.connected >> r) & 1u)) ? 0 : r;
                        src = e.inputs[size_t(ri)];
                    }
                    float* out = node.out(int(k));
                    float g = start;
                    for (int i = 0; i < frames; ++i) {
                        g += step;
                        float thru = src ? src[i] : 0;
                        out[i] = (start == 1 && target == 1) ? thru : out[i] * (1 - g) + thru * g;
                    }
                }
                node.bypassMix = target;
                if (target == 1) std::fill(node.outVoices.begin(), node.outVoices.end(), 1);
            }
            float fall = std::exp(-float(frames) / (0.25f * float(ctx.sampleRate)));
            for (size_t k = 0; k < node.outputs.size(); ++k) {
                float pk = 0;
                int nv = std::clamp(node.outVoices[k], 1, int(node.outputs[k].size()) / kMaxBlock);
                for (int v = 0; v < nv; ++v) {
                    float* out = node.outVoice(int(k), v);
                    for (int i = 0; i < frames; ++i) {
                        if (!std::isfinite(out[i])) { out[i] = 0; ++node.nonFinite; }
                        if (v == 0) pk = std::max(pk, std::abs(out[i]));
                    }
                }
                node.outLevel[k] = std::max(pk, node.outLevel[k] * fall);
            }
        }
    }
};

// ---------------------------------------------------------------- GraphHost

GraphHost::GraphHost(double sr) : sampleRate(sr), ctx(sr) { zero.assign(kMaxBlock, 0); }
GraphHost::~GraphHost() { slot.store(nullptr); }

DSPNode* GraphHost::node(const juce::String& id) {
    auto it = nodes.find(id);
    return it == nodes.end() ? nullptr : it->second.get();
}

void GraphHost::transport(int t) {
    if (t == 0) ctx.running = true;
    else if (t == 1) ctx.running = false;
    else { ctx.running = false; ctx.stopPending = true; }
}

void GraphHost::load(const Patch& patch) {
    lastPatch = patch;
    defaultBPM = patch.tempo.value_or(120);
    std::map<juce::String, std::unique_ptr<DSPNode>> fresh;
    for (auto& n : patch.nodes) {
        auto it = nodes.find(n.id);
        if (it != nodes.end()) {
            it->second->bypassed = n.bypassed;
            it->second->syncTo(n);
            fresh[n.id] = std::move(it->second);
            nodes.erase(it);
        } else if (auto* spec = Registry::spec(n.kind)) {
            std::unique_ptr<DSPNode> node = spec->factory ? spec->factory(*spec, sampleRate)
                                                          : std::make_unique<DSPNode>(*spec, sampleRate);
            node->bypassed = n.bypassed;
            node->bypassMix = n.bypassed ? 1.0f : 0.0f;
            for (auto& [k, v] : n.data) node->setData(k, v);
            node->loadAutomation(n.data);
            for (int i = 0; i < node->paramCount; ++i) {
                auto& p = spec->params[size_t(i)];
                if (p.isTrigger()) continue;
                auto pit = n.params.find(p.key);
                if (pit != n.params.end()) { node->base[size_t(i)] = pit->second; node->params[size_t(i)] = pit->second; }
            }
            fresh[n.id] = std::move(node);
        }
    }
    // boxes that went away: the audio thread may still be in them for a moment — free them later
    auto now = juce::Time::getMillisecondCounter();
    for (auto& [id, n] : nodes) retiredOwned.emplace_back(std::move(n), now);
    nodes = std::move(fresh);
    auto g = compile(patch);
    slot.store(g.get());
    if (live) retired.emplace_back(live, now);
    live = g;
    purge();
}

void GraphHost::purge() {
    auto now = juce::Time::getMillisecondCounter();
    retired.erase(std::remove_if(retired.begin(), retired.end(), [&](auto& r) { return now - r.second > 2000; }), retired.end());
    retiredOwned.erase(std::remove_if(retiredOwned.begin(), retiredOwned.end(), [&](auto& r) { return now - r.second > 2000; }), retiredOwned.end());
}

void GraphHost::setSampleRate(double sr) {
    if (sr == sampleRate) return;
    sampleRate = sr;
    ctx.sampleRate = sr;
    ctx.samplesPerBeat = sr * 0.5;
    slot.store(nullptr);
    auto now = juce::Time::getMillisecondCounter();
    for (auto& [id, n] : nodes) retiredOwned.emplace_back(std::move(n), now);
    nodes.clear();
    load(lastPatch);
}

static std::vector<juce::String> topo(const std::vector<juce::String>& ids, const std::vector<PatchCable>& cables) {
    std::set<juce::String> set(ids.begin(), ids.end());
    std::map<juce::String, int> indeg;
    std::map<juce::String, std::vector<juce::String>> down;
    for (auto& id : ids) indeg[id] = 0;
    for (auto& c : cables)
        if (set.count(c.fromNode) && set.count(c.toNode) && c.fromNode != c.toNode) { indeg[c.toNode]++; down[c.fromNode].push_back(c.toNode); }
    std::deque<juce::String> queue;
    for (auto& id : ids) if (indeg[id] == 0) queue.push_back(id);
    std::vector<juce::String> out;
    std::set<juce::String> seen;
    while (!queue.empty()) {
        auto id = queue.front(); queue.pop_front();
        if (!seen.insert(id).second) continue;
        out.push_back(id);
        for (auto& d : down[id]) if (--indeg[d] == 0) queue.push_back(d);
    }
    for (auto& id : ids) if (!seen.count(id)) out.push_back(id);
    return out;
}

// slider / knob outlets set a parameter's position; the node publishes it here (Modules_Core.cpp)
const float* controlPosition(DSPNode* node, int port);

std::shared_ptr<CompiledGraph> GraphHost::compile(const Patch& patch) {
    std::vector<juce::String> ids;
    for (auto& n : patch.nodes) if (nodes.count(n.id)) ids.push_back(n.id);
    std::set<juce::String> idSet(ids.begin(), ids.end());
    std::vector<PatchCable> cables;
    for (auto& c : patch.cables) if (idSet.count(c.fromNode) && idSet.count(c.toNode)) cables.push_back(c);

    // clocks (and what feeds them) first, so every synced module sees this block's beat
    std::map<juce::String, std::vector<juce::String>> upstream;
    for (auto& c : cables) upstream[c.toNode].push_back(c.fromNode);
    std::set<juce::String> first;
    std::vector<juce::String> stack;
    for (auto& n : patch.nodes) if (n.kind == "clock" && idSet.count(n.id)) stack.push_back(n.id);
    while (!stack.empty()) {
        auto id = stack.back(); stack.pop_back();
        if (first.insert(id).second) for (auto& u : upstream[id]) stack.push_back(u);
    }
    std::vector<juce::String> a, b;
    for (auto& id : ids) (first.count(id) ? a : b).push_back(id);
    auto order = topo(a, cables);
    auto rest = topo(b, cables);
    order.insert(order.end(), rest.begin(), rest.end());

    auto g = std::make_shared<CompiledGraph>();
    g->owned.reserve(order.size() * 4);
    for (auto& id : order) {
        DSPNode* node = nodes[id].get();
        CompiledGraph::Entry e;
        e.node = node;
        size_t nIn = node->spec.inputs.size();
        e.inputs.assign(std::max<size_t>(1, nIn), zero.data());
        for (size_t p = 0; p < nIn; ++p) {
            std::vector<const float*> sources;
            for (auto& c : cables)
                if (c.toNode == id && c.toPort == int(p)) {
                    auto* src = nodes[c.fromNode].get();
                    if (c.fromPort < int(src->outputs.size())) sources.push_back(src->out(c.fromPort));
                }
            if (sources.empty()) continue;
            e.connected |= uint64_t(1) << p;
            if (sources.size() == 1) {
                e.inputs[p] = sources[0];
                for (auto& c : cables)
                    if (c.toNode == id && c.toPort == int(p)) {
                        auto* src = nodes[c.fromNode].get();
                        auto& po = src->spec.polyOutputs;
                        if (std::find(po.begin(), po.end(), c.fromPort) != po.end())
                            e.polyIn.push_back({ int(p), &src->outVoices[size_t(c.fromPort)] });
                        break;
                    }
            }
            else {
                g->owned.emplace_back(kMaxBlock, 0.0f);
                float* dest = g->owned.back().data();
                e.sums.push_back({ dest, sources });
                e.inputs[p] = dest;
            }
        }
        {
            uint64_t po = 0;
            for (auto& c : cables) if (c.fromNode == id && c.fromPort < 64) po |= uint64_t(1) << c.fromPort;
            node->patchedOutputs = po;
        }
        if (node->spec.kind == "out") {
            uint64_t cv = 0;
            for (size_t p = 0; p < std::min<size_t>(nIn, 64); ++p) {
                bool any = false, all = true;
                for (auto& c : cables) if (c.toNode == id && c.toPort == int(p)) { any = true; all = all && isCV(c.fromNode, c.fromPort, cables, 0); }
                if (any && all) cv |= uint64_t(1) << p;
            }
            node->cvChannels = cv;
        }
        for (int i = 0; i < node->paramCount; ++i) {
            CompiledGraph::Mod m { i, {}, {} };
            for (auto& c : cables) {
                if (c.toNode != id || c.toPort != kParamPortBase + i) continue;
                auto* src = nodes[c.fromNode].get();
                if (c.fromPort >= int(src->outputs.size())) continue;
                if (auto* pos = controlPosition(src, c.fromPort)) m.absolute.push_back(pos);
                else m.sources.push_back(src->out(c.fromPort));
            }
            if (!m.sources.empty() || !m.absolute.empty()) e.mods.push_back(m);
        }
        if (node->spec.kind == "clock") g->hasClock = true;
        g->entries.push_back(std::move(e));
    }
    return g;
}

bool GraphHost::isCV(const juce::String& id, int port, const std::vector<PatchCable>& cables, int depth) {
    auto* n = node(id);
    if (!n || depth >= 8) return false;
    if (n->spec.kind == "scope") {
        bool any = false;
        for (auto& c : cables) if (c.toNode == id && c.toPort == port) { any = true; if (!isCV(c.fromNode, c.fromPort, cables, depth + 1)) return false; }
        return any;
    }
    return n->spec.outputsAreCV;
}

void GraphHost::renew(const juce::String& id, const Patch& patch) {
    auto it = nodes.find(id);
    if (it == nodes.end()) return;
    retiredOwned.emplace_back(std::move(it->second), juce::Time::getMillisecondCounter());
    nodes.erase(it);
    load(patch);
    if (auto* n = node(id)) n->bypassMix = 1;
}

void GraphHost::clearReadouts() {
    for (auto& [id, n] : nodes) n->readouts.fill(0);
    ctx.samplesPerBeat = sampleRate * 0.5;
    ctx.externalClock = false;
}

void GraphHost::process(int frames, const float* const* inputs, int inputCount, float* const* outputs, int outputCount) {
    CompiledGraph* graph = slot.load(std::memory_order_acquire);
    if (!graph) return;
    int ic = std::min(inputCount, ProcessContext::maxChannels), oc = std::min(outputCount, ProcessContext::maxChannels);
    int off = 0;
    while (off < frames) {
        int n = std::min(kMaxBlock, frames - off);
        for (int c = 0; c < ic; ++c) ctx.inputs[c] = const_cast<float*>(inputs[c]) + off;
        for (int c = 0; c < oc; ++c) ctx.outputs[c] = outputs[c] + off;
        ctx.inputCount = ic; ctx.outputCount = oc; ctx.frames = n;
        if (!graph->hasClock) {
            ctx.samplesPerBeat = sampleRate * 60 / std::clamp(defaultBPM, 20.0, 300.0);
            ctx.externalClock = false;
            double step = ctx.running ? 1 / ctx.samplesPerBeat : 0;
            double b = ctx.stopPending ? -1e-6 : ctx.lastBeat;
            for (int i = 0; i < n; ++i) { b += step; ctx.beat[i] = b; }
        }
        graph->process(n, ctx);
        ctx.lastBeat = ctx.beat[n - 1];
        ctx.stopPending = false;
        off += n;
    }
}

} // namespace pn
