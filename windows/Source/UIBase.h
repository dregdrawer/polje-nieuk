// The look of the app (Theme.swift, CustomColours.swift), the drawing calls every box uses (NativeLive.swift
// LiveGC) and where everything in a box is (Theme.swift BoxLayout, NativeBoxes.swift BoxGeo) — the same numbers
// as the Mac / iPad app, so boxes, rows, ports and cables line up identically.
#pragma once
#include "Engine.h"
#include "ModulesShared.h"
#include <set>

namespace pn {

class AppModel;

// ---------------------------------------------------------------- settings (UserDefaults)

juce::PropertiesFile& settings();

// ---------------------------------------------------------------- colours

namespace CustomColours {
    enum Slot { background = 0, windows = 1, cables = 2 };
    std::optional<juce::Colour> colour(Slot s);
    void set(Slot s, std::optional<juce::Colour> c);
    void resetAll();
    void schemeChanged();
    bool anyCustom();
    extern int version;
    struct WindowPalette { bool isLight; juce::Colour box, row, fill, border, faint, text, dim; };
    std::optional<WindowPalette> windowPalette();
    std::optional<juce::Colour> defaultCable();
    std::optional<juce::Colour> gridDot();
    const char* title(Slot s);
}

namespace Theme {
    extern bool light;
    juce::Colour bg(); juce::Colour defaultBg(); juce::Colour gridDot();
    bool boxIsLight();
    juce::Colour box(); juce::Colour defaultBox(); juce::Colour border(); juce::Colour selected(); juce::Colour text();
    juce::Colour dim(); juce::Colour faint(); juce::Colour row(); juce::Colour fill(); juce::Colour cable();
    juce::Colour defaultCable(); juce::Colour bar(); juce::Colour inverse(); juce::Colour shade();
    juce::Colour keyWhite(); juce::Colour keyBlack(); juce::Colour keyWhiteLit(); juce::Colour keyBlackLit();
    const juce::Colour rec { juce::Colour::fromFloatRGBA(1.0f, 0.23f, 0.2f, 1.0f) };
    const juce::Colour meterGreen { juce::Colour::fromFloatRGBA(0.25f, 0.85f, 0.35f, 1.0f) };
    const juce::Colour meterYellow { juce::Colour::fromFloatRGBA(1.0f, 0.82f, 0.2f, 1.0f) };
    const juce::Colour meterRed { juce::Colour::fromFloatRGBA(1.0f, 0.23f, 0.2f, 1.0f) };
    inline juce::Colour white(float w, float a = 1) { return juce::Colour::fromFloatRGBA(w, w, w, a); }
    /// the monospaced font every word in the app is set in (Menlo on the Mac build, Consolas on Windows)
    juce::Font mono(float size, bool bold = false);
}

float textWidth(const juce::String& s, float size, bool bold = false);
juce::String fitText(const juce::String& s, float size, float width, bool bold = false);
inline int ri(float v) { return std::isfinite(v) ? int(std::clamp(v, -1e9f, 1e9f)) : 0; }
inline float fin(float v) { return std::isfinite(v) ? v : 0.0f; }

// ---------------------------------------------------------------- drawing (LiveGC)

using Rect = juce::Rectangle<float>;
using Pt = juce::Point<float>;

struct GC {
    juce::Graphics& g;
    explicit GC(juce::Graphics& gg) : g(gg) {}
    void fill(const juce::Path& p, juce::Colour c) { g.setColour(c); g.fillPath(p); }
    void fill(Rect r, juce::Colour c) { g.setColour(c); g.fillRect(r); }
    void fillEllipse(Rect r, juce::Colour c) { g.setColour(c); g.fillEllipse(r); }
    void fillRounded(Rect r, float radius, juce::Colour c) { g.setColour(c); g.fillRoundedRectangle(r, radius); }
    void stroke(const juce::Path& p, juce::Colour c, float width = 1, bool round = false, std::vector<float> dash = {});
    void strokeRect(Rect r, juce::Colour c, float width = 1) { g.setColour(c); g.drawRect(r, width); }
    void strokeRounded(Rect r, float radius, juce::Colour c, float width = 1) { g.setColour(c); g.drawRoundedRectangle(r, radius, width); }
    void strokeEllipse(Rect r, juce::Colour c, float width = 1) { g.setColour(c); g.drawEllipse(r, width); }
    void line(Pt a, Pt b, juce::Colour c, float width = 1) { g.setColour(c); g.drawLine({ a, b }, width); }
    /// text anchored like SwiftUI's draw(at:anchor:) — ax / ay 0 = left / top, 0.5 = centre, 1 = right / bottom
    void text(const juce::String& s, Pt at, float size, juce::Colour c, bool bold = false, float ax = 0.5f, float ay = 0.5f);
    void textLeft(const juce::String& s, Pt at, float size, juce::Colour c, bool bold = false) { text(s, at, size, c, bold, 0, 0.5f); }
    void textRight(const juce::String& s, Pt at, float size, juce::Colour c, bool bold = false) { text(s, at, size, c, bold, 1, 0.5f); }
    /// a left-to-right gradient across `r`, shown up to `upTo` of its width
    void fillGradient(Rect r, const std::vector<std::pair<juce::Colour, float>>& stops, float upTo = 1);
    template <class F> void dimmed(float alpha, F body) {
        if (alpha >= 1) { body(); return; }
        g.beginTransparencyLayer(alpha); body(); g.endTransparencyLayer();
    }
    template <class F> void clipped(Rect r, F body) {
        juce::Graphics::ScopedSaveState s(g);
        g.reduceClipRegion(r.getSmallestIntegerContainer());
        body();
    }
    template <class F> void translated(Pt d, F body) {
        juce::Graphics::ScopedSaveState s(g);
        g.addTransform(juce::AffineTransform::translation(d.x, d.y));
        body();
    }
};

// ---------------------------------------------------------------- box geometry (BoxLayout)

struct HardwareCounts { int inputs = 12, outputs = 8; bool operator==(const HardwareCounts& o) const { return inputs == o.inputs && outputs == o.outputs; } };
struct PortUsage { std::set<int> ins, outs; };

namespace MixerLayout {
    constexpr int maxChannels = 16, masterIndex = 1 + 2 * maxChannels, showPansIndex = masterIndex + 1, channelMeterBase = 8;
    inline int channels(float v) { static const int c[] = { 2, 4, 8, 16 }; return c[clampIndex(v, 4)]; }
}
namespace ControlsLayout {
    constexpr int maxControls = 8;
    inline int count(float v) { static const int c[] = { 1, 2, 4, 8 }; return c[clampIndex(v, 4)]; }
    inline int valueIndex(int k) { return 3 + k; }
    extern const std::vector<std::string> ranges;
}
namespace SegmentsLayout {
    extern const std::vector<std::string> types;
    inline int count(float v) { return clampIndex(v, 6) + 1; }
    inline int base(int k) { return 1 + k * 4; }
}

namespace BoxLayout {
    extern std::map<juce::String, PortUsage> usage;
    void rebuildUsage(const Patch& p);
    constexpr float header = 22, portRow = 15, readout = 20, row = 20, port = 9, paramPort = 7, sideOutletColumn = 30, pad = 12;
    float param(const PatchNode& n, const char* key, float def);
    std::vector<int> collapsedLeft(const PatchNode& n, const ModuleSpec& s);
    std::vector<int> collapsedRight(const PatchNode& n, const ModuleSpec& s);
    int collapsedRows(const PatchNode& n, const ModuleSpec& s);
    juce::String inletName(const ModuleSpec& s, int port);
    float width(const std::string& kind);
    float defaultWidth(const PatchNode& n);
    float defaultReadoutHeight(const PatchNode& n);
    juce::Point<float> textSize(const PatchNode& n);
    float width(const PatchNode& n);
    float readoutHeight(const PatchNode& n);
    float readoutHeight(const std::string& kind);
    std::pair<bool, bool> resizable(const std::string& kind);
    bool hasReadout(const std::string& kind);
    struct Ports { std::vector<juce::String> ins, outs; };
    Ports ports(const PatchNode& n, const ModuleSpec& s, const HardwareCounts& hw);
    bool hasTriggerRow(const ModuleSpec& s);
    std::vector<int> rowParams(const ModuleSpec& s, const PatchNode& n);
    inline bool rowOutlets(const std::string& kind) { return kind == "div"; }
    inline int outletParam(const std::string& kind, int i) { return kind == "div" ? 3 + i : -1; }
    int portRows(const PatchNode& n, const ModuleSpec& s, const HardwareCounts& hw);
    bool sideDisplay(const std::string& kind);
    float bodyHeight(const PatchNode& n, const ModuleSpec& s, const HardwareCounts& hw);
    float portsHeight(const PatchNode& n, const ModuleSpec& s, const HardwareCounts& hw);
    float height(const PatchNode& n, const ModuleSpec& s, const HardwareCounts& hw);
    Pt inlet(const PatchNode& n, const ModuleSpec& s, const HardwareCounts& hw, int i);
    Pt outlet(const PatchNode& n, const ModuleSpec& s, const HardwareCounts& hw, int i);
    std::optional<float> paramRowY(const PatchNode& n, const ModuleSpec& s, const HardwareCounts& hw, int param);
    std::optional<Pt> paramInlet(const PatchNode& n, const ModuleSpec& s, const HardwareCounts& hw, int param);
    struct VisiblePort { Pt point; juce::String name; bool output; };
    std::vector<VisiblePort> visiblePorts(const PatchNode& n, const ModuleSpec& s, const HardwareCounts& hw);
    std::optional<Pt> destination(const PatchNode& n, const ModuleSpec& s, const HardwareCounts& hw, int port);
}

/// The cable curve (PatchCanvasView.swift addCable): leaves an outlet heading right, enters an inlet heading right.
void addCable(juce::Path& p, Pt a, Pt b, float scale);

/// Small drawn icons (NativeBoxes.swift Icons).
namespace Icons {
    void xmark(GC& g, Pt c, float size = 3, std::optional<juce::Colour> colour = std::nullopt);
    void chevron(GC& g, Pt c, bool up);
    void waveform(GC& g, Pt c);
    void trash(GC& g, Pt c);
    void resetArrow(GC& g, Pt c);
    void play(GC& g, Pt c, juce::Colour col);
    void pause(GC& g, Pt c, juce::Colour col);
    void stop(GC& g, Pt c, juce::Colour col);
}

void drawMeter(GC& g, Rect r, float level);
void drawGainReduction(GC& g, Rect r, float db);

/// Signature helpers (LiveView.swift LiveSig): fold values into one number, quantised.
namespace LiveSig {
    inline int64_t q(float v, float steps = 64) { return std::isfinite(v) ? int64_t(std::llround(std::clamp(v, -1e6f, 1e6f) * steps)) : 0; }
    inline void mix(int64_t& h, int64_t v) { h = int64_t(uint64_t(h) * 31u + uint64_t(v)); }
    int64_t floats(const float* p, int n);
    int64_t readouts(const DSPNode* node, int n, float steps = 128);
    int64_t patch(const PatchNode& n);
}

} // namespace pn
