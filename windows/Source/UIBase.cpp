#include "UIBase.h"
#include <unordered_map>

namespace pn {

juce::PropertiesFile& settings() {
    static juce::PropertiesFile* f = [] {
        juce::PropertiesFile::Options o;
        o.applicationName = "polje nieuk";
        o.filenameSuffix = ".settings";
        o.folderName = "polje nieuk";
        o.osxLibrarySubFolder = "Application Support";
        return new juce::PropertiesFile(o);
    }();
    return *f;
}

// ---------------------------------------------------------------- custom colours

namespace CustomColours {
int version = 0;
static const char* names[] = { "background", "windows", "cables" };
const char* title(Slot s) { return s == background ? "background" : s == windows ? "windows" : "patch cords"; }
static juce::String key(Slot s) { return juce::String("colour.") + (Theme::light ? "light." : "dark.") + names[s]; }
std::optional<juce::Colour> colour(Slot s) {
    auto v = settings().getValue(key(s));
    if (v.isEmpty()) return std::nullopt;
    auto parts = juce::StringArray::fromTokens(v, ",", "");
    if (parts.size() != 4) return std::nullopt;
    return juce::Colour::fromFloatRGBA(parts[0].getFloatValue(), parts[1].getFloatValue(), parts[2].getFloatValue(), 1.0f);
}
void set(Slot s, std::optional<juce::Colour> c) {
    ++version;
    if (!c) { settings().removeValue(key(s)); return; }
    settings().setValue(key(s), juce::String(c->getFloatRed()) + "," + juce::String(c->getFloatGreen()) + "," + juce::String(c->getFloatBlue()) + ",1");
}
void resetAll() { for (auto s : { background, windows, cables }) set(s, std::nullopt); }
void schemeChanged() { ++version; }
bool anyCustom() { return colour(background) || colour(windows) || colour(cables); }
static double lum(juce::Colour c) { return 0.2126 * c.getFloatRed() + 0.7152 * c.getFloatGreen() + 0.0722 * c.getFloatBlue(); }
std::optional<WindowPalette> windowPalette() {
    auto c = colour(windows);
    if (!c) return std::nullopt;
    bool isLight = lum(*c) > 0.5;
    float toward = isLight ? 0.0f : 1.0f;
    auto step = [&](float a) {
        return juce::Colour::fromFloatRGBA(c->getFloatRed() + (toward - c->getFloatRed()) * a, c->getFloatGreen() + (toward - c->getFloatGreen()) * a,
                                           c->getFloatBlue() + (toward - c->getFloatBlue()) * a, 1.0f);
    };
    return WindowPalette { isLight, step(0), step(0.07f), step(0.22f), step(0.24f), step(0.34f), step(0.9f), step(0.5f) };
}
std::optional<juce::Colour> defaultCable() {
    auto c = colour(background);
    if (!c) return std::nullopt;
    return lum(*c) > 0.5 ? Theme::white(0.35f) : Theme::white(0.62f);
}
std::optional<juce::Colour> gridDot() {
    auto c = colour(background);
    if (!c) return std::nullopt;
    return lum(*c) > 0.5 ? juce::Colours::black.withAlpha(0.12f) : juce::Colours::white.withAlpha(0.09f);
}
}

// ---------------------------------------------------------------- theme

namespace Theme {
bool light = false;
using namespace CustomColours;
juce::Colour defaultBg() { return light ? white(0.94f) : juce::Colours::black; }
juce::Colour bg() { return colour(background).value_or(defaultBg()); }
juce::Colour gridDot() { if (auto d = CustomColours::gridDot()) return *d; return light ? juce::Colours::black.withAlpha(0.10f) : juce::Colours::white.withAlpha(0.07f); }
bool boxIsLight() { if (auto w = windowPalette()) return w->isLight; return light; }
juce::Colour defaultBox() { return light ? white(0.995f) : white(0.055f); }
juce::Colour box() { if (auto w = windowPalette()) return w->box; return defaultBox(); }
juce::Colour border() { if (auto w = windowPalette()) return w->border; return light ? white(0.72f) : white(0.24f); }
juce::Colour selected() { if (auto w = windowPalette()) return w->text; return light ? juce::Colours::black : juce::Colours::white; }
juce::Colour text() { if (auto w = windowPalette()) return w->text; return light ? white(0.08f) : white(0.92f); }
juce::Colour dim() { if (auto w = windowPalette()) return w->dim; return light ? white(0.45f) : white(0.5f); }
juce::Colour faint() { if (auto w = windowPalette()) return w->faint; return light ? white(0.72f) : white(0.3f); }
juce::Colour row() { if (auto w = windowPalette()) return w->row; return light ? white(0.91f) : white(0.1f); }
juce::Colour fill() { if (auto w = windowPalette()) return w->fill; return light ? white(0.78f) : white(0.24f); }
juce::Colour defaultCable() { if (auto d = CustomColours::defaultCable()) return *d; return light ? white(0.4f) : white(0.55f); }
juce::Colour cable() { return colour(cables).value_or(defaultCable()); }
juce::Colour bar() { if (auto w = windowPalette()) return w->box; return light ? white(0.97f) : juce::Colours::black; }
juce::Colour inverse() { if (auto w = windowPalette()) return w->box; return light ? juce::Colours::white : juce::Colours::black; }
juce::Colour shade() { return boxIsLight() ? juce::Colours::black.withAlpha(0.06f) : juce::Colours::black.withAlpha(0.35f); }
juce::Colour keyWhite() { return boxIsLight() ? juce::Colours::white : white(0.92f, 0.85f); }
juce::Colour keyBlack() { return boxIsLight() ? white(0.15f) : juce::Colours::black; }
juce::Colour keyWhiteLit() { return boxIsLight() ? white(0.62f) : white(0.5f); }
juce::Colour keyBlackLit() { return boxIsLight() ? white(0.5f) : white(0.92f, 0.75f); }

static juce::String family() {
   #if JUCE_WINDOWS
    return "Consolas";
   #else
    return "Menlo";
   #endif
}
juce::Font mono(float size, bool bold) {
    // Menlo / Consolas run a touch larger than SF Mono at the same point size: match its width (0.6 em)
   #if JUCE_WINDOWS
    const float k = 1.09f;    // Consolas is 0.55 em wide
   #else
    const float k = 1.0f;     // Menlo is 0.6 em, like SF Mono
   #endif
    // looked up once per size: finding a font by name on every line of text was a large part of drawing
    static std::map<int, juce::Font> cache;
    int key = int(std::round(size * 100)) * 2 + (bold ? 1 : 0);
    auto it = cache.find(key);
    if (it != cache.end()) return it->second;
    if (cache.size() > 400) cache.clear();
    return cache.emplace(key, juce::Font(juce::FontOptions(family(), size * k, bold ? juce::Font::bold : juce::Font::plain))).first->second;
}
}

// Shaping a line of text (finding fonts, laying out glyphs) costs far more than drawing it, and the same few
// hundred labels and numbers are drawn over and over: each is shaped once and kept.
struct ShapedLine { juce::GlyphArrangement glyphs; float width, ascent, height; };
struct CharGlyph { std::optional<juce::PositionedGlyph> glyph; float advance; };
static const CharGlyph& charGlyph(juce::juce_wchar ch, float size, bool bold) {
    static std::unordered_map<uint64_t, CharGlyph> cache;
    uint64_t key = (uint64_t(ch) << 32) | (uint64_t(int(std::round(size * 100))) << 1) | (bold ? 1u : 0u);
    auto it = cache.find(key);
    if (it != cache.end()) return it->second;
    auto f = Theme::mono(size, bold);
    auto str = juce::String::charToString(ch);
    juce::GlyphArrangement ga;
    ga.addLineOfText(f, str, 0, 0);
    CharGlyph c { std::nullopt, juce::GlyphArrangement::getStringWidth(f, str) };
    if (ga.getNumGlyphs() == 1) c.glyph = ga.getGlyph(0);
    return cache.emplace(key, std::move(c)).first->second;
}

static const ShapedLine& shaped(const juce::String& s, float size, bool bold) {
    static std::unordered_map<std::string, ShapedLine> cache;
    std::string key = std::to_string(int(std::round(size * 100)) * 2 + (bold ? 1 : 0)) + "|" + s.toStdString();
    auto it = cache.find(key);
    if (it != cache.end()) return it->second;
    if (cache.size() > 6000) cache.clear();
    auto f = Theme::mono(size, bold);
    ShapedLine l;
    // monospaced: a line is its characters side by side, each shaped once (no shaping per new number)
    float x = 0;
    for (auto p = s.getCharPointer(); !p.isEmpty();) {
        auto ch = p.getAndAdvance();
        auto& cg = charGlyph(ch, size, bold);
        if (cg.glyph) { auto g = *cg.glyph; g.moveBy(x, 0); l.glyphs.addGlyph(g); }
        x += cg.advance;
    }
    l.width = x;
    l.ascent = f.getAscent(); l.height = f.getAscent() + f.getDescent();
    return cache.emplace(key, std::move(l)).first->second;
}

float textWidth(const juce::String& s, float size, bool bold) {
    if (s.isEmpty()) return 0;
    return shaped(s, size, bold).width;
}

juce::String fitText(const juce::String& s, float size, float width, bool bold) {
    if (textWidth(s, size, bold) <= width) return s;
    juce::String t = s;
    while (t.length() > 1 && textWidth(t + juce::String::fromUTF8("\xe2\x80\xa6"), size, bold) > width) t = t.dropLastCharacters(1);
    return t + juce::String::fromUTF8("\xe2\x80\xa6");
}

// ---------------------------------------------------------------- GC

void GC::stroke(const juce::Path& p, juce::Colour c, float width, bool round, std::vector<float> dash) {
    g.setColour(c);
    juce::PathStrokeType st(width, juce::PathStrokeType::curved, round ? juce::PathStrokeType::rounded : juce::PathStrokeType::butt);
    if (dash.empty()) { g.strokePath(p, st); return; }
    juce::Path d;
    st.createDashedStroke(d, p, dash.data(), int(dash.size()));
    g.fillPath(d);
}

void GC::text(const juce::String& s, Pt at, float size, juce::Colour c, bool bold, float ax, float ay) {
    if (s.isEmpty()) return;
    auto& l = shaped(s, size, bold);
    float x = at.x - ax * l.width, top = at.y - ay * l.height;
    g.setColour(c);
    l.glyphs.draw(g, juce::AffineTransform::translation(x, top + l.ascent));
}

void GC::fillGradient(Rect r, const std::vector<std::pair<juce::Colour, float>>& stops, float upTo) {
    Rect shown = r.withWidth(r.getWidth() * std::clamp(upTo, 0.0f, 1.0f));
    if (shown.getWidth() <= 0 || stops.empty()) return;
    juce::ColourGradient grad(stops.front().first, r.getX(), r.getCentreY(), stops.back().first, r.getRight(), r.getCentreY(), false);
    for (size_t i = 1; i + 1 < stops.size(); ++i) grad.addColour(stops[i].second, stops[i].first);
    g.setGradientFill(grad);
    g.fillRect(shown);
}

// ---------------------------------------------------------------- layouts

namespace ControlsLayout { const std::vector<std::string> ranges = { "0…10 V", "±10 V", "0…5 V", "±5 V", "0…1 V" }; }

namespace BoxLayout {
std::map<juce::String, PortUsage> usage;
static const PortUsage& use(const juce::String& id) { static PortUsage none; auto it = usage.find(id); return it == usage.end() ? none : it->second; }

void rebuildUsage(const Patch& p) {
    usage.clear();
    for (auto& c : p.cables) { usage[c.toNode].ins.insert(c.toPort); usage[c.fromNode].outs.insert(c.fromPort); }
}

float param(const PatchNode& n, const char* key, float def) { auto it = n.params.find(key); return it == n.params.end() ? def : it->second; }

std::vector<int> collapsedLeft(const PatchNode& n, const ModuleSpec& s) {
    auto& used = use(n.id).ins;
    std::vector<int> r;
    for (int i = 0; i < int(s.inputs.size()); ++i) if (used.count(i)) r.push_back(i);
    for (int i : rowParams(s, n)) if (used.count(kParamPortBase + i)) r.push_back(kParamPortBase + i);
    for (int i = 0; i < int(s.params.size()); ++i) if (s.params[size_t(i)].isTrigger() && used.count(kParamPortBase + i)) r.push_back(kParamPortBase + i);
    return r;
}
std::vector<int> collapsedRight(const PatchNode& n, const ModuleSpec& s) {
    auto& used = use(n.id).outs;
    std::vector<int> r;
    for (int i = 0; i < int(s.outputs.size()); ++i) if (used.count(i)) r.push_back(i);
    return r;
}
int collapsedRows(const PatchNode& n, const ModuleSpec& s) { return int(std::max(collapsedLeft(n, s).size(), collapsedRight(n, s).size())); }
static float collapsedY(int k) { return header + 3 + float(k) * portRow + portRow / 2; }

juce::String inletName(const ModuleSpec& s, int port) {
    if (port >= kParamPortBase) { int i = port - kParamPortBase; return i < int(s.params.size()) ? juce::String(s.params[size_t(i)].name) : "?"; }
    return port < int(s.inputs.size()) ? juce::String(s.inputs[size_t(port)]) : "?";
}

float width(const std::string& k) {
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
    if (k == "knob") return 240;
    if (k == "comp") return 240;
    if (k == "scope") return 320;
    if (k == "wave") return 300;
    if (k == "chord") return 220;
    return 186;
}
float defaultWidth(const PatchNode& n) {
    if (n.kind == "slider") return std::max(width(n.kind), float(ControlsLayout::count(param(n, "count", 2))) * 44 + 20 + sideOutletColumn);
    if (n.kind == "knob") return std::max(width(n.kind), float(std::min(ControlsLayout::count(param(n, "count", 2)), 4)) * 56 + 20 + sideOutletColumn);
    return width(n.kind);
}
float defaultReadoutHeight(const PatchNode& n) {
    if (n.kind == "knob" && ControlsLayout::count(param(n, "count", 2)) > 4) return readoutHeight(n.kind) * 2 - 10;
    return readoutHeight(n.kind);
}
Pt textSize(const PatchNode& n) {
    auto lines = juce::StringArray::fromLines(n.text.value_or("text"));
    int longest = 4;
    for (auto& l : lines) longest = std::max(longest, l.length());
    return { float(longest) * 7.3f + 14, float(std::max(lines.size(), 1)) * 15 + 8 };
}
float width(const PatchNode& n) {
    if (n.kind == "text") return textSize(n).x;
    float d = defaultWidth(n);
    if (!n.w || !std::isfinite(*n.w)) return d;
    return std::clamp(float(*n.w), d, 1600.0f);
}
float padLaneHeight(const PatchNode& n) {
    bool rack = n.kind == "rack";
    float base = rack ? 9.0f : 14.0f, lanes = rack ? 16.0f : 4.0f;
    return base + std::max(readoutHeight(n) - defaultReadoutHeight(n), 0.0f) / lanes;
}
float readoutHeight(const PatchNode& n) {
    float d = defaultReadoutHeight(n);
    if (d <= 0 || !n.dh || !std::isfinite(*n.dh)) return d;
    return std::clamp(float(*n.dh), d, 1200.0f);
}
std::pair<bool, bool> resizable(const std::string& k) { return { k != "in" && k != "out", readoutHeight(k) > 0 }; }
bool hasReadout(const std::string& k) {
    static const std::set<std::string> s { "clock", "looper", "grain", "rec", "comp", "limit", "repeat", "gain", "mix", "sampler", "stretch", "peq",
        "keys", "seq", "turing", "roll", "drums", "slider", "knob", "lfo", "rack", "drumsynth", "scope", "wave", "chord" };
    return s.count(k) > 0;
}
float readoutHeight(const std::string& k) {
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
    if (k == "rack") return 16 * 9 + 8 + 4 * 42 + 3 * 4 + 8;
    if (k == "drumsynth") return 4 * 14 + 8 + 42 + 8;
    if (k == "comp") return 92;
    if (k == "lfo") return 56;
    if (k == "clock") return 40;
    if (k == "scope") return 160;
    if (k == "wave") return 170;
    if (k == "chord") return 58;
    return hasReadout(k) ? readout : 0;
}

static std::vector<juce::String> strs(const std::vector<std::string>& v, size_t n) {
    std::vector<juce::String> r;
    for (size_t i = 0; i < std::min(n, v.size()); ++i) r.push_back(juce::String::fromUTF8(v[i].c_str()));
    return r;
}

Ports ports(const PatchNode& n, const ModuleSpec& s, const HardwareCounts& hw) {
    if (n.kind == "in") {
        auto& o = use(n.id).outs;
        int used = o.empty() ? 0 : *o.rbegin() + 1;
        return { {}, strs(s.outputs, size_t(std::max({ hw.inputs, used, 1 }))) };
    }
    if (n.kind == "out") {
        int used = 0;
        for (int p : use(n.id).ins) if (p < kParamPortBase) used = std::max(used, p + 1);
        return { strs(s.inputs, size_t(std::max({ hw.outputs, used, 1 }))), {} };
    }
    if (n.kind == "mix") return { strs(s.inputs, size_t(MixerLayout::channels(param(n, "chans", 1)))), strs(s.outputs, 99) };
    if (n.kind == "div") {
        std::vector<juce::String> outs;
        for (int k = 0; k < int(s.outputs.size()); ++k) {
            float v = param(n, ("d" + std::to_string(k + 1)).c_str(), float(k + 1));
            outs.push_back(juce::String::fromUTF8("\xc3\xb7") + juce::String(std::isfinite(v) ? int(std::round(v)) : k + 1));
        }
        return { strs(s.inputs, 99), outs };
    }
    if (n.kind == "slider" || n.kind == "knob") {
        auto& o = use(n.id).outs;
        int used = o.empty() ? 0 : *o.rbegin() + 1;
        return { {}, strs(s.outputs, size_t(std::max(ControlsLayout::count(param(n, "count", 2)), used))) };
    }
    return { strs(s.inputs, 99), strs(s.outputs, 99) };
}

bool hasTriggerRow(const ModuleSpec& s) { for (auto& p : s.params) if (p.isTrigger()) return true; return false; }

std::vector<int> rowParams(const ModuleSpec& s, const PatchNode& n) {
    std::vector<int> all;
    for (int i = 0; i < int(s.params.size()); ++i) if (!s.params[size_t(i)].isTrigger()) all.push_back(i);
    auto findKey = [&](const char* key) { for (size_t a = 0; a < all.size(); ++a) if (s.params[size_t(all[a])].key == key) return int(a); return -1; };
    if (int a = findKey("algo"); a >= 0) { int v = all[size_t(a)]; all.erase(all.begin() + a); all.insert(all.begin(), v); }
    if (int a = findKey("voices"); a >= 0) { int v = all[size_t(a)]; all.erase(all.begin() + a); all.insert(all.begin() + std::min(1, int(all.size())), v); }
    if (int a = findKey("attack"); a >= 0 && s.paramIndex("decay") >= 0) {
        int v = all[size_t(a)]; all.erase(all.begin() + a);
        int d = findKey("decay");
        if (d >= 0) all.insert(all.begin() + d, v); else all.push_back(v);
    }
    auto& patched = use(n.id).ins;
    if (s.kind == "mix") {
        int ch = MixerLayout::channels(param(n, "chans", 1));
        bool showPans = param(n, "pans", 0) > 0.5f;
        std::vector<int> r { 0 };
        for (int k = 0; k < ch; ++k) r.push_back(1 + 2 * k);
        r.push_back(MixerLayout::masterIndex); r.push_back(MixerLayout::showPansIndex);
        for (int k = 0; k < ch; ++k) if (showPans || patched.count(kParamPortBase + 2 + 2 * k)) r.push_back(2 + 2 * k);
        return r;
    }
    if (s.kind == "rack" || s.kind == "drumsynth") {
        bool rack = s.kind == "rack";
        int globals = rack ? RackLayout::globals : DrumSynthLayout::globals;
        int count = rack ? RackLayout::pads : DrumSynthLayout::voices, shown = rack ? 5 : DrumSynthLayout::shown;
        int sel = std::clamp(int(std::round(param(n, "sel", 0))), 0, count - 1);
        int b = rack ? RackLayout::base(sel) : DrumSynthLayout::base(sel);
        std::vector<int> r;
        for (int k = 0; k < globals; ++k) r.push_back(k);
        for (int k = b; k < b + shown; ++k) r.push_back(k);
        for (int i : all) if (i >= globals && !(i >= b && i < b + shown) && patched.count(kParamPortBase + i)) r.push_back(i);
        return r;
    }
    if (s.kind == "slider" || s.kind == "knob") {
        std::vector<int> r;
        for (int i : all) if (i < 3 || patched.count(kParamPortBase + i)) r.push_back(i);
        return r;
    }
    if (s.kind != "peq") return all;
    int bands = ParametricEQ::bandCount(param(n, "bands", 0));
    std::vector<int> r;
    for (int i : all) if (i < 2 || (i - 2) / 3 < bands) r.push_back(i);
    return r;
}

int portRows(const PatchNode& n, const ModuleSpec& s, const HardwareCounts& hw) {
    auto p = ports(n, s, hw);
    if (n.kind == "rack") return std::max(int(p.ins.size()), 2);     // the pad outlets sit beside the drum roll's rows
    return rowOutlets(n.kind) ? int(p.ins.size()) : int(std::max(p.ins.size(), p.outs.size()));
}
bool sideDisplay(const std::string& k) { return k == "slider" || k == "knob" || k == "drums" || k == "roll"; }
float portsHeight(const PatchNode& n, const ModuleSpec& s, const HardwareCounts& hw) {
    int r = portRows(n, s, hw);
    return r > 0 ? float(r) * portRow + 6 : 0;
}
float bodyHeight(const PatchNode& n, const ModuleSpec& s, const HardwareCounts& hw) {
    return sideDisplay(n.kind) ? std::max(portsHeight(n, s, hw), readoutHeight(n) + 6) : portsHeight(n, s, hw) + readoutHeight(n);
}
float height(const PatchNode& n, const ModuleSpec& s, const HardwareCounts& hw) {
    if (n.kind == "text") return textSize(n).y;
    if (n.collapsed) {
        int r = collapsedRows(n, s);
        float display = readoutHeight(n);
        return header + (r > 0 ? float(r) * portRow + 6 : 0) + (display > 0 ? display + 6 : 0);
    }
    int rows = int(rowParams(s, n).size()) + (hasTriggerRow(s) ? 1 : 0);
    return header + bodyHeight(n, s, hw) + (rows > 0 ? float(rows) * row + 4 : 0) + 4;
}
Pt inlet(const PatchNode& n, const ModuleSpec& s, const HardwareCounts&, int i) {
    float y = header + 3 + float(i) * portRow + portRow / 2;
    if (n.collapsed) {
        auto l = collapsedLeft(n, s);
        auto it = std::find(l.begin(), l.end(), i);
        y = it == l.end() ? header / 2 : collapsedY(int(it - l.begin()));
    }
    return { float(n.x), float(n.y) + y };
}
Pt outlet(const PatchNode& n, const ModuleSpec& s, const HardwareCounts& hw, int i) {
    float y = header + 3 + float(i) * portRow + portRow / 2;
    if (!n.collapsed) { int pi = outletParam(n.kind, i); if (pi >= 0) if (auto ry = paramRowY(n, s, hw, pi)) y = *ry; }
    if (!n.collapsed && n.kind == "rack" && i >= 2)    // rack: pad k's outlet is level with its row in the drum roll
        y = header + portsHeight(n, s, hw) + 4 + (float(i - 2) + 0.5f) * padLaneHeight(n);
    if (n.collapsed) {
        auto r = collapsedRight(n, s);
        auto it = std::find(r.begin(), r.end(), i);
        y = it == r.end() ? header / 2 : collapsedY(int(it - r.begin()));
    }
    return { float(n.x) + width(n), float(n.y) + y };
}
std::optional<float> paramRowY(const PatchNode& n, const ModuleSpec& s, const HardwareCounts& hw, int p) {
    if (n.collapsed) {
        auto l = collapsedLeft(n, s);
        auto it = std::find(l.begin(), l.end(), kParamPortBase + p);
        return it == l.end() ? header / 2 : collapsedY(int(it - l.begin()));
    }
    auto rp = rowParams(s, n);
    auto it = std::find(rp.begin(), rp.end(), p);
    if (it == rp.end()) return std::nullopt;
    int k2 = int(it - rp.begin()) + (hasTriggerRow(s) ? 1 : 0);
    return header + bodyHeight(n, s, hw) + 2 + float(k2) * row + (row - 3) / 2;
}
std::optional<Pt> paramInlet(const PatchNode& n, const ModuleSpec& s, const HardwareCounts& hw, int p) {
    auto y = paramRowY(n, s, hw, p);
    if (!y) return std::nullopt;
    return Pt { float(n.x), float(n.y) + *y };
}
std::vector<VisiblePort> visiblePorts(const PatchNode& n, const ModuleSpec& s, const HardwareCounts& hw) {
    std::vector<VisiblePort> r;
    auto p = ports(n, s, hw);
    if (n.collapsed) {
        for (int k : collapsedLeft(n, s)) if (auto pt = destination(n, s, hw, k)) r.push_back({ *pt, inletName(s, k), false });
        for (int k : collapsedRight(n, s)) r.push_back({ outlet(n, s, hw, k), juce::String::fromUTF8(s.outputs[size_t(k)].c_str()), true });
    } else {
        for (int k = 0; k < int(p.ins.size()); ++k) r.push_back({ inlet(n, s, hw, k), p.ins[size_t(k)], false });
        for (int k = 0; k < int(p.outs.size()); ++k) r.push_back({ outlet(n, s, hw, k), p.outs[size_t(k)], true });
        for (int k : rowParams(s, n)) if (auto pt = paramInlet(n, s, hw, k)) r.push_back({ *pt, juce::String::fromUTF8(s.params[size_t(k)].name.c_str()), false });
    }
    return r;
}
std::optional<Pt> destination(const PatchNode& n, const ModuleSpec& s, const HardwareCounts& hw, int port) {
    if (port >= kParamPortBase) return paramInlet(n, s, hw, port - kParamPortBase);
    if (port >= int(ports(n, s, hw).ins.size())) return std::nullopt;
    return inlet(n, s, hw, port);
}
}

void addCable(juce::Path& p, Pt a, Pt b, float scale) {
    p.startNewSubPath(a);
    float d = std::min(140 * scale, std::max(30 * scale, std::abs(b.x - a.x) * 0.45f + std::abs(b.y - a.y) * 0.15f));
    p.cubicTo(a.x + d, a.y, b.x - d, b.y, b.x, b.y);
}

// ---------------------------------------------------------------- icons

namespace Icons {
void xmark(GC& g, Pt c, float s, std::optional<juce::Colour> colour) {
    juce::Path p;
    p.startNewSubPath(c.x - s, c.y - s); p.lineTo(c.x + s, c.y + s);
    p.startNewSubPath(c.x + s, c.y - s); p.lineTo(c.x - s, c.y + s);
    g.stroke(p, colour.value_or(Theme::dim()), 1.4f, true);
}
void dash(GC& g, Pt c) {      // collapse / expand a box
    juce::Path p; p.startNewSubPath(c.x - 3.5f, c.y); p.lineTo(c.x + 3.5f, c.y);
    g.stroke(p, Theme::dim(), 1.4f, true);
}
void chevron(GC& g, Pt c, bool up) {
    juce::Path p; float d = up ? -1.0f : 1.0f;
    p.startNewSubPath(c.x - 3.5f, c.y - 1.75f * d); p.lineTo(c.x, c.y + 1.75f * d); p.lineTo(c.x + 3.5f, c.y - 1.75f * d);
    g.stroke(p, Theme::dim(), 1.4f, true);
}
void waveform(GC& g, Pt c) {
    juce::Path p; const float hs[] = { 2, 5, 3.5f, 6, 2.5f };
    for (int k = 0; k < 5; ++k) { float x = c.x - 4 + float(k) * 2; p.startNewSubPath(x, c.y - hs[k] / 2); p.lineTo(x, c.y + hs[k] / 2); }
    g.stroke(p, Theme::dim(), 1.1f, true);
}
void trash(GC& g, Pt c) {
    juce::Path p;
    p.startNewSubPath(c.x - 3.5f, c.y - 2.5f); p.lineTo(c.x + 3.5f, c.y - 2.5f);
    p.startNewSubPath(c.x - 1, c.y - 3.5f); p.lineTo(c.x + 1, c.y - 3.5f);
    p.addRectangle(c.x - 2.5f, c.y - 2.5f, 5, 6);
    g.stroke(p, Theme::dim(), 1, true);
}
void resetArrow(GC& g, Pt c) {
    // reset automation: an open circle running clockwise from the upper right round to the top, with an arrowhead there
    const float r = 3.4f, pi = juce::MathConstants<float>::pi;
    auto pt = [&](float deg) { float t = deg * pi / 180; return Pt { c.x + r * std::cos(t), c.y + r * std::sin(t) }; };
    juce::Path p;
    p.startNewSubPath(pt(-40));
    for (int k = 1; k <= 20; ++k) p.lineTo(pt(-40 + float(k) * 15));
    Pt tip = pt(260); float t = 260 * pi / 180;
    Pt dir { -std::sin(t), std::cos(t) }, nrm { std::cos(t), std::sin(t) };
    juce::Path h;
    h.startNewSubPath(tip.x - dir.x * 2.2f + nrm.x * 1.8f, tip.y - dir.y * 2.2f + nrm.y * 1.8f);
    h.lineTo(tip);
    h.lineTo(tip.x - dir.x * 2.2f - nrm.x * 1.8f, tip.y - dir.y * 2.2f - nrm.y * 1.8f);
    g.stroke(p, Theme::dim(), 1.3f, true);
    g.stroke(h, Theme::dim(), 1.3f, true);
}
void play(GC& g, Pt c, juce::Colour col) {
    juce::Path p; p.addTriangle(c.x - 2.5f, c.y - 3.5f, c.x + 3.5f, c.y, c.x - 2.5f, c.y + 3.5f);
    g.fill(p, col);
}
void pause(GC& g, Pt c, juce::Colour col) { g.fill(Rect(c.x - 3, c.y - 3.5f, 2, 7), col); g.fill(Rect(c.x + 1, c.y - 3.5f, 2, 7), col); }
void stop(GC& g, Pt c, juce::Colour col) { g.fill(Rect(c.x - 3, c.y - 3, 6, 6), col); }
}

void drawMeter(GC& g, Rect r, float level) {
    float db = 20 * std::log10(std::max(fin(level), 1e-5f));
    float f = std::clamp((db + 60) / 60, 0.0f, 1.0f);
    g.fill(r, Theme::row());
    g.fillGradient(r, { { Theme::meterGreen, 0 }, { Theme::meterGreen, 0.7f }, { Theme::meterYellow, 0.88f }, { Theme::meterRed, 1 } }, f);
}

void drawGainReduction(GC& g, Rect r, float db) {
    g.fill(r, Theme::row());
    float w = r.getWidth() * std::clamp(db / 24, 0.0f, 1.0f);
    g.fill(Rect(r.getRight() - w, r.getY(), w, r.getHeight()), Theme::meterYellow);
}

namespace LiveSig {
int64_t floats(const float* p, int n) {
    uint64_t h = uint64_t(n);
    for (int i = 0; i < n; ++i) { uint32_t b; std::memcpy(&b, &p[i], 4); h = h * 1000003u + b; }
    return int64_t(h);
}
int64_t readouts(const DSPNode* node, int n, float steps) {
    if (!node) return 0;
    int64_t h = 0;
    for (int i = 0; i < std::min(n, kReadoutCount); ++i) mix(h, q(node->readouts[size_t(i)], steps));
    return h;
}
int64_t patch(const PatchNode& n) {
    uint64_t h = 0;
    std::hash<std::string> hs;
    for (auto& [k, v] : n.params) { uint32_t b; std::memcpy(&b, &v, 4); h += uint64_t(hs(k)) ^ (uint64_t(b) * 2654435761u); }
    for (auto& [k, v] : n.data) {
        h += uint64_t(hs(k)) ^ uint64_t(v.size()) * 40503u;
        for (size_t i = 0; i < std::min<size_t>(v.size(), 600); ++i) { uint32_t b; std::memcpy(&b, &v[i], 4); h = h * 31u + b; }
    }
    int64_t r = int64_t(h);
    mix(r, int64_t(n.w.value_or(0) * 8)); mix(r, int64_t(n.dh.value_or(0) * 8)); mix(r, n.collapsed ? 1 : 0);
    return r;
}
}

} // namespace pn
