// arrange's display and the model's side of it — a port of ArrangeView.swift.
#include "Displays.h"
#include "ModulesArrange.h"

namespace pn {

// ---------------------------------------------------------------- view state (not saved with the patch)

struct ArrangeViewState {
    double scroll = 0;            // beats at the lane area's left edge
    float ppb = 14;               // points per beat
    std::set<int> selected;
    std::optional<int> track;     // a selected track: the strip sets its level and pan
    bool cut = false, selecting = false;
    std::optional<Rect> band;
    int version = 0;
};
struct ArrangeDropPreview { int lane; double start, length; juce::String name, path; };

namespace ArrangeViews {
    static std::map<juce::String, ArrangeViewState> state;
    static std::map<juce::String, ArrangeDropPreview> preview;
    static juce::String focused;                 // the box whose clip was clicked last (the Delete key)
    static ArrangeViewState get(const juce::String& id) { auto it = state.find(id); return it == state.end() ? ArrangeViewState() : it->second; }
    template <class F> static void set(const juce::String& id, F f) { auto s = get(id); f(s); s.version++; state[id] = s; liveRefreshNow = true; }
    static double gridStep(float ppb) {
        for (double s : { 0.125, 0.25, 0.5, 1.0, 2.0, 4.0, 8.0, 16.0, 32.0 }) if (float(s) * ppb >= 14) return s;
        return 64;
    }
    static double snap(const PatchNode& n, float ppb) {
        auto it = n.params.find("snap");
        int i = std::clamp(int(std::lround(it == n.params.end() ? 1.0f : it->second)), 0, ArrangeLayout::snapCount - 1);
        double s = ArrangeLayout::snapBeats[i];
        return s < 0 ? std::min(gridStep(ppb), 4.0) : s;
    }
    static double seconds(const juce::File& f) {
        static std::map<juce::String, double> cache;
        auto k = f.getFullPathName();
        if (auto it = cache.find(k); it != cache.end()) return it->second;
        juce::AudioFormatManager fm; fm.registerBasicFormats();
        std::unique_ptr<juce::AudioFormatReader> r(fm.createReaderFor(f));
        double s = r ? double(r->lengthInSamples) / std::max(r->sampleRate, 1.0) : 0;
        cache[k] = s;
        return s;
    }
}

static float nparam(const PatchNode& n, const char* key, float def) { auto it = n.params.find(key); return it == n.params.end() ? def : it->second; }

/// Where things are inside arrange's display (r = the display, box points).
struct ArrangeGeo {
    Rect r;
    int tracks, first, shown;
    float laneH;
    static constexpr float headW = 76, barW = 10;
    ArrangeGeo(Rect rr, const PatchNode& n) : r(rr) {
        tracks = ArrangeLayout::count(nparam(n, "tracks", 8));
        auto v = BoxLayout::arrangeView(n);
        first = v.first; shown = v.shown;
        laneH = std::max((r.getHeight() - BoxLayout::arrangeTop - BoxLayout::arrangeBottom) / float(std::max(shown, 1)), 6.0f);
    }
    bool visible(int k) const { return k >= first && k < first + shown; }
    Rect toolbar() const { return Rect(r.getX(), r.getY(), r.getWidth(), 18); }
    Rect ruler() const { return Rect(r.getX() + headW, r.getY() + 21, r.getWidth() - headW - barW, 15); }
    Rect area() const { return Rect(r.getX() + headW, r.getY() + BoxLayout::arrangeTop, r.getWidth() - headW - barW, laneH * float(shown)); }
    Rect hbar() const { auto a = area(); return Rect(a.getX(), a.getBottom() + 3, a.getWidth(), 9); }
    Rect vbar() const { auto a = area(); return Rect(r.getRight() - barW + 2, a.getY(), barW - 3, a.getHeight()); }
    Rect lane(int k) const { return Rect(r.getX(), r.getY() + BoxLayout::arrangeTop + float(k - first) * laneH, r.getWidth() - barW, laneH); }
    Rect header(int k) const { auto l = lane(k); return Rect(l.getX(), l.getY() + 1, headW - 4, l.getHeight() - 2); }
    Rect button(int k, int b) const { auto h = header(k); return Rect(h.getX() + 18 + float(b) * 17, h.getY() + 1, 15, std::min(12.0f, std::max(h.getHeight() / 2 - 1, 6.0f))); }
    Rect volume(int k) const { auto h = header(k); float vh = std::min(6.0f, h.getHeight() / 3); return Rect(h.getX() + 4, h.getBottom() - vh - 1, h.getWidth() - 10, vh); }
    int laneAt(float y) const { return first + std::clamp(int(std::floor((y - area().getY()) / laneH)), 0, shown - 1); }
    float x(double beat, const ArrangeViewState& v) const { return area().getX() + float(beat - v.scroll) * v.ppb; }
    double beat(float xx, const ArrangeViewState& v) const { return v.scroll + double((xx - area().getX()) / v.ppb); }
    Rect clipRect(const ArrangeClip& c, const ArrangeViewState& v) const { auto l = lane(c.track); return Rect(x(c.start, v), l.getY() + 1, float(c.length) * v.ppb, l.getHeight() - 2); }
    Rect gainBar() const { return Rect(r.getX() + headW, r.getBottom() - 17, std::max((r.getWidth() - headW) * 0.55f - 66, 40.0f), 13); }
    Rect gainLabel() const { return Rect(r.getX(), r.getBottom() - 17, headW - 4, 13); }
    Rect pitchLabel() const { auto g = gainBar(); return Rect(g.getRight() + 66, g.getY(), 56, 13); }
    Rect pitchBar() const { auto g = gainBar(); float xx = g.getRight() + 66 + 58; return Rect(xx, g.getY(), std::max(r.getRight() - xx - 50, 30.0f), 13); }
    static constexpr float gainMin = -24, gainMax = 12, pitchRange = 24, trackMin = -24, trackMax = 6;
    std::vector<std::pair<std::string, Rect>> tools() const {
        auto t = toolbar();
        std::vector<std::pair<std::string, Rect>> out;
        float xx = t.getX();
        for (auto& [name, w] : std::vector<std::pair<std::string, float>> { { "play", 22 }, { "stop", 22 }, { "rec", 44 }, { "loop", 38 }, { "sel", 30 }, { "cut", 30 }, { "dup", 30 }, { "del", 30 } }) {
            out.push_back({ name, Rect(xx, t.getY(), w, t.getHeight()) }); xx += w + 4;
        }
        out.push_back({ "export", Rect(t.getRight() - 150, t.getY(), 46, t.getHeight()) });
        out.push_back({ "in", Rect(t.getRight() - 20, t.getY(), 20, t.getHeight()) });
        out.push_back({ "out", Rect(t.getRight() - 44, t.getY(), 20, t.getHeight()) });
        return out;
    }
};

static juce::String fileName(const juce::String& p) { return p.fromLastOccurrenceOf("/", false, false).fromLastOccurrenceOf("\\", false, false); }

class ArrangeDisplay : public NativeDisplay {
public:
    using NativeDisplay::NativeDisplay;
    ArrangeNode* an() { return dynamic_cast<ArrangeNode*>(dsp()); }
    ArrangeViewState view() const { return ArrangeViews::get(id); }
    int trackCount() const { return ArrangeLayout::count(p("tracks", 8)); }

    // ---------------------------------------------------------------- drawing

    std::vector<LivePart> parts(Rect r) override {
        ArrangeGeo geo(r, node);
        auto main = part("arrange", r, [this] {
            auto* n = an(); if (!n) return int64_t(0);
            int64_t h = int64_t(view().version) * 31 + ArrangeAudio::shared().generation;
            for (auto& c : work ? *work : n->clips) LiveSig::mix(h, int64_t(c.start * 1000) + c.track * 7 + int64_t(c.length * 1000) * 13 + int64_t(c.fadeIn * 100) + int64_t(c.fadeOut * 300) + int64_t(c.gain * 100) + int64_t(c.transpose));
            LiveSig::mix(h, LiveSig::q(n->readouts[ArrangeLayout::secondsPerBeatSlot], 1000));
            LiveSig::mix(h, int64_t(n->loopRange.first * 100) + int64_t(n->loopRange.second * 1000));
            if (loopDrag) LiveSig::mix(h, int64_t(loopDrag->first * 100) + int64_t(loopDrag->second * 1000));
            if (auto it = ArrangeViews::preview.find(id); it != ArrangeViews::preview.end()) LiveSig::mix(h, it->second.lane + int64_t(it->second.start * 100) + it->second.name.hashCode());
            LiveSig::mix(h, p("loop", 0) > 0.5f ? 1 : 0);
            LiveSig::mix(h, int64_t(p("tracks", 8)) * 100 + int64_t(p("vscroll", 0)));
            LiveSig::mix(h, int64_t(node.dh.value_or(0) * 8) + int64_t(node.w.value_or(0) * 8));
            LiveSig::mix(h, CustomColours::version * 2 + (Theme::light ? 1 : 0));
            return h;
        }, [this, geo](GC& g, Pt) { drawMain(g, geo, false); });
        auto chrome = part("arrangeChrome", r, [this] {
            auto* n = an(); if (!n) return int64_t(0);
            int64_t h = int64_t(view().version) * 31 + chromeTick;
            LiveSig::mix(h, LiveSig::patch(node));
            for (auto& c : work ? *work : n->clips) LiveSig::mix(h, int64_t(c.gain * 1000) + int64_t(c.transpose));
            for (float v : trackWork ? *trackWork : n->trackData) LiveSig::mix(h, int64_t(v * 1000));
            LiveSig::mix(h, model.transport == 0 ? 1 : 0);
            LiveSig::mix(h, int64_t(n->clips.size()));
            LiveSig::mix(h, CustomColours::version * 2 + (Theme::light ? 1 : 0));
            return h;
        }, [this, geo](GC& g, Pt) { drawMain(g, geo, true); });
        auto overlay = part("arrangePlay", r, [this] {
            auto* n = an(); if (!n) return int64_t(0);
            int64_t h = LiveSig::q(n->readouts[ArrangeLayout::posSlot] * view().ppb, 1);
            LiveSig::mix(h, LiveSig::q(n->readouts[ArrangeLayout::recSlot], 2));
            for (int t = 0; t < trackCount(); ++t) LiveSig::mix(h, LiveSig::q(n->levels[size_t(t)], 30));
            LiveSig::mix(h, view().version);
            LiveSig::mix(h, model.isRunning ? 1 : 0);
            return h;
        }, [this, geo](GC& g, Pt) { drawLive(g, geo); });
        return { main, chrome, overlay };
    }

