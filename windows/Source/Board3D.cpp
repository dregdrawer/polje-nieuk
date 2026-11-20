// 3D mode (Board3DView.swift): the board tilted away in perspective, boxes at their own heights, shadows and
// stems under floating boxes, cables between them. Each box is drawn in perspective in small tiles (JUCE draws
// affine pictures, a perspective is made of many); presses are mapped back onto the board, so rows, displays,
// ports and cables work just as on the flat canvas. Drag empty board to pan, a box's dot to lift it, right-drag
// to orbit.
#include "Canvas.h"

namespace pn {

std::pair<double, double> Canvas::Cam::spun(Pt p) const {
    double x = p.x - centre.x, y = p.y - centre.y;
    return { x * std::cos(yaw) - y * std::sin(yaw), x * std::sin(yaw) + y * std::cos(yaw) };
}
Pt Canvas::Cam::project(Pt p, double h) const {
    auto [u, v] = spun(p);
    double ww = std::max(w(v, h), 0.05);
    return { float(centre.x + u / ww), float(centre.y + (v * std::cos(tilt) - h * std::sin(tilt)) / ww) };
}
Pt Canvas::Cam::unproject(Pt q, double h) const {
    double k = (q.y - centre.y) / distance;
    double den = std::cos(tilt) + k * std::sin(tilt);
    double v = std::abs(den) < 1e-6 ? 0 : (k * (distance - h * std::cos(tilt)) + h * std::sin(tilt)) / den;
    double u = (q.x - centre.x) * std::max(w(v, h), 0.05);
    double x = u * std::cos(yaw) + v * std::sin(yaw), y = -u * std::sin(yaw) + v * std::cos(yaw);
    return { float(centre.x + x), float(centre.y + y) };
}

Canvas::Cam Canvas::camera() const {
    Cam c;
    c.tilt = model.orbitPitch * juce::MathConstants<double>::pi / 180;
    c.yaw = model.orbitYaw * juce::MathConstants<double>::pi / 180;
    c.centre = { getWidth() / 2.0f, getHeight() * 0.55f };
    return c;
}

static Pt boxSize(const PatchNode& n, const HardwareCounts& hw) {
    if (n.kind == "text") return BoxLayout::textSize(n);
    auto* s = Registry::spec(n.kind);
    return s ? Pt { BoxLayout::width(n), BoxLayout::height(n, *s, hw) } : Pt();
}

std::vector<const PatchNode*> Canvas::drawOrder3D(const Cam& cam) const {
    float s = model.viewScale;
    std::vector<std::tuple<const PatchNode*, double, double>> v;
    for (auto& n : model.patch.nodes) {
        auto sz = boxSize(n, model.hw);
        Pt c = board({ float(n.x) + sz.x / 2, float(n.y) + sz.y / 2 });
        juce::ignoreUnused(s);
        v.push_back({ &n, std::round(n.z.value_or(0) * 100), cam.nearness(c, heightOf(n)) });
    }
    std::stable_sort(v.begin(), v.end(), [](auto& a, auto& b) { return std::get<1>(a) != std::get<1>(b) ? std::get<1>(a) < std::get<1>(b) : std::get<2>(a) < std::get<2>(b); });
    std::vector<const PatchNode*> r;
    for (auto& t : v) r.push_back(std::get<0>(t));
    return r;
}

void Canvas::drawBox3D(juce::Graphics& g, Item& it, const Cam& cam, float px) {
    float s = model.viewScale, sp = s * px;
    float m = it.margin();
    // the box as a picture: static parts and displays, at this zoom
    if (it.cache3D.isNull() || it.key3D != it.key || it.scale3D != sp || it.dirty) {
        int w = int(std::ceil((it.rect.getWidth() + 2 * m) * sp)), h = int(std::ceil((it.rect.getHeight() + 2 * m) * sp));
        if (w <= 0 || h <= 0 || w > 8000 || h > 8000) return;
        it.cache3D = juce::Image(juce::Image::ARGB, w, h, true);
        juce::Graphics ig(it.cache3D);
        ig.addTransform(juce::AffineTransform::translation(m, m).scaled(sp));
        GC gc(ig);
        if (it.kind == Item::module && it.geo) {
            BoxPainter::paint(gc, *it.geo, model, it.selected, it.dropTarget, it.liveRows, it.display.get());
            for (auto& p : it.parts) {
                juce::Graphics::ScopedSaveState save(ig);
                ig.reduceClipRegion(p.lp.rect.getSmallestIntegerContainer());
                ig.addTransform(juce::AffineTransform::translation(p.lp.rect.getX(), p.lp.rect.getY()));
                gc.dimmed(p.lp.dimmed ? 0.35f : 1.0f, [&] { p.lp.draw(gc, { p.lp.rect.getWidth(), p.lp.rect.getHeight() }); });
            }
        } else if (it.kind == Item::text) BoxPainter::paintText(gc, it.node, { it.rect.getWidth(), it.rect.getHeight() }, it.selected, it.editing);
        it.key3D = it.key; it.scale3D = sp;
    }
    double h = heightOf(it.node);
    Pt origin = board(it.rect.getPosition() + dragShift(it.id));
    // picture pixel → screen, through the perspective; drawn in tiles, each placed by three of its corners
    auto toScreen = [&](float ix, float iy) { return cam.project({ origin.x + (ix / sp - m) * s, origin.y + (iy / sp - m) * s }, h); };
    int W = it.cache3D.getWidth(), H = it.cache3D.getHeight();
    int nx = std::clamp(W / 48 + 1, 2, 10), ny = std::clamp(H / 48 + 1, 2, 12);
    for (int ty = 0; ty < ny; ++ty)
        for (int tx = 0; tx < nx; ++tx) {
            int x0 = W * tx / nx, x1 = W * (tx + 1) / nx, y0 = H * ty / ny, y1 = H * (ty + 1) / ny;
            // overlap by a pixel so no seams show between tiles
            int ex = std::min(x1 + 1, W), ey = std::min(y1 + 1, H);
            auto sub = it.cache3D.getClippedImage({ x0, y0, ex - x0, ey - y0 });
            Pt a = toScreen(float(x0), float(y0)), b = toScreen(float(ex), float(y0)), c = toScreen(float(x0), float(ey));
            auto t = juce::AffineTransform::fromTargetPoints(0.0f, 0.0f, a.x, a.y, float(ex - x0), 0.0f, b.x, b.y, 0.0f, float(ey - y0), c.x, c.y);
            g.drawImageTransformed(sub, t);
        }
}

void Canvas::paint3D(juce::Graphics& g) {
    g.fillAll(Theme::bg());
    auto cam = camera();
    float s = model.viewScale, px = pixelScale();
    Pt o = model.viewOffset;
    // the grid, in short pieces, only in front of the camera, fading toward the horizon
    {
        double span = std::max(getWidth(), getHeight()) * 3.5;
        double step = std::max(120.0 * s, 30.0);
        double phaseX = std::fmod(double(o.x), step), phaseY = std::fmod(double(o.y), step);
        double x0 = std::floor((cam.centre.x - span) / step) * step + phaseX, y0 = std::floor((cam.centre.y - span) / step) * step + phaseY;
        double x1 = cam.centre.x + span, y1 = cam.centre.y + span;
        const int pieces = 28;
        juce::Path nearP, farP;
        auto line = [&](Pt a, Pt b) {
            for (int k = 0; k < pieces; ++k) {
                float t0 = float(k) / pieces, t1 = float(k + 1) / pieces;
                Pt p0 = a + (b - a) * t0, p1 = a + (b - a) * t1;
                double n0 = cam.nearness(p0), n1 = cam.nearness(p1);
                if (n0 <= 0.12 || n1 <= 0.12) continue;
                auto& path = std::min(n0, n1) > 0.45 ? nearP : farP;
                path.startNewSubPath(cam.project(p0)); path.lineTo(cam.project(p1));
            }
        };
        for (double x = x0; x <= x1; x += step) line({ float(x), float(y0) }, { float(x), float(y1) });
        for (double y = y0; y <= y1; y += step) line({ float(x0), float(y) }, { float(x1), float(y) });
        g.setColour(Theme::gridDot().withMultipliedAlpha(0.9f)); g.strokePath(nearP, juce::PathStrokeType(0.6f));
        g.setColour(Theme::gridDot().withMultipliedAlpha(0.4f)); g.strokePath(farP, juce::PathStrokeType(0.5f));
    }
    auto quad = [&](Rect r, double h) {
        juce::Path p;
        p.startNewSubPath(cam.project(r.getTopLeft(), h)); p.lineTo(cam.project(r.getTopRight(), h));
        p.lineTo(cam.project(r.getBottomRight(), h)); p.lineTo(cam.project(r.getBottomLeft(), h)); p.closeSubPath();
        return p;
    };
    // shadows and stems under floating boxes
    for (auto& n : model.patch.nodes) {
        if (n.z.value_or(0) <= 0.5) continue;
        auto sz = boxSize(n, model.hw);
        Rect r(board({ float(n.x), float(n.y) }), board({ float(n.x) + sz.x, float(n.y) + sz.y }));
        g.setColour(juce::Colours::black.withAlpha(Theme::light ? 0.10f : 0.35f));
        g.fillPath(quad(r, 0));
        juce::Path stem; stem.startNewSubPath(cam.project({ r.getCentreX(), r.getBottom() }, 0)); stem.lineTo(cam.project({ r.getCentreX(), r.getBottom() }, heightOf(n)));
        GC gc(g); gc.stroke(stem, Theme::dim().withMultipliedAlpha(0.6f), 1, false, { 3, 3 });
    }
    // cables between the boxes at their heights
    if (!model.hideCables) {
        juce::Path plain, dashed;
        for (auto& c : model.patch.cables) {
            auto* a = model.nodeFor(c.fromNode); auto* b = model.nodeFor(c.toNode);
            if (!a || !b) continue;
            auto* sa = Registry::spec(a->kind); auto* sb = Registry::spec(b->kind);
            if (!sa || !sb || c.fromPort >= int(BoxLayout::ports(*a, *sa, model.hw).outs.size())) continue;
            auto dest = BoxLayout::destination(*b, *sb, model.hw, c.toPort);
            if (!dest) continue;
            Pt p1 = cam.project(board(BoxLayout::outlet(*a, *sa, model.hw, c.fromPort)), heightOf(*a));
            Pt p2 = cam.project(board(*dest), heightOf(*b));
            float dx = std::max(30.0f, std::abs(p2.x - p1.x) * 0.45f);
            auto& path = c.toPort >= kParamPortBase ? dashed : plain;
            path.startNewSubPath(p1); path.cubicTo(p1.x + dx, p1.y, p2.x - dx, p2.y, p2.x, p2.y);
        }
        GC gc(g);
        gc.stroke(plain, Theme::cable(), 1.5f, true);
        gc.stroke(dashed, Theme::cable(), 1.5f, true, { 4, 3 });
    }
    // the boxes, lower first, then farthest first
    for (auto* n : drawOrder3D(cam)) {
        auto f = items.find(n->id);
        if (f != items.end()) drawBox3D(g, *f->second, cam, px);
    }
    // lift dots
    g.setColour(Theme::text());
    for (auto& n : model.patch.nodes) {
        auto sz = boxSize(n, model.hw);
        Pt d = cam.project(board({ float(n.x) + sz.x - 8 / s, float(n.y) - 12 / s }), heightOf(n));
        g.fillEllipse(d.x - 6, d.y - 6, 12, 12);
    }
}

bool Canvas::down3D(const juce::MouseEvent& e) {
    auto cam = camera();
    start3D = e.position;
    if (e.mods.isPopupMenu()) { mode3D = Mode3D::orbit; pitch3D = model.orbitPitch; yaw3D = model.orbitYaw; return true; }
    float s = model.viewScale;
    // a lift dot
    for (auto& n : model.patch.nodes) {
        auto sz = boxSize(n, model.hw);
        Pt d = cam.project(board({ float(n.x) + sz.x - 8 / s, float(n.y) - 12 / s }), heightOf(n));
        if (d.getDistanceFrom(e.position) < 15) { mode3D = Mode3D::lift; lift3D = n.id; startZ3D = n.z.value_or(0); model.select(n.id); return true; }
    }
    // a box: the press is mapped back onto the board at the box's height, where the flat canvas handles it
    auto order = drawOrder3D(cam);
    for (auto it = order.rbegin(); it != order.rend(); ++it) {
        auto* n = *it;
        double h = heightOf(*n);
        Pt q = cam.unproject(e.position, h), c = model.toCanvas(q);
        auto sz = boxSize(*n, model.hw);
        if (Rect(float(n->x) - 11, float(n->y), sz.x + 22, sz.y).contains(c)) {
            pressH3D = h;
            if (began(q, e)) { mode3D = Mode3D::box; return true; }
        }
    }
    mode3D = Mode3D::pan;
    startOffset3D = model.viewOffset;
    startBoard3D = cam.unproject(e.position);
    return true;
}

void Canvas::drag3D(const juce::MouseEvent& e) {
    auto cam = camera();
    switch (mode3D) {
        case Mode3D::orbit:
            model.orbit(pitch3D - double(e.position.y - start3D.y) * 0.25, yaw3D - double(e.position.x - start3D.x) * 0.3);
            break;
        case Mode3D::lift:
            model.setHeight(lift3D, startZ3D + double(start3D.y - e.position.y) * 1.6 / model.viewScale);
            break;
        case Mode3D::box: moved(cam.unproject(e.position, pressH3D)); break;
        case Mode3D::pan: {
            Pt now = cam.unproject(e.position);
            model.setView(startOffset3D + (now - startBoard3D), model.viewScale);
            break;
        }
        default: break;
    }
    repaint();
}

void Canvas::up3D(const juce::MouseEvent& e) {
    auto cam = camera();
    if (mode3D == Mode3D::box) ended(cam.unproject(e.position, pressH3D));
    else if (mode3D == Mode3D::pan && e.position.getDistanceFrom(start3D) < 3) model.clearSelection();
    if (mode3D != Mode3D::none) model.scheduleAutosave();
    mode3D = Mode3D::none;
    repaint();
}

} // namespace pn
