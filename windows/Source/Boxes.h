// Where everything in a box is (BoxGeo) and the drawing of what only changes with its settings (BoxPainter)
// — NativeBoxes.swift.
#pragma once
#include "Displays.h"

namespace pn {

struct BoxGeo {
    enum Button { bypass, clearPattern, autoRec, resetAuto, audioMenu, close, collapse };
    BoxGeo(const PatchNode& n, const ModuleSpec& s, const HardwareCounts& hw, bool selected, AppModel& m);
    const PatchNode* node; const ModuleSpec* spec; HardwareCounts hw;
    float w, h;
    std::vector<std::pair<Button, Rect>> buttons;
    Rect titleRect;
    Rect header() const { return Rect(0, 0, w, BoxLayout::header); }
    std::optional<Rect> portRows() const;
    std::optional<Rect> display() const;
    float paramsTop() const;
    std::vector<std::pair<int, Rect>> triggers() const;
    std::vector<std::pair<int, Rect>> rows() const;
    std::optional<Rect> grip() const;
    struct Port { int port; bool output; Pt center; float size; };
    std::vector<Port> ports() const;
    std::optional<Port> port(Pt p) const;
};

namespace BoxPainter {
    void paint(GC& g, const BoxGeo& geo, AppModel& m, bool selected, bool dropTarget, const std::set<int>& liveRows, NativeDisplay* display);
    Rect meterRect(const BoxGeo& geo, int r);
    void trigger(GC& g, Rect r, const ParamSpec& ps);
    void paramRow(GC& g, Rect r, const ParamSpec& ps, float value);
    void liveRow(GC& g, Pt size, const ParamSpec& ps, float base, float live, bool automated);
    void paintText(GC& g, const PatchNode& n, Pt size, bool selected, bool editing);
    void paintGroup(GC& g, const PatchGroup& group, Pt size, bool selected, bool renaming);
}

} // namespace pn