    void drawMain(GC& g, const ArrangeGeo& geo, bool chrome) {
        auto* n = an(); if (!n) return;
        Pt o { -geo.r.getX(), -geo.r.getY() };
        auto at = [&](Rect q) { return q.translated(o.x, o.y); };
        auto v = view();
        double spbSec = std::max(double(n->readouts[ArrangeLayout::secondsPerBeatSlot]), 0.01);
        bool recOn = p("rec", 0) > 0.5f, loopOn = p("loop", 0) > 0.5f, playing = model.transport == 0;
        if (chrome) {
            for (auto& [name, q] : geo.tools()) {
                auto b = at(q);
                bool on = (name == "rec" && recOn) || (name == "loop" && loopOn) || (name == "cut" && v.cut) || (name == "play" && playing) || (name == "sel" && v.selecting);
                bool enabled = !((name == "dup" || name == "del") && v.selected.empty());
                g.fillRounded(b, 2, on ? Theme::text() : Theme::row());
                auto col = on ? Theme::inverse() : (name == "rec" ? Theme::rec : (enabled ? Theme::text() : Theme::faint()));
                auto c = b.getCentre();
                if (name == "play") { juce::Path pp; pp.addTriangle(c.x - 3, c.y - 4.5f, c.x + 4.5f, c.y, c.x - 3, c.y + 4.5f); g.fill(pp, col); }
                else if (name == "stop") g.fill(Rect(c.x - 3.5f, c.y - 3.5f, 7, 7), col);
                else {
                    std::map<std::string, juce::String> labels { { "export", "export" }, { "rec", juce::String::fromUTF8("\xe2\x97\x8f rec") }, { "loop", "loop" }, { "sel", "sel" },
                                                                 { "cut", "cut" }, { "dup", "dup" }, { "del", "del" }, { "in", "+" }, { "out", juce::String::fromUTF8("\xe2\x88\x92") } };
                    g.text(labels[name], c, 9, col, name == "rec");
                }
            }
        }
        // ruler, grid, the loop range
        auto ru = at(geo.ruler());
        auto lr = loopDrag ? *loopDrag : n->loopRange;
        double la = lr.first, lb = lr.second;
        if (!chrome) {
            g.fill(ru, Theme::row());
            float lx0 = std::max(geo.x(la, v), geo.area().getX()), lx1 = std::min(geo.x(lb, v), geo.area().getRight());
            if (lx1 > lx0) g.fill(Rect(lx0 + o.x, ru.getY(), lx1 - lx0, ru.getHeight()), loopOn ? Theme::fill() : Theme::faint().withMultipliedAlpha(0.5f));
        }
        double step = ArrangeViews::gridStep(v.ppb);
        float barPx = 4 * v.ppb;
        int labelEvery = barPx >= 40 ? 1 : (barPx >= 20 ? 2 : (barPx >= 10 ? 4 : (barPx >= 5 ? 8 : 16)));
        double b0 = geo.beat(geo.area().getX(), v), b1 = geo.beat(geo.area().getRight(), v);
        juce::Path minor, beats, bars;
        auto areaS = at(geo.area());
        if (!chrome) {
            for (long k = long(std::floor(std::max(b0, 0.0) / step)); double(k) * step <= b1; ++k) {
                double b = double(k) * step;
                float xx = geo.x(b, v) + o.x;
                if (xx < ru.getX() - 1) continue;
                bool isBar = std::fmod(b, 4.0) == 0, isBeat = std::fmod(b, 1.0) == 0;
                juce::Rectangle<float> line(xx, areaS.getY(), isBar ? 0.75f : 0.5f, areaS.getHeight());
                (isBar ? bars : isBeat ? beats : minor).addRectangle(line);
                if (isBar) { int bar = int(b / 4); if (bar % labelEvery == 0) g.textLeft(juce::String(bar + 1), { xx + 3, ru.getCentreY() }, 8, Theme::text()); }
                else if (isBeat && v.ppb >= 36) g.textLeft(juce::String(int(b / 4) + 1) + "." + juce::String(int(std::fmod(b, 4.0)) + 1), { xx + 2, ru.getCentreY() }, 7, Theme::dim());
            }
        }
        // lanes and their headers
        auto& tracks = trackWork ? *trackWork : n->trackData;
        for (int k = geo.first; k < geo.first + geo.shown; ++k) {
            auto l = at(geo.lane(k));
            auto h = at(geo.header(k));
            if (!chrome) {
                if (k % 2 == 1) g.fill(Rect(l.getX() + ArrangeGeo::headW, l.getY(), l.getWidth() - ArrangeGeo::headW, l.getHeight()), Theme::shade());
                if (v.track == k && v.selected.empty()) g.fill(Rect(l.getX() + ArrangeGeo::headW, l.getY(), l.getWidth() - ArrangeGeo::headW, l.getHeight()), Theme::selected().withAlpha(0.07f));
                continue;
            }
            g.fillRounded(h, 2, Theme::row());
            if (v.track == k && v.selected.empty()) g.strokeRounded(h.reduced(0.5f), 2, Theme::selected(), 1.5f);
            size_t f = size_t(k * ArrangeLayout::trackFields);
            bool small = geo.laneH < 18;
            g.textLeft(juce::String(k + 1), { h.getX() + 4, at(geo.button(k, 0)).getCentreY() }, small ? 8.0f : 10.0f, Theme::text(), true);
            const char* labels[] = { "M", "S", "\xe2\x97\x8f" };
            for (int b = 0; b < 3; ++b) {
                auto q = at(geo.button(k, b));
                bool on = tracks[f + 2 + size_t(b)] > 0.5f;
                g.fillRounded(q, 2, on ? (b == 2 ? Theme::rec : Theme::text()) : Theme::box());
                g.text(juce::String::fromUTF8(labels[b]), q.getCentre(), small ? 6.0f : 8.0f, on ? Theme::inverse() : (b == 2 ? Theme::rec : Theme::dim()), true);
            }
            auto vq = at(geo.volume(k));
            g.fillRounded(vq, 1, Theme::box());
            g.fillRounded(Rect(vq.getX(), vq.getY(), vq.getWidth() * std::clamp(tracks[f] / 2, 0.0f, 1.0f), vq.getHeight()), 1, Theme::fill());
            g.fill(Rect(vq.getCentreX(), vq.getY() - 1, 0.75f, vq.getHeight() + 2), Theme::dim());
        }
        if (chrome) {
            // scrollbars
            auto hb = at(geo.hbar());
            g.fillRounded(hb, 3, Theme::row());
            double total = contentBeats(*n, geo, v);
            float tx = hb.getX() + hb.getWidth() * float(v.scroll / total);
            float tw = std::max(hb.getWidth() * float(double(geo.area().getWidth() / v.ppb) / total), 12.0f);
            g.fillRounded(Rect(std::min(tx, hb.getRight() - tw), hb.getY() + 1, tw, hb.getHeight() - 2), 3, Theme::fill());
            auto vb = at(geo.vbar());
            g.fillRounded(vb, 3, Theme::row());
            float th = vb.getHeight() * float(geo.shown) / float(geo.tracks), ty = vb.getY() + vb.getHeight() * float(geo.first) / float(geo.tracks);
            g.fillRounded(Rect(vb.getX() + 1, ty, vb.getWidth() - 2, th), 3, geo.shown < geo.tracks ? Theme::fill() : Theme::faint().withMultipliedAlpha(0.4f));
            drawStrip(g, geo, *n, v, at, tracks);
            return;
        }
        g.fill(minor, Theme::border().withMultipliedAlpha(0.22f));
        g.fill(beats, Theme::border().withMultipliedAlpha(0.45f));
        g.fill(bars, Theme::border().withMultipliedAlpha(0.9f));
        auto& clips = work ? *work : n->clips;
        g.clipped(areaS, [&] {
            for (size_t i = 0; i < clips.size(); ++i) {
                auto& c = clips[i];
                if (!geo.visible(c.track)) continue;
                auto q = at(geo.clipRect(c, v));
                if (q.getRight() < areaS.getX() || q.getX() > areaS.getRight()) continue;
                auto name = c.file < int(n->files.size()) ? fileName(n->files[size_t(c.file)]) : juce::String("?");
                bool missing = c.file < int(n->files.size()) && ArrangeAudio::shared().isMissing(n->files[size_t(c.file)]);
                drawClip(g, q, c, n->audioFor(c), spbSec * c.speed(), v, areaS, v.selected.count(int(i)) > 0, missing ? "missing: " + name : name, missing, false);
            }
            for (double b : { la, lb }) {
                float xx = geo.x(b, v) + o.x;
                if (xx < areaS.getX() - 1 || xx > areaS.getRight() + 1) continue;
                g.fill(Rect(xx - 0.75f, areaS.getY(), 1.5f, areaS.getHeight()), loopOn ? Theme::selected().withAlpha(0.8f) : Theme::dim().withAlpha(0.5f));
            }
            if (v.band) {
                auto q = at(*v.band);
                g.fill(q, Theme::selected().withAlpha(0.08f));
                juce::Path pp; pp.addRectangle(q.reduced(0.5f));
                g.stroke(pp, Theme::selected(), 1, false, { 3, 2 });
            }
            if (auto it = ArrangeViews::preview.find(id); it != ArrangeViews::preview.end() && geo.visible(it->second.lane)) {
                auto& pv = it->second;
                auto l = at(geo.lane(pv.lane));
                Rect q(geo.x(pv.start, v) + o.x, l.getY() + 1, std::max(float(pv.length) * v.ppb, 30.0f), l.getHeight() - 2);
                ArrangeClip c; c.track = pv.lane; c.start = pv.start; c.length = pv.length;
                auto audio = pv.path.isNotEmpty() ? ArrangeAudio::shared().audio(pv.path) : nullptr;
                drawClip(g, q, c, audio, spbSec, v, areaS, true, pv.name, false, true);
            }
        });
    }

