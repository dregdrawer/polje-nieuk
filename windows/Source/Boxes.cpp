#include "Boxes.h"

namespace pn {

BoxGeo::BoxGeo(const PatchNode& n, const ModuleSpec& s, const HardwareCounts& hw_, bool selected, AppModel& m)
    : node(&n), spec(&s), hw(hw_) {
    w = BoxLayout::width(n); h = BoxLayout::height(n, s, hw);
    if (s.bypass() != BypassMode::none) buttons.push_back({ bypass, Rect(6, 2, 18, 18) });
    std::vector<std::pair<Button, float>> right { { close, 18 }, { collapse, 18 } };   // the cross always, at the very right
    if (dynamic_cast<SampleBufferNode*>(m.node(n.id))) right.push_back({ audioMenu, 18 });
    if (m.canAutomate(s) && !n.collapsed) {
        if (m.hasAutomation(n)) right.push_back({ resetAuto, 15 });
        right.push_back({ autoRec, 15 });
    }
    if (AppModel::patternKinds.count(n.kind) && !n.collapsed) right.push_back({ clearPattern, 15 });
    float x = w - 4, leftmost = x;
    for (size_t k = 0; k < right.size(); ++k) {
        if (k > 0) x -= 6;
        x -= right[k].second;
        buttons.push_back({ right[k].first, Rect(x, 2, right[k].second, 18) });
        leftmost = x;
    }
    float tx = s.bypass() != BypassMode::none ? 30.0f : 10.0f;
    titleRect = Rect(tx, 0, std::max(leftmost - 6 - tx, 0.0f), BoxLayout::header);
}

std::optional<Rect> BoxGeo::portRows() const {
    int r = node->collapsed ? BoxLayout::collapsedRows(*node, *spec) : BoxLayout::portRows(*node, *spec, hw);
    if (r <= 0) return std::nullopt;
    return Rect(0, BoxLayout::header, w, float(r) * BoxLayout::portRow + 6);
}

std::optional<Rect> BoxGeo::display() const {
    float dh = BoxLayout::readoutHeight(*node);
    if (!BoxLayout::hasReadout(spec->kind) || dh <= 0) return std::nullopt;
    if (node->collapsed) {
        int r = BoxLayout::collapsedRows(*node, *spec);
        return Rect(10, BoxLayout::header + (r > 0 ? float(r) * BoxLayout::portRow + 6 : 0), w - 20, dh);
    }
    if (BoxLayout::sideDisplay(spec->kind)) return Rect(10, BoxLayout::header, std::max(w - 20 - BoxLayout::sideOutletColumn, 10.0f), dh);
    return Rect(10, BoxLayout::header + BoxLayout::portsHeight(*node, *spec, hw), w - 20, dh);
}

float BoxGeo::paramsTop() const { return BoxLayout::header + BoxLayout::bodyHeight(*node, *spec, hw) + 2; }

std::vector<std::pair<int, Rect>> BoxGeo::triggers() const {
    if (node->collapsed) return {};
    std::vector<int> t;
    for (int i = 0; i < int(spec->params.size()); ++i) if (spec->params[size_t(i)].isTrigger()) t.push_back(i);
    if (t.empty()) return {};
    float full = w - 16, gap = 4, bw = (full - gap * float(t.size() - 1)) / float(t.size());
    std::vector<std::pair<int, Rect>> r;
    for (size_t k = 0; k < t.size(); ++k) r.push_back({ t[k], Rect(8 + float(k) * (bw + gap), paramsTop(), bw, BoxLayout::row - 3) });
    return r;
}

std::vector<std::pair<int, Rect>> BoxGeo::rows() const {
    if (node->collapsed) return {};
    int off = BoxLayout::hasTriggerRow(*spec) ? 1 : 0;
    auto rp = BoxLayout::rowParams(*spec, *node);
    std::vector<std::pair<int, Rect>> r;
    for (size_t k = 0; k < rp.size(); ++k) r.push_back({ rp[k], Rect(8, paramsTop() + float(int(k) + off) * BoxLayout::row, w - 16, BoxLayout::row - 3) });
    return r;
}

std::optional<Rect> BoxGeo::grip() const {
    if (node->collapsed) return std::nullopt;
    auto can = BoxLayout::resizable(node->kind);
    if (!can.first && !can.second) return std::nullopt;
    return Rect(w - 22, h - 22, 22, 22);
}

std::vector<BoxGeo::Port> BoxGeo::ports() const {
    std::vector<Port> r;
    auto& n = *node; auto& s = *spec;
    float ny = float(n.y);
    if (n.collapsed) {
        for (int i : BoxLayout::collapsedLeft(n, s)) {
            if (i >= kParamPortBase) { if (auto y = BoxLayout::paramRowY(n, s, hw, i - kParamPortBase)) r.push_back({ i, false, { 0, *y }, BoxLayout::paramPort }); }
            else r.push_back({ i, false, { 0, BoxLayout::inlet(n, s, hw, i).y - ny }, BoxLayout::port });
        }
        for (int i : BoxLayout::collapsedRight(n, s)) r.push_back({ i, true, { w, BoxLayout::outlet(n, s, hw, i).y - ny }, BoxLayout::port });
        return r;
    }
    auto p = BoxLayout::ports(n, s, hw);
    for (int i = 0; i < int(p.ins.size()); ++i) r.push_back({ i, false, { 0, BoxLayout::inlet(n, s, hw, i).y - ny }, BoxLayout::port });
    for (int i = 0; i < int(p.outs.size()); ++i) r.push_back({ i, true, { w, BoxLayout::outlet(n, s, hw, i).y - ny }, BoxLayout::port });
    for (int i : BoxLayout::rowParams(s, n)) if (auto y = BoxLayout::paramRowY(n, s, hw, i)) r.push_back({ kParamPortBase + i, false, { 0, *y }, BoxLayout::paramPort });
    return r;
}

std::optional<BoxGeo::Port> BoxGeo::port(Pt p) const {
    std::optional<Port> best; float bd = INFINITY;
    for (auto& q : ports()) {
        if (std::abs(q.center.x - p.x) > 11 || std::abs(q.center.y - p.y) > 9) continue;
        float d = q.center.getDistanceFrom(p);
        if (d < bd) { bd = d; best = q; }
    }
    return best;
}

// ---------------------------------------------------------------- painter

namespace BoxPainter {

static void header(GC& g, const BoxGeo& geo, AppModel& m) {
    auto& node = *geo.node;
    float mid = BoxLayout::header / 2;
    for (auto& [b, r] : geo.buttons) {
        Pt c = r.getCentre();
        switch (b) {
            case BoxGeo::bypass: {
                Rect dot(c.x - 4.5f, c.y - 4.5f, 9, 9);
                if (!node.bypassed) g.fillEllipse(dot, Theme::text());
                g.strokeEllipse(dot.reduced(0.5f), node.bypassed ? Theme::dim() : Theme::text(), 1);
                break;
            }
            case BoxGeo::collapse: Icons::dash(g, c); break;
            case BoxGeo::close: Icons::xmark(g, c); break;
            case BoxGeo::audioMenu: Icons::waveform(g, c); break;
            case BoxGeo::resetAuto: Icons::resetArrow(g, c); break;
            case BoxGeo::clearPattern: Icons::trash(g, c); break;
            case BoxGeo::autoRec: {
                bool on = m.autoRecording.count(node.id) > 0;
                Rect ring(c.x - 4.5f, c.y - 4.5f, 9, 9);
                if (on) g.fillEllipse(ring, Theme::rec);
                g.strokeEllipse(ring.reduced(0.5f), on ? Theme::rec : Theme::dim(), 1);
                g.fillEllipse(Rect(c.x - 1.5f, c.y - 1.5f, 3, 3), on ? juce::Colours::white.withAlpha(0.9f) : Theme::dim());
                break;
            }
        }
    }
    auto t = geo.titleRect;
    auto name = fitText(juce::String::fromUTF8(geo.spec->name.c_str()), 11, t.getWidth(), true);
    g.textLeft(name, { t.getX(), mid }, 11, node.bypassed ? Theme::dim() : Theme::text(), true);
    if (node.bypassed) g.fill(Rect(t.getX(), mid, textWidth(name, 11, true), 1), Theme::dim());
}

static void portRowsDraw(GC& g, const BoxGeo& geo) {
    auto p = BoxLayout::ports(*geo.node, *geo.spec, geo.hw);
    int rows = BoxLayout::portRows(*geo.node, *geo.spec, geo.hw);
    bool outLabels = !BoxLayout::rowOutlets(geo.node->kind);
    for (int r = 0; r < rows; ++r) {
        float y = BoxLayout::header + 3 + float(r) * BoxLayout::portRow + BoxLayout::portRow / 2;
        if (r < int(p.ins.size())) g.textLeft(p.ins[size_t(r)], { 10, y }, 9, Theme::dim());
        if (outLabels && r < int(p.outs.size())) g.textRight(p.outs[size_t(r)], { geo.w - 10, y }, 9, Theme::dim());
    }
}

Rect meterRect(const BoxGeo& geo, int r) {
    auto p = BoxLayout::ports(*geo.node, *geo.spec, geo.hw);
    float y = BoxLayout::header + 3 + float(r) * BoxLayout::portRow + BoxLayout::portRow / 2;
    float l = r < int(p.ins.size()) ? textWidth(p.ins[size_t(r)], 9) : 0;
    float rr = r < int(p.outs.size()) && !BoxLayout::rowOutlets(geo.node->kind) ? textWidth(p.outs[size_t(r)], 9) : 0;
    float x0 = 10 + l + 6, x1 = geo.w - 10 - rr - 6;
    return Rect(x0, y - 2, std::max(x1 - x0, 0.0f), 4);
}

static void collapsedRows(GC& g, const BoxGeo& geo) {
    auto left = BoxLayout::collapsedLeft(*geo.node, *geo.spec), right = BoxLayout::collapsedRight(*geo.node, *geo.spec);
    for (int r = 0; r < int(std::max(left.size(), right.size())); ++r) {
        float y = BoxLayout::header + 3 + float(r) * BoxLayout::portRow + BoxLayout::portRow / 2;
        if (r < int(left.size())) g.textLeft(BoxLayout::inletName(*geo.spec, left[size_t(r)]), { 10, y }, 9, Theme::dim());
        if (r < int(right.size())) g.textRight(juce::String::fromUTF8(geo.spec->outputs[size_t(right[size_t(r)])].c_str()), { geo.w - 10, y }, 9, Theme::dim());
    }
}

void trigger(GC& g, Rect r, const ParamSpec& ps) {
    g.fillRounded(r, 2, Theme::row());
    g.strokeRounded(r.reduced(0.5f), 2, Theme::border(), 1);
    g.text(juce::String::fromUTF8(ps.name.c_str()), r.getCentre(), 9, ps.key == "rec" ? Theme::rec : Theme::text(), true);
}

void paramRow(GC& g, Rect r, const ParamSpec& ps, float value) {
    float fill = ps.normalized(value);
    juce::String text = juce::String::fromUTF8(ps.display(value).c_str());
    bool recOn = false;
    float trailing = 0;
    if (ps.kind == ParamKind::toggle) { fill = value > 0.5f ? 1.0f : 0.0f; text = value > 0.5f ? "on" : "off"; recOn = value > 0.5f && ps.key == "rec"; }
    else if (ps.kind == ParamKind::choice) trailing = 16;
    g.fill(r, Theme::row());
    g.fill(Rect(r.getX(), r.getY(), r.getWidth() * std::clamp(fill, 0.0f, 1.0f), r.getHeight()), recOn ? Theme::rec.withMultipliedAlpha(0.5f) : Theme::fill());
    float valueX = r.getRight() - 6 - trailing;
    float vw = textWidth(text, 11);
    auto name = fitText(juce::String::fromUTF8(ps.name.c_str()), 11, std::max(valueX - vw - 4 - (r.getX() + 6), 8.0f));
    g.textLeft(name, { r.getX() + 6, r.getCentreY() }, 11, Theme::dim());
    g.textRight(text, { valueX, r.getCentreY() }, 11, recOn ? Theme::rec : Theme::text());
    if (ps.kind == ParamKind::choice) g.text(juce::String::fromUTF8("\xe2\x96\xbe"), { r.getRight() - 9, r.getCentreY() }, 11, Theme::dim());
}

void liveRow(GC& g, Pt size, const ParamSpec& ps, float base, float live, bool automated) {
    float n = ps.normalized(live);
    g.fill(Rect(0, 0, size.x, size.y), Theme::row());
    float trailing = 0, fill = ps.normalized(base);
    bool recOn = false;
    if (ps.kind == ParamKind::toggle) { fill = base > 0.5f ? 1.0f : 0.0f; recOn = base > 0.5f && ps.key == "rec"; }
    else if (ps.kind == ParamKind::choice) trailing = 16;
    if (automated) {
        g.fill(Rect(0, 0, size.x * n, size.y), Theme::fill());
        g.fill(Rect(0, 0, 2, size.y), Theme::rec);
    } else {
        g.fill(Rect(0, 0, size.x * fill, size.y), recOn ? Theme::rec.withMultipliedAlpha(0.5f) : Theme::fill());
        g.fill(Rect(std::max(0.0f, size.x * n - 1), 0, 2, size.y), Theme::text());
    }
    juce::String text = juce::String::fromUTF8(ps.display(live).c_str());
    float vw = textWidth(text, 11);
    auto name = fitText(juce::String::fromUTF8(ps.name.c_str()), 11, std::max(size.x - 6 - trailing - vw - 4 - 6, 8.0f));
    g.textLeft(name, { 6, size.y / 2 }, 11, Theme::dim());
    g.textRight(text, { size.x - 6 - trailing, size.y / 2 }, 11, Theme::text());
    if (ps.kind == ParamKind::choice) g.text(juce::String::fromUTF8("\xe2\x96\xbe"), { size.x - 9, size.y / 2 }, 11, Theme::dim());
}

static void portsDraw(GC& g, const BoxGeo& geo, AppModel& m) {
    for (auto& p : geo.ports()) {
        bool connected = m.isPortConnected(geo.node->id, p.port, p.output);
        Rect r(p.center.x - p.size / 2, p.center.y - p.size / 2, p.size, p.size);
        g.fillEllipse(r, p.output || connected ? Theme::text() : Theme::box());
        g.strokeEllipse(r.reduced(0.5f), p.port >= kParamPortBase && !connected ? Theme::faint() : Theme::text(), 1);
    }
}

void paint(GC& g, const BoxGeo& geo, AppModel& m, bool selected, bool dropTarget, const std::set<int>& liveRows, NativeDisplay* display) {
    auto& node = *geo.node; auto& spec = *geo.spec;
    Rect box(0, 0, geo.w, geo.h);
    g.fillRounded(box, 3, Theme::box());
    g.strokeRounded(box.reduced(0.5f), 3, selected ? Theme::selected() : Theme::border(), 1);
    header(g, geo, m);
    if (!node.collapsed) g.fill(Rect(0, BoxLayout::header - 1, geo.w, 1), Theme::border().withMultipliedAlpha(0.6f));
    g.dimmed(node.bypassed ? 0.35f : 1.0f, [&] {
        if (node.collapsed) collapsedRows(g, geo);
        else {
            portRowsDraw(g, geo);
            for (auto& [i, r] : geo.triggers()) trigger(g, r, spec.params[size_t(i)]);
            for (auto& [i, r] : geo.rows()) if (!liveRows.count(i)) paramRow(g, r, spec.params[size_t(i)], m.value(node, i, spec));
        }
        if (auto d = geo.display(); d && display) display->paintStatic(g, *d);
    });
    portsDraw(g, geo, m);
    if (auto r = geo.grip()) g.fillEllipse(Rect(r->getRight() - 7, r->getBottom() - 7, 3, 3), Theme::dim());
    if (dropTarget) {
        g.fillRounded(box, 3, Theme::text().withMultipliedAlpha(0.06f));
        g.strokeRounded(box.reduced(1), 3, Theme::text(), 2);
    }
}

void paintText(GC& g, const PatchNode& n, Pt size, bool selected, bool editing) {
    if (!editing) {
        auto t = n.text.value_or("");
        auto lines = juce::StringArray::fromLines(t.isEmpty() ? juce::String("text") : t);
        for (int k = 0; k < lines.size(); ++k) g.textLeft(lines[k], { 5, 3 + float(k) * 15 + 7.5f }, 12, t.isEmpty() ? Theme::faint() : Theme::text());
    }
    if (selected || editing) {
        juce::Path p; p.addRectangle(Rect(0, 0, size.x, size.y).reduced(0.5f));
        g.stroke(p, Theme::dim().withMultipliedAlpha(0.6f), 0.75f, false, { 3, 2 });
    }
}

void paintGroup(GC& g, const PatchGroup& group, Pt size, bool selected, bool renaming) {
    Rect r(0, 0, size.x, size.y);
    g.fillRounded(r, 6, Theme::text().withMultipliedAlpha(Theme::boxIsLight() ? 0.07f : 0.09f));
    g.strokeRounded(r.reduced(0.5f), 6, selected ? Theme::text().withMultipliedAlpha(0.6f) : Theme::text().withMultipliedAlpha(0.18f), 1);
    if (!renaming) g.textLeft(group.name, { 10, 14 }, 11, Theme::dim(), true);
}

}

} // namespace pn
