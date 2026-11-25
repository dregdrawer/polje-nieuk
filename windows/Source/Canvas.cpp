#include "Canvas.h"

namespace pn {

static double now() { return juce::Time::getMillisecondCounterHiRes() * 0.001; }
static juce::String u8(const char* s) { return juce::String::fromUTF8(s); }
static juce::String nameOf(const std::string& s) { return juce::String::fromUTF8(s.c_str()); }

Canvas::Canvas(AppModel& m) : model(m) {
    setWantsKeyboardFocus(true);
    setOpaque(true);
    model.listeners.push_back([this] { sync(); });
    model.onViewport = [this] { viewportChanged(); };
    model.onDragMoved = [this] { dragged(); };
    drawnScale = model.viewScale;
    sync();
    startTimerHz(60);
}

Canvas::~Canvas() { stopTimer(); }

float Canvas::pixelScale() const {
    // device pixels per point: 2 on a Retina Mac, the display's scaling (1.25, 1.5 …) on Windows
    auto& displays = juce::Desktop::getInstance().getDisplays();
    const juce::Displays::Display* d = isShowing() ? displays.getDisplayForRect(getScreenBounds()) : displays.getPrimaryDisplay();
    return float(d ? d->scale : 1.0) * float(juce::Desktop::getInstance().getGlobalScaleFactor());
}

void Canvas::resized() {
    model.viewSize = { float(getWidth()), float(getHeight()) };
    if (finder) closeFinder();
}

// ---------------------------------------------------------------- keeping up with the patch

int64_t Canvas::keyFor(const PatchNode& n, const std::vector<const PatchCable*>& cables, const std::vector<const PatchNode*>& related) {
    int64_t h = LiveSig::patch(n);
    LiveSig::mix(h, int64_t(n.x * 8)); LiveSig::mix(h, int64_t(n.y * 8));
    LiveSig::mix(h, n.bypassed ? 1 : 0); LiveSig::mix(h, n.text ? n.text->hashCode64() : 7);
    LiveSig::mix(h, int64_t(n.z.value_or(-1) * 8));
    LiveSig::mix(h, n.highlight ? n.highlight->hashCode64() : 3);
    { auto tc = model.typeColour(n); LiveSig::mix(h, tc ? tc->hashCode64() : 5); }
    for (auto* c : cables) { LiveSig::mix(h, c->id.hashCode64()); LiveSig::mix(h, c->fromPort * 7919 + c->toPort); }
    for (auto* r : related) { LiveSig::mix(h, LiveSig::patch(*r)); LiveSig::mix(h, r->id.hashCode64()); }
    LiveSig::mix(h, int64_t(model.patch.nodes.size()));
    LiveSig::mix(h, model.selectedNodes.count(n.id) ? 1 : 0);
    LiveSig::mix(h, model.isRunning ? 1 : 0);
    LiveSig::mix(h, model.hw.inputs); LiveSig::mix(h, model.hw.outputs);
    LiveSig::mix(h, model.transport);
    LiveSig::mix(h, model.autoRecording.count(n.id) ? 1 : 0);
    LiveSig::mix(h, CustomColours::version * 2 + (Theme::light ? 1 : 0));
    if (n.kind == "rack") {
        if (auto* r = dynamic_cast<RackNode*>(model.node(n.id))) for (auto& s : r->padNames) LiveSig::mix(h, int64_t(std::hash<std::string>()(s)));
        if (model.loadingPads.count(n.id)) for (int k : model.loadingPads[n.id]) LiveSig::mix(h, k + 100);
    }
    return h;
}

void Canvas::sync() {
    auto& p = model.patch;
    std::map<juce::String, std::vector<const PatchCable*>> byNode;
    for (auto& c : p.cables) { byNode[c.fromNode].push_back(&c); if (c.toNode != c.fromNode) byNode[c.toNode].push_back(&c); }
    std::set<juce::String> alive;
    for (auto& n : p.nodes) alive.insert(n.id);
    for (auto it = items.begin(); it != items.end();) {
        if (!alive.count(it->first)) {
            if (editingID == it->first) { editor.reset(); editingID = {}; }
            if (press && press->item == it->second.get()) press.reset();
            if (dropItem == it->second.get()) dropItem = nullptr;
            queue.erase(std::remove(queue.begin(), queue.end(), it->second.get()), queue.end());
            it = items.erase(it);
        } else ++it;
    }
    for (auto& n : p.nodes) {
        auto& slot = items[n.id];
        if (!slot) { slot = std::make_unique<Item>(); slot->id = n.id; slot->kind = n.kind == "text" ? Item::text : Item::module; }
        auto& it = *slot;
        std::vector<const PatchNode*> related;
        if (n.kind == "slider" || n.kind == "knob")
            for (auto* c : byNode[n.id]) if (c->fromNode == n.id) if (auto* t = model.nodeFor(c->toNode)) related.push_back(t);
        int64_t k = keyFor(n, byNode[n.id], related);
        if (!it.hasKey || it.key != k) { it.key = k; it.hasKey = true; it.node = n; update(it); }
    }
    order.clear();
    for (auto& n : p.nodes) order.push_back(n.id);
    // groups
    std::set<juce::String> gids;
    for (auto& g : p.groups) gids.insert(g.id);
    for (auto it = groupItems.begin(); it != groupItems.end();) {
        if (!gids.count(it->first)) { queue.erase(std::remove(queue.begin(), queue.end(), it->second.get()), queue.end()); it = groupItems.erase(it); }
        else ++it;
    }
    for (auto& g : p.groups) {
        auto& slot = groupItems[g.id];
        if (!slot) { slot = std::make_unique<Item>(); slot->id = g.id; slot->kind = Item::grp; }
        auto& it = *slot;
        auto r = model.groupRect(g);
        bool sel = !g.members.empty();
        for (auto& m : g.members) if (!model.selectedNodes.count(m)) sel = false;
        int64_t h = g.name.hashCode64();
        if (r) { LiveSig::mix(h, int64_t(r->getX() * 8)); LiveSig::mix(h, int64_t(r->getY() * 8)); LiveSig::mix(h, int64_t(r->getWidth() * 8)); LiveSig::mix(h, int64_t(r->getHeight() * 8)); }
        LiveSig::mix(h, sel ? 1 : 0); LiveSig::mix(h, CustomColours::version * 2 + (Theme::light ? 1 : 0));
        if (!it.hasKey || it.key != h) {
            it.key = h; it.hasKey = true; it.group = g; it.selected = sel; it.rect = r.value_or(Rect());
            it.dirty = true;
        }
    }
    // a note being written in, now deselected: done
    if (editingID.isNotEmpty() && !editingGroup && items.count(editingID) && !model.selectedNodes.count(editingID)) finishEditing();
    if (finder && !model.finderAt) closeFinder();
    if (!finder && model.finderAt) openFinder(*model.finderAt);
    cablesDirty = true;
    repaint();
}

void Canvas::update(Item& it) {
    auto& n = it.node;
    it.selected = model.selectedNodes.count(n.id) > 0;
    it.dirty = true;
    if (it.kind == Item::text) {
        auto s = BoxLayout::textSize(n);
        it.rect = Rect(float(n.x), float(n.y), s.x, s.y);
        if (!n.text && editingID.isEmpty()) {
            auto id = n.id;
            juce::MessageManager::callAsync([this, id] { if (items.count(id)) startEditing(id, false); });
        }
        return;
    }
    it.spec = Registry::spec(n.kind);
    if (!it.spec) return;
    it.geo = std::make_unique<BoxGeo>(it.node, *it.spec, model.hw, it.selected, model);
    it.rect = Rect(float(n.x), float(n.y), it.geo->w, it.geo->h);
    if (!it.display) it.display = NativeDisplay::make(model, n, *it.spec);
    if (it.display) it.display->node = n;
    it.liveRows.clear();
    for (auto& [i, r] : it.geo->rows()) if (model.isModulated(n.id, i) || model.isAutomated(n, i, *it.spec)) it.liveRows.insert(i);
    auto list = partsFor(it);
    std::vector<Part> parts;
    for (auto& lp : list) {
        Part p; p.lp = lp;
        for (auto& old : it.parts) if (old.lp.key == lp.key) p.last = old.last;
        p.phase = int(std::hash<std::string>()(lp.key + it.id.toStdString()) % 997);
        parts.push_back(std::move(p));
    }
    it.parts = std::move(parts);
}

std::vector<LivePart> Canvas::partsFor(Item& it) {
    auto& geo = *it.geo;
    auto& n = it.node;
    auto* spec = it.spec;
    auto id = n.id;
    auto* m = &model;
    std::vector<LivePart> list;
    if (auto d = geo.display(); d && it.display) { auto ps = it.display->parts(*d); list.insert(list.end(), ps.begin(), ps.end()); }
    if (!n.collapsed) {
        for (auto& [i, r] : geo.rows()) {
            if (!it.liveRows.count(i)) continue;
            auto ps = spec->params[size_t(i)];
            bool automated = model.isAutomated(n, i, *spec);
            float base = model.value(n, i, *spec);
            int idx = i;
            list.push_back(LivePart { "row" + std::to_string(i), r, 2, false, n.bypassed, [m, id, ps, idx] {
                auto* d = m->node(id);
                if (!d) return int64_t(0);
                int64_t h = LiveSig::q(ps.normalized(d->params[size_t(idx)]), 240);
                LiveSig::mix(h, int64_t(std::hash<std::string>()(ps.display(d->params[size_t(idx)]))));
                return h;
            }, [m, id, ps, idx, base, automated](GC& g, Pt size) {
                auto* d = m->node(id);
                if (!d) return;
                BoxPainter::liveRow(g, size, ps, base, d->params[size_t(idx)], automated);
            } });
        }
        auto p = BoxLayout::ports(n, *spec, geo.hw);
        if (n.kind == "in" || n.kind == "out" || n.kind == "mix") {
            int rows = n.kind == "mix" ? int(p.ins.size()) : BoxLayout::portRows(n, *spec, geo.hw);
            for (int r = 0; r < rows; ++r) {
                int ch = n.kind == "mix" ? MixerLayout::channelMeterBase + r : r;
                auto mr = BoxPainter::meterRect(geo, r);
                if (mr.getWidth() <= 4) continue;
                int c = std::min(ch, kReadoutCount - 1);
                list.push_back(LivePart { "meter" + std::to_string(r), mr, 2, false, n.bypassed, [m, id, c] {
                    auto* d = m->node(id); return LiveSig::q(d ? d->readouts[size_t(c)] : 0.0f, 60);
                }, [m, id, c](GC& g, Pt size) { auto* d = m->node(id); drawMeter(g, Rect(0, 0, size.x, size.y), d ? d->readouts[size_t(c)] : 0.0f); } });
            }
        }
    }
    std::vector<int> outs;
    if (n.collapsed) outs = BoxLayout::collapsedRight(n, *spec);
    else { auto p = BoxLayout::ports(n, *spec, geo.hw); for (int k = 0; k < int(p.outs.size()); ++k) if (!BoxLayout::hasLaneOutlets(n.kind) || k < 2) outs.push_back(k); }   // rack pads light up themselves
    if (model.isRunning && !outs.empty() && n.kind != "in") {
        std::vector<float> ys; std::vector<juce::String> names; std::vector<bool> gate;
        for (int k : outs) {
            ys.push_back(BoxLayout::outlet(n, *spec, geo.hw, k).y - float(n.y));
            auto nm = k < int(spec->outputs.size()) ? nameOf(spec->outputs[size_t(k)]) : juce::String();
            names.push_back(nm);
            gate.push_back(n.kind == "div" || nm == "gate" || nm == "pulse" || nm == "trig" || nm == "t1" || nm == "t2" || nm == "t3");
        }
        float w = geo.w;
        bool rowOutlets = BoxLayout::rowOutlets(n.kind) && !n.collapsed;
        int nOut = int(spec->outputs.size());
        list.push_back(LivePart { "dots", Rect(0, 0, w, geo.h), 2, false, false, [m, id, outs, gate, nOut] {
            auto* d = m->node(id);
            if (!d) return int64_t(0);
            int64_t h = 0;
            for (size_t j = 0; j < outs.size(); ++j) {
                int k = outs[j];
                if (k >= nOut) continue;
                float lv = d->outLevel[size_t(k)];
                LiveSig::mix(h, gate[j] ? (lv * 4 > 0.1f ? 1 : 0) : LiveSig::q(std::clamp(lv * 4, 0.0f, 1.0f), 4));
            }
            return h;
        }, [m, id, outs, gate, ys, names, w, rowOutlets, nOut](GC& g, Pt) {
            auto* d = m->node(id);
            if (!d) return;
            for (size_t j = 0; j < outs.size(); ++j) {
                int k = outs[j];
                if (k >= nOut) continue;
                float lv = d->outLevel[size_t(k)];
                float a = !std::isfinite(lv) ? 0 : gate[j] ? (lv * 4 > 0.1f ? 1.0f : 0.0f) : std::round(std::clamp(lv * 4, 0.0f, 1.0f) * 4) / 4;
                float x = rowOutlets ? 8 + 8 + 5 * 5.45f + 14 : w - 10 - textWidth(names[j], 9) - 8;
                Rect r(x - 3, ys[j] - 3, 6, 6);
                if (a > 0.02f) g.fillEllipse(r, Theme::text().withMultipliedAlpha(0.35f + 0.65f * a));
                else g.strokeEllipse(r.reduced(0.5f), Theme::dim().withMultipliedAlpha(0.7f), 1);
            }
        } });
    }
    return list;
}

// ---------------------------------------------------------------- drawing

Pt Canvas::dragShift(const juce::String& id) const {
    auto& ds = model.dragState;
    if (!ds.ids.count(id)) return {};
    auto it = items.find(id);
    if (it == items.end()) return ds.delta;
    auto& n = it->second->node;
    return { float(std::max(-2000.0, std::round(n.x + ds.delta.x)) - n.x), float(std::max(-2000.0, std::round(n.y + ds.delta.y)) - n.y) };
}

Rect Canvas::screenRect(const Item& it) const {
    float s = model.viewScale;
    Pt d = it.kind == Item::grp ? Pt() : dragShift(it.id);
    if (it.kind == Item::grp) {
        bool all = !it.group.members.empty();
        for (auto& mm : it.group.members) if (!model.dragState.ids.count(mm)) all = false;
        if (all) d = model.dragState.delta;
    }
    return Rect((it.rect.getX() + d.x) * s + model.viewOffset.x, (it.rect.getY() + d.y) * s + model.viewOffset.y, it.rect.getWidth() * s, it.rect.getHeight() * s);
}

void Canvas::renderCache(Item& it, float s, float px) {
    float sp = s * px;
    float mx = it.margin();
    it.marginPx = std::ceil(mx * sp);
    float ex = it.rect.getX() * sp, ey = it.rect.getY() * sp;
    it.fracPx = { ex - std::floor(ex), ey - std::floor(ey) };
    int w = int(std::ceil(it.rect.getWidth() * sp + it.fracPx.x)) + 1 + 2 * int(it.marginPx);
    int h = int(std::ceil(it.rect.getHeight() * sp + it.fracPx.y)) + 1 + 2 * int(it.marginPx);
    if (w <= 0 || h <= 0 || w > 16000 || h > 16000) { it.cache = {}; return; }
    it.cache = juce::Image(juce::Image::ARGB, w, h, true);
    {
        juce::Graphics ig(it.cache);
        ig.addTransform(juce::AffineTransform::scale(sp).translated(it.marginPx + it.fracPx.x, it.marginPx + it.fracPx.y));
        GC g(ig);
        switch (it.kind) {
            case Item::module:
                if (it.geo) BoxPainter::paint(g, *it.geo, model, it.selected, it.dropTarget, it.liveRows, it.display.get());
                break;
            case Item::text:
                BoxPainter::paintText(g, it.node, { it.rect.getWidth(), it.rect.getHeight() }, it.selected, it.editing);
                break;
            case Item::grp:
                BoxPainter::paintGroup(g, it.group, { it.rect.getWidth(), it.rect.getHeight() }, it.selected, it.editing);
                break;
        }
    }
    it.cacheScale = s; it.cachePx = px; it.dirty = false;
}

void Canvas::drawItem(juce::Graphics& g, Item& it, float s, Pt o, float px) {
    if (it.dirty || it.cache.isNull() || it.cachePx != px || (it.cacheScale != s && it.cacheScale <= 0)) {
        // never drawn (or its settings changed): draw it now at this zoom
        if (it.dirty || it.cache.isNull() || it.cachePx != px) renderCache(it, s, px);
    }
    if (it.cache.isNull()) return;
    Pt d = it.kind == Item::grp ? Pt() : dragShift(it.id);
    if (it.kind == Item::grp) {
        bool all = !it.group.members.empty();
        for (auto& mm : it.group.members) if (!model.dragState.ids.count(mm)) all = false;
        if (all) d = model.dragState.delta;
    }
    float cs = it.cacheScale;
    float k = s / cs;
    // the bitmap's corner in device pixels at the zoom it was drawn at (whole pixels: sharp)
    float px0 = std::floor(it.rect.getX() * cs * px) - it.marginPx, py0 = std::floor(it.rect.getY() * cs * px) - it.marginPx;
    float ox = std::round(o.x * px) / px + d.x * s, oy = std::round(o.y * px) / px + d.y * s;
    if (k == 1) { ox = std::round(ox * px) / px; oy = std::round(oy * px) / px; }
    auto t = juce::AffineTransform::scale(1 / px).translated(px0 / px, py0 / px).scaled(k).translated(ox, oy);
    g.setOpacity(1.0f);
    g.drawImageTransformed(it.cache, t, false);
}

void Canvas::drawParts(juce::Graphics& g, Item& it, float s, Pt o) {
    if (it.parts.empty()) return;
    Pt d = dragShift(it.id);
    float bx = (it.rect.getX() + d.x) * s + o.x, by = (it.rect.getY() + d.y) * s + o.y;
    auto clip = g.getClipBounds().toFloat();
    for (auto& p : it.parts) {
        Rect sr(bx + p.lp.rect.getX() * s, by + p.lp.rect.getY() * s, p.lp.rect.getWidth() * s, p.lp.rect.getHeight() * s);
        if (!sr.intersects(clip)) continue;
        juce::Graphics::ScopedSaveState save(g);
        g.reduceClipRegion(sr.getSmallestIntegerContainer());
        g.addTransform(juce::AffineTransform::scale(s).translated(sr.getX(), sr.getY()));
        GC gc(g);
        gc.dimmed(p.lp.dimmed ? 0.35f : 1.0f, [&] { p.lp.draw(gc, { p.lp.rect.getWidth(), p.lp.rect.getHeight() }); });
    }
}

std::optional<std::pair<Pt, Pt>> Canvas::cableEnds(const PatchCable& c) {
    auto* a = model.nodeFor(c.fromNode); auto* b = model.nodeFor(c.toNode);
    if (!a || !b) return std::nullopt;
    auto* sa = Registry::spec(a->kind); auto* sb = Registry::spec(b->kind);
    if (!sa || !sb || c.fromPort >= int(BoxLayout::ports(*a, *sa, model.hw).outs.size())) return std::nullopt;
    auto dest = BoxLayout::destination(*b, *sb, model.hw, c.toPort);
    if (!dest) return std::nullopt;
    Pt da = dragShift(a->id), db = dragShift(b->id);
    return std::make_pair(model.toScreen(BoxLayout::outlet(*a, *sa, model.hw, c.fromPort) + da), model.toScreen(*dest + db));
}

void Canvas::paint(juce::Graphics& g) {
    float s = model.viewScale, px = pixelScale();
    Pt o = model.viewOffset;
    auto clip = g.getClipBounds().toFloat();
    g.fillAll(Theme::bg());
    // the background picture: scaled once to fill the window (cropped, centred), then just drawn
    if (auto& pic = BackgroundPicture::image(); pic.isValid()) {
        int w = getWidth(), h = getHeight();
        if (bgImage.isNull() || bgW != w || bgH != h || bgPx != px || bgVersion != CustomColours::version) {
            bgW = w; bgH = h; bgPx = px; bgVersion = CustomColours::version;
            int iw = std::max(1, int(std::ceil(float(w) * px))), ih = std::max(1, int(std::ceil(float(h) * px)));
            bgImage = juce::Image(juce::Image::RGB, iw, ih, true);
            juce::Graphics ig(bgImage);
            ig.setImageResamplingQuality(juce::Graphics::highResamplingQuality);
            ig.drawImageWithin(pic, 0, 0, iw, ih, juce::RectanglePlacement::centred | juce::RectanglePlacement::fillDestination);
        }
        g.drawImageTransformed(bgImage, juce::AffineTransform::scale(1 / px));
    } else bgImage = {};
    // dot grid: zoomed far out every 4th dot (then every 16th), so it stays visible but calm. Drawn once per zoom /
    // window size into a picture one step bigger than the window, then only slid along while panning.
    {
        float step = 24 * s;
        while (step < 8) step *= 4;
        auto col = Theme::gridDot();
        int w = getWidth() + int(std::ceil(step)) + 2, h = getHeight() + int(std::ceil(step)) + 2;
        if (gridImage.isNull() || gridStep != step || gridPx != px || gridColour != col || gridW != w || gridH != h) {
            gridStep = step; gridPx = px; gridColour = col; gridW = w; gridH = h;
            gridImage = juce::Image(juce::Image::ARGB, int(std::ceil(float(w) * px)), int(std::ceil(float(h) * px)), true);
            juce::Graphics ig(gridImage);
            ig.addTransform(juce::AffineTransform::scale(px));
            ig.setColour(col);
            juce::RectangleList<float> dots;
            for (float y = step; y < float(h); y += step)
                for (float x = step; x < float(w); x += step) dots.addWithoutMerging(Rect(x - 1, y - 1, 2, 2));
            ig.fillRectList(dots);
        }
        float x0 = std::fmod(o.x, step), y0 = std::fmod(o.y, step);
        if (x0 > 0) x0 -= step;
        if (y0 > 0) y0 -= step;
        x0 = std::round((x0 - step) * px) / px; y0 = std::round((y0 - step) * px) / px;
        g.drawImageTransformed(gridImage, juce::AffineTransform::scale(1 / px).translated(x0, y0));
    }
    auto visible = [&](const Item& it) { return screenRect(it).expanded(it.margin() * s + 2).intersects(clip); };
    for (auto& [id, it] : groupItems) if (visible(*it)) drawItem(g, *it, s, o, px);
    // cables: the curves are kept in canvas points and only worked out again when the patch or a drag changes;
    // drawn through the view's transform, with the line width divided by the zoom so they stay one width on screen
    if (!model.hideCables) {
        if (cablesDirty) rebuildCables();
        juce::Graphics::ScopedSaveState save(g);
        g.addTransform(juce::AffineTransform::scale(s).translated(o.x, o.y));
        juce::PathStrokeType st(1.0f / s, juce::PathStrokeType::curved, juce::PathStrokeType::rounded);
        g.setColour(Theme::cable());
        g.strokePath(cablePlain, st);
        if (!cableDashed.isEmpty()) {
            if (dashedFor != s) {
                float dash[] = { 4 / s, 3 / s };
                cableDashedStroke.clear();
                st.createDashedStroke(cableDashedStroke, cableDashed, dash, 2);
                dashedFor = s;
            }
            g.fillPath(cableDashedStroke);
        }
        g.setColour(Theme::selected());
        g.strokePath(cableSel, juce::PathStrokeType(2.0f / s, juce::PathStrokeType::curved, juce::PathStrokeType::rounded));
    }
    for (auto& id : order) {
        auto it = items.find(id);
        if (it == items.end() || !visible(*it->second)) continue;
        drawItem(g, *it->second, s, o, px);
        drawParts(g, *it->second, s, o);
    }
    // the cable being dragged out of a port
    if (model.pendingCable) {
        auto& pc = *model.pendingCable;
        if (auto* n = model.nodeFor(pc.node)) if (auto* sp = Registry::spec(n->kind)) {
            std::optional<Pt> anchor = pc.fromOutput ? std::optional<Pt>(BoxLayout::outlet(*n, *sp, model.hw, pc.port)) : BoxLayout::destination(*n, *sp, model.hw, pc.port);
            if (anchor) {
                Pt start = model.toScreen(*anchor);
                juce::Path p;
                if (pc.fromOutput) addCable(p, start, pc.point, s); else addCable(p, pc.point, start, s);
                GC gc(g);
                gc.stroke(p, Theme::text(), 1, true, { 5, 4 });
            }
        }
    }
    if (marquee) {
        g.setColour(Theme::text().withAlpha(0.06f));
        g.fillRect(*marquee);
        juce::Path p; p.addRectangle(*marquee);
        GC gc(g); gc.stroke(p, Theme::text().withMultipliedAlpha(0.7f), 1, false, { 4, 3 });
    }
    // the selected cable's delete button
    deleteButton = {};
    if (model.selectedCable.isNotEmpty() && !model.hideCables) {
        for (auto& c : model.patch.cables) {
            if (c.id != model.selectedCable) continue;
            if (auto e = cableEnds(c)) {
                juce::Path p; addCable(p, e->first, e->second, s);
                Pt mid = p.getPointAlongPath(p.getLength() * 0.5f);
                const float size = 24;
                Rect b(mid.x - size / 2, mid.y - size / 2, size, size);
                deleteButton = b.getSmallestIntegerContainer();
                g.setColour(Theme::selected());
                g.fillEllipse(b);
                GC gc(g); Icons::xmark(gc, mid, 3.5f, Theme::inverse());
            }
        }
    }
    // the port under the pointer, with its name — and while a cable is dragged, the port it would connect to
    auto& pc = model.pendingCable;
    std::optional<Pt> at = pc ? std::optional<Pt>(pc->point) : (press ? std::nullopt : hover);
    if (at && !model.finderAt) {
        float reach = pc ? 24.0f : 22.0f;            // 24 = what finishCable connects to
        std::optional<std::tuple<Pt, juce::String, bool>> best; float bd = INFINITY;
        int top = model.topBox(model.toCanvas(*at));   // only the box on top answers where boxes overlap
        for (int k = 0; k < int(model.patch.nodes.size()); ++k) {
            auto& n = model.patch.nodes[size_t(k)];
            if (top >= 0 && k < top) continue;
            auto* sp = Registry::spec(n.kind);
            if (!sp) continue;
            if (pc && n.id == pc->node) continue;
            Rect r(float(n.x) * s + o.x, float(n.y) * s + o.y, BoxLayout::width(n) * s, BoxLayout::height(n, *sp, model.hw) * s);
            if (!r.expanded(40).contains(*at)) continue;
            for (auto& vp : BoxLayout::visiblePorts(n, *sp, model.hw)) {
                if (pc && vp.output == pc->fromOutput) continue;
                Pt q = model.toScreen(vp.point);
                float dd = q.getDistanceFrom(*at);
                auto name = vp.output ? model.outletName(n, vp.port).value_or(vp.name) : vp.name;   // a pad outlet: the sample's name
                if (dd < reach && dd < bd) { bd = dd; best = std::make_tuple(q, name, vp.output); }
            }
        }
        if (best) {
            auto [pt, name, isOut] = *best;
            g.setColour(Theme::text());
            g.drawEllipse(Rect(pt.x - 9, pt.y - 9, 18, 18), 1.5f);
            float tw = textWidth(name, 11), th = 14;
            float x = isOut ? pt.x + 14 : pt.x - 14 - tw;
            Rect box(x - 5, pt.y - th / 2 - 3, tw + 10, th + 6);
            g.fillRoundedRectangle(box, 3);
            GC gc(g); gc.text(name, box.getCentre(), 11, Theme::inverse());
        }
    }
    // the patch map (bottom right)
    if (model.showMap) {
        auto mr = mapRect(); auto e = mapExtent();
        float sc = std::min(mr.getWidth() / std::max(e.getWidth(), 1.0f), mr.getHeight() / std::max(e.getHeight(), 1.0f));
        Pt o { mr.getX() + (mr.getWidth() - e.getWidth() * sc) / 2, mr.getY() + (mr.getHeight() - e.getHeight() * sc) / 2 };
        auto map = [&](Rect r) { return Rect(o.x + (r.getX() - e.getX()) * sc, o.y + (r.getY() - e.getY()) * sc, r.getWidth() * sc, r.getHeight() * sc); };
        g.setColour(Theme::border()); g.drawRoundedRectangle(mr, 3, 1);       // see-through: just the frame
        for (auto& n : model.patch.nodes) {
            auto* sp = Registry::spec(n.kind);
            if (!sp) continue;
            auto r = map(Rect(float(n.x), float(n.y), BoxLayout::width(n), BoxLayout::height(n, *sp, model.hw)));
            auto hex = n.highlight ? n.highlight : model.typeColour(n);
            g.setColour(hex && hex->length() == 7 ? juce::Colour::fromString("ff" + hex->substring(1))
                                                  : Theme::text().withMultipliedAlpha(model.selectedNodes.count(n.id) ? 0.7f : 0.35f));
            g.fillRect(r.reduced(0.25f));
        }
        auto a = model.toCanvas({ 0, 0 }), b = model.toCanvas({ float(getWidth()), float(getHeight()) });
        g.setColour(Theme::text()); g.drawRect(map(Rect(a, b)), 1.0f);
    }
    // help panel (bottom left)
    if (model.helpMode) {
        juce::String title = model.helpTopics.empty() ? juce::String("help") : model.helpTopics.back().title;
        juce::String body = model.helpTopics.empty() ? u8("Point at anything \xe2\x80\x94 a box, an inlet or outlet, a parameter, a button up top \xe2\x80\x94 to see what it does.") : model.helpTopics.back().body;
        juce::AttributedString as;
        as.append(body, Theme::mono(9), Theme::dim());
        as.setWordWrap(juce::AttributedString::byWord);
        juce::TextLayout tl; tl.createLayout(as, 300);
        float h = tl.getHeight() + 34;
        Rect panel(12, float(getHeight()) - 12 - h, 320, h);
        juce::DropShadow(juce::Colours::black.withAlpha(Theme::light ? 0.18f : 0.35f), 8, {}).drawForRectangle(g, panel.getSmallestIntegerContainer());
        g.setColour(Theme::box()); g.fillRoundedRectangle(panel, 3);
        g.setColour(Theme::border()); g.drawRoundedRectangle(panel.reduced(0.5f), 3, 1);
        GC gc(g);
        gc.textLeft(title, { panel.getX() + 10, panel.getY() + 16 }, 11, Theme::text(), true);
        Icons::xmark(gc, { panel.getRight() - 14, panel.getY() + 16 }, 3);
        tl.draw(g, Rect(panel.getX() + 10, panel.getY() + 26, 300, tl.getHeight()));
    }
}

// ---------------------------------------------------------------- ticking: live parts, zoom settling, long presses

void Canvas::timerCallback() {
    ++frame;
    double t = now();
    float s = model.viewScale;
    // a zoom has paused: draw everything sharp again, a few each frame, nearest the middle first
    if (settleAt > 0 && t >= settleAt && !model.isZooming) {
        settleAt = 0;
        drawnScale = s;
        queue.clear();
        for (auto* it : allItems()) if (it->cacheScale != s || it->dirty) queue.push_back(it);
        Pt mid = model.toCanvas({ getWidth() / 2.0f, getHeight() / 2.0f });
        std::stable_sort(queue.begin(), queue.end(), [&](Item* a, Item* b) { return a->rect.getCentre().getDistanceFrom(mid) < b->rect.getCentre().getDistanceFrom(mid); });
    }
    if (!queue.empty()) {
        float px = pixelScale();
        double start = now();
        auto view = getLocalBounds().toFloat();
        while (!queue.empty() && now() - start < 0.006) {
            auto* it = queue.front(); queue.erase(queue.begin());
            auto sr = screenRect(*it);
            if (!sr.expanded(60).intersects(view)) { it->dirty = true; continue; }    // off screen: drawn when it comes on
            renderCache(*it, s, px);
            repaint(sr.expanded(it->margin() * s + 2).getSmallestIntegerContainer());
        }
    }
    if (press && longPressAt > 0 && t >= longPressAt) {
        longPressAt = 0;
        // a long press = a right-click: duplicate, replace, highlight
        if (!press->dragging && !press->info.moved && press->item->kind == Item::module) { press->longFired = true; showBoxMenu(press->item->id, press->startScreen); }
    }
    // live parts: gliding ones at 30 fps, the rest at 20 fps (slower still with audio off)
    bool running = model.isRunning;
    auto view = getLocalBounds().toFloat();
    for (auto& id : order) {
        auto f = items.find(id);
        if (f == items.end()) continue;
        auto& it = *f->second;
        if (it.parts.empty()) continue;
        auto sr = screenRect(it);
        if (!sr.intersects(view)) continue;
        Pt d = dragShift(it.id);
        for (auto& p : it.parts) {
            int period = p.lp.smooth ? 2 : 3 * p.lp.every;
            if (!running) period *= 5;
            if ((frame + p.phase) % period != 0) continue;
            bool redraw = true;
            if (p.lp.signature) { auto sig = p.lp.signature(); redraw = sig != p.last; p.last = sig; }
            if (!redraw) continue;
            Rect r((it.rect.getX() + d.x + p.lp.rect.getX()) * s + model.viewOffset.x, (it.rect.getY() + d.y + p.lp.rect.getY()) * s + model.viewOffset.y,
                   p.lp.rect.getWidth() * s, p.lp.rect.getHeight() * s);
            repaint(r.getSmallestIntegerContainer().expanded(1));
        }
    }
}

std::vector<Canvas::Item*> Canvas::allItems() {
    std::vector<Item*> v;
    for (auto& [k, it] : items) v.push_back(it.get());
    for (auto& [k, it] : groupItems) v.push_back(it.get());
    return v;
}

void Canvas::viewportChanged() {
    float s = model.viewScale;
    if (s != drawnScale) settleAt = now() + 0.12;
    if (editor) placeEditor();
    if (finder) closeFinder();
    repaint();
}

void Canvas::dragged() { cablesDirty = true; repaint(); }

void Canvas::rebuildCables() {
    cablesDirty = false;
    dashedFor = 0;
    cablePlain.clear(); cableDashed.clear(); cableSel.clear();
    std::map<juce::String, const PatchNode*> byID;
    for (auto& n : model.patch.nodes) byID[n.id] = &n;
    for (auto& c : model.patch.cables) {
        auto fa = byID.find(c.fromNode), fb = byID.find(c.toNode);
        if (fa == byID.end() || fb == byID.end()) continue;
        auto* a = fa->second; auto* b = fb->second;
        if (a->hideOut || b->hideIn) continue;        // that box's cables are hidden
        auto* sa = Registry::spec(a->kind); auto* sb = Registry::spec(b->kind);
        if (!sa || !sb || c.fromPort >= int(BoxLayout::ports(*a, *sa, model.hw).outs.size())) continue;
        auto dest = BoxLayout::destination(*b, *sb, model.hw, c.toPort);
        if (!dest) continue;
        Pt pa = BoxLayout::outlet(*a, *sa, model.hw, c.fromPort) + dragShift(a->id), pb = *dest + dragShift(b->id);
        bool selected = model.selectedCable == c.id || model.insertCandidates.count(c.id);
        addCable(selected ? cableSel : (c.toPort >= kParamPortBase ? cableDashed : cablePlain), pa, pb, 1);
    }
}

// ---------------------------------------------------------------- what's under the pointer

Canvas::Item* Canvas::itemAt(Pt screen) {
    Pt c = model.toCanvas(screen);
    for (auto it = order.rbegin(); it != order.rend(); ++it) {
        auto f = items.find(*it);
        if (f == items.end()) continue;
        auto& item = *f->second;
        Pt sh = dragShift(item.id);
        Rect r = item.rect.translated(sh.x, sh.y);
        if (item.kind == Item::text) { if (r.expanded(10).contains(c)) return &item; continue; }
        if (r.contains(c)) return &item;
        if (r.expanded(11, 0).contains(c) && item.geo && item.geo->port(c - r.getPosition())) return &item;
    }
    for (auto& [k, it] : groupItems) if (it->rect.contains(c)) return it.get();
    return nullptr;
}

Pt Canvas::local(const Item& it, Pt screen) const {
    Pt c = model.toCanvas(screen), sh = it.kind == Item::grp ? Pt() : dragShift(it.id);
    return { c.x - it.rect.getX() - sh.x, c.y - it.rect.getY() - sh.y };
}

Canvas::Hit Canvas::region(Item& it, Pt p) {
    Hit h;
    if (it.kind == Item::text) { h.region = Region::text; return h; }
    if (it.kind == Item::grp) {
        h.region = p.y < 26 && p.x < 10 + textWidth(it.group.name, 11, true) + 10 ? Region::groupName : Region::group;
        return h;
    }
    if (!it.geo) return h;
    auto& geo = *it.geo;
    if (auto port = geo.port(p)) { h.region = Region::port; h.index = port->port; h.output = port->output; return h; }
    if (p.x < 0 || p.x > geo.w || p.y < 0 || p.y > geo.h) return h;
    if (geo.header().contains(p)) {
        for (auto& [b, r] : geo.buttons) if (r.contains(p)) { h.region = Region::button; h.button = b; return h; }
        h.region = Region::title; return h;
    }
    if (auto gr = geo.grip(); gr && gr->contains(p)) { h.region = Region::grip; return h; }
    for (auto& [i, r] : geo.triggers()) if (r.contains(p)) { h.region = Region::trigger; h.index = i; return h; }
    for (auto& [i, r] : geo.rows()) if (r.expanded(0, 1.5f).contains(p)) { h.region = Region::row; h.index = i; return h; }
    if (auto d = geo.display(); d && d->contains(p)) { h.region = Region::display; return h; }
    if (auto pr = geo.portRows(); pr && pr->contains(p)) { h.region = Region::grab; return h; }
    return h;
}

std::optional<juce::String> Canvas::hitCable(Pt p) {
    if (model.hideCables) return std::nullopt;
    std::optional<juce::String> best; float bd = INFINITY;
    for (auto& c : model.patch.cables) {
        int ia = model.patch.index(c.fromNode), ib = model.patch.index(c.toNode);
        if ((ia >= 0 && model.patch.nodes[size_t(ia)].hideOut) || (ib >= 0 && model.patch.nodes[size_t(ib)].hideIn)) continue;
        auto e = cableEnds(c);
        if (!e) continue;
        juce::Path path; addCable(path, e->first, e->second, model.viewScale);
        float len = path.getLength();
        for (int k = 0; k <= 24; ++k) {
            Pt q = path.getPointAlongPath(len * float(k) / 24);
            float d = q.getDistanceFrom(p);
            if (d < 10 && d < bd) { bd = d; best = c.id; }
        }
    }
    return best;
}

// ---------------------------------------------------------------- presses on boxes

bool Canvas::began(Pt screen, const juce::MouseEvent& e) {
    if (model.isZooming) return false;
    auto* it = itemAt(screen);
    if (!it) return false;
    PointerInfo info;
    info.clickCount = e.getNumberOfClicks();
    info.shift = e.mods.isShiftDown(); info.option = e.mods.isAltDown(); info.command = e.mods.isCommandDown();
    info.right = e.mods.isPopupMenu();
    Pt lp = local(*it, screen);
    info.start = lp;
    auto hit = region(*it, lp);
    if (editingID == it->id && (it->kind == Item::text || hit.region == Region::groupName)) return true;
    press = Press { it, hit, screen, info };
    press->pressedAt = now();
    auto id = it->id;
    switch (hit.region) {
        case Region::port: {
            bool connected = model.isPortConnected(id, hit.index, hit.output);
            if (!model.pendingCable && !hit.output && connected && model.pickUpCable(id, hit.index, screen)) break;
            model.pendingCable = PendingCable { id, hit.index, hit.output, screen };
            repaint();
            break;
        }
        case Region::button:
            if (hit.button == BoxGeo::autoRec) { press->autoRecWasOn = model.autoRecording.count(id) > 0; if (!press->autoRecWasOn) model.startAutoRecord(id); }
            break;
        case Region::title: case Region::text:
            if (info.right && it->kind == Item::module) {
                press.reset();
                showBoxMenu(id, screen);
                return true;
            }
            if (!info.right) longPressAt = now() + 0.5;
            break;
        case Region::row:
            if (it->spec) press->rowStart = it->spec->params[size_t(hit.index)].normalized(model.value(it->node, hit.index, *it->spec));
            break;
        case Region::grip:
            press->resizeStart = Pt { BoxLayout::width(it->node), BoxLayout::readoutHeight(it->node) };
            break;
        case Region::display: {
            auto d = it->geo ? it->geo->display() : std::nullopt;
            if (!d || !it->display) break;
            if (info.right) {
                if (auto items_ = it->display->menu(lp, *d)) showMenu(*items_, screen);
                press.reset();
                return true;
            }
            if (!it->display->press(lp, *d, info)) {
                if (auto pr = it->geo->portRows(); pr && pr->contains(lp)) press->hit.region = Region::grab;
                else press->hit.region = Region::nothing;
            }
            break;
        }
        default: break;
    }
    return true;
}

void Canvas::moved(Pt screen) {
    if (!press) return;
    auto& pr = *press;
    auto* it = pr.item;
    auto id = it->id;
    float dx = screen.x - pr.startScreen.x, dy = screen.y - pr.startScreen.y;
    if (!pr.info.moved && std::hypot(dx, dy) > 2.5f) { pr.info.moved = true; longPressAt = 0; }
    if (model.isZooming && !pr.dragging) return;
    Pt lp = local(*it, screen);
    switch (pr.hit.region) {
        case Region::port:
            if (model.pendingCable) { model.pendingCable->point = screen; repaint(); }
            break;
        case Region::title: case Region::grab: case Region::text:
            if (!pr.info.moved || pr.longFired || editingID == id) return;
            if (!pr.dragging) { pr.dragging = true; model.nativeDragBegan(id); }
            model.nativeDragMoved({ dx, dy }, screen);
            break;
        case Region::group:
            if (!pr.info.moved) return;
            if (!pr.dragging) { pr.dragging = true; model.selectGroup(it->group); model.beginGroupDrag(); }
            model.groupDrag({ dx / model.viewScale, dy / model.viewScale });
            break;
        case Region::row: {
            if (!pr.info.moved || !it->spec || !pr.rowStart) return;
            auto& ps = it->spec->params[size_t(pr.hit.index)];
            if (ps.kind == ParamKind::toggle) return;
            float width = std::max((it->geo ? it->geo->w : 186.0f) - 16, 1.0f);
            float n = *pr.rowStart + dx / model.viewScale / width;
            if (!model.isZooming) model.setParam(id, pr.hit.index, ps.valueFromNormalized(n));
            break;
        }
        case Region::grip: {
            if (!pr.info.moved || !pr.resizeStart) return;
            auto can = BoxLayout::resizable(it->node.kind);
            model.resizeNode(id, can.first ? std::optional<float>(pr.resizeStart->x + dx / model.viewScale) : std::nullopt,
                             can.second ? std::optional<float>(pr.resizeStart->y + dy / model.viewScale) : std::nullopt);
            break;
        }
        case Region::display:
            if (it->geo && it->display) if (auto d = it->geo->display()) { it->display->drag(lp, *d, pr.info); repaint(screenRect(*it).getSmallestIntegerContainer()); }
            break;
        default: break;
    }
}

void Canvas::ended(Pt screen, bool cancelled) {
    if (!press) return;
    auto pr = *press;
    press.reset();
    longPressAt = 0;
    auto* it = pr.item;
    auto id = it->id;
    Pt lp = local(*it, screen);
    auto inside = [&](std::optional<Rect> r) { return r && r->contains(lp); };
    if (cancelled) {
        if (pr.dragging) model.nativeDragEnded();
        if (pr.hit.region == Region::port) { model.pendingCable.reset(); repaint(); }
        if (pr.hit.region == Region::display && it->geo && it->display) if (auto d = it->geo->display()) it->display->release(lp, *d, pr.info);
        return;
    }
    switch (pr.hit.region) {
        case Region::port: model.finishCable(screen); break;
        case Region::button: {
            std::optional<Rect> r;
            for (auto& [b, rr] : it->geo->buttons) if (b == pr.hit.button) r = rr;
            if (pr.hit.button == BoxGeo::autoRec) {
                if (pr.autoRecWasOn || now() - pr.pressedAt > 0.35) model.stopAutoRecord(id);
                break;
            }
            if (!r || !inside(r->expanded(3))) break;
            switch (pr.hit.button) {
                case BoxGeo::bypass: model.toggleBypass(id); break;
                case BoxGeo::collapse: model.toggleCollapsed(id); break;
                case BoxGeo::close: model.removeNode(id); break;
                case BoxGeo::clearPattern: model.clearPattern(id); break;
                case BoxGeo::resetAuto: model.clearAutomation(id); break;
                case BoxGeo::audioMenu: {
                    auto* m = &model;
                    std::vector<MenuItem> list;
                    MenuItem load; load.title = u8("Load audio file\xe2\x80\xa6"); load.action = [m, id] { m->audioImportTarget = id; m->changed(); };
                    list.push_back(load);
                    std::vector<const PatchNode*> sources;
                    for (auto& n : model.patch.nodes) if (n.id != id && dynamic_cast<SampleBufferNode*>(model.node(n.id))) sources.push_back(&n);
                    if (!sources.empty()) {
                        list.push_back(MenuItem::divider());
                        list.push_back(MenuItem::section("Copy audio from"));
                        for (auto* src : sources) { MenuItem mi; mi.title = model.label(*src); auto sid = src->id; mi.action = [m, sid, id] { m->copyBuffer(sid, id); }; list.push_back(mi); }
                    }
                    showMenu(list, screen);
                    break;
                }
                case BoxGeo::autoRec: break;
            }
            break;
        }
        case Region::title: case Region::grab: case Region::text:
            if (pr.dragging) model.nativeDragEnded();
            else if (!pr.longFired && !pr.info.moved) {
                if (it->kind == Item::text && pr.info.clickCount >= 2) startEditing(id, false);
                else if (pr.hit.region == Region::title && pr.info.clickCount >= 2) model.duplicate(id);
                else if (model.selectMode || pr.info.shift) model.toggleSelected(id);
                else model.select(id);
            }
            break;
        case Region::group: case Region::groupName:
            if (pr.dragging) { model.endGroupDrag(); model.scheduleAutosave(); }
            else if (!pr.info.moved) {
                if (pr.hit.region == Region::groupName && pr.info.clickCount >= 2) startEditing(id, true);
                else model.selectGroup(it->group);
            }
            break;
        case Region::trigger:
            for (auto& [i, r] : it->geo->triggers()) if (i == pr.hit.index && inside(r)) model.fire(id, i);
            break;
        case Region::row: {
            if (!it->spec) break;
            auto& ps = it->spec->params[size_t(pr.hit.index)];
            int i = pr.hit.index;
            if (!pr.info.moved) {
                if (ps.kind == ParamKind::toggle) model.setParam(id, i, model.value(it->node, i, *it->spec) > 0.5f ? 0.0f : 1.0f);
                else if (ps.kind == ParamKind::choice) {
                    int cur = int(std::round(model.value(it->node, i, *it->spec)));
                    std::vector<MenuItem> list;
                    auto* m = &model;
                    for (int k = 0; k < int(ps.options.size()); ++k) {
                        MenuItem mi; mi.title = nameOf(ps.options[size_t(k)]); mi.checked = k == cur; mi.action = [m, id, i, k] { m->setParam(id, i, float(k)); };
                        list.push_back(mi);
                    }
                    showMenu(list, screen);
                } else if (pr.info.clickCount >= 2) model.setParam(id, i, ps.def);
            }
            model.scheduleAutosave();
            break;
        }
        case Region::grip:
            if (!pr.info.moved && pr.info.clickCount >= 2) model.resizeNode(id, std::nullopt, std::nullopt);
            model.scheduleAutosave();
            break;
        case Region::display:
            if (it->geo && it->display) if (auto d = it->geo->display()) { it->display->release(lp, *d, pr.info); repaint(screenRect(*it).getSmallestIntegerContainer()); }
            break;
        default: break;
    }
}

/// The box menu's colour row: circles (the first, with a slash, = no highlight); the current one has a ring.
class SwatchRow : public juce::PopupMenu::CustomComponent {
public:
    SwatchRow(std::optional<juce::String> cur, std::function<void(std::optional<juce::String>)> pick)
        : juce::PopupMenu::CustomComponent(false), current(std::move(cur)), onPick(std::move(pick)) {}
    void getIdealSize(int& w, int& h) override { w = 10 + int(AppModel::highlightColours.size() + 1) * 24 + 6; h = 28; }
    void paint(juce::Graphics& g) override {
        for (int k = 0; k <= int(AppModel::highlightColours.size()); ++k) {
            auto r = cell(k);
            std::optional<juce::String> hex = k == 0 ? std::nullopt : std::optional<juce::String>(AppModel::highlightColours[size_t(k - 1)]);
            auto c = r.reduced(2);
            if (hex) { g.setColour(juce::Colour::fromString("ff" + hex->substring(1))); g.fillEllipse(c); }
            else {
                g.setColour(Theme::dim()); g.drawEllipse(c.reduced(0.5f), 1);
                g.drawLine(c.getX() + 4, c.getBottom() - 4, c.getRight() - 4, c.getY() + 4, 1);
            }
            if (hex == current) { g.setColour(Theme::text()); g.drawEllipse(r.reduced(0.75f), 1.5f); }
        }
    }
    void mouseUp(const juce::MouseEvent& e) override {
        for (int k = 0; k <= int(AppModel::highlightColours.size()); ++k)
            if (cell(k).contains(e.position)) {
                onPick(k == 0 ? std::nullopt : std::optional<juce::String>(AppModel::highlightColours[size_t(k - 1)]));
                triggerMenuItem();
                return;
            }
    }
private:
    juce::Rectangle<float> cell(int k) const { return { 10.0f + float(k) * 24, 3, 22, 22 }; }
    std::optional<juce::String> current;
    std::function<void(std::optional<juce::String>)> onPick;
};

void Canvas::showBoxMenu(const juce::String& id, Pt screen) {
    int i = model.patch.index(id);
    if (i < 0) return;
    juce::PopupMenu menu;
    menu.setLookAndFeel(&getLookAndFeel());
    auto targets = model.menuTargets(id);         // right-clicking a selected box acts on the whole selection
    menu.addItem(targets.size() > 1 ? "duplicate " + juce::String(int(targets.size())) : juce::String("duplicate"),
                 [this, id, targets] { if (targets.size() > 1) model.duplicateSelection(); else model.duplicate(id); });
    menu.addItem(juce::String::fromUTF8("replace\xe2\x80\xa6"), [this, id] { model.beginReplace(id); });
    auto& nd = model.patch.nodes[size_t(i)];
    bool locked = nd.pin.has_value(), hin = nd.hideIn, hout = nd.hideOut;
    menu.addItem("lock to screen", true, locked, [this, targets, locked] { model.setLocked(targets, !locked); });
    menu.addItem("hide cables in", true, hin, [this, targets, hin] { model.setHidden(targets, !hin, std::nullopt); });
    menu.addItem("hide cables out", true, hout, [this, targets, hout] { model.setHidden(targets, std::nullopt, !hout); });
    menu.addSeparator();
    menu.addSectionHeader("highlight");
    menu.addCustomItem(1000, std::make_unique<SwatchRow>(model.patch.nodes[size_t(i)].highlight,
                                                         [this, targets](std::optional<juce::String> h) { model.setHighlights(targets, h); }), nullptr);
    auto p = localPointToGlobal(screen.toInt());
    menu.showMenuAsync(juce::PopupMenu::Options().withTargetScreenArea({ p.x, p.y, 1, 1 }));
}

void Canvas::showMenu(const std::vector<MenuItem>& list, Pt screen) {
    juce::PopupMenu menu;
    menu.setLookAndFeel(&getLookAndFeel());
    int idn = 1;
    std::map<int, std::function<void()>> actions;
    for (auto& it : list) {
        if (it.separator) { menu.addSeparator(); continue; }
        if (it.header) { menu.addSectionHeader(it.title); continue; }
        actions[idn] = it.action;
        menu.addItem(idn++, it.title, it.enabled, it.checked);
    }
    auto p = localPointToGlobal(screen.toInt());
    menu.showMenuAsync(juce::PopupMenu::Options().withTargetScreenArea({ p.x, p.y, 1, 1 }), [actions](int r) {
        auto f = actions.find(r);
        if (f != actions.end() && f->second) f->second();
    });
}

// ---------------------------------------------------------------- mouse

Rect Canvas::mapRect() const { return Rect(float(getWidth()) - 12 - 220, float(getHeight()) - 12 - 150, 220, 150); }
Rect Canvas::mapExtent() const {
    if (mapHeld) return *mapHeld;
    Rect r; bool any = false;
    for (auto& n : model.patch.nodes) {
        auto* sp = Registry::spec(n.kind);
        if (!sp) continue;
        Rect b(float(n.x), float(n.y), BoxLayout::width(n), BoxLayout::height(n, *sp, model.hw));
        r = any ? r.getUnion(b) : b; any = true;
    }
    auto a = model.toCanvas({ 0, 0 }), b = model.toCanvas({ float(getWidth()), float(getHeight()) });
    Rect v(a, b);
    r = any ? r.getUnion(v) : v;
    return r.expanded(60);
}
void Canvas::mapGo(Pt p) {
    auto mr = mapRect(); auto e = mapExtent();
    float sc = std::min(mr.getWidth() / std::max(e.getWidth(), 1.0f), mr.getHeight() / std::max(e.getHeight(), 1.0f));
    Pt o { mr.getX() + (mr.getWidth() - e.getWidth() * sc) / 2, mr.getY() + (mr.getHeight() - e.getHeight() * sc) / 2 };
    Pt c { e.getX() + (p.x - o.x) / sc, e.getY() + (p.y - o.y) / sc };     // centre the view on that point of the patch
    float s = model.viewScale;
    model.setView({ float(getWidth()) / 2 - c.x * s, float(getHeight()) / 2 - c.y * s }, s);
}

void Canvas::mouseDown(const juce::MouseEvent& e) {
    grabKeyboardFocus();
    Pt p = e.position;
    if (editor) finishEditing();
    if (model.finderAt) { model.finderAt.reset(); model.replaceTarget = {}; model.changed(); return; }
    if (model.showColours) { model.showColours = false; model.changed(); }
    if (model.helpMode && Rect(12, float(getHeight()) - 200, 320, 200).contains(p)) {
        // the help panel's ×
        if (p.x > 300 && p.y > float(getHeight()) - 200) { }
    }
    if (!deleteButton.isEmpty() && deleteButton.toFloat().contains(p)) { model.removeCable(model.selectedCable); return; }
    if (model.showMap && mapRect().contains(p)) { mapDragging = true; mapHeld = mapExtent(); mapGo(p); return; }
    if (began(p, e)) return;
    bgPressed = true; panning = false; marquee.reset();
    bgRight = e.mods.isPopupMenu();          // right-click and drag: a selection box
    bgStart = p; panStart = model.viewOffset;
    model.isZooming = false;
}

void Canvas::mouseDrag(const juce::MouseEvent& e) {
    Pt p = e.position;
    if (mapDragging) { mapGo(p); return; }
    if (press) { moved(p); return; }
    if (!bgPressed) return;
    if (!panning && !marquee && p.getDistanceFrom(bgStart) < 3) return;
    if (marquee || (!panning && (bgRight || model.selectMode || e.mods.isShiftDown()))) {
        marquee = Rect(std::min(bgStart.x, p.x), std::min(bgStart.y, p.y), std::abs(p.x - bgStart.x), std::abs(p.y - bgStart.y));
        repaint();
        return;
    }
    panning = true;
    model.setView({ panStart.x + p.x - bgStart.x, panStart.y + p.y - bgStart.y }, model.viewScale);
}

void Canvas::mouseUp(const juce::MouseEvent& e) {
    Pt p = e.position;
    if (mapDragging) { mapDragging = false; mapHeld.reset(); repaint(); return; }
    if (press) { ended(p); return; }
    if (!bgPressed) return;
    bgPressed = false;
    if (marquee) {
        auto a = model.toCanvas(marquee->getTopLeft()), b = model.toCanvas(marquee->getBottomRight());
        model.selectIn(Rect(a, b), e.mods.isShiftDown());
        marquee.reset();
        repaint();
        return;
    }
    if (panning) { panning = false; return; }
    if (bgRight) return;                     // a right-click on empty canvas without a drag: nothing
    // a tap on empty canvas or a cable
    if (e.getNumberOfClicks() >= 2) {
        if (auto c = hitCable(p)) { model.removeCable(*c); return; }
        model.clearSelection();
        model.finderAt = model.toCanvas(p);
        model.changed();
        return;
    }
    if (auto c = hitCable(p)) { model.selectedNodes.clear(); model.selectedCable = *c; model.changed(); }
    else {
        model.clearSelection();
        model.selectMode = false; model.showColours = false; model.helpMode = false; model.helpTopics.clear();
        model.changed();
    }
}

void Canvas::mouseMove(const juce::MouseEvent& e) {
    hover = e.position;
    hovered(e.position);
    repaint();
}
void Canvas::mouseExit(const juce::MouseEvent&) { hover.reset(); hovered(std::nullopt); repaint(); }

void Canvas::mouseWheelMove(const juce::MouseEvent& e, const juce::MouseWheelDetails& w) {
    if (finder) return;
    float raw = w.deltaY != 0 ? w.deltaY : w.deltaX;
    float dy = w.isReversed ? -raw : raw;
    // over a piano roll's grid: scroll through its octaves
    if (auto* it = itemAt(e.position); it && it->display && it->geo)
        if (auto d = it->geo->display()) if (it->display->wheel(local(*it, e.position), *d, dy)) return;
    float factor = w.isSmooth ? std::exp(std::clamp(dy * 256, -40.0f, 40.0f) * 0.005f) : (dy > 0 ? 1.1f : (dy < 0 ? 1 / 1.1f : 1.0f));
    if (factor != 1) model.zoomBy(factor, e.position);
}

void Canvas::mouseMagnify(const juce::MouseEvent& e, float scale) { model.zoomBy(scale, e.position); }

bool Canvas::keyPressed(const juce::KeyPress& k) {
    if (editor) return false;
    if (k == juce::KeyPress::deleteKey || k == juce::KeyPress::backspaceKey) { if (!model.finderAt) model.removeSelection(); return true; }
    if (k == juce::KeyPress::escapeKey) { if (model.finderAt) { model.finderAt.reset(); model.changed(); } return true; }
    return false;
}

// ---------------------------------------------------------------- help hover

void Canvas::hovered(std::optional<Pt> screen) {
    if (!model.helpMode) { helpShown.clear(); return; }
    std::vector<HelpTopic> topics;
    if (screen) if (auto* it = itemAt(*screen)) {
        Pt lp = local(*it, *screen);
        if (it->kind == Item::grp)
            topics.push_back({ "group-" + it->id, it->group.name, "A group. Drag its backdrop to move all its boxes, tap it to select them, double-tap the name to rename. Ungroup from the top bar." });
        else if (it->kind == Item::module && it->spec) {
            auto& spec = *it->spec;
            juce::String body = nameOf(spec.summary) + ".";
            auto join = [](const std::vector<std::string>& v) { juce::StringArray a; for (auto& s : v) a.add(nameOf(s)); return a.joinIntoString(", "); };
            if (!spec.inputs.empty()) body += "\nIn: " + join(spec.inputs) + ".";
            if (!spec.outputs.empty()) body += "\nOut: " + join(spec.outputs) + ".";
            body += u8("\nDrag the title to move \xc2\xb7 double-click the title to duplicate \xc2\xb7 \xe2\x97\x8b/\xe2\x97\x8f bypasses \xc2\xb7 corner dot resizes.");
            topics.push_back({ "box-" + it->id, nameOf(spec.name), body });
            auto hit = region(*it, lp);
            if (hit.region == Region::row) {
                auto& p = spec.params[size_t(hit.index)];
                juce::String range;
                if (p.kind == ParamKind::choice) {
                    juce::StringArray o; for (size_t i = 0; i < std::min<size_t>(8, p.options.size()); ++i) o.add(nameOf(p.options[i]));
                    range = "Choices: " + o.joinIntoString(", ") + (p.options.size() > 8 ? u8(" \xe2\x80\xa6") : juce::String()) + ".";
                } else if (p.kind == ParamKind::toggle) range = "On / off.";
                else if (p.kind == ParamKind::trigger) range = "Press to fire.";
                else range = "Range " + nameOf(p.display(p.min)) + u8(" \xe2\x80\xa6 ") + nameOf(p.display(p.max)) + (p.unit.empty() ? juce::String() : " " + nameOf(p.unit)) + ".";
                topics.push_back({ "param-" + it->id + "-" + juce::String(hit.index), nameOf(spec.name) + u8(" \xc2\xb7 ") + nameOf(p.name),
                                   range + u8(" Drag across the row to change it, double-tap to reset. The \xe2\x97\x8b on its left takes a CV / modulation cable.") });
            } else if (hit.region == Region::port) {
                int port = hit.index; bool output = hit.output;
                juce::String title, what;
                if (port >= kParamPortBase) {
                    int i = port - kParamPortBase;
                    title = nameOf(spec.name) + u8(" \xc2\xb7 ") + (i < int(spec.params.size()) ? nameOf(spec.params[size_t(i)].name) : juce::String("parameter")) + " (CV in)";
                    what = u8("Patch any outlet here to move this parameter. \xc2\xb1" "1.0 (\xe2\x89\x88 \xc2\xb1" "10 V) sweeps its whole range; use atten to scale. A slider / knob patched here takes it over completely and moves with its row.");
                } else {
                    auto& names = output ? spec.outputs : spec.inputs;
                    juce::String name = port < int(names.size()) ? nameOf(names[size_t(port)]) : "?";
                    auto n = name.toLowerCase();
                    if (n == "l" || n == "r" || n == "in" || n == "out") what = output ? u8("Audio out \xe2\x80\x94 patch to out or into another box.") : juce::String("Audio in.");
                    else if (n == "pitch") what = output ? "Pitch CV out, 1 V/oct (0.1 = one octave). Patch into a voice's pitch inlet or out to the modular." : "Pitch CV in, 1 V/oct (0.1 = one octave).";
                    else if (n == "gate") what = output ? "Gate out: high while a note / step is on." : "Gate in: high starts, low releases.";
                    else if (n == "trig" || n == "strum" || n == "seed") what = output ? "Trigger pulses out." : "Trigger in: each rising edge fires it.";
                    else if (n == "clock" || n == "t clk" || n == "x clk") what = output ? "Clock pulses out." : "Clock in: pulses from the modular or clock drive it.";
                    else if (n == "reset") what = "Reset in: a pulse goes back to the start.";
                    else if (n == "sc") what = "Sidechain in: this signal drives the compression instead of the input.";
                    else if (n == "freeze") what = "Freeze in: high holds the current sound.";
                    else if (n == "vel") what = "Velocity CV out.";
                    else if (n == "rec") what = "Record gate in: a pulse starts / stops recording.";
                    else if (n == "play") what = "Play gate in: a pulse restarts playback.";
                    else if (n == "pulse") what = "Clock pulses at the chosen division.";
                    else if (n == "ramp") what = u8("A 0\xe2\x80\xa6" "1 ramp each beat \xe2\x80\x94 handy as a synced LFO.");
                    else what = output ? "Signal out." : "Signal in.";
                    title = nameOf(spec.name) + u8(" \xc2\xb7 ") + (output ? "outlet " : "inlet ") + name;
                    what += output ? u8(" Drag from here to an inlet or a parameter's \xe2\x97\x8b to connect.") : juce::String(" Drag an outlet here to connect; drag a plugged cable's end to move it.");
                }
                topics.push_back({ "port-" + it->id + "-" + juce::String(int(output)) + "-" + juce::String(port), title, what });
            } else if (hit.region == Region::button && hit.button == BoxGeo::autoRec)
                topics.push_back({ "autorec-" + it->id, "Record automation", "Hold and move this box's controls: the movements are recorded into a 4-bar loop and play back. A quick tap latches recording on; tap again to stop." });
            else if (hit.region == Region::button && hit.button == BoxGeo::resetAuto)
                topics.push_back({ "autoreset-" + it->id, "Reset automation", "Removes every recorded movement in this box. Parameters stay where they are." });
        }
    }
    bool same = topics.size() == helpShown.size();
    for (size_t i = 0; same && i < topics.size(); ++i) same = topics[i] == helpShown[i];
    if (same) return;
    for (auto& t : helpShown) if (std::find(topics.begin(), topics.end(), t) == topics.end()) model.hoverHelp(t, false);
    for (auto& t : topics) if (std::find(helpShown.begin(), helpShown.end(), t) == helpShown.end()) model.hoverHelp(t, true);
    helpShown = topics;
}

// ---------------------------------------------------------------- files dropped on boxes

bool Canvas::dropHover(std::optional<Pt> screen) {
    Item* target = nullptr; std::optional<int> pad;
    if (screen) if (auto* it = itemAt(*screen); it && it->kind == Item::module) {
        if (it->node.kind == "rack") {
            target = it;
            if (it->geo && it->display) if (auto d = it->geo->display()) pad = it->display->pad(local(*it, *screen), *d);
        } else if (dynamic_cast<SampleBufferNode*>(model.node(it->id))) target = it;
    }
    if (dropItem != target || (dropItem && dropItem->display && dropItem->display->dropPad != pad)) {
        if (dropItem && dropItem != target) { dropItem->dropTarget = false; if (dropItem->display) dropItem->display->dropPad.reset(); dropItem->dirty = true; }
        dropItem = target;
        if (target) { if (target->display) target->display->dropPad = pad; target->dropTarget = !pad.has_value(); target->dirty = true; }
        repaint();
    }
    return target != nullptr;
}

void Canvas::fileDragMove(const juce::StringArray&, int x, int y) { dropHover(Pt { float(x), float(y) }); }
void Canvas::fileDragExit(const juce::StringArray&) { dropHover(std::nullopt); }

void Canvas::filesDropped(const juce::StringArray& files, int x, int y) {
    Pt p { float(x), float(y) };
    dropHover(p);
    auto* it = dropItem;
    juce::Array<juce::File> fs;
    for (auto& f : files) fs.add(juce::File(f));
    if (it && !fs.isEmpty()) {
        if (it->node.kind == "rack") {
            int from = it->display && it->display->dropPad ? *it->display->dropPad : int(std::round(BoxLayout::param(it->node, "sel", 0)));
            model.loadPads(it->id, from, fs);
        } else model.loadAudio(fs[0], it->id);
    } else if (fs.size() == 1 && fs[0].hasFileExtension("json")) model.openFile(fs[0]);
    dropHover(std::nullopt);
}

// ---------------------------------------------------------------- text editing (notes, group names)

void Canvas::startEditing(const juce::String& id, bool isGroup) {
    finishEditing();
    editingID = id; editingGroup = isGroup;
    editor = std::make_unique<juce::TextEditor>();
    editor->setMultiLine(!isGroup, false);
    editor->setReturnKeyStartsNewLine(false);
    editor->setColour(juce::TextEditor::backgroundColourId, juce::Colours::transparentBlack);
    editor->setColour(juce::TextEditor::outlineColourId, juce::Colours::transparentBlack);
    editor->setColour(juce::TextEditor::focusedOutlineColourId, juce::Colours::transparentBlack);
    editor->setColour(juce::TextEditor::textColourId, Theme::text());
    editor->setColour(juce::CaretComponent::caretColourId, Theme::text());
    editor->setBorder({ 0, 0, 0, 0 });
    editor->setIndents(0, 0);
    if (isGroup) { for (auto& g : model.patch.groups) if (g.id == id) editor->setText(g.name, false); }
    else { if (auto* n = model.nodeFor(id)) editor->setText(n->text.value_or(""), false); model.select(id); }
    editor->addListener(this);
    addAndMakeVisible(*editor);
    placeEditor();
    editor->grabKeyboardFocus();
    editor->moveCaretToEnd();
    auto set = [&](std::map<juce::String, std::unique_ptr<Item>>& m) { auto f = m.find(id); if (f != m.end()) { f->second->editing = true; f->second->dirty = true; } };
    set(items); set(groupItems);
    repaint();
}

void Canvas::placeEditor() {
    if (!editor) return;
    float s = model.viewScale;
    if (auto* n = model.nodeFor(editingID); n && !editingGroup) {
        auto sz = BoxLayout::textSize(*n);
        Pt p = model.toScreen({ float(n->x), float(n->y) });
        editor->setFont(Theme::mono(12 * s));
        editor->setBounds(Rect(p.x + 5 * s, p.y + 3 * s, std::max(sz.x + 60, 120.0f) * s, (sz.y + 15) * s).getSmallestIntegerContainer());
        return;
    }
    auto f = groupItems.find(editingID);
    if (f != groupItems.end()) {
        Pt p = model.toScreen(f->second->rect.getPosition());
        editor->setFont(Theme::mono(11 * s, true));
        editor->setBounds(Rect(p.x + 10 * s, p.y + 5 * s, 180 * s, 18 * s).getSmallestIntegerContainer());
    }
}

void Canvas::textEditorTextChanged(juce::TextEditor& e) {
    if (editingGroup || editingID.isEmpty()) return;
    model.setText(editingID, e.getText());
    placeEditor();
}
void Canvas::textEditorReturnKeyPressed(juce::TextEditor& e) {
    if (!editingGroup && juce::ModifierKeys::getCurrentModifiers().isAltDown()) { e.insertTextAtCaret("\n"); return; }
    finishEditing();
}
void Canvas::textEditorEscapeKeyPressed(juce::TextEditor&) { finishEditing(); }
void Canvas::textEditorFocusLost(juce::TextEditor&) { juce::MessageManager::callAsync([sp = juce::Component::SafePointer<Canvas>(this)] { if (sp) sp->finishEditing(); }); }

void Canvas::finishEditing() {
    if (!editor || editingID.isEmpty()) return;
    auto id = editingID; bool group = editingGroup;
    auto text = editor->getText();
    editingID = {};
    editor->removeListener(this);
    removeChildComponent(editor.get());
    editor.reset();
    if (group) model.renameGroup(id, text);
    else {
        model.setText(id, text.trim());
        if (auto* n = model.nodeFor(id); n && n->text.value_or("").isEmpty()) model.removeNode(id);
    }
    auto set = [&](std::map<juce::String, std::unique_ptr<Item>>& m) { auto f = m.find(id); if (f != m.end()) { f->second->editing = false; f->second->dirty = true; } };
    set(items); set(groupItems);
    grabKeyboardFocus();
    repaint();
}

// ---------------------------------------------------------------- the module list

void Canvas::openFinder(Pt at) {
    finder = std::make_unique<ObjectFinder>(model, at);
    finder->onClose = [this] { juce::MessageManager::callAsync([sp = juce::Component::SafePointer<Canvas>(this)] { if (sp) sp->closeFinder(); }); };
    Pt sp = model.toScreen(at);
    int maxH = std::max(getHeight() - 16, 120);
    int h = std::min(finder->contentHeight(), maxH);
    int x = int(std::clamp(sp.x, 8.0f, std::max(float(getWidth() - ObjectFinder::width - 8), 8.0f)));
    int y = int(std::clamp(sp.y, 8.0f, std::max(float(getHeight() - h - 8), 8.0f)));
    finder->setBounds(x, y, ObjectFinder::width, h);
    addAndMakeVisible(*finder);
}

void Canvas::closeFinder() {
    if (finder) { removeChildComponent(finder.get()); finder.reset(); }
    if (model.finderAt) { model.finderAt.reset(); model.replaceTarget = {}; model.changed(); }
    repaint();
}

static const std::vector<std::vector<std::string>> finderColumns = { { "I/O", "Clock", "Utility", "Dynamics" }, { "Sequencing", "Instruments" }, { "Modulation", "Loop & Grain" }, { "Effects" } };

ObjectFinder::ObjectFinder(AppModel& m, Pt canvasPoint) : model(m), at(canvasPoint) {
    float colW = (float(width) - float(finderColumns.size() - 1)) / float(finderColumns.size());
    float top = 0;
    if (model.replaceTarget.isNotEmpty()) top = 22;
    float maxY = 0;
    for (size_t c = 0; c < finderColumns.size(); ++c) {
        float x = float(c) * (colW + 1), y = top;
        for (auto& cat : finderColumns[c]) {
            y += 8;
            headings.push_back({ juce::String(cat).toLowerCase(), juce::Rectangle<float>(x + 10, y, colW - 20, 12) });
            y += 14;
            for (auto& s : Registry::all()) if (s.category == cat) { entries.push_back({ &s, juce::Rectangle<float>(x, y, colW, 19) }); y += 19; }
            if (cat == "Effects") {
                // every installed VST3, a level down
                y += 8;
                headings.push_back({ "vst", juce::Rectangle<float>(x + 10, y, colW - 20, 12) });
                y += 14;
                entries.push_back({ nullptr, juce::Rectangle<float>(x, y, colW, 19) }); y += 19;
            }
        }
        maxY = std::max(maxY, y);
    }
    contentH = int(maxY + 6);
}

void ObjectFinder::paint(juce::Graphics& g) {
    auto b = getLocalBounds().toFloat();
    g.setColour(Theme::box()); g.fillRoundedRectangle(b, 3);
    GC gc(g);
    juce::Graphics::ScopedSaveState s(g);
    g.addTransform(juce::AffineTransform::translation(0, -scroll));
    if (model.replaceTarget.isNotEmpty()) if (auto* n = model.nodeFor(model.replaceTarget))
        gc.textLeft("replace " + model.label(*n) + juce::String::fromUTF8(" with\xe2\x80\xa6"), { 10, 14 }, 9, Theme::text());
    float colW = (float(width) - float(finderColumns.size() - 1)) / float(finderColumns.size());
    for (size_t c = 1; c < finderColumns.size(); ++c) { g.setColour(Theme::border().withMultipliedAlpha(0.5f)); g.fillRect(float(c) * (colW + 1) - 1, 0.0f, 1.0f, float(contentH) + scroll); }
    for (auto& [t, r] : headings) gc.textLeft(t, { r.getX(), r.getCentreY() }, 9, Theme::faint());
    for (size_t i = 0; i < entries.size(); ++i) {
        auto& e = entries[i];
        bool h = int(i) == hoverIndex;
        if (h) { g.setColour(Theme::text()); g.fillRect(e.r); }
        gc.textLeft(e.spec ? juce::String::fromUTF8(e.spec->name.c_str()) : juce::String("plugins"), { e.r.getX() + 10, e.r.getCentreY() }, 11, h ? Theme::inverse() : Theme::text());
        if (!e.spec) gc.textRight(juce::String::fromUTF8("\xe2\x80\xba"), { e.r.getRight() - 10, e.r.getCentreY() }, 11, h ? Theme::inverse() : Theme::text());
    }
    g.setColour(Theme::border());
    g.drawRoundedRectangle(b.translated(0, scroll).reduced(0.5f), 3, 1);
}

void ObjectFinder::mouseMove(const juce::MouseEvent& e) {
    int h = -1;
    auto p = e.position.translated(0, scroll);
    for (size_t i = 0; i < entries.size(); ++i) if (entries[i].r.contains(p)) h = int(i);
    if (h != hoverIndex) {
        hoverIndex = h;
        auto* sp = h >= 0 ? entries[size_t(h)].spec : nullptr;
        setTooltip(sp ? juce::String::fromUTF8(sp->summary.c_str()) : h >= 0 ? juce::String("Every installed VST3 plugin, by company") : juce::String());
        repaint();
    }
}
void ObjectFinder::mouseExit(const juce::MouseEvent&) { hoverIndex = -1; repaint(); }
void ObjectFinder::mouseUp(const juce::MouseEvent& e) {
    auto p = e.position.translated(0, scroll);
    for (auto& en : entries) if (en.r.contains(p)) {
        if (!en.spec) {
            juce::PopupMenu menu;
            auto* m = &model; auto where = at; auto close = onClose;
            addPluginList(menu, model, {}, [m, where, close](const PluginInfo& info) { m->addPluginBox(info, where); if (close) close(); });
            menu.showMenuAsync(juce::PopupMenu::Options().withMousePosition());
            return;
        }
        if (model.replaceTarget.isNotEmpty()) model.replaceNode(model.replaceTarget, en.spec->kind);
        else model.addNode(en.spec->kind, at);
        model.finderAt.reset(); model.replaceTarget = {};
        model.changed();
        if (onClose) onClose();
        return;
    }
}
void ObjectFinder::mouseWheelMove(const juce::MouseEvent&, const juce::MouseWheelDetails& w) {
    float maxScroll = std::max(0.0f, float(contentH - getHeight()));
    scroll = std::clamp(scroll - w.deltaY * 200, 0.0f, maxScroll);
    repaint();
}

} // namespace pn