    template <class At>
    void drawStrip(GC& g, const ArrangeGeo& geo, ArrangeNode& n, const ArrangeViewState& v, At at, const std::vector<float>& tracks) {
        auto& clips = work ? *work : n.clips;
        std::vector<int> sel;
        for (int i : v.selected) if (i < int(clips.size())) sel.push_back(i);
        auto gq = at(geo.gainBar()), gl = at(geo.gainLabel());
        bool trackMode = sel.empty() && v.track && *v.track < geo.tracks;
        g.textLeft(trackMode ? "track " + juce::String(*v.track + 1) + " level" : juce::String("clip gain"), { gl.getX() + 2, gl.getCentreY() }, 9,
                   sel.empty() && !trackMode ? Theme::faint() : Theme::dim());
        g.fillRounded(gq, 2, Theme::row());
        auto pq = at(geo.pitchBar()), pl = at(geo.pitchLabel());
        if (trackMode) {
            int k = *v.track;
            float vol = tracks[size_t(k * ArrangeLayout::trackFields)], pan = tracks[size_t(k * ArrangeLayout::trackFields + 1)];
            float db = 20 * std::log10(std::max(vol, 1e-6f));
            float f = vol <= 0.0001f ? 0 : (std::clamp(db, ArrangeGeo::trackMin, ArrangeGeo::trackMax) - ArrangeGeo::trackMin) / (ArrangeGeo::trackMax - ArrangeGeo::trackMin);
            g.fillRounded(Rect(gq.getX(), gq.getY(), gq.getWidth() * f, gq.getHeight()), 2, Theme::fill());
            float zero = gq.getX() + gq.getWidth() * (-ArrangeGeo::trackMin / (ArrangeGeo::trackMax - ArrangeGeo::trackMin));
            g.fill(Rect(zero, gq.getY() - 1, 0.75f, gq.getHeight() + 2), Theme::dim());
            g.textLeft(vol <= 0.0001f ? juce::String("off") : juce::String::formatted("%+.1f dB", db), { gq.getRight() + 6, gq.getCentreY() }, 9, Theme::text());
            g.textLeft("pan", { pl.getX(), pl.getCentreY() }, 9, Theme::dim());
            g.fillRounded(pq, 2, Theme::row());
            float xx = pq.getCentreX() + pq.getWidth() / 2 * pan;
            g.fill(Rect(std::min(xx, pq.getCentreX()), pq.getY(), std::max(std::abs(xx - pq.getCentreX()), 1.5f), pq.getHeight()), Theme::fill());
            g.fill(Rect(pq.getCentreX(), pq.getY() - 1, 0.75f, pq.getHeight() + 2), Theme::dim());
            g.textLeft(std::abs(pan) < 0.01f ? juce::String("C") : juce::String(pan < 0 ? "L" : "R") + juce::String(int(std::round(std::abs(pan) * 100))),
                       { pq.getRight() + 6, pq.getCentreY() }, 9, Theme::text());
            return;
        }
        if (!sel.empty()) {
            int first = *std::min_element(sel.begin(), sel.end());
            auto& c = clips[size_t(first)];
            float db = 20 * std::log10(std::max(c.gain, 1e-6f));
            float f = (std::clamp(db, ArrangeGeo::gainMin, ArrangeGeo::gainMax) - ArrangeGeo::gainMin) / (ArrangeGeo::gainMax - ArrangeGeo::gainMin);
            g.fillRounded(Rect(gq.getX(), gq.getY(), gq.getWidth() * f, gq.getHeight()), 2, Theme::fill());
            float zero = gq.getX() + gq.getWidth() * (-ArrangeGeo::gainMin / (ArrangeGeo::gainMax - ArrangeGeo::gainMin));
            g.fill(Rect(zero, gq.getY() - 1, 0.75f, gq.getHeight() + 2), Theme::dim());
            g.textLeft(juce::String::formatted("%+.1f dB", db) + (sel.size() > 1 ? juce::String::fromUTF8("  \xc3\x97") + juce::String(int(sel.size())) : juce::String()),
                       { gq.getRight() + 6, gq.getCentreY() }, 9, Theme::text());
            auto name = c.file < int(n.files.size()) ? fileName(n.files[size_t(c.file)]) : juce::String();
            if (sel.size() > 1) name += "  + " + juce::String(int(sel.size()) - 1) + " more";
            g.textLeft(fitText(name, 8, gq.getWidth() - 10), { gq.getX() + 5, gq.getCentreY() }, 8, Theme::text());
        } else g.text("select a clip", gq.getCentre(), 8, Theme::faint());
        g.textLeft("transpose", { pl.getX(), pl.getCentreY() }, 9, sel.empty() ? Theme::faint() : Theme::dim());
        g.fillRounded(pq, 2, Theme::row());
        g.fill(Rect(pq.getCentreX(), pq.getY() - 1, 0.75f, pq.getHeight() + 2), Theme::dim());
        if (!sel.empty()) {
            float st = clips[size_t(*std::min_element(sel.begin(), sel.end()))].transpose;
            float xx = pq.getX() + pq.getWidth() * (st + ArrangeGeo::pitchRange) / (2 * ArrangeGeo::pitchRange);
            g.fill(Rect(std::min(xx, pq.getCentreX()), pq.getY(), std::abs(xx - pq.getCentreX()), pq.getHeight()), Theme::fill());
            g.textLeft(juce::String::formatted("%+.0f st", st), { pq.getRight() + 6, pq.getCentreY() }, 9, Theme::text());
        }
    }

    /// One clip: its box, the waveform (summaries when zoomed out, samples zoomed in), fades, name.
    void drawClip(GC& g, Rect q, const ArrangeClip& c, std::shared_ptr<ClipAudio> a, double spbSec, const ArrangeViewState& v,
                  Rect area, bool selected, const juce::String& label, bool missing, bool ghost) {
        g.fillRounded(q, 2, Theme::fill().withMultipliedAlpha(ghost ? 0.35f : 0.55f));
        if (a) {
            juce::Path path;
            float mid = q.getCentreY(), half = q.getHeight() / 2 - 2;
            float x0 = std::max(q.getX(), area.getX()), x1 = std::min(q.getRight(), area.getRight());
            double fpp = spbSec * a->rate / double(v.ppb);
            if (fpp < 1.5) {
                bool first = true;
                for (float xx = x0; xx <= x1; xx += 1) {
                    double pos = (c.offset + double(xx - q.getX()) / double(v.ppb) * spbSec) * a->rate;
                    int k = int(pos);
                    if (k < 0 || k + 1 >= a->frames()) continue;
                    float f = float(pos - double(k));
                    float s = ((a->left[size_t(k)] + (a->left[size_t(k + 1)] - a->left[size_t(k)]) * f) + (a->right[size_t(k)] + (a->right[size_t(k + 1)] - a->right[size_t(k)]) * f)) * 0.5f * c.gain;
                    Pt pt { xx, mid - std::clamp(s, -1.0f, 1.0f) * half };
                    if (first) { path.startNewSubPath(pt); first = false; } else path.lineTo(pt);
                }
                g.stroke(path, Theme::text().withMultipliedAlpha(ghost ? 0.5f : 0.85f), 1);
            } else {
                // a column a point, as one list of rectangles (an outline of thousands of points fills slowly)
                juce::RectangleList<float> cols;
                for (float xx = x0; xx < x1; xx += 1) {
                    int f0 = int((c.offset + double(xx - q.getX()) / double(v.ppb) * spbSec) * a->rate);
                    int f1 = std::max(int((c.offset + double(xx + 1 - q.getX()) / double(v.ppb) * spbSec) * a->rate), f0 + 1);
                    if (f0 < 0 || f0 >= a->frames()) continue;
                    auto [lo, hi] = a->minMax(f0, f1);
                    lo = std::max(lo * c.gain, -1.0f); hi = std::min(hi * c.gain, 1.0f);
                    float top = mid - hi * half, bottom = std::max(mid - lo * half, top + 0.75f);
                    cols.addWithoutMerging(Rect(xx, top, 1, bottom - top));
                }
                g.g.setColour(Theme::text().withMultipliedAlpha(ghost ? 0.45f : 0.75f));
                g.g.fillRectList(cols);
            }
        }
        if (c.fadeIn > 0 || c.fadeOut > 0) {
            juce::Path fp;
            if (c.fadeIn > 0) { fp.startNewSubPath(q.getX(), q.getBottom()); fp.lineTo(q.getX() + float(c.fadeIn) * v.ppb, q.getY()); }
            if (c.fadeOut > 0) { fp.startNewSubPath(q.getRight() - float(c.fadeOut) * v.ppb, q.getY()); fp.lineTo(q.getRight(), q.getBottom()); }
            g.stroke(fp, Theme::text(), 1);
        }
        if (!ghost) for (float hx : { q.getX() + float(c.fadeIn) * v.ppb, q.getRight() - float(c.fadeOut) * v.ppb }) g.fill(Rect(hx - 2.5f, q.getY(), 5, 5), Theme::text());
        auto text = !a && !missing ? juce::String::fromUTF8("loading\xe2\x80\xa6 ") + label : label;
        if (q.getWidth() > 30 && q.getHeight() > 10)
            g.textLeft(fitText(text, 8, q.getWidth() - 10), { std::max(q.getX(), area.getX()) + 5, q.getY() + 6 }, 8, missing ? Theme::rec : Theme::text());
        juce::Path outline; outline.addRoundedRectangle(q.reduced(0.5f), 2);
        if (ghost) g.stroke(outline, Theme::selected(), 1.5f, false, { 3, 2 });
        else g.strokeRounded(q.reduced(0.5f), 2, selected ? Theme::selected() : Theme::border(), selected ? 1.5f : 1);
    }

