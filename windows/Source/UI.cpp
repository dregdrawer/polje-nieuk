#include "UI.h"
#include <cmath>

namespace pn {

// ================================================================ Theme

namespace Theme {
static bool light = false;
void setLight(bool l) { light = l; }
juce::Colour bg() { return light ? juce::Colour(0xfff2f2f2) : juce::Colour(0xff000000); }
juce::Colour box() { return light ? juce::Colours::white : juce::Colour(0xff111111); }
juce::Colour text() { return light ? juce::Colour(0xff111111) : juce::Colour(0xffeeeeee); }
juce::Colour dim() { return light ? juce::Colour(0xff777777) : juce::Colour(0xff8a8a8a); }
juce::Colour faint() { return light ? juce::Colour(0xffbbbbbb) : juce::Colour(0xff444444); }
juce::Colour border() { return light ? juce::Colour(0xffaaaaaa) : juce::Colour(0xff4a4a4a); }
juce::Colour row() { return light ? juce::Colour(0xffe6e6e6) : juce::Colour(0xff1d1d1d); }
juce::Colour fill() { return light ? juce::Colour(0xffc4c4c4) : juce::Colour(0xff3c3c3c); }
juce::Colour cable() { return light ? juce::Colour(0xff555555) : juce::Colour(0xffb0b0b0); }
juce::Colour selected() { return light ? juce::Colour(0xff000000) : juce::Colours::white; }
juce::Colour bar() { return light ? juce::Colour(0xfffafafa) : juce::Colour(0xff0a0a0a); }
juce::Colour rec() { return juce::Colour(0xffe0443e); }
juce::Font mono(float size, bool bold) {
    return juce::Font(juce::FontOptions(juce::Font::getDefaultMonospacedFontName(), size, bold ? juce::Font::bold : juce::Font::plain));
}
}

// ================================================================ Model

Model::Model() {
    auto f = dataFolder().getChildFile("autosave.json");
    if (auto p = f.existsAsFile() ? Patch::fromJSON(f.loadFileAsString()) : std::nullopt) patch = *p;
    else newPatch();
    auto settings = dataFolder().getChildFile("settings.json");
    auto s = juce::JSON::parse(settings.loadFileAsString());
    lightScheme = bool(s.getProperty("light", false));
    hideCables = bool(s.getProperty("hideCables", false));
    Theme::setLight(lightScheme);
    std::unique_ptr<juce::XmlElement> audioState;
    if (auto st = dataFolder().getChildFile("audio.xml"); st.existsAsFile()) audioState = juce::XmlDocument::parse(st);
    devices.initialise(32, 32, audioState.get(), true);
    devices.addChangeListener(this);
    restartEngineForDevice();
    startTimer(1000);
}

Model::~Model() {
    devices.removeAudioCallback(this);
    timerCallback();
    if (auto xml = devices.createStateXml()) xml->writeTo(dataFolder().getChildFile("audio.xml"));
}

juce::File Model::dataFolder() const {
#if JUCE_WINDOWS
    auto d = juce::File::getSpecialLocation(juce::File::userApplicationDataDirectory).getChildFile("polje nieuk");
#else
    // the Mac / iPad app keeps its own patch in "polje nieuk": this build keeps a separate one
    auto d = juce::File::getSpecialLocation(juce::File::userApplicationDataDirectory).getChildFile("polje nieuk (JUCE)");
#endif
    d.createDirectory();
    return d;
}

void Model::restartEngineForDevice() {
    devices.removeAudioCallback(this);
    if (auto* dev = devices.getCurrentAudioDevice()) {
        host.setSampleRate(dev->getCurrentSampleRate());
        hwIns = std::max(1, dev->getActiveInputChannels().countNumberOfSetBits());
        hwOuts = std::max(1, dev->getActiveOutputChannels().countNumberOfSetBits());
    }
    host.load(patch);
    devices.addAudioCallback(this);
    if (onChange) onChange();
}

void Model::changeListenerCallback(juce::ChangeBroadcaster*) { restartEngineForDevice(); }

void Model::audioDeviceIOCallbackWithContext(const float* const* in, int numIn, float* const* out, int numOut, int numSamples,
                                             const juce::AudioIODeviceCallbackContext&) {
    auto t0 = juce::Time::getHighResolutionTicks();
    for (int c = 0; c < numOut; ++c) if (out[c]) juce::FloatVectorOperations::clear(out[c], numSamples);
    host.process(numSamples, in, numIn, out, numOut);
    for (int c = 0; c < numOut; ++c)
        if (out[c]) for (int i = 0; i < numSamples; ++i) { float v = out[c][i]; out[c][i] = std::isfinite(v) ? std::clamp(v, -1.0f, 1.0f) : 0.0f; }
    auto dt = juce::Time::highResolutionTicksToSeconds(juce::Time::getHighResolutionTicks() - t0);
    double sr = host.sampleRate;
    float load = float(dt / (numSamples / sr));
    cpuLoad.store(cpuLoad.load() * 0.9f + load * 0.1f);
}

void Model::pushUndo() {
    undoStack.push_back(patch);
    if (undoStack.size() > 200) undoStack.erase(undoStack.begin());
    redoStack.clear();
}

void Model::beginGesture() { pushUndo(); gestureOpen = true; }

void Model::changed(bool structural, bool) {
    gestureOpen = false;
    if (structural) host.load(patch);
    dirty = true; lastEdit = juce::Time::getMillisecondCounter();
    if (onChange) onChange();
}

void Model::setParam(const juce::String& id, int index, float value, bool commit) {
    int i = patch.index(id);
    if (i < 0) return;
    auto* spec = Registry::spec(patch.nodes[size_t(i)].kind);
    if (!spec || index < 0 || index >= int(spec->params.size())) return;
    if (commit && !gestureOpen) pushUndo();
    auto& p = spec->params[size_t(index)];
    if (p.isTrigger()) { if (auto* n = host.node(id)) n->base[size_t(index)] = 1; return; }
    patch.nodes[size_t(i)].params[p.key] = value;
    if (auto* n = host.node(id)) n->base[size_t(index)] = value;
    bool structural = spec->kind == "mix" || spec->kind == "slider" || spec->kind == "knob";   // ports come and go
    if (commit) changed(structural);
    else if (onChange) onChange();
}

juce::String Model::addNode(const std::string& kind, double x, double y) {
    pushUndo();
    PatchNode n; n.id = Patch::newID(); n.kind = kind; n.x = x; n.y = y;
    if (kind == "text") n.text = juce::String("text");
    patch.nodes.push_back(n);
    changed(true);
    return n.id;
}

void Model::removeNodes(const std::set<juce::String>& ids) {
    if (ids.empty()) return;
    pushUndo();
    patch.nodes.erase(std::remove_if(patch.nodes.begin(), patch.nodes.end(), [&](auto& n) { return ids.count(n.id) > 0; }), patch.nodes.end());
    patch.cables.erase(std::remove_if(patch.cables.begin(), patch.cables.end(),
                                      [&](auto& c) { return ids.count(c.fromNode) || ids.count(c.toNode); }), patch.cables.end());
    for (auto& g : patch.groups)
        g.members.erase(std::remove_if(g.members.begin(), g.members.end(), [&](auto& m) { return ids.count(m) > 0; }), g.members.end());
    changed(true);
}

void Model::removeCable(const juce::String& id) {
    pushUndo();
    patch.cables.erase(std::remove_if(patch.cables.begin(), patch.cables.end(), [&](auto& c) { return c.id == id; }), patch.cables.end());
    changed(true);
}

void Model::connect(const juce::String& from, int fromPort, const juce::String& to, int toPort) {
    for (auto& c : patch.cables)
        if (c.fromNode == from && c.fromPort == fromPort && c.toNode == to && c.toPort == toPort) return;
    if (!gestureOpen) pushUndo();
    PatchCable c; c.id = Patch::newID(); c.fromNode = from; c.fromPort = fromPort; c.toNode = to; c.toPort = toPort;
    patch.cables.push_back(c);
    changed(true);
}

void Model::undo() {
    if (undoStack.empty()) return;
    redoStack.push_back(patch); patch = undoStack.back(); undoStack.pop_back();
    changed(true);
}
void Model::redo() {
    if (redoStack.empty()) return;
    undoStack.push_back(patch); patch = redoStack.back(); redoStack.pop_back();
    changed(true);
}

void Model::newPatch() {
    // in, out, clock, mixer — not patched (as on the Mac)
    Patch p;
    auto add = [&](const char* k, double x, double y) { PatchNode n; n.id = Patch::newID(); n.kind = k; n.x = x; n.y = y; p.nodes.push_back(n); };
    add("in", 40, 60); add("clock", 40, 260); add("mix", 420, 60); add("out", 680, 60);
    if (!patch.nodes.empty()) pushUndo();
    patch = p;
    changed(true);
}

bool Model::open(const juce::File& f) {
    auto p = Patch::fromJSON(f.loadFileAsString());
    if (!p) return false;
    pushUndo(); patch = *p; changed(true);
    return true;
}
bool Model::saveAs(const juce::File& f) { return f.replaceWithText(patch.toJSON()); }

void Model::timerCallback() {
    if (dirty && juce::Time::getMillisecondCounter() - lastEdit > 600) {
        dataFolder().getChildFile("autosave.json").replaceWithText(patch.toJSON());
        auto* s = new juce::DynamicObject();
        s->setProperty("light", lightScheme); s->setProperty("hideCables", hideCables);
        dataFolder().getChildFile("settings.json").replaceWithText(juce::JSON::toString(juce::var(s)));
        dirty = false;
    }
}

// ================================================================ Box geometry

namespace Box {
static float defaultWidth(const std::string& k) {
    if (k == "in" || k == "out") return 132;
    if (k == "looper" || k == "sampler") return 300;
    if (k == "stretch") return 280;
    if (k == "peq") return 320;
    if (k == "keys") return 300;
    if (k == "seq") return 320;
    if (k == "turing") return 220;
    if (k == "roll" || k == "drums") return 410;
    if (k == "rack") return 480;
    if (k == "drumsynth") return 420;
    if (k == "slider") return 200;
    if (k == "knob" || k == "comp") return 240;
    return 186;
}
static juce::StringArray textLines(const PatchNode& n) { return juce::StringArray::fromLines(n.text.value_or("text")); }
float width(const PatchNode& n) {
    if (n.kind == "text") { int longest = 4; for (auto& l : textLines(n)) longest = std::max(longest, l.length()); return float(longest) * 7.3f + 14; }
    float d = defaultWidth(n.kind);
    return n.w ? std::clamp(float(*n.w), d, 1600.0f) : d;
}
static bool hasReadout(const std::string& k) {
    static const std::set<std::string> s { "clock", "looper", "grain", "rec", "comp", "limit", "repeat", "gain", "mix", "sampler", "stretch",
                                           "peq", "keys", "seq", "turing", "roll", "drums", "slider", "knob", "segments", "lfo", "rack", "drumsynth" };
    return s.count(k) > 0;
}
static float readoutDefault(const std::string& k) {
    if (k == "looper" || k == "stretch") return 104;
    if (k == "sampler") return 122;
    if (k == "peq") return 150;
    if (k == "keys") return 72;
    if (k == "seq") return 100;
    if (k == "turing") return 74;
    if (k == "roll") return 168;
    if (k == "drums") return 8 * portRow + 6;
    if (k == "slider") return 180;
    if (k == "knob") return 100;
    if (k == "segments") return 44;
    if (k == "rack") return 16 * 9 + 8 + 4 * 42 + 3 * 4 + 8;
    if (k == "drumsynth") return 4 * 14 + 8 + 42 + 8;
    if (k == "comp") return 92;
    if (k == "lfo") return 56;
    if (k == "clock") return 40;
    return hasReadout(k) ? 20 : 0;
}
float readoutHeight(const PatchNode& n) {
    float d = readoutDefault(n.kind);
    return (d > 0 && n.dh) ? std::clamp(float(*n.dh), d, 1200.0f) : d;
}
static int controlsCount(const PatchNode& n) {
    static const int c[] = { 1, 2, 4, 8 };
    auto it = n.params.find("count"); return c[clampIndex(it == n.params.end() ? 2.0f : it->second, 4)];
}
static int usedOuts(const Patch& p, const juce::String& id) { int m = 0; for (auto& c : p.cables) if (c.fromNode == id) m = std::max(m, c.fromPort + 1); return m; }
static int usedIns(const Patch& p, const juce::String& id) { int m = 0; for (auto& c : p.cables) if (c.toNode == id && c.toPort < kParamPortBase) m = std::max(m, c.toPort + 1); return m; }
std::vector<std::string> ins(const PatchNode& n, const ModuleSpec& s, const Model& m) {
    if (n.kind == "out") { int k = std::max({ m.hwOuts, usedIns(m.patch, n.id), 1 }); return { s.inputs.begin(), s.inputs.begin() + std::min(k, int(s.inputs.size())) }; }
    if (n.kind == "mix") { static const int c[] = { 2, 4, 8, 16 }; auto it = n.params.find("chans");
                           int k = c[clampIndex(it == n.params.end() ? 1.0f : it->second, 4)]; return { s.inputs.begin(), s.inputs.begin() + k }; }
    return s.inputs;
}
std::vector<std::string> outs(const PatchNode& n, const ModuleSpec& s, const Model& m) {
    if (n.kind == "in") { int k = std::max({ m.hwIns, usedOuts(m.patch, n.id), 1 }); return { s.outputs.begin(), s.outputs.begin() + std::min(k, int(s.outputs.size())) }; }
    if (n.kind == "slider" || n.kind == "knob") { int k = std::max(controlsCount(n), usedOuts(m.patch, n.id)); return { s.outputs.begin(), s.outputs.begin() + k }; }
    return s.outputs;
}
bool hasTriggerRow(const ModuleSpec& s) { for (auto& p : s.params) if (p.isTrigger()) return true; return false; }
std::vector<int> rowParams(const ModuleSpec& s, const PatchNode& n, const Patch& patch) {
    std::vector<int> all;
    for (int i = 0; i < int(s.params.size()); ++i) if (!s.params[size_t(i)].isTrigger()) all.push_back(i);
    auto key = [&](int i) { return s.params[size_t(i)].key; };
    if (auto it = std::find_if(all.begin(), all.end(), [&](int i) { return key(i) == "algo"; }); it != all.end()) { int v = *it; all.erase(it); all.insert(all.begin(), v); }
    if (s.paramIndex("decay") >= 0)
        if (auto it = std::find_if(all.begin(), all.end(), [&](int i) { return key(i) == "attack"; }); it != all.end()) {
            int v = *it; all.erase(it);
            auto d = std::find_if(all.begin(), all.end(), [&](int i) { return key(i) == "decay"; });
            all.insert(d, v);
        }
    std::set<int> patched;
    for (auto& c : patch.cables) if (c.toNode == n.id && c.toPort >= kParamPortBase) patched.insert(c.toPort - kParamPortBase);
    auto pv = [&](const char* k, float d) { auto it = n.params.find(k); return it == n.params.end() ? d : it->second; };
    if (s.kind == "mix") {
        static const int c[] = { 2, 4, 8, 16 };
        int k = c[clampIndex(pv("chans", 1), 4)];
        bool pans = pv("pans", 0) > 0.5f;
        std::vector<int> r { 0 };
        for (int j = 0; j < k; ++j) r.push_back(1 + 2 * j);
        r.push_back(33); r.push_back(34);
        for (int j = 0; j < k; ++j) if (pans || patched.count(2 + 2 * j)) r.push_back(2 + 2 * j);
        return r;
    }
    if (s.kind == "rack" || s.kind == "drumsynth") {
        int per = s.kind == "rack" ? 7 : 14, shown = s.kind == "rack" ? 5 : 12, count = s.kind == "rack" ? 16 : 4;
        int b = 5 + std::clamp(int(std::round(pv("sel", 0))), 0, count - 1) * per;
        std::vector<int> r { 0, 1, 2, 3, 4 };
        for (int j = b; j < b + shown; ++j) r.push_back(j);
        for (int i : all) if (i >= 5 && !(i >= b && i < b + shown) && patched.count(i)) r.push_back(i);
        return r;
    }
    if (s.kind == "segments") {
        int cnt = clampIndex(pv("count", 1), 6) + 1;
        std::vector<int> r; for (int i : all) if (i == 0 || (i - 1) / 4 < cnt) r.push_back(i); return r;
    }
    if (s.kind == "slider" || s.kind == "knob") { std::vector<int> r; for (int i : all) if (i < 3 || patched.count(i)) r.push_back(i); return r; }
    if (s.kind == "peq") {
        static const int c[] = { 3, 5, 8 };
        int b = c[clampIndex(pv("bands", 0), 3)];
        std::vector<int> r; for (int i : all) if (i < 2 || (i - 2) / 3 < b) r.push_back(i); return r;
    }
    return all;
}
static bool sideDisplay(const std::string& k) { return k == "slider" || k == "knob" || k == "drums" || k == "roll"; }
static int portRows(const PatchNode& n, const ModuleSpec& s, const Model& m) {
    int i = int(ins(n, s, m).size()), o = int(outs(n, s, m).size());
    return n.kind == "div" ? i : std::max(i, o);
}
static float portsHeight(const PatchNode& n, const ModuleSpec& s, const Model& m) { int r = portRows(n, s, m); return r > 0 ? r * portRow + 6 : 0; }
float bodyHeight(const PatchNode& n, const ModuleSpec& s, const Model& m) {
    return sideDisplay(n.kind) ? std::max(portsHeight(n, s, m), readoutHeight(n) + 6) : portsHeight(n, s, m) + readoutHeight(n);
}
float height(const PatchNode& n, const ModuleSpec& s, const Model& m) {
    if (n.kind == "text") return float(std::max(textLines(n).size(), 1)) * 15 + 8;
    if (n.collapsed) return header;
    int rows = int(rowParams(s, n, m.patch).size()) + (hasTriggerRow(s) ? 1 : 0);
    return header + bodyHeight(n, s, m) + (rows > 0 ? rows * row + 4 : 0) + 4;
}
juce::Point<float> inlet(const PatchNode& n, int i) {
    float y = n.collapsed ? header / 2 : header + 3 + i * portRow + portRow / 2;
    return { float(n.x), float(n.y) + y };
}
std::optional<float> paramRowY(const PatchNode& n, const ModuleSpec& s, const Model& m, int param) {
    if (n.collapsed) return header / 2;
    auto rp = rowParams(s, n, m.patch);
    auto it = std::find(rp.begin(), rp.end(), param);
    if (it == rp.end()) return std::nullopt;
    int k2 = int(it - rp.begin()) + (hasTriggerRow(s) ? 1 : 0);
    return header + bodyHeight(n, s, m) + 2 + k2 * row + (row - 3) / 2;
}
juce::Point<float> outlet(const PatchNode& n, const ModuleSpec& s, const Model& m, int i) {
    float y = header + 3 + i * portRow + portRow / 2;
    if (n.collapsed) y = header / 2;
    else if (n.kind == "div") if (auto ry = paramRowY(n, s, m, 3 + i)) y = *ry;
    return { float(n.x) + width(n), float(n.y) + y };
}
std::optional<juce::Point<float>> destination(const PatchNode& n, const ModuleSpec& s, const Model& m, int port) {
    if (port >= kParamPortBase) {
        auto y = paramRowY(n, s, m, port - kParamPortBase);
        if (!y) return std::nullopt;
        return juce::Point<float>(float(n.x), float(n.y) + *y);
    }
    if (port >= int(ins(n, s, m).size())) return std::nullopt;
    return inlet(n, port);
}
}

// ================================================================ Canvas

Canvas::Canvas(Model& m) : model(m) {
    setWantsKeyboardFocus(true);
    startTimerHz(30);
}

void Canvas::resetView() { offset = { 30, 30 }; scale = 1; repaint(); }

juce::Path Canvas::cablePath(juce::Point<float> a, juce::Point<float> b) const {
    float d = std::min(140 * scale, std::max(30 * scale, std::abs(b.x - a.x) * 0.45f + std::abs(b.y - a.y) * 0.15f));
    juce::Path p;
    p.startNewSubPath(a);
    p.cubicTo(a.x + d, a.y, b.x - d, b.y, b.x, b.y);
    return p;
}

void Canvas::drawCable(juce::Graphics& g, juce::Point<float> a, juce::Point<float> b, juce::Colour c, float w, bool dashed) {
    auto p = cablePath(a, b);
    g.setColour(c);
    if (dashed) {
        juce::Path d; const float dash[] = { 4 * scale, 3 * scale };
        juce::PathStrokeType(w).createDashedStroke(d, p, dash, 2);
        g.fillPath(d);
    } else g.strokePath(p, juce::PathStrokeType(w, juce::PathStrokeType::curved, juce::PathStrokeType::rounded));
}

void Canvas::paint(juce::Graphics& g) {
    g.fillAll(Theme::bg());
    // dot grid
    float step = 24 * scale;
    while (step < 8) step *= 4;
    g.setColour(Theme::faint());
    for (float y = std::fmod(offset.y, step); y < getHeight(); y += step)
        for (float x = std::fmod(offset.x, step); x < getWidth(); x += step) g.fillRect(x - 0.75f, y - 0.75f, 1.5f, 1.5f);

    auto& p = model.patch;
    // group backdrops
    for (auto& grp : p.groups) {
        juce::Rectangle<float> r;
        bool first = true;
        for (auto& id : grp.members) {
            int i = p.index(id); if (i < 0) continue;
            auto& n = p.nodes[size_t(i)];
            auto* s = Registry::spec(n.kind); if (!s) continue;
            juce::Rectangle<float> b(float(n.x), float(n.y), Box::width(n), Box::height(n, *s, model));
            r = first ? b : r.getUnion(b); first = false;
        }
        if (first) continue;
        r = r.withTrimmedLeft(-14).withTrimmedTop(-30).withTrimmedRight(-14).withTrimmedBottom(-14);
        auto sr = juce::Rectangle<float>(toScreen(r.getTopLeft()), toScreen(r.getBottomRight()));
        g.setColour(Theme::text().withAlpha(0.05f)); g.fillRoundedRectangle(sr, 6 * scale);
        g.setColour(Theme::dim()); g.setFont(Theme::mono(12 * scale)); g.drawText(grp.name, sr.reduced(10 * scale, 6 * scale), juce::Justification::topLeft);
    }
    // cables
    if (!model.hideCables) {
        for (auto& c : p.cables) {
            int ai = p.index(c.fromNode), bi = p.index(c.toNode);
            if (ai < 0 || bi < 0) continue;
            auto& a = p.nodes[size_t(ai)]; auto& b = p.nodes[size_t(bi)];
            auto* sa = Registry::spec(a.kind); auto* sb = Registry::spec(b.kind);
            if (!sa || !sb || c.fromPort >= int(Box::outs(a, *sa, model).size())) continue;
            auto dest = Box::destination(b, *sb, model, c.toPort);
            if (!dest) continue;
            bool sel = c.id == selectedCable;
            drawCable(g, toScreen(Box::outlet(a, *sa, model, c.fromPort)), toScreen(*dest), sel ? Theme::selected() : Theme::cable(),
                      std::max(1.0f, 1.5f * scale) + (sel ? 1.5f : 0), c.toPort >= kParamPortBase && !sel);
        }
    }
    // boxes
    for (auto& n : p.nodes) if (auto* s = Registry::spec(n.kind)) drawBox(g, n, *s);
    // cable being dragged
    if (drag == Drag::cable) {
        int i = p.index(dragNode);
        if (i >= 0) {
            auto& n = p.nodes[size_t(i)]; auto* s = Registry::spec(n.kind);
            auto anchor = dragFromOutput ? Box::outlet(n, *s, model, dragIndex) : *Box::destination(n, *s, model, dragIndex);
            auto a = toScreen(anchor);
            if (dragFromOutput) drawCable(g, a, pointer, Theme::text(), std::max(1.0f, 1.5f * scale), true);
            else drawCable(g, pointer, a, Theme::text(), std::max(1.0f, 1.5f * scale), true);
        }
    }
    if (drag == Drag::marquee) {
        g.setColour(Theme::text().withAlpha(0.06f)); g.fillRect(marquee);
        g.setColour(Theme::text().withAlpha(0.7f)); g.drawRect(marquee, 1);
    }
}

void Canvas::drawBox(juce::Graphics& g, const PatchNode& n, const ModuleSpec& s) {
    float w = Box::width(n), h = Box::height(n, s, model);
    auto r = juce::Rectangle<float>(toScreen({ float(n.x), float(n.y) }), toScreen({ float(n.x) + w, float(n.y) + h }));
    if (!r.intersects(getLocalBounds().toFloat().expanded(40))) return;
    bool sel = selected.count(n.id) > 0;
    float z = scale;
    if (n.kind == "text") {
        g.setColour(Theme::text()); g.setFont(Theme::mono(12 * z));
        float y = r.getY() + 4 * z;
        for (auto& l : Box::textLines(n)) { g.drawText(l, juce::Rectangle<float>(r.getX() + 7 * z, y, r.getWidth(), 15 * z), juce::Justification::centredLeft); y += 15 * z; }
        if (sel) { g.setColour(Theme::dim()); g.drawRect(r, 1); }
        return;
    }
    auto* node = model.host.node(n.id);
    g.setColour(Theme::box()); g.fillRoundedRectangle(r, 3 * z);
    g.setColour(sel ? Theme::selected() : Theme::border()); g.drawRoundedRectangle(r, 3 * z, 1);
    // header: bypass dot, name, collapse
    float hy = r.getY(), hh = Box::header * z;
    bool bypassable = s.bypass() != BypassMode::none;
    if (bypassable) {
        g.setColour(n.bypassed ? Theme::faint() : Theme::text());
        g.fillEllipse(r.getX() + 8 * z, hy + hh / 2 - 4 * z, 8 * z, 8 * z);
    }
    g.setColour(Theme::text()); g.setFont(Theme::mono(12 * z, true));
    g.drawText(juce::String(s.name), juce::Rectangle<float>(r.getX() + (bypassable ? 22 : 8) * z, hy, r.getWidth() - 40 * z, hh), juce::Justification::centredLeft);
    g.setColour(Theme::dim()); g.setFont(Theme::mono(11 * z));
    g.drawText(n.collapsed ? "v" : "^", juce::Rectangle<float>(r.getRight() - 18 * z, hy, 14 * z, hh), juce::Justification::centred);
    if (!s.factory) {
        g.setColour(Theme::dim()); g.setFont(Theme::mono(9 * z));
        g.drawText("not on Windows yet", juce::Rectangle<float>(r.getX() + 60 * z, hy, r.getWidth() - 80 * z, hh), juce::Justification::centredRight);
    }
    g.setColour(Theme::border()); g.drawHorizontalLine(int(hy + hh), r.getX(), r.getRight());
    if (n.collapsed) return;
    float alpha = n.bypassed ? 0.35f : 1.0f;
    // ports
    auto inNames = Box::ins(n, s, model), outNames = Box::outs(n, s, model);
    g.setFont(Theme::mono(10 * z));
    auto connectedIn = [&](int k) { for (auto& c : model.patch.cables) if (c.toNode == n.id && c.toPort == k) return true; return false; };
    for (size_t k = 0; k < inNames.size(); ++k) {
        auto pt = toScreen(Box::inlet(n, int(k)));
        bool con = connectedIn(int(k));
        g.setColour(con ? Theme::text() : Theme::box()); g.fillEllipse(pt.x - 4.5f * z, pt.y - 4.5f * z, 9 * z, 9 * z);
        g.setColour(Theme::text()); g.drawEllipse(pt.x - 4.5f * z, pt.y - 4.5f * z, 9 * z, 9 * z, 1);
        g.setColour(Theme::dim().withMultipliedAlpha(alpha));
        g.drawText(juce::String(inNames[k]), juce::Rectangle<float>(pt.x + 8 * z, pt.y - 7 * z, w * z / 2, 14 * z), juce::Justification::centredLeft);
    }
    for (size_t k = 0; k < outNames.size(); ++k) {
        auto pt = toScreen(Box::outlet(n, s, model, int(k)));
        g.setColour(Theme::text()); g.fillEllipse(pt.x - 4.5f * z, pt.y - 4.5f * z, 9 * z, 9 * z);
        if (n.kind != "div") {
            g.setColour(Theme::dim().withMultipliedAlpha(alpha));
            g.drawText(juce::String(outNames[k]), juce::Rectangle<float>(pt.x - w * z / 2 - 16 * z, pt.y - 7 * z, w * z / 2, 14 * z), juce::Justification::centredRight);
        }
        // activity dot: gates blink, smooth signals fade
        if (node && k < node->outLevel.size()) {
            float lv = node->outLevel[k] * 4;
            if (lv > 0.1f) {
                g.setColour(Theme::text().withAlpha(std::clamp(0.35f + 0.65f * std::min(lv, 1.0f), 0.0f, 1.0f)));
                float dx = n.kind == "div" ? r.getX() + (8 + 8 + 5 * 5.45f + 14) * z : pt.x - 14 * z - float(outNames[k].size()) * 6 * z;
                g.fillEllipse(dx - 3 * z, pt.y - 3 * z, 6 * z, 6 * z);
            }
        }
    }
    // display area: a simple live readout for now
    float portsH = 0; { int rws = n.kind == "div" ? int(inNames.size()) : int(std::max(inNames.size(), outNames.size())); portsH = rws > 0 ? rws * Box::portRow + 6 : 0; }
    float dispH = Box::readoutHeight(n);
    if (dispH > 0 && node) {
        auto d = juce::Rectangle<float>(r.getX() + 10 * z, r.getY() + (Box::header + portsH) * z, r.getWidth() - 20 * z, dispH * z - 4 * z);
        g.setColour(Theme::row()); g.fillRect(d);
        g.setColour(Theme::text()); g.setFont(Theme::mono(11 * z));
        if (n.kind == "clock") {
            juce::String t = juce::String(node->readouts[3] > 0.5f ? "EXT " : "INT ") + juce::String(node->readouts[0], 1) + " bpm  beat " + juce::String(int(node->readouts[1]) + 1);
            g.drawText(t, d.reduced(6 * z, 0), juce::Justification::centredLeft);
        } else if (n.kind == "lfo") {
            g.setColour(Theme::text());
            float v = std::clamp(node->readouts[0], -1.0f, 1.0f);
            g.fillRect(d.getCentreX() + std::min(0.0f, v) * d.getWidth() / 2, d.getY() + 4 * z, std::abs(v) * d.getWidth() / 2, d.getHeight() - 8 * z);
        } else if (n.kind == "mix" || n.kind == "gain") {
            for (int c = 0; c < 2; ++c) {
                float v = std::clamp(node->readouts[size_t(c)], 0.0f, 1.0f);
                g.fillRect(d.getX(), d.getY() + (c * d.getHeight() / 2), v * d.getWidth(), d.getHeight() / 2 - 1);
            }
        } else if (!s.factory) {
            g.setColour(Theme::dim()); g.drawText("(display coming in a later version)", d, juce::Justification::centred);
        }
    }
    // trigger buttons and parameter rows
    float y0 = r.getY() + (Box::header + Box::bodyHeight(n, s, model) + 2) * z;
    if (Box::hasTriggerRow(s)) {
        float x = r.getX() + 8 * z;
        for (size_t i = 0; i < s.params.size(); ++i) {
            if (!s.params[i].isTrigger()) continue;
            auto b = juce::Rectangle<float>(x, y0, 44 * z, (Box::row - 3) * z);
            g.setColour(Theme::row()); g.fillRect(b);
            g.setColour(Theme::text()); g.setFont(Theme::mono(10 * z, true)); g.drawText(juce::String(s.params[i].name), b, juce::Justification::centred);
            x += 48 * z;
        }
        y0 += Box::row * z;
    }
    auto rows = Box::rowParams(s, n, model.patch);
    for (int idx : rows) {
        auto& ps = s.params[size_t(idx)];
        auto it = n.params.find(ps.key);
        float v = it == n.params.end() ? ps.def : it->second;
        bool automated = n.data.count(DSPNode::autoKey(ps.key)) > 0;
        if (node && (automated || [&] { for (auto& c : model.patch.cables) if (c.toNode == n.id && c.toPort == kParamPortBase + idx) return true; return false; }()))
            v = node->params[size_t(idx)];
        auto rr = juce::Rectangle<float>(r.getX() + 8 * z, y0, r.getWidth() - 16 * z, (Box::row - 3) * z);
        g.setColour(Theme::row()); g.fillRect(rr);
        float fillN = ps.kind == ParamKind::toggle ? (v > 0.5f ? 1.0f : 0.0f) : ps.normalized(v);
        g.setColour(Theme::fill().withMultipliedAlpha(alpha)); g.fillRect(rr.withWidth(rr.getWidth() * fillN));
        g.setColour(Theme::dim().withMultipliedAlpha(alpha)); g.setFont(Theme::mono(11 * z));
        g.drawText(juce::String(ps.name), rr.reduced(6 * z, 0), juce::Justification::centredLeft);
        g.setColour(Theme::text().withMultipliedAlpha(alpha));
        g.drawText(juce::String(ps.display(v)) + (ps.kind == ParamKind::choice ? juce::String(" v") : juce::String()),
                   rr.reduced(6 * z, 0), juce::Justification::centredRight);
        // parameter inlet
        auto pi = juce::Point<float>(r.getX(), rr.getCentreY());
        bool con = false; for (auto& c : model.patch.cables) if (c.toNode == n.id && c.toPort == kParamPortBase + idx) con = true;
        g.setColour(con ? Theme::text() : Theme::box()); g.fillEllipse(pi.x - 3.5f * z, pi.y - 3.5f * z, 7 * z, 7 * z);
        g.setColour(con ? Theme::text() : Theme::faint()); g.drawEllipse(pi.x - 3.5f * z, pi.y - 3.5f * z, 7 * z, 7 * z, 1);
        y0 += Box::row * z;
    }
}

Canvas::Hit Canvas::hitTest(juce::Point<float> sp) {
    auto c = toCanvas(sp);
    auto& p = model.patch;
    float tol = 9 / scale;
    // topmost first
    for (auto it = p.nodes.rbegin(); it != p.nodes.rend(); ++it) {
        auto& n = *it; auto* s = Registry::spec(n.kind); if (!s) continue;
        float w = Box::width(n), h = Box::height(n, *s, model);
        // ports stick out over the edges
        if (n.kind != "text" && !n.collapsed) {
            auto outsN = Box::outs(n, *s, model);
            for (int k = 0; k < int(outsN.size()); ++k) if (c.getDistanceFrom(Box::outlet(n, *s, model, k)) < tol) return { Hit::outlet, n.id, {}, k };
            auto insN = Box::ins(n, *s, model);
            for (int k = 0; k < int(insN.size()); ++k) if (c.getDistanceFrom(Box::inlet(n, k)) < tol) return { Hit::inlet, n.id, {}, k };
            for (int i : Box::rowParams(*s, n, p))
                if (auto y = Box::paramRowY(n, *s, model, i); y && c.getDistanceFrom({ float(n.x), float(n.y) + *y }) < tol * 0.8f)
                    return { Hit::paramInlet, n.id, {}, i };
        }
        juce::Rectangle<float> b(float(n.x), float(n.y), w, h);
        if (!b.contains(c)) continue;
        float ly = c.y - float(n.y), lx = c.x - float(n.x);
        if (n.kind == "text") return { Hit::header, n.id };
        if (ly < Box::header) {
            if (s->bypass() != BypassMode::none && lx < 20) return { Hit::bypass, n.id };
            if (lx > w - 20) return { Hit::collapse, n.id };
            return { Hit::header, n.id };
        }
        if (n.collapsed) return { Hit::header, n.id };
        float y0 = Box::header + Box::bodyHeight(n, *s, model) + 2;
        if (Box::hasTriggerRow(*s)) {
            if (ly >= y0 && ly < y0 + Box::row) {
                float x = 8; int ti = 0;
                for (size_t i = 0; i < s->params.size(); ++i) {
                    if (!s->params[i].isTrigger()) continue;
                    if (lx >= x && lx < x + 44) return { Hit::trigger, n.id, {}, int(i) };
                    x += 48; ++ti;
                }
                return { Hit::body, n.id };
            }
            y0 += Box::row;
        }
        auto rows = Box::rowParams(*s, n, p);
        int k = int(std::floor((ly - y0) / Box::row));
        if (ly >= y0 && k >= 0 && k < int(rows.size())) return { Hit::row, n.id, {}, rows[size_t(k)] };
        return { Hit::body, n.id };
    }
    // cables
    if (!model.hideCables) {
        for (auto& cb : p.cables) {
            int ai = p.index(cb.fromNode), bi = p.index(cb.toNode);
            if (ai < 0 || bi < 0) continue;
            auto& a = p.nodes[size_t(ai)]; auto& b = p.nodes[size_t(bi)];
            auto* sa = Registry::spec(a.kind); auto* sb = Registry::spec(b.kind);
            if (!sa || !sb) continue;
            auto dest = Box::destination(b, *sb, model, cb.toPort); if (!dest) continue;
            auto path = cablePath(toScreen(Box::outlet(a, *sa, model, cb.fromPort)), toScreen(*dest));
            juce::Point<float> nearest;
            path.getNearestPoint(sp, nearest);
            if (nearest.getDistanceFrom(sp) < 6) return { Hit::cableHit, {}, cb.id };
        }
    }
    return {};
}

void Canvas::zoom(float factor, juce::Point<float> anchor) {
    float old = scale, nw = std::clamp(scale * factor, 0.12f, 2.0f);
    auto c = (anchor - offset) / old;
    scale = nw; offset = anchor - c * nw;
    repaint();
}

void Canvas::mouseWheelMove(const juce::MouseEvent& e, const juce::MouseWheelDetails& w) {
    float dy = w.deltaY != 0 ? w.deltaY : w.deltaX;
    if (w.isReversed) dy = -dy;
    zoom(w.isSmooth ? std::exp(std::clamp(dy, -1.0f, 1.0f) * 0.6f) : (dy > 0 ? 1.1f : (dy < 0 ? 1 / 1.1f : 1.0f)), e.position);
}
void Canvas::mouseMagnify(const juce::MouseEvent& e, float s) { zoom(s, e.position); }
void Canvas::mouseMove(const juce::MouseEvent& e) { pointer = e.position; }

void Canvas::mouseDown(const juce::MouseEvent& e) {
    grabKeyboardFocus();
    pointer = e.position; dragStart = e.position;
    auto h = hitTest(e.position);
    auto& p = model.patch;
    if (e.mods.isPopupMenu() && h.kind != Hit::none && h.node.isNotEmpty()) {
        juce::PopupMenu m;
        m.addItem(1, "Delete");
        int ni = p.index(h.node);
        m.addItem(2, ni >= 0 && p.nodes[size_t(ni)].bypassed ? "Switch on" : "Bypass");
        m.showMenuAsync({}, [this, id = h.node](int r) {
            if (r == 1) { model.removeNodes({ id }); selected.erase(id); }
            if (r == 2) { int i = model.patch.index(id); if (i >= 0) { model.beginGesture(); model.patch.nodes[size_t(i)].bypassed = !model.patch.nodes[size_t(i)].bypassed; model.changed(true); } }
        });
        return;
    }
    switch (h.kind) {
        case Hit::outlet: drag = Drag::cable; dragNode = h.node; dragIndex = h.index; dragFromOutput = true; break;
        case Hit::inlet: case Hit::paramInlet: {
            int port = h.kind == Hit::inlet ? h.index : kParamPortBase + h.index;
            // a plugged inlet: pick its cable up
            for (auto it = p.cables.rbegin(); it != p.cables.rend(); ++it)
                if (it->toNode == h.node && it->toPort == port) {
                    model.beginGesture();
                    dragNode = it->fromNode; dragIndex = it->fromPort; dragFromOutput = true;
                    p.cables.erase(std::next(it).base());
                    model.host.load(p);
                    drag = Drag::cable;
                    return;
                }
            drag = Drag::cable; dragNode = h.node; dragIndex = port; dragFromOutput = false;
            break;
        }
        case Hit::bypass: {
            int i = p.index(h.node); model.beginGesture();
            p.nodes[size_t(i)].bypassed = !p.nodes[size_t(i)].bypassed;
            model.changed(true);
            break;
        }
        case Hit::collapse: {
            int i = p.index(h.node); model.beginGesture();
            p.nodes[size_t(i)].collapsed = !p.nodes[size_t(i)].collapsed;
            model.changed(false);
            break;
        }
        case Hit::trigger: model.setParam(h.node, h.index, 1, false); break;
        case Hit::row: {
            int i = p.index(h.node);
            auto* s = Registry::spec(p.nodes[size_t(i)].kind);
            auto& ps = s->params[size_t(h.index)];
            auto it = p.nodes[size_t(i)].params.find(ps.key);
            float v = it == p.nodes[size_t(i)].params.end() ? ps.def : it->second;
            if (ps.kind == ParamKind::toggle) { model.setParam(h.node, h.index, v > 0.5f ? 0 : 1, true); break; }
            if (ps.kind == ParamKind::choice && e.position.x > toScreen({ float(p.nodes[size_t(i)].x) + Box::width(p.nodes[size_t(i)]) - 24, 0 }).x) {
                juce::PopupMenu m;
                for (size_t k = 0; k < ps.options.size(); ++k) m.addItem(int(k) + 1, ps.options[k], true, int(std::round(v)) == int(k));
                m.showMenuAsync({}, [this, id = h.node, idx = h.index](int r) { if (r > 0) model.setParam(id, idx, float(r - 1), true); });
                break;
            }
            drag = Drag::row; dragNode = h.node; dragIndex = h.index; rowStart = ps.normalized(v);
            model.beginGesture();
            break;
        }
        case Hit::header: case Hit::body: {
            if (e.mods.isShiftDown()) { if (selected.count(h.node)) selected.erase(h.node); else selected.insert(h.node); }
            else if (!selected.count(h.node)) { selected = { h.node }; }
            selectedCable = {};
            drag = Drag::move; moveStart.clear();
            for (auto& id : selected) { int i = p.index(id); if (i >= 0) moveStart[id] = { p.nodes[size_t(i)].x, p.nodes[size_t(i)].y }; }
            model.beginGesture();
            break;
        }
        case Hit::cableHit: selectedCable = h.cable; selected.clear(); break;
        case Hit::none:
            selectedCable = {};
            if (e.mods.isShiftDown()) { drag = Drag::marquee; marquee = {}; }
            else { selected.clear(); drag = Drag::pan; panStart = offset; }
            break;
    }
    repaint();
}

void Canvas::mouseDrag(const juce::MouseEvent& e) {
    pointer = e.position;
    auto d = e.position - dragStart;
    auto& p = model.patch;
    switch (drag) {
        case Drag::pan: offset = panStart + d; break;
        case Drag::move:
            for (auto& [id, st] : moveStart) { int i = p.index(id); if (i >= 0) { p.nodes[size_t(i)].x = st.x + d.x / scale; p.nodes[size_t(i)].y = st.y + d.y / scale; } }
            break;
        case Drag::row: {
            int i = p.index(dragNode); if (i < 0) break;
            auto& n = p.nodes[size_t(i)];
            auto* s = Registry::spec(n.kind);
            float wpx = (Box::width(n) - 16) * scale;
            float v = s->params[size_t(dragIndex)].valueFromNormalized(rowStart + d.x / std::max(wpx, 1.0f));
            model.setParam(dragNode, dragIndex, v, false);
            break;
        }
        case Drag::marquee: marquee = juce::Rectangle<float>(dragStart, e.position); break;
        default: break;
    }
    repaint();
}

void Canvas::mouseUp(const juce::MouseEvent& e) {
    auto& p = model.patch;
    if (drag == Drag::cable) {
        auto h = hitTest(e.position);
        if (dragFromOutput && (h.kind == Hit::inlet || h.kind == Hit::paramInlet || h.kind == Hit::row) && h.node != dragNode)
            model.connect(dragNode, dragIndex, h.node, h.kind == Hit::inlet ? h.index : kParamPortBase + h.index);
        else if (!dragFromOutput && h.kind == Hit::outlet && h.node != dragNode)
            model.connect(h.node, h.index, dragNode, dragIndex);
        else model.changed(true);
    } else if (drag == Drag::move || drag == Drag::row) {
        model.changed(false);
    } else if (drag == Drag::marquee) {
        auto a = toCanvas(marquee.getTopLeft()), b = toCanvas(marquee.getBottomRight());
        juce::Rectangle<float> r(a, b);
        for (auto& n : p.nodes) if (auto* s = Registry::spec(n.kind))
            if (r.intersects(juce::Rectangle<float>(float(n.x), float(n.y), Box::width(n), Box::height(n, *s, model)))) selected.insert(n.id);
    }
    drag = Drag::none;
    repaint();
}

void Canvas::mouseDoubleClick(const juce::MouseEvent& e) {
    auto h = hitTest(e.position);
    auto& p = model.patch;
    if (h.kind == Hit::none) { showAddMenu(toCanvas(e.position)); return; }
    if (h.kind == Hit::cableHit) { model.removeCable(h.cable); return; }
    int i = p.index(h.node);
    if (i < 0) return;
    if (h.kind == Hit::row) {
        auto* s = Registry::spec(p.nodes[size_t(i)].kind);
        model.setParam(h.node, h.index, s->params[size_t(h.index)].def, true);
        return;
    }
    if (p.nodes[size_t(i)].kind == "text") {
        auto* w = new juce::AlertWindow("text", {}, juce::MessageBoxIconType::NoIcon);
        w->addTextEditor("t", p.nodes[size_t(i)].text.value_or(""), {});
        w->getTextEditor("t")->setMultiLine(true, true);
        w->getTextEditor("t")->setReturnKeyStartsNewLine(true);
        w->getTextEditor("t")->setSize(360, 160);
        w->addButton("OK", 1); w->addButton("Cancel", 0);
        w->enterModalState(true, juce::ModalCallbackFunction::create([this, w, id = h.node](int r) {
            if (r == 1) { int k = model.patch.index(id); if (k >= 0) { model.beginGesture(); model.patch.nodes[size_t(k)].text = w->getTextEditorContents("t"); model.changed(false); } }
        }), true);
    }
}

void Canvas::showAddMenu(juce::Point<float> at) {
    juce::PopupMenu m;
    int id = 1;
    std::vector<std::string> kinds;
    for (auto& cat : Registry::categories) {
        juce::PopupMenu sub;
        for (auto& s : Registry::all()) {
            if (s.category != cat) continue;
            sub.addItem(id++, juce::String(s.name) + "   " + juce::String(s.summary) + (s.factory ? "" : "  (not on Windows yet)"));
            kinds.push_back(s.kind);
        }
        m.addSubMenu(cat, sub);
    }
    m.showMenuAsync({}, [this, kinds, at](int r) {
        if (r <= 0) return;
        auto nid = model.addNode(kinds[size_t(r - 1)], at.x, at.y);
        selected = { nid };
    });
}

bool Canvas::keyPressed(const juce::KeyPress& k) {
    auto cmd = juce::ModifierKeys::commandModifier;
    if (k == juce::KeyPress::deleteKey || k == juce::KeyPress::backspaceKey) {
        if (selectedCable.isNotEmpty()) { model.removeCable(selectedCable); selectedCable = {}; }
        else { model.removeNodes(selected); selected.clear(); }
        return true;
    }
    if (k == juce::KeyPress('z', cmd, 0)) { model.undo(); return true; }
    if (k == juce::KeyPress('z', cmd | juce::ModifierKeys::shiftModifier, 0) || k == juce::KeyPress('y', cmd, 0)) { model.redo(); return true; }
    if (k == juce::KeyPress(juce::KeyPress::spaceKey)) { model.host.transport(model.host.isPlaying() ? 1 : 0); return true; }
    return false;
}

// ================================================================ TopBar

TopBar::TopBar(Model& m, Canvas& c) : model(m), canvas(c) { startTimerHz(4); }

std::vector<TopBar::Item> TopBar::layout() {
    std::vector<Item> v;
    auto add = [&](juce::String l, std::function<void()> a, bool on = false) { v.push_back({ l, {}, a, on }); };
    add("polje nieuk", nullptr);
    add("audio", [this] {
        auto* sel = new juce::AudioDeviceSelectorComponent(model.devices, 0, 32, 0, 32, false, false, false, false);
        sel->setSize(520, 420);
        juce::DialogWindow::LaunchOptions o;
        o.content.setOwned(sel); o.dialogTitle = "audio"; o.useNativeTitleBar = true; o.resizable = false;
        o.dialogBackgroundColour = Theme::box();
        o.launchAsync();
    });
    if (auto* d = model.devices.getCurrentAudioDevice())
        add(d->getName() + juce::String::formatted(" %dk %d", int(d->getCurrentSampleRate() / 1000), d->getCurrentBufferSizeSamples()), nullptr);
    add("|>", [this] { model.host.transport(0); }, model.host.isPlaying());
    add("||", [this] { model.host.transport(1); });
    add("[]", [this] { model.host.transport(2); });
    add(juce::String(model.host.clockBPM(), 1) + " bpm" + (model.host.externalClock() ? " EXT" : ""), nullptr);
    add(juce::String::formatted("cpu %3.0f%%", model.cpu() * 100), nullptr);
    add("undo", [this] { model.undo(); });
    add("redo", [this] { model.redo(); });
    add("+", [this] { canvas.showAddMenu(canvas.getLocalBounds().getCentre().toFloat() / canvas.scale - canvas.offset / canvas.scale); });
    add("delete", [this] {
        if (canvas.selectedCable.isNotEmpty()) model.removeCable(canvas.selectedCable);
        else model.removeNodes(canvas.selected);
        canvas.selected.clear(); canvas.selectedCable = {};
    });
    add("view", [this] {
        juce::PopupMenu m;
        m.addItem(1, "Hide cables", true, model.hideCables);
        m.addItem(2, "Light scheme", true, model.lightScheme);
        m.addSeparator();
        m.addItem(3, "Reset view");
        m.showMenuAsync({}, [this](int r) {
            if (r == 1) model.hideCables = !model.hideCables;
            if (r == 2) { model.lightScheme = !model.lightScheme; Theme::setLight(model.lightScheme); }
            if (r == 3) canvas.resetView();
            model.changed(false, false);
            getParentComponent()->repaint();
        });
    });
    add("file", [this] {
        juce::PopupMenu m;
        m.addItem(1, "New"); m.addItem(2, "Open..."); m.addItem(3, "Save As...");
        m.showMenuAsync({}, [this](int r) {
            if (r == 1) model.newPatch();
            if (r == 2) {
                auto ch = std::make_shared<juce::FileChooser>("Open patch", model.dataFolder(), "*.json");
                ch->launchAsync(juce::FileBrowserComponent::openMode | juce::FileBrowserComponent::canSelectFiles,
                                [this, ch](const juce::FileChooser& c) { if (c.getResult().existsAsFile()) model.open(c.getResult()); });
            }
            if (r == 3) {
                auto ch = std::make_shared<juce::FileChooser>("Save patch", model.dataFolder().getChildFile("patch.json"), "*.json");
                ch->launchAsync(juce::FileBrowserComponent::saveMode | juce::FileBrowserComponent::warnAboutOverwriting,
                                [this, ch](const juce::FileChooser& c) { if (c.getResult() != juce::File()) model.saveAs(c.getResult().withFileExtension("json")); });
            }
        });
    });
    // positions: left group, then right group
    juce::Font f = Theme::mono(12);
    int x = 12;
    for (size_t i = 0; i < v.size(); ++i) {
        int w = juce::GlyphArrangement::getStringWidthInt(f, v[i].label) + 14;
        if (v[i].label == "|>") x = std::max(x + 20, getWidth() / 2 - 160);
        if (v[i].label == "undo") x = std::max(x + 20, getWidth() - 380);
        v[i].area = { x, 0, w, getHeight() };
        x += w + 4;
    }
    return v;
}

void TopBar::paint(juce::Graphics& g) {
    g.fillAll(Theme::bar());
    g.setColour(Theme::border()); g.drawHorizontalLine(getHeight() - 1, 0, float(getWidth()));
    items = layout();
    g.setFont(Theme::mono(12));
    for (size_t i = 0; i < items.size(); ++i) {
        auto& it = items[i];
        g.setColour(i == 0 ? Theme::text() : (it.action ? (it.on ? Theme::text() : Theme::dim()) : Theme::dim()));
        if (i == 0) g.setFont(Theme::mono(12, true)); else g.setFont(Theme::mono(12));
        g.drawText(it.label, it.area, juce::Justification::centred);
    }
}

void TopBar::mouseDown(const juce::MouseEvent& e) {
    for (auto& it : items) if (it.action && it.area.contains(e.getPosition())) { it.action(); repaint(); return; }
}

// ================================================================ MainComponent

MainComponent::MainComponent() {
    addAndMakeVisible(canvas);
    addAndMakeVisible(bar);
    model.onChange = [this] { canvas.repaint(); bar.repaint(); };
    setSize(1280, 820);
}
void MainComponent::paint(juce::Graphics& g) { g.fillAll(Theme::bg()); }
void MainComponent::resized() {
    auto r = getLocalBounds();
    bar.setBounds(r.removeFromTop(34));
    canvas.setBounds(r);
}

} // namespace pn
