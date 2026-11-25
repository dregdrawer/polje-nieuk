// Each module's own display on the canvas (NativeDisplays.swift + the drawing code of the Swift views):
// what it draws, where, and what pointer presses do in it. Positions are box points.
#pragma once
#include "AppModel.h"

namespace pn {

struct PointerInfo {
    int clickCount = 1;
    bool shift = false, option = false, command = false, right = false;
    Pt start;            // where it went down (box points)
    bool moved = false;  // past the drag threshold
};

struct MenuItem {
    juce::String title;
    bool checked = false, enabled = true, header = false, separator = false;
    std::function<void()> action;
    static MenuItem divider() { MenuItem m; m.separator = true; return m; }
    static MenuItem section(const juce::String& t) { MenuItem m; m.title = t; m.enabled = false; m.header = true; return m; }
};

/// A part of a box that moves on its own (a display, a live row, a meter): redrawn when `signature` changes.
struct LivePart {
    std::string key;
    Rect rect;                                 // box points
    int every = 1;
    bool smooth = false, dimmed = false;
    std::function<int64_t()> signature;        // null: every tick
    std::function<void(GC&, Pt)> draw;         // (gc, size)
};

class NativeDisplay {
public:
    NativeDisplay(AppModel& m, const PatchNode& n, const ModuleSpec& s) : model(m), id(n.id), node(n), spec(s) {}
    virtual ~NativeDisplay() = default;
    virtual std::vector<LivePart> parts(Rect) { return {}; }
    virtual void paintStatic(GC&, Rect) {}
    virtual bool press(Pt, Rect, const PointerInfo&) { return false; }
    virtual void drag(Pt, Rect, const PointerInfo&) {}
    virtual void release(Pt, Rect, const PointerInfo&) {}
    virtual std::optional<std::vector<MenuItem>> menu(Pt, Rect) { return std::nullopt; }
    virtual std::optional<int> pad(Pt, Rect) { return std::nullopt; }
    /// the scroll wheel over the display (true: taken; roll scrolls its octaves)
    virtual bool wheel(Pt, Rect, float) { return false; }
    static std::unique_ptr<NativeDisplay> make(AppModel& m, const PatchNode& n, const ModuleSpec& s);

    AppModel& model;
    juce::String id;
    PatchNode node;
    const ModuleSpec& spec;
    std::optional<int> dropPad;
    DSPNode* dsp() { return model.node(id); }
    int param(const std::string& key) const { return spec.paramIndex(key); }
    void setParam(const std::string& key, float v) { int i = param(key); if (i >= 0) model.setParam(id, i, v); }
    float p(const std::string& key, float def) const { auto it = node.params.find(key); return it == node.params.end() ? def : it->second; }
    LivePart part(std::string key, Rect r, std::function<int64_t()> sig, std::function<void(GC&, Pt)> draw, int every = 1, bool smooth = false) {
        return LivePart { std::move(key), r, every, smooth, node.bypassed, std::move(sig), std::move(draw) };
    }
};

/// Every installed VST3, by company, into `menu`; `pick` gets the one chosen (the plugin box and the module list).
void addPluginList(juce::PopupMenu& menu, AppModel& m, const juce::String& current, std::function<void(const PluginInfo&)> pick);
std::unique_ptr<NativeDisplay> makePluginDisplay(AppModel& m, const PatchNode& n, const ModuleSpec& s);

/// A step grid's beat / bar lines (RackView.swift drawStepGrid).
void drawStepGrid(GC& g, Pt size, int steps, std::optional<float> division);

} // namespace pn