    void drawLive(GC& g, const ArrangeGeo& geo) {
        auto* n = an(); if (!n) return;
        Pt o { -geo.r.getX(), -geo.r.getY() };
        auto v = view();
        double pos = n->readouts[ArrangeLayout::posSlot];
        auto area = geo.area().translated(o.x, o.y);
        if (n->readouts[ArrangeLayout::recSlot] > 0.75f) {
            double start = n->readouts[ArrangeLayout::recStartSlot];
            for (int k = geo.first; k < geo.first + geo.shown; ++k) {
                if (n->trackData[size_t(k * ArrangeLayout::trackFields + 4)] <= 0.5f) continue;
                auto l = geo.lane(k).translated(o.x, o.y);
                float x0 = std::max(geo.x(start, v) + o.x, area.getX()), x1 = std::min(geo.x(pos, v) + o.x, area.getRight());
                if (x1 > x0) g.fill(Rect(x0, l.getY() + 1, x1 - x0, l.getHeight() - 2), Theme::rec.withAlpha(0.35f));
            }
        }
        float px = geo.x(pos, v) + o.x;
        if (px >= area.getX() && px <= area.getRight())
            g.fill(Rect(px - 0.5f, area.getY() - 17, 1.5f, area.getHeight() + 17), n->readouts[ArrangeLayout::recSlot] > 0.75f ? Theme::rec : Theme::selected());
        for (int k = geo.first; k < geo.first + geo.shown; ++k) {
            auto h = geo.header(k).translated(o.x, o.y);
            float m = std::min(n->levels[size_t(k)], 1.0f);
            g.fill(Rect(h.getRight() - 4, h.getBottom() - h.getHeight() * m, 2.5f, h.getHeight() * m), m > 0.95f ? Theme::meterRed : Theme::meterGreen);
        }
        float rs = n->readouts[ArrangeLayout::recSlot];
        bool waiting = rs > 0.25f && rs < 0.75f;
        int bar = int(std::floor(std::max(pos, 0.0) / 4)) + 1, beat = int(std::floor(std::fmod(std::max(pos, 0.0), 4.0))) + 1;
        auto t = geo.toolbar().translated(o.x, o.y);
        g.textRight(waiting ? juce::String("rec waits for the bar") : juce::String(bar) + "." + juce::String(beat), { t.getRight() - 156, t.getCentreY() }, 9,
                    waiting ? Theme::rec : Theme::dim());
    }

    // ---------------------------------------------------------------- editing

    enum class Op { none, move, trimL, trimR, fadeIn, fadeOut, band, loop, pan, volume, gain, pitch, trackLevel, trackPan, hscroll, vscroll };
    Op op = Op::none;
    ArrangeClip anchor; int opIndex = -1; bool opCopy = false;
    std::vector<int> group;
    std::set<int> bandKeep;
    std::map<int, ArrangeClip> startClips;
    double opBeat = 0; int opInt = 0;
    std::optional<std::vector<ArrangeClip>> work;
    std::optional<std::vector<float>> trackWork;
    std::optional<std::pair<double, double>> loopDrag;
    int64_t chromeTick = 0;

    double spbSec() { auto* n = an(); return std::max(double(n ? n->readouts[ArrangeLayout::secondsPerBeatSlot] : 0.5f), 0.01); }
    double cs(const ArrangeClip& c) { return spbSec() * c.speed(); }
    double snapped(double b, const PointerInfo& info) { double g = ArrangeViews::snap(node, view().ppb); return g > 0 && !info.command ? std::round(b / g) * g : b; }
    void commit(const std::vector<ArrangeClip>& clips) { model.setData(id, ArrangeLayout::clipsKey, ArrangeClip::encode(clips)); }
    void select(const std::set<int>& s) {
        ArrangeViews::set(id, [&](ArrangeViewState& st) { st.selected = s; if (!s.empty()) st.track.reset(); });
        ArrangeViews::focused = s.empty() ? juce::String() : id;
    }
    void redraw() { ArrangeViews::set(id, [](ArrangeViewState&) {}); }
    double contentBeats(ArrangeNode& n, const ArrangeGeo& geo, const ArrangeViewState& v) {
        double last = 0; for (auto& c : n.clips) last = std::max(last, c.end());
        return std::max({ last + 16, n.loopRange.second + 16, v.scroll + double(geo.area().getWidth() / v.ppb), 64.0 });
    }
    void scrollTracks(int f, const ArrangeGeo& geo) { model.setViewParam(id, "vscroll", float(std::clamp(f, 0, std::max(geo.tracks - geo.shown, 0)))); }

    std::optional<ArrangeClip> crop(const ArrangeClip& c, double from, double to) {
        double s = std::max(c.start, from), e = std::min(c.end(), to);
        if (e - s <= 0.001) return std::nullopt;
        auto m = c;
        m.offset = c.offset + (s - c.start) * cs(c);
        m.start = s; m.length = e - s;
        if (s > c.start) m.fadeIn = 0;
        if (e < c.end()) m.fadeOut = 0;
        m.fadeIn = std::min(m.fadeIn, m.length); m.fadeOut = std::min(m.fadeOut, m.length - m.fadeIn);
        return m;
    }
    /// clip i (just trimmed) wins: what it covers on its track is cut out of the others there
    std::vector<ArrangeClip> carve(const std::vector<ArrangeClip>& clips, int i) {
        auto m = clips[size_t(i)];
        std::vector<ArrangeClip> out;
        int mine = -1;
        for (size_t k = 0; k < clips.size(); ++k) {
            auto& c = clips[k];
            if (int(k) == i) { mine = int(out.size()); out.push_back(c); continue; }
            if (c.track != m.track || c.end() <= m.start || c.start >= m.end()) { out.push_back(c); continue; }
            if (auto b = crop(c, -1e18, m.start)) out.push_back(*b);
            if (auto a = crop(c, m.end(), 1e18)) out.push_back(*a);
        }
        if (mine >= 0 && mine != i) { auto x = out[size_t(mine)]; out.erase(out.begin() + mine); out.insert(out.begin() + std::min(i, int(out.size())), x); }
        return out;
    }

    /// The clip under a point and which part: 0 body, 1 left edge, 2 right edge, 3 fade-in handle, 4 fade-out handle.
    std::optional<std::pair<int, int>> hit(Pt pt, const ArrangeGeo& geo) {
        auto* n = an();
        if (!n || !geo.area().contains(pt)) return std::nullopt;
        auto v = view();
        for (int i = int(n->clips.size()) - 1; i >= 0; --i) {
            auto& c = n->clips[size_t(i)];
            if (!geo.visible(c.track)) continue;
            auto q = geo.clipRect(c, v);
            if (!q.expanded(3, 3).contains(pt)) continue;
            float fi = q.getX() + float(c.fadeIn) * v.ppb, fo = q.getRight() - float(c.fadeOut) * v.ppb;
            if (pt.y < q.getY() + 10 && std::abs(pt.x - fi) < 8) return std::make_pair(i, 3);
            if (pt.y < q.getY() + 10 && std::abs(pt.x - fo) < 8) return std::make_pair(i, 4);
            float edge = std::min(6.0f, q.getWidth() / 4);
            if (pt.x < q.getX() + edge) return std::make_pair(i, 1);
            if (pt.x > q.getRight() - edge) return std::make_pair(i, 2);
            return std::make_pair(i, 0);
        }
        return std::nullopt;
    }

    bool press(Pt pt, Rect r, const PointerInfo& info) override {
        ArrangeGeo geo(r, node);
        auto* n = an(); if (!n) return false;
        op = Op::none; work.reset(); trackWork.reset(); loopDrag.reset();
        auto v = view();
        if (geo.toolbar().contains(pt)) return true;
        if (geo.hbar().expanded(0, 2).contains(pt)) {
            double total = contentBeats(*n, geo, v), visible = double(geo.area().getWidth() / v.ppb);
            float thumbX = geo.hbar().getX() + geo.hbar().getWidth() * float(v.scroll / total);
            float thumbW = std::max(geo.hbar().getWidth() * float(visible / total), 12.0f);
            if (pt.x < thumbX || pt.x > thumbX + thumbW) {
                double s = std::max(double((pt.x - geo.hbar().getX()) / geo.hbar().getWidth()) * total - visible / 2, 0.0);
                ArrangeViews::set(id, [&](ArrangeViewState& st) { st.scroll = s; });
            }
            op = Op::hscroll; opBeat = view().scroll;
            return true;
        }
        if (geo.vbar().expanded(2, 0).contains(pt)) {
            float thumbY = geo.vbar().getY() + geo.vbar().getHeight() * float(geo.first) / float(geo.tracks);
            float thumbH = geo.vbar().getHeight() * float(geo.shown) / float(geo.tracks);
            if (pt.y < thumbY || pt.y > thumbY + thumbH) scrollTracks(int((pt.y - geo.vbar().getY()) / geo.vbar().getHeight() * float(geo.tracks)) - geo.shown / 2, geo);
            op = Op::vscroll; opInt = int(std::lround(p("vscroll", 0)));
            return true;
        }
        if (v.track && v.selected.empty() && *v.track < geo.tracks) {
            if (geo.gainBar().expanded(0, 3).contains(pt)) { op = Op::trackLevel; opInt = *v.track; return true; }
            if (geo.pitchBar().expanded(0, 3).contains(pt)) { op = Op::trackPan; opInt = *v.track; return true; }
        }
        if (geo.gainBar().expanded(0, 3).contains(pt) || geo.pitchBar().expanded(0, 3).contains(pt)) {
            startClips.clear();
            for (int i : v.selected) if (i < int(n->clips.size())) startClips[i] = n->clips[size_t(i)];
            if (!startClips.empty()) op = geo.gainBar().expanded(0, 3).contains(pt) ? Op::gain : Op::pitch;
            return true;
        }
        if (geo.ruler().contains(pt)) { op = Op::loop; opBeat = snapped(geo.beat(pt.x, v), info); return true; }
        for (int k = geo.first; k < geo.first + geo.shown; ++k) {
            if (!geo.header(k).contains(pt)) continue;
            if (geo.volume(k).expanded(0, 3).contains(pt)) { op = Op::volume; opInt = k; return true; }
            bool onButton = false;
            for (int b = 0; b < 3; ++b) onButton |= geo.button(k, b).contains(pt);
            if (!onButton) { ArrangeViews::set(id, [&](ArrangeViewState& st) { st.track = k; st.selected.clear(); }); ArrangeViews::focused = {}; }
            return true;
        }
        if (!geo.area().contains(pt)) return false;
        if (auto h = hit(pt, geo)) {
            auto [i, zone] = *h;
            auto c = n->clips[size_t(i)];
            if (info.shift) {
                auto s = v.selected;
                if (s.count(i)) s.erase(i); else s.insert(i);
                select(s); op = Op::band; bandKeep = s;
                return true;
            }
            if (!v.selected.count(i)) select({ i });
            if (v.cut || info.clickCount == 2) { select({ i }); return true; }
            anchor = c; opIndex = i;
            switch (zone) {
                case 1: select({ i }); op = Op::trimL; break;
                case 2: select({ i }); op = Op::trimR; break;
                case 3: select({ i }); op = Op::fadeIn; break;
                case 4: select({ i }); op = Op::fadeOut; break;
                default: op = Op::move; opCopy = info.option; group.assign(view().selected.begin(), view().selected.end());
            }
        } else if (v.selecting || info.shift) {
            bandKeep = info.shift ? v.selected : std::set<int>();
            select(bandKeep);
            op = Op::band;
        } else { select({}); op = Op::pan; opBeat = v.scroll; }
        return true;
    }

    void drag(Pt pt, Rect r, const PointerInfo& info) override {
        ArrangeGeo geo(r, node);
        auto* n = an(); if (!n || op == Op::none) return;
        auto v = view();
        double d = double((pt.x - info.start.x) / v.ppb);
        auto clips = n->clips;
        switch (op) {
            case Op::move: {
                double dBeat = std::max(snapped(anchor.start + d, info), 0.0) - anchor.start;
                int dTrack = geo.laneAt(pt.y) - anchor.track;
                int lo = 99, hi = -1; double earliest = 1e18;
                for (int i : group) if (i < int(clips.size())) { lo = std::min(lo, n->clips[size_t(i)].track); hi = std::max(hi, n->clips[size_t(i)].track); earliest = std::min(earliest, n->clips[size_t(i)].start); }
                if (hi >= 0) dTrack = std::clamp(dTrack, -lo, geo.tracks - 1 - hi);
                if (earliest < 1e18) dBeat = std::max(dBeat, -earliest);
                for (int i : group) {
                    if (i >= int(clips.size())) continue;
                    auto m = n->clips[size_t(i)];
                    m.start += dBeat; m.track += dTrack;
                    if (opCopy) clips.push_back(m); else clips[size_t(i)] = m;
                }
                work = clips;
                break;
            }
            case Op::band: {
                Rect band(std::min(info.start.x, pt.x), std::min(info.start.y, pt.y), std::abs(pt.x - info.start.x), std::abs(pt.y - info.start.y));
                auto s = bandKeep;
                for (size_t i = 0; i < n->clips.size(); ++i) if (geo.visible(n->clips[i].track) && geo.clipRect(n->clips[i], v).intersects(band)) s.insert(int(i));
                ArrangeViews::set(id, [&](ArrangeViewState& st) { st.band = band; st.selected = s; });
                ArrangeViews::focused = s.empty() ? juce::String() : id;
                return;
            }
            case Op::trimL: {
                auto& c = anchor;
                double earliest = c.start - c.offset / cs(c);
                double s = std::min(std::max({ snapped(c.start + d, info), earliest, 0.0 }), c.end() - 1.0 / 64);
                auto m = c;
                m.offset = std::max(c.offset + (s - c.start) * cs(c), 0.0);
                m.start = s; m.length = c.end() - s; m.fadeIn = std::min(m.fadeIn, m.length);
                clips[size_t(opIndex)] = m; work = carve(clips, opIndex);
                break;
            }
            case Op::trimR: {
                auto& c = anchor;
                double latest = 1e18;
                if (auto a = n->audioFor(c)) latest = c.start + (a->seconds() - c.offset) / cs(c);
                double e = std::max(std::min(snapped(c.end() + d, info), latest), c.start + 1.0 / 64);
                auto m = c;
                m.length = e - c.start; m.fadeOut = std::min(m.fadeOut, m.length);
                clips[size_t(opIndex)] = m; work = carve(clips, opIndex);
                break;
            }
            case Op::fadeIn: { auto m = anchor; m.fadeIn = std::clamp(double(pt.x - geo.x(anchor.start, v)) / double(v.ppb), 0.0, anchor.length - anchor.fadeOut); clips[size_t(opIndex)] = m; work = clips; break; }
            case Op::fadeOut: { auto m = anchor; m.fadeOut = std::clamp(double(geo.x(anchor.end(), v) - pt.x) / double(v.ppb), 0.0, anchor.length - anchor.fadeIn); clips[size_t(opIndex)] = m; work = clips; break; }
            case Op::loop: { double b = snapped(geo.beat(pt.x, v), info); loopDrag = std::make_pair(std::max(std::min(opBeat, b), 0.0), std::max(std::max(opBeat, b), 0.0)); break; }
            case Op::pan: { double s = std::max(opBeat - d, 0.0); ArrangeViews::set(id, [&](ArrangeViewState& st) { st.scroll = s; }); return; }
            case Op::hscroll: {
                double total = contentBeats(*n, geo, v);
                double s = std::max(opBeat + double((pt.x - info.start.x) / geo.hbar().getWidth()) * total, 0.0);
                ArrangeViews::set(id, [&](ArrangeViewState& st) { st.scroll = s; });
                return;
            }
            case Op::vscroll: scrollTracks(opInt + int(std::round((pt.y - info.start.y) / geo.vbar().getHeight() * float(geo.tracks))), geo); return;
            case Op::gain: {
                if (startClips.empty()) return;
                auto& c0 = startClips.begin()->second;
                auto q = geo.gainBar();
                float f = std::clamp((pt.x - q.getX()) / q.getWidth(), 0.0f, 1.0f);
                float db = ArrangeGeo::gainMin + f * (ArrangeGeo::gainMax - ArrangeGeo::gainMin);
                float delta = db - 20 * std::log10(std::max(c0.gain, 1e-6f));
                for (auto& [i, c] : startClips) if (i < int(clips.size()))
                    clips[size_t(i)].gain = std::clamp(c.gain * std::pow(10.0f, delta / 20), std::pow(10.0f, ArrangeGeo::gainMin / 20), std::pow(10.0f, ArrangeGeo::gainMax / 20));
                work = clips;
                break;
            }
            case Op::pitch: {
                if (startClips.empty()) return;
                auto& c0 = startClips.begin()->second;
                auto q = geo.pitchBar();
                float st = (std::clamp((pt.x - q.getX()) / q.getWidth(), 0.0f, 1.0f) * 2 - 1) * ArrangeGeo::pitchRange;
                float delta = std::round(st) - c0.transpose;
                for (auto& [i, c] : startClips) {
                    if (i >= int(clips.size())) continue;
                    auto m = c;
                    m.transpose = std::clamp(c.transpose + delta, -ArrangeGeo::pitchRange, ArrangeGeo::pitchRange);
                    double k = c.speed() / m.speed();
                    m.length = c.length * k; m.fadeIn = c.fadeIn * k; m.fadeOut = c.fadeOut * k;
                    clips[size_t(i)] = m;
                }
                work = clips;
                break;
            }
            case Op::trackLevel: case Op::trackPan: case Op::volume: {
                auto t = n->trackData;
                size_t f = size_t(opInt * ArrangeLayout::trackFields);
                if (op == Op::trackLevel) {
                    auto q = geo.gainBar();
                    float x01 = std::clamp((pt.x - q.getX()) / q.getWidth(), 0.0f, 1.0f);
                    t[f] = x01 < 0.01f ? 0 : std::min(std::pow(10.0f, (ArrangeGeo::trackMin + x01 * (ArrangeGeo::trackMax - ArrangeGeo::trackMin)) / 20), 2.0f);
                } else if (op == Op::trackPan) {
                    auto q = geo.pitchBar();
                    float pv = std::clamp((pt.x - q.getX()) / q.getWidth(), 0.0f, 1.0f) * 2 - 1;
                    t[f + 1] = std::abs(pv) < 0.04f ? 0 : pv;
                } else {
                    auto q = geo.volume(opInt);
                    t[f] = std::clamp((pt.x - q.getX()) / q.getWidth(), 0.0f, 1.0f) * 2;
                }
                trackWork = t;
                n->setData(ArrangeLayout::tracksKey, t);        // heard while dragging; saved on release
                chromeTick++;
                liveRefreshNow = true;
                return;                                          // only the headers / strip change
            }
            default: return;
        }
        redraw();
    }

    void release(Pt pt, Rect r, const PointerInfo& info) override {
        ArrangeGeo geo(r, node);
        auto* n = an();
        auto finish = [&] {
            bool hadBand = view().band.has_value();
            op = Op::none; work.reset(); trackWork.reset(); loopDrag.reset();
            if (hadBand) ArrangeViews::set(id, [](ArrangeViewState& st) { st.band.reset(); }); else chromeTick++;
        };
        if (!n) { finish(); return; }
        auto v = view();
        if (!info.moved) {
            if (geo.toolbar().contains(pt)) { tool(geo, pt); finish(); return; }
            if (geo.ruler().contains(pt) && info.clickCount == 2) { duplicateLoop(); finish(); return; }
            if (v.track && v.selected.empty() && *v.track < geo.tracks && (geo.gainBar().expanded(0, 3).contains(pt) || geo.pitchBar().expanded(0, 3).contains(pt))) {
                bool level = geo.gainBar().expanded(0, 3).contains(pt);
                if (info.clickCount == 2) {
                    auto t = n->trackData; t[size_t(*v.track * ArrangeLayout::trackFields + (level ? 0 : 1))] = level ? 1.0f : 0.0f;
                    model.setData(id, ArrangeLayout::tracksKey, t);
                } else { drag(pt, r, info); if (trackWork) model.setData(id, ArrangeLayout::tracksKey, *trackWork); }
                finish(); return;
            }
            if (geo.pitchBar().expanded(0, 3).contains(pt) || geo.gainBar().expanded(0, 3).contains(pt)) {
                bool gainBar = geo.gainBar().expanded(0, 3).contains(pt);
                if (info.clickCount == 2) {
                    auto clips = n->clips;
                    for (int i : v.selected) {
                        if (i >= int(clips.size())) continue;
                        auto& c = clips[size_t(i)];
                        if (gainBar) c.gain = 1;
                        else { double k = c.speed(); c.transpose = 0; c.length *= k; c.fadeIn *= k; c.fadeOut *= k; }
                    }
                    if (!v.selected.empty()) commit(clips);
                } else if (op == Op::gain || op == Op::pitch) { drag(pt, r, info); if (work) commit(*work); }
                finish(); return;
            }
            for (int k = geo.first; k < geo.first + geo.shown; ++k) {
                for (int b = 0; b < 3; ++b) if (geo.button(k, b).contains(pt)) {
                    auto t = n->trackData; size_t f = size_t(k * ArrangeLayout::trackFields + 2 + b);
                    t[f] = t[f] > 0.5f ? 0.0f : 1.0f;
                    model.setData(id, ArrangeLayout::tracksKey, t);
                    finish(); return;
                }
                if (geo.volume(k).expanded(0, 3).contains(pt) && info.clickCount == 2) {
                    auto t = n->trackData; t[size_t(k * ArrangeLayout::trackFields)] = 1;
                    model.setData(id, ArrangeLayout::tracksKey, t);
                    finish(); return;
                }
            }
            if (auto h = hit(pt, geo); h && (v.cut || info.clickCount == 2) && !info.shift) split(h->first, snapped(geo.beat(pt.x, v), info));
            finish(); return;
        }
        if (work) {
            int count = int(work->size());
            commit(*work);
            if (op == Op::move && opCopy) { std::set<int> s; for (int i = count - int(group.size()); i < count; ++i) s.insert(i); select(s); }
        }
        if (trackWork) model.setData(id, ArrangeLayout::tracksKey, *trackWork);
        if (loopDrag && loopDrag->second - loopDrag->first > 0.05) model.setData(id, ArrangeLayout::loopKey, { float(loopDrag->first), float(loopDrag->second) });
        finish();
    }

    void tool(const ArrangeGeo& geo, Pt pt) {
        std::string name;
        for (auto& [nm, q] : geo.tools()) if (q.contains(pt)) name = nm;
        auto* n = an();
        if (name == "play") model.setTransport(0);
        else if (name == "stop") model.setTransport(2);
        else if (name == "rec") setParam("rec", p("rec", 0) > 0.5f ? 0 : 1);
        else if (name == "loop") setParam("loop", p("loop", 0) > 0.5f ? 0 : 1);
        else if (name == "cut") ArrangeViews::set(id, [](ArrangeViewState& s) { s.cut = !s.cut; if (s.cut) s.selecting = false; });
        else if (name == "sel") ArrangeViews::set(id, [](ArrangeViewState& s) { s.selecting = !s.selecting; if (s.selecting) s.cut = false; });
        else if (name == "dup") duplicateSelection();
        else if (name == "del") deleteSelection();
        else if (name == "export") exportLoop();
        else if ((name == "in" || name == "out") && n) {
            float f = name == "in" ? 1.5f : 1 / 1.5f;
            if (p("loop", 0) > 0.5f) {
                double mid = (n->loopRange.first + n->loopRange.second) / 2;
                float w = geo.area().getWidth();
                ArrangeViews::set(id, [&](ArrangeViewState& s) { s.ppb = std::clamp(s.ppb * f, 0.5f, 2000.0f); s.scroll = std::max(mid - double(w / 2 / s.ppb), 0.0); });
            } else zoom(f, geo, std::nullopt);
        }
    }

    void zoom(float f, const ArrangeGeo& geo, std::optional<float> around) {
        float cx = around ? *around : geo.area().getCentreX();
        double b = geo.beat(cx, view());
        float ax = geo.area().getX();
        ArrangeViews::set(id, [&](ArrangeViewState& s) { s.ppb = std::clamp(s.ppb * f, 0.5f, 2000.0f); s.scroll = std::max(b - double((cx - ax) / s.ppb), 0.0); });
    }

    bool wheelXY(Pt pt, Rect r, float dx, float dy, bool inertial) override {
        ArrangeGeo geo(r, node);
        if (!geo.area().contains(pt) && !geo.ruler().contains(pt)) return false;
        if (inertial) return true;                                   // the swipe's momentum: the view stops with the fingers
        if (std::abs(dx) > std::abs(dy)) {                           // sideways: along the timeline
            ArrangeViews::set(id, [&](ArrangeViewState& s) { s.scroll = std::max(s.scroll - double(dx * 300 / s.ppb), 0.0); });
            return true;
        }
        return wheel(pt, r, dy);
    }
    bool wheel(Pt pt, Rect r, float dy) override {
        ArrangeGeo geo(r, node);
        if (!geo.area().contains(pt) && !geo.ruler().contains(pt)) return false;
        if (juce::ModifierKeys::currentModifiers.isShiftDown() || juce::ModifierKeys::currentModifiers.isCommandDown()) {
            ArrangeViews::set(id, [&](ArrangeViewState& s) { s.scroll = std::max(s.scroll - double(dy * 300 / s.ppb), 0.0); });
        } else zoom(std::exp(std::clamp(dy * 256, -60.0f, 60.0f) * 0.01f), geo, pt.x);
        return true;
    }

    void split(int i, double b) {
        auto* n = an(); if (!n || i >= int(n->clips.size())) return;
        auto c = n->clips[size_t(i)];
        if (!(b > c.start + 0.001 && b < c.end() - 0.001)) return;
        auto left = c, right = c;
        left.length = b - c.start; left.fadeOut = 0;
        right.start = b; right.length = c.end() - b; right.offset = c.offset + (b - c.start) * cs(c); right.fadeIn = 0;
        auto clips = n->clips;
        clips[size_t(i)] = left; clips.push_back(right);
        commit(clips);
        select({ int(clips.size()) - 1 });
    }
    void duplicateNext(const std::vector<int>& idx) {
        auto* n = an(); if (!n) return;
        double lo = 1e18, hi = -1e18;
        for (int i : idx) if (i < int(n->clips.size())) { lo = std::min(lo, n->clips[size_t(i)].start); hi = std::max(hi, n->clips[size_t(i)].end()); }
        if (lo > hi) return;
        auto clips = n->clips;
        std::set<int> s;
        for (int i : idx) if (i < int(n->clips.size())) { auto c = n->clips[size_t(i)]; c.start += hi - lo; s.insert(int(clips.size())); clips.push_back(c); }
        commit(clips);
        select(s);
    }
    void duplicateSelection() {
        auto* n = an(); if (!n) return;
        std::vector<int> sel;
        for (int i : view().selected) if (i < int(n->clips.size())) sel.push_back(i);
        if (sel.empty()) return;
        if (sel.size() == 1 && n->clips[size_t(sel[0])].length * spbSec() >= 8) { model.arrangeInsertTrack(id, n->clips[size_t(sel[0])].track, true, &sel); select({}); }
        else duplicateNext(sel);
    }
    void deleteSelection() {
        auto* n = an(); if (!n) return;
        auto sel = view().selected;
        std::vector<ArrangeClip> keep;
        for (size_t i = 0; i < n->clips.size(); ++i) if (!sel.count(int(i))) keep.push_back(n->clips[i]);
        commit(keep);
        select({});
    }
    /// double-click on the ruler: what's in the loop is copied right after it; what came after moves later
    void duplicateLoop() {
        auto* n = an(); if (!n) return;
        double a = n->loopRange.first, b = n->loopRange.second, len = b - a;
        if (len <= 0.01) return;
        std::vector<ArrangeClip> out, copies;
        for (auto& c : n->clips) {
            if (auto before = crop(c, -1e18, b)) out.push_back(*before);
            if (auto after = crop(c, b, 1e18)) { after->start += len; out.push_back(*after); }
            if (auto inside = crop(c, a, b)) { inside->start += len; copies.push_back(*inside); }
        }
        std::set<int> s;
        for (size_t k = 0; k < copies.size(); ++k) s.insert(int(out.size() + k));
        out.insert(out.end(), copies.begin(), copies.end());
        commit(out);
        select(s);
    }

    /// export: the loop range as a WAV (and, if wanted, every track with clips there as its own file)
    void exportLoop() {
        auto* n = an(); if (!n) return;
        auto range = n->loopRange;
        double rate = n->sampleRate, sec = spbSec();
        auto nid = id; auto* m = &model;
        juce::NativeMessageBox::showYesNoCancelBox(juce::MessageBoxIconType::QuestionIcon, "Export the loop",
            "Save the loop as a WAV file. Also save each track as its own file (stems)?", nullptr,
            juce::ModalCallbackFunction::create([range, rate, sec, nid, m](int result) {
                if (result == 0) return;
                bool stems = result == 1;
                static std::unique_ptr<juce::FileChooser> chooser;
                chooser = std::make_unique<juce::FileChooser>("Export the loop", juce::File::getSpecialLocation(juce::File::userDocumentsDirectory)
                    .getChildFile("arrangement bars " + juce::String(int(range.first / 4) + 1) + "-" + juce::String(int(std::ceil(range.second / 4))) + ".wav"), "*.wav");
                chooser->launchAsync(juce::FileBrowserComponent::saveMode | juce::FileBrowserComponent::canSelectFiles | juce::FileBrowserComponent::warnAboutOverwriting,
                    [range, rate, sec, nid, m, stems](const juce::FileChooser& fc) {
                        auto f = fc.getResult();
                        auto* an = dynamic_cast<ArrangeNode*>(m->node(nid));
                        if (f == juce::File() || !an) return;
                        if (!f.hasFileExtension("wav")) f = f.withFileExtension("wav");
                        auto r = an->render(range.first, range.second, rate, sec);
                        auto write = [rate](const juce::File& to, const std::vector<float>& l, const std::vector<float>& rr) {
                            to.deleteFile();
                            auto os = to.createOutputStream();
                            if (!os) return;
                            juce::WavAudioFormat wav;
                            auto* raw = os.release();
                            std::unique_ptr<juce::AudioFormatWriter> w(wav.createWriterFor(raw, rate, 2, 32, {}, 0));
                            if (!w) { delete raw; return; }
                            const float* ch[2] = { l.data(), rr.data() };
                            w->writeFromFloatArrays(ch, 2, int(l.size()));
                        };
                        if (stems) for (auto& [t, lr] : r.tracks) write(f.getSiblingFile(f.getFileNameWithoutExtension() + " - track " + juce::String(t + 1) + ".wav"), lr.first, lr.second);
                        write(f, r.l, r.r);
                        f.revealToUser();
                    });
            }));
    }

    std::optional<std::vector<MenuItem>> menu(Pt pt, Rect r) override {
        ArrangeGeo geo(r, node);
        auto* n = an(); if (!n) return std::nullopt;
        auto* m = &model; auto nid = id;
        for (int k = geo.first; k < geo.first + geo.shown; ++k) {
            if (!geo.header(k).contains(pt)) continue;
            std::vector<MenuItem> items { MenuItem::section("track " + juce::String(k + 1)) };
            MenuItem a; a.title = "duplicate track"; a.enabled = geo.tracks < ArrangeLayout::tracks; a.action = [m, nid, k] { m->arrangeInsertTrack(nid, k, true); };
            MenuItem b; b.title = "insert an empty track below"; b.enabled = geo.tracks < ArrangeLayout::tracks; b.action = [m, nid, k] { m->arrangeInsertTrack(nid, k, false); };
            MenuItem c; c.title = "clear its clips"; c.action = [this, k] {
                auto* n = an(); if (!n) return;
                std::vector<ArrangeClip> keep; for (auto& cl : n->clips) if (cl.track != k) keep.push_back(cl);
                commit(keep); select({});
            };
            MenuItem d; d.title = "delete track"; d.enabled = geo.tracks > 1; d.action = [m, nid, k] { m->arrangeDeleteTrack(nid, k); };
            items.insert(items.end(), { a, b, c, d });
            return items;
        }
        if (auto h = hit(pt, geo)) {
            int i = h->first;
            if (!view().selected.count(i)) select({ i });
            double b = geo.beat(pt.x, view());
            auto c = n->clips[size_t(i)];
            std::vector<MenuItem> items { MenuItem::section(juce::String::formatted("clip  %+.1f dB", 20 * std::log10(std::max(c.gain, 1e-6f)))) };
            auto add = [&](const juce::String& t, std::function<void()> f) { MenuItem it; it.title = t; it.action = f; items.push_back(it); };
            add("split here", [this, i, b] { split(i, b); });
            add("duplicate (next to it)", [this] { auto s = view().selected; duplicateNext(std::vector<int>(s.begin(), s.end())); });
            add("duplicate onto a new track", [m, nid, c, i] { std::vector<int> only { i }; m->arrangeInsertTrack(nid, c.track, true, &only); });
            add("duplicate the whole track", [m, nid, c] { m->arrangeInsertTrack(nid, c.track, true); });
            add("delete", [this] { deleteSelection(); });
            items.push_back(MenuItem::divider());
            auto gain = [this, i](std::optional<float> db) {
                auto* n = an(); if (!n || i >= int(n->clips.size())) return;
                auto clips = n->clips;
                clips[size_t(i)].gain = db ? std::clamp(clips[size_t(i)].gain * std::pow(10.0f, *db / 20), 0.0625f, 4.0f) : 1.0f;
                commit(clips);
            };
            add("louder (+1.5 dB)", [gain] { gain(1.5f); });
            add(juce::String::fromUTF8("quieter (\xe2\x88\x92" "1.5 dB)"), [gain] { gain(-1.5f); });
            add("gain 0 dB", [gain] { gain(std::nullopt); });
            add("remove fades", [this, i] {
                auto* n = an(); if (!n || i >= int(n->clips.size())) return;
                auto clips = n->clips; clips[size_t(i)].fadeIn = 0; clips[size_t(i)].fadeOut = 0; commit(clips);
            });
            return items;
        }
        if (geo.area().contains(pt)) {
            std::vector<MenuItem> items;
            MenuItem a; a.title = "zoom in"; a.action = [this, geo, pt] { zoom(1.5f, geo, pt.x); };
            MenuItem b; b.title = "zoom out"; b.action = [this, geo, pt] { zoom(1 / 1.5f, geo, pt.x); };
            MenuItem c; c.title = "back to the start"; c.action = [nid] { ArrangeViews::set(nid, [](ArrangeViewState& s) { s.scroll = 0; }); };
            items.insert(items.end(), { a, b, c });
            return items;
        }
        return std::nullopt;
    }

    std::optional<std::pair<juce::String, juce::String>> help(Pt pt, Rect r) override {
        ArrangeGeo geo(r, node);
        auto v = view();
        for (auto& [name, q] : geo.tools()) {
            if (!q.contains(pt)) continue;
            static const std::map<std::string, std::pair<const char*, const char*>> t {
                { "play", { "play", "Starts the patch's transport (every clock, sequencer and arrange box). With loop on it starts at the loop." } },
                { "stop", { "stop", "Stops the transport; the next play starts from the beginning (or the loop's start)." } },
                { "rec", { "record armed tracks", "Records every armed track to its own file, from the next bar (or straight away when you press play). When you stop, each take lands as a clip where it was played." } },
                { "loop", { "loop", "Switches looping on and off. Drag on the bar ruler to set where the loop is." } },
                { "sel", { "select tool", "Drag on empty space to draw a box round clips and select them all. Shift-click adds or removes one. Move, duplicate and delete them together." } },
                { "cut", { "cut tool", "Click a clip to split it there (on the snap grid; hold Ctrl for anywhere). A double-click splits too, without the tool." } },
                { "dup", { "duplicate", "A clip shorter than 8 seconds (or several clips): a copy right after it. A longer clip: a copy on a new track below. Right-click for the other kinds." } },
                { "del", { "delete", "Deletes the selected clips (the Delete key does too)." } },
                { "export", { "export", "Saves the loop range as a WAV file (you choose where), with each track as its own file too if you like (stems). Only the clips are rendered, not what comes into the inlets." } },
                { "in", { "zoom in", "Zooms the timeline in (the scroll wheel too). With loop on it zooms onto the loop." } },
                { "out", { "zoom out", "Zooms the timeline out." } } };
            if (auto it = t.find(name); it != t.end()) return std::make_pair(juce::String(it->second.first), juce::String(it->second.second));
        }
        if (v.track && v.selected.empty() && *v.track < geo.tracks) {
            if (geo.gainBar().expanded(0, 3).contains(pt)) return std::make_pair(juce::String("track level"), juce::String::fromUTF8("The selected track's level, \xe2\x88\x92" "24 \xe2\x80\xa6 +6 dB (all the way left: off). Double-click: back to 0 dB."));
            if (geo.pitchBar().expanded(0, 3).contains(pt)) return std::make_pair(juce::String("pan"), juce::String::fromUTF8("The selected track's place left \xe2\x80\x93 right. Double-click: back to the middle."));
        }
        if (geo.gainBar().expanded(0, 3).contains(pt)) return std::make_pair(juce::String("clip gain"), juce::String::fromUTF8("The level of the selected clips, \xe2\x88\x92" "24 \xe2\x80\xa6 +12 dB. Double-click: back to 0 dB."));
        if (geo.pitchBar().expanded(0, 3).contains(pt)) return std::make_pair(juce::String("transpose"), juce::String::fromUTF8("Re-pitches the selected clips, \xe2\x88\x92" "24 \xe2\x80\xa6 +24 semitones, like a record's speed: up is higher and faster. Double-click: back to 0."));
        if (geo.hbar().expanded(0, 2).contains(pt)) return std::make_pair(juce::String("timeline scrollbar"), juce::String("Drag it to move along the arrangement; click beside it to jump there. The scroll wheel zooms; with Shift it scrolls."));
        if (geo.vbar().expanded(2, 0).contains(pt)) return std::make_pair(juce::String("tracks scrollbar"), juce::String("With more tracks than fit, drag it to see the others (or make the box taller). Their inlets and outlets move with them."));
        if (geo.ruler().contains(pt)) return std::make_pair(juce::String("bar ruler"), juce::String("Drag along it to set the loop. Double-click it to duplicate everything inside the loop: the copy goes right after it and what came after moves later."));
        for (int k = geo.first; k < geo.first + geo.shown; ++k) {
            if (!geo.header(k).contains(pt)) continue;
            if (geo.button(k, 0).contains(pt)) return std::make_pair(juce::String("mute"), "Silences track " + juce::String(k + 1) + ".");
            if (geo.button(k, 1).contains(pt)) return std::make_pair(juce::String("solo"), juce::String("Plays only the soloed tracks."));
            if (geo.button(k, 2).contains(pt)) return std::make_pair(juce::String("arm"), "Track " + juce::String(k + 1) + " records its inlets when you press rec.");
            if (geo.volume(k).expanded(0, 3).contains(pt)) return std::make_pair(juce::String("volume"), juce::String("Drag for the track's volume. Double-click: back to unity."));
            return std::make_pair("track " + juce::String(k + 1), juce::String("Click to select it (its level and pan show on the strip below). Its inlets on the left are heard and recorded; its outlets carry the track alone. Right-click: duplicate, insert, clear or delete."));
        }
        if (auto h = hit(pt, geo)) {
            switch (h->second) {
                case 1: return std::make_pair(juce::String("clip start"), juce::String("Drag to trim the clip's start."));
                case 2: return std::make_pair(juce::String("clip end"), juce::String("Drag to trim the clip's end (over another clip it cuts that one back)."));
                case 3: return std::make_pair(juce::String("fade in"), juce::String("Drag the little square right for a fade in."));
                case 4: return std::make_pair(juce::String("fade out"), juce::String("Drag the little square left for a fade out."));
                default: return std::make_pair(juce::String("clip"), juce::String("Drag to move (to another track too; Alt copies, Ctrl ignores the snap). Double-click to split. Overlapping clips crossfade. Right-click for more."));
            }
        }
        if (geo.area().contains(pt)) return std::make_pair(juce::String("tracks"), juce::String("Drop audio files here (from Explorer, the browser or rec's list). Drag empty space to scroll (with the select tool: to select). The scroll wheel zooms."));
        return std::nullopt;
    }
};

std::unique_ptr<NativeDisplay> makeArrangeDisplay(AppModel& m, const PatchNode& n, const ModuleSpec& s) {
    return std::make_unique<ArrangeDisplay>(m, n, s);
}

// ---------------------------------------------------------------- the model's side

void AppModel::setViewParam(const juce::String& id, const std::string& key, float v) {
    int i = index(id);
    if (i < 0) return;
    auto it = patch.nodes[size_t(i)].params.find(key);
    if (it != patch.nodes[size_t(i)].params.end() && it->second == v) return;
    patch.nodes[size_t(i)].params[key] = v;
    changed();
    scheduleAutosave();
}

void AppModel::editNodeAndCables(const juce::String& id, std::function<void(PatchNode&, std::vector<PatchCable>&)> body) {
    int i = index(id);
    if (i < 0) return;
    if (!restoringHistory) checkpoint();
    body(patch.nodes[size_t(i)], patch.cables);
    topologyChanged();
    if (!restoringHistory) checkpoint();
}

static std::optional<std::tuple<int, double, double>> arrangeSpot(AppModel& m, const juce::String& id, Pt pt, Rect r) {
    auto* n = dynamic_cast<ArrangeNode*>(m.node(id));
    auto* pn = m.nodeFor(id);
    if (!n || !pn) return std::nullopt;
    ArrangeGeo geo(r, *pn);
    auto v = ArrangeViews::get(id);
    double snap = ArrangeViews::snap(*pn, v.ppb);
    double start = std::max(geo.beat(pt.x, v), 0.0);
    if (snap > 0) start = std::floor(start / snap) * snap;
    return std::make_tuple(geo.laneAt(pt.y), start, std::max(double(n->readouts[ArrangeLayout::secondsPerBeatSlot]), 0.01));
}

void AppModel::arrangePreview(const juce::String& id, const juce::File* f, std::optional<Pt> pt, Rect r) {
    std::optional<std::tuple<int, double, double>> spot;
    if (pt) spot = arrangeSpot(*this, id, *pt, r);
    if (!spot) {
        if (ArrangeViews::preview.erase(id)) ArrangeViews::set(id, [](ArrangeViewState&) {});
        return;
    }
    auto [lane, start, spb] = *spot;
    double secs = f ? ArrangeViews::seconds(*f) : 0;
    ArrangeViews::preview[id] = { lane, start, secs > 0 ? secs / spb : 4, f ? f->getFileNameWithoutExtension() : juce::String("drop audio here"), f ? f->getFullPathName() : juce::String() };
    ArrangeViews::set(id, [](ArrangeViewState&) {});
}

/// a file from outside the recordings folder: a copy inside it (so the patch keeps its audio)
static juce::File keepLocal(const juce::File& f) {
    auto rec = recordingsDirectory();
    if (f.isAChildOf(rec)) return f;
    auto dir = rec.getChildFile("Imported");
    dir.createDirectory();
    auto dest = dir.getChildFile(f.getFileName());
    if (dest.existsAsFile()) {
        if (dest.getSize() == f.getSize()) return dest;
        dest = dest.getNonexistentSibling();
    }
    return f.copyFileTo(dest) ? dest : f;
}

bool AppModel::arrangeDrop(const juce::String& id, const juce::Array<juce::File>& files, Pt pt, Rect r) {
    arrangePreview(id, nullptr, std::nullopt, r);
    auto* n = dynamic_cast<ArrangeNode*>(node(id));
    auto spot = arrangeSpot(*this, id, pt, r);
    auto* pn = nodeFor(id);
    if (!n || !spot || !pn) return false;
    auto [lane, start, spb] = *spot;
    int count = ArrangeLayout::count(pn->params.count("tracks") ? pn->params.at("tracks") : 8.0f);
    auto fs = n->files; auto clips = n->clips;
    size_t before = clips.size();
    for (auto& file : files) {
        auto local = keepLocal(file);
        double secs = ArrangeViews::seconds(local);
        if (secs <= 0) continue;
        int k = -1;
        for (size_t j = 0; j < fs.size(); ++j) if (fs[j] == local.getFullPathName()) k = int(j);
        if (k < 0) { fs.push_back(local.getFullPathName()); k = int(fs.size()) - 1; }
        ArrangeClip c; c.track = lane; c.start = start; c.length = std::max(secs / spb, 1.0 / 64); c.file = k;
        clips.push_back(c);
        lane = std::min(lane + 1, count - 1);
    }
    if (clips.size() == before) return false;
    setData(id, { { ArrangeLayout::filesKey, ArrangeClip::encodeFiles(fs) }, { ArrangeLayout::clipsKey, ArrangeClip::encode(clips) } });
    ArrangeViews::set(id, [&](ArrangeViewState& s) { s.selected.clear(); for (size_t i = before; i < clips.size(); ++i) s.selected.insert(int(i)); });
    ArrangeViews::focused = id;
    return true;
}

bool AppModel::deleteArrangeClip() {
    auto id = ArrangeViews::focused;
    if (id.isEmpty()) return false;
    auto sel = ArrangeViews::get(id).selected;
    if (sel.empty() || !(selectedNodes.empty() || (selectedNodes.size() == 1 && selectedNodes.count(id))) || selectedCable.isNotEmpty()) return false;
    auto* n = dynamic_cast<ArrangeNode*>(node(id));
    if (!n) return false;
    std::vector<ArrangeClip> keep;
    for (size_t i = 0; i < n->clips.size(); ++i) if (!sel.count(int(i))) keep.push_back(n->clips[i]);
    setData(id, ArrangeLayout::clipsKey, ArrangeClip::encode(keep));
    ArrangeViews::set(id, [](ArrangeViewState& s) { s.selected.clear(); });
    ArrangeViews::focused = {};
    return true;
}

void AppModel::arrangeInsertTrack(const juce::String& id, int t, bool copy, const std::vector<int>* only) {
    auto* n = dynamic_cast<ArrangeNode*>(node(id));
    auto* pn = nodeFor(id);
    if (!n || !pn) return;
    int count = ArrangeLayout::count(pn->params.count("tracks") ? pn->params.at("tracks") : 8.0f);
    if (count >= ArrangeLayout::tracks || t >= count) return;
    const int F = ArrangeLayout::trackFields;
    auto clips = n->clips;
    for (auto& c : clips) if (c.track > t) c.track += 1;
    if (copy) {
        if (only) { for (int i : *only) if (i < int(n->clips.size())) { auto c = n->clips[size_t(i)]; c.track = t + 1; clips.push_back(c); } }
        else for (auto c : n->clips) if (c.track == t) { c.track = t + 1; clips.push_back(c); }
    }
    clips.erase(std::remove_if(clips.begin(), clips.end(), [](auto& c) { return c.track >= ArrangeLayout::tracks; }), clips.end());
    auto tracks = n->trackData;
    std::vector<float> row = copy ? std::vector<float>(tracks.begin() + t * F, tracks.begin() + t * F + F) : std::vector<float> { 1, 0, 0, 0, 0 };
    tracks.insert(tracks.begin() + (t + 1) * F, row.begin(), row.end());
    tracks.resize(size_t(ArrangeLayout::tracks * F));
    editNodeAndCables(id, [&](PatchNode& node, std::vector<PatchCable>& cables) {
        node.params["tracks"] = float(count + 1);
        node.data[ArrangeLayout::clipsKey] = ArrangeClip::encode(clips);
        node.data[ArrangeLayout::tracksKey] = tracks;
        std::vector<PatchCable> keep;
        for (auto c : cables) {
            if (c.toNode == id && c.toPort < kParamPortBase && c.toPort >= 2 * (t + 1)) { c.toPort += 2; if (c.toPort >= 2 * ArrangeLayout::tracks) continue; }
            if (c.fromNode == id && c.fromPort >= 3 + 2 * (t + 1)) { c.fromPort += 2; if (c.fromPort >= 3 + 2 * ArrangeLayout::tracks) continue; }
            keep.push_back(c);
        }
        cables = keep;
    });
    ArrangeViews::set(id, [](ArrangeViewState& s) { s.selected.clear(); });
}

void AppModel::arrangeDeleteTrack(const juce::String& id, int t) {
    auto* n = dynamic_cast<ArrangeNode*>(node(id));
    auto* pn = nodeFor(id);
    if (!n || !pn) return;
    int count = ArrangeLayout::count(pn->params.count("tracks") ? pn->params.at("tracks") : 8.0f);
    if (count <= 1) return;
    const int F = ArrangeLayout::trackFields;
    std::vector<ArrangeClip> clips;
    for (auto c : n->clips) { if (c.track == t) continue; if (c.track > t) c.track -= 1; clips.push_back(c); }
    auto tracks = n->trackData;
    tracks.erase(tracks.begin() + t * F, tracks.begin() + t * F + F);
    tracks.insert(tracks.end(), { 1, 0, 0, 0, 0 });
    editNodeAndCables(id, [&](PatchNode& node, std::vector<PatchCable>& cables) {
        node.params["tracks"] = float(count - 1);
        node.data[ArrangeLayout::clipsKey] = ArrangeClip::encode(clips);
        node.data[ArrangeLayout::tracksKey] = tracks;
        std::vector<PatchCable> keep;
        for (auto c : cables) {
            if (c.toNode == id && c.toPort < kParamPortBase) { if (c.toPort / 2 == t) continue; if (c.toPort / 2 > t) c.toPort -= 2; }
            if (c.fromNode == id && c.fromPort >= 3) { if ((c.fromPort - 3) / 2 == t) continue; if ((c.fromPort - 3) / 2 > t) c.fromPort -= 2; }
            keep.push_back(c);
        }
        cables = keep;
    });
    ArrangeViews::set(id, [](ArrangeViewState& s) { s.selected.clear(); });
}

void AppModel::addTakes(ArrangeNode* n, const std::vector<ArrangeTake>& takes) {
    juce::String id;
    for (auto& pn : patch.nodes) if (node(pn.id) == n) id = pn.id;
    if (id.isEmpty()) return;
    auto fs = n->files; auto clips = n->clips;
    for (auto& t : takes) {
        fs.push_back(t.file.getFullPathName());
        ArrangeClip c; c.track = t.track; c.start = t.start; c.length = std::max(t.length, 1.0 / 64); c.file = int(fs.size()) - 1;
        clips.push_back(c);
    }
    setData(id, { { ArrangeLayout::filesKey, ArrangeClip::encodeFiles(fs) }, { ArrangeLayout::clipsKey, ArrangeClip::encode(clips) } });
}

void startArrange(AppModel& m) {
    ArrangeNode::onTakes = [&m](ArrangeNode* n, std::vector<ArrangeTake> takes) { m.addTakes(n, takes); };
}

} // namespace pn
