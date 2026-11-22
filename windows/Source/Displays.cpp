#include "Displays.h"
#include "ModulesFM.h"
#include <complex>

namespace pn {

using C = juce::Colour;
static juce::String u8(const char* s) { return juce::String::fromUTF8(s); }
static juce::String fmt(const char* f, double v) { char b[96]; std::snprintf(b, sizeof b, f, v); return b; }
static float toDB(float x) { return 20 * std::log10(std::max(fin(x), 1e-5f)); }

void drawStepGrid(GC& g, Pt size, int len, std::optional<float> division) {
    float cw = size.x / float(std::max(len, 1));
    double beats = Divisions::beats(division.value_or(float(Divisions::index("1/16"))));
    for (int s = 1; s < std::max(len, 1); ++s) {
        double pos = double(s) * beats;
        bool onBeat = std::abs(pos - std::round(pos)) < 1e-6;
        bool onBar = onBeat && int(std::round(pos)) % 4 == 0;
        float x = float(s) * cw;
        if (onBar) g.fill(Rect(x - 0.5f, 0, 1, size.y), Theme::dim().withMultipliedAlpha(0.7f));
        else if (onBeat) g.fill(Rect(x - 0.25f, 0, 0.75f, size.y), Theme::dim().withMultipliedAlpha(0.45f));
        else if (cw >= 4) g.fill(Rect(x, 0, 0.5f, size.y), Theme::faint().withMultipliedAlpha(0.45f));
    }
}

static std::optional<float> divOf(const PatchNode& n) { auto it = n.params.find("div"); if (it == n.params.end()) return std::nullopt; return it->second; }

// ---------------------------------------------------------------- small text readouts (ReadoutView.drawLive)

static void drawReadout(GC& g, Pt size, const std::string& kind, DSPNode* node) {
    float mid = size.y / 2, w = size.x;
    if (!node) { g.textLeft(u8("\xe2\x80\x94"), { 0, mid }, 11, Theme::dim()); return; }
    auto& r = node->readouts;
    if (kind == "clock") {
        juce::String src = r[3] > 0.5f ? (r[2] > 0.5f ? "EXT" : "EXT --") : "INT";
        g.textLeft(src, { 0, mid }, 11, Theme::dim());
        g.textLeft(fmt("%.1f bpm", r[0]), { float(src.length()) * 6.6f + 6, mid }, 11, Theme::text());
        for (int b = 0; b < 4; ++b) {
            float x = w - float(4 - b) * 9 + 1;
            g.fillEllipse(Rect(x, mid - 3, 6, 6), ri(r[1]) == b && r[2] > 0.5f ? Theme::text() : Theme::faint());
        }
    } else if (kind == "grain") {
        g.textLeft("grains " + juce::String(ri(r[0])), { 0, mid }, 11, Theme::text());
        if (r[1] > 0.5f) g.textRight("frozen", { w, mid }, 11, Theme::text());
    } else if (kind == "rec") {
        bool on = r[1] > 0.5f;
        g.fillEllipse(Rect(0, mid - 4, 8, 8), on ? Theme::rec : Theme::faint());
        g.textLeft(on ? "REC" : "idle", { 14, mid }, 11, on ? Theme::rec : Theme::dim());
        int t = std::max(ri(r[0]), 0);
        char b[32]; std::snprintf(b, sizeof b, "%02d:%02d.%d", t / 60, t % 60, std::max(ri((fin(r[0]) - float(t)) * 10), 0));
        g.textRight(b, { w, mid }, 11, Theme::text());
    } else if (kind == "comp" || kind == "limit") {
        g.textLeft("GR", { 0, mid }, 11, Theme::dim());
        float barX = 20, barW = std::max(w - barX - 34, 4.0f);
        drawGainReduction(g, Rect(barX, mid - 2, barW, 4), fin(r[0]));
        g.textRight(fmt("%4.1f", r[0]), { w, mid }, 9, Theme::text());
    } else if (kind == "repeat") {
        bool on = r[0] > 0.5f;
        g.fillEllipse(Rect(0, mid - 3.5f, 7, 7), on ? Theme::text() : Theme::faint());
        g.textLeft(on ? "repeating" : "waiting", { 13, mid }, 11, on ? Theme::text() : Theme::dim());
    } else if (kind == "gain" || kind == "mix") {
        drawMeter(g, Rect(0, mid - 5, w, 4), r[0]);
        drawMeter(g, Rect(0, mid + 1, w, 4), r[1]);
    }
}

class TextReadout : public NativeDisplay {
public:
    using NativeDisplay::NativeDisplay;
    std::vector<LivePart> parts(Rect r) override {
        auto* m = &model; auto nid = id; auto kind = spec.kind;
        return { part("readout", r, [this, m, nid] { return LiveSig::readouts(m->node(nid), 24, 200) + LiveSig::patch(node) * 3 + (m->isRunning ? 1 : 0); },
                      [m, nid, kind](GC& g, Pt size) { drawReadout(g, size, kind, m->node(nid)); }) };
    }
};

// ---------------------------------------------------------------- clock

class ClockDisplay : public NativeDisplay {
public:
    using NativeDisplay::NativeDisplay;
    std::vector<std::pair<int, Rect>> buttons(Rect r) const {
        std::vector<std::pair<int, Rect>> b;
        for (int k = 0; k < 3; ++k) b.push_back({ k, Rect(r.getX() + float(k) * 19, r.getY() + 17, 18, 16) });
        return b;
    }
    std::vector<LivePart> parts(Rect r) override {
        auto* m = &model; auto nid = id;
        return { part("tempo", Rect(r.getX(), r.getY(), r.getWidth(), 14), [this, m, nid] { return LiveSig::readouts(m->node(nid), 24, 200) + LiveSig::patch(node) * 3 + (m->isRunning ? 1 : 0); },
                      [m, nid](GC& g, Pt size) { drawReadout(g, size, "clock", m->node(nid)); }) };
    }
    void paintStatic(GC& g, Rect r) override {
        for (auto& [t, b] : buttons(r)) {
            bool on = model.transport == t;
            if (on) g.fill(b, Theme::fill());
            Pt c = b.getCentre();
            auto col = on ? Theme::text() : Theme::dim().withMultipliedAlpha(0.7f);
            if (t == 0) Icons::play(g, c, col); else if (t == 1) Icons::pause(g, c, col); else Icons::stop(g, c, col);
        }
    }
    bool press(Pt p, Rect r, const PointerInfo&) override {
        for (auto& [t, b] : buttons(r)) if (b.contains(p)) { model.setTransport(t); return true; }
        return false;
    }
};

// ---------------------------------------------------------------- looper / sampler / stretch

class BufferDisplay : public NativeDisplay {
public:
    using NativeDisplay::NativeDisplay;
    Rect wave(Rect r) const { return Rect(r.getX(), r.getY() + 3 + 18, r.getWidth(), r.getHeight() - 6 - 18); }
    int startIndex() const { return spec.paramIndex("start"); }
    int endIndex() const { return spec.paramIndex("end"); }
    std::optional<double> gridStep() {
        auto* n = dsp(); auto* b = dynamic_cast<SampleBufferNode*>(n);
        int gi = spec.paramIndex("grid");
        if (!n || !b || gi < 0) return std::nullopt;
        static const double gridBeats[] = { 0, 0.125, 0.25, 0.5, 1, 2, 4 };
        double beats = gridBeats[std::clamp(int(std::round(n->params[size_t(gi)])), 0, 6)];
        double bs = n->readouts[kBeatSamplesSlot], len = b->waveLength();
        if (beats <= 0 || !std::isfinite(bs) || bs <= 1 || len <= 0) return std::nullopt;
        double step = beats * bs / len;
        return step > 0.002 ? std::optional<double>(step) : std::nullopt;
    }
    double snap(double x) { auto g = gridStep(); if (!g) return x; return std::clamp(std::round(x / *g) * *g, 0.0, 1.0); }

    std::vector<float> peaks(int width) {
        auto* b = dynamic_cast<SampleBufferNode*>(dsp());
        if (!b) return {};
        int len = b->waveLength(), ver = b->contentVersion();
        if (cacheVersion == ver && cacheLength == len && cacheWidth == width) return cache;
        std::vector<float> p(size_t(std::max(width, 1)), 0.0f);
        if (len > 0 && width > 0) {
            const float* buf = b->waveBuffer(); const float* bufR = b->waveBufferR();
            int span = b->waveRecording() ? std::max(len, int(model.host.sampleRate * 2)) : len;
            for (int x = 0; x < width; ++x) {
                int a = int(int64_t(x) * span / width), e = std::min(int(int64_t(x + 1) * span / width), len);
                if (a >= e) continue;
                int stride = std::max(1, (e - a) / 48);
                float m = 0;
                for (int i = a; i < e; i += stride) m = std::max({ m, std::abs(buf[i]), std::abs(bufR[i]) });
                p[size_t(x)] = std::isfinite(m) ? std::min(m, 1.0f) : 0.0f;
            }
        }
        cacheVersion = ver; cacheLength = len; cacheWidth = width; cache = p;
        return p;
    }

    void drawWave(GC& g, Pt size) {
        auto* node_ = dsp(); auto* b = dynamic_cast<SampleBufferNode*>(node_);
        if (!b) return;
        float w = size.x, h = size.y, mid = h / 2;
        g.fill(Rect(0, 0, w, h), Theme::row());
        bool rec = b->waveRecording() && node_->readouts[0] != 4;
        auto p = peaks(int(w));
        juce::Path wave;
        for (int x = 0; x < int(p.size()); ++x) {
            float v = p[size_t(x)];
            if (v <= 0.0005f) continue;
            float a = std::min(std::sqrt(v), 1.0f) * (mid - 1);
            wave.addRectangle(float(x), mid - a, 1, std::max(a * 2, 1.0f));
        }
        g.fill(wave, rec ? Theme::rec : Theme::text().withMultipliedAlpha(0.75f));
        g.fill(Rect(0, mid, w, 0.5f), Theme::faint());
        int len = b->waveLength();
        if (len <= 0 || b->waveRecording()) return;
        if (auto gs = gridStep()) {
            double x = 0; int k = 0;
            while (x <= 1.0001 && k < 512) { g.fill(Rect(float(x) * w, 0, 0.5f, h), Theme::faint()); x += *gs; ++k; }
        }
        for (int k = 0; k < b->markerCount(); ++k) {
            float x = float(b->marker(k)) / float(len) * w;
            g.fill(Rect(x, 0, 1, h), Theme::dim().withMultipliedAlpha(0.8f));
        }
        int s = startIndex(), e = endIndex();
        if (s >= 0 && e >= 0) {
            float a = std::clamp(node_->params[size_t(s)], 0.0f, 1.0f), bb = std::clamp(node_->params[size_t(e)], 0.0f, 1.0f);
            if (bb < a) std::swap(a, bb);
            if (a > 0.001f || bb < 0.999f) {
                g.fill(Rect(0, 0, a * w, h), juce::Colours::black.withAlpha(0.6f));
                g.fill(Rect(bb * w, 0, (1 - bb) * w, h), juce::Colours::black.withAlpha(0.6f));
                g.fill(Rect(a * w, 0, 1, h), Theme::text());
                g.fill(Rect(bb * w - 1, 0, 1, h), Theme::text());
            }
        }
        for (int k = 0; k < 8; ++k) {
            float v = node_->readouts[size_t(kPlayheadSlot + k)];
            if (!std::isfinite(v) || v < 0 || v > 1) continue;
            g.fill(Rect(v * w, 0, 1.5f, h), Theme::text());
        }
    }

    std::vector<LivePart> parts(Rect r) override {
        auto* d = dsp(); auto* b = dynamic_cast<SampleBufferNode*>(d);
        if (!b) return {};
        auto* m = &model; auto kind = spec.kind;
        auto status = part("status", Rect(r.getX(), r.getY() + 3, r.getWidth(), 14),
            [d, b, m] { return LiveSig::readouts(d, 12, 100) * 3 + (m->isRunning ? 1 : 2) + int64_t(b->contentVersion()) * 7; },
            [d, b, m, kind](GC& g, Pt size) {
                float mid = size.y / 2;
                auto& rr = d->readouts;
                if (!m->isRunning) {
                    double secs = double(b->waveLength()) / std::max(m->host.sampleRate, 1.0);
                    g.textLeft(b->waveLength() > 0 ? u8("loaded \xe2\x80\x94 audio off") : u8("empty \xe2\x80\x94 REC or load"), { 0, mid }, 11, Theme::dim());
                    g.textRight(fmt("%.2fs", secs), { size.x, mid }, 9, Theme::dim());
                    return;
                }
                if (kind == "looper") {
                    int st = std::clamp(ri(rr[0]), 0, 6);
                    static const char* names[] = { "empty", "armed", "REC", "play", "DUB", "stop", "REC\xe2\x86\x92" };
                    g.textLeft(u8(names[st]), { 0, mid }, 11, st == 2 || st == 4 || st == 6 ? Theme::rec : Theme::text());
                    g.textRight(fmt("%.2fs", fin(rr[2])), { size.x, mid }, 9, Theme::dim());
                } else if (kind == "sampler") {
                    int st = ri(rr[0]);
                    juce::String a = st == 1 ? juce::String("REC") : st == 2 ? juce::String(ri(rr[2])) + " slices" : u8("empty \xe2\x80\x94 REC or load");
                    g.textLeft(a, { 0, mid }, 11, st == 1 ? Theme::rec : Theme::text());
                    float x = textWidth(a, 11) + 6;
                    if (st == 2) { auto s = u8("\xe2\x96\xb8 ") + juce::String(ri(rr[3])); g.textLeft(s, { x, mid }, 11, Theme::dim()); x += textWidth(s, 11) + 6; }
                    if (st == 2 && ri(rr[4]) == 3) g.textLeft("stopped", { x, mid }, 11, Theme::dim());
                    g.textRight(fmt("%.2fs", fin(rr[1])), { size.x, mid }, 9, Theme::dim());
                } else {
                    int st = ri(rr[0]);
                    g.textLeft(st == 1 ? juce::String("REC") : st == 2 ? juce::String("stretching") : u8("empty \xe2\x80\x94 REC or load"), { 0, mid }, 11, st == 1 ? Theme::rec : Theme::text());
                    g.textRight(fmt("%.2fs", fin(rr[1])), { size.x, mid }, 9, Theme::dim());
                }
            });
        auto waveform = part("wave", wave(r), nullptr, [this](GC& g, Pt size) { drawWave(g, size); }, 1, true);
        return { status, waveform };
    }
    bool press(Pt p, Rect r, const PointerInfo& info) override {
        if (!wave(r).contains(p) || startIndex() < 0 || endIndex() < 0) return false;
        if (info.clickCount >= 2) { model.setParam(id, startIndex(), 0); model.setParam(id, endIndex(), 1); }
        from.reset();
        return true;
    }
    void drag(Pt p, Rect r, const PointerInfo& info) override {
        if (!info.moved || startIndex() < 0) return;
        auto w = wave(r); float width = std::max(w.getWidth(), 1.0f);
        if (!from) from = info.start.x - w.getX();
        float x = p.x - w.getX();
        double a = std::clamp(std::min(*from, x) / width, 0.0f, 1.0f), b = std::clamp(std::max(*from, x) / width, 0.0f, 1.0f);
        a = snap(a); b = snap(b);
        if (b <= a) if (auto gs = gridStep()) b = std::min(a + *gs, 1.0);
        model.setParam(id, startIndex(), float(a)); model.setParam(id, endIndex(), float(b));
    }
    void release(Pt p, Rect r, const PointerInfo& info) override {
        auto w = wave(r);
        if (!info.moved && info.clickCount == 1) model.audition(id, double((p.x - w.getX()) / std::max(w.getWidth(), 1.0f)));
        from.reset();
    }
private:
    std::optional<float> from;
    int cacheVersion = -1, cacheLength = -1, cacheWidth = -1;
    std::vector<float> cache;
};

// ---------------------------------------------------------------- keys

namespace KeysGeo {
static const int whiteSemis[] = { 0, 2, 4, 5, 7, 9, 11 }, blackSemis[] = { 1, 3, 6, 8, 10 }, blackWhite[] = { 0, 1, 3, 4, 5 };
static float edge(int i, float width) { return std::round(float(i) * width / 15); }
static Rect whiteRect(int w, Pt size) { float x0 = edge(w, size.x), x1 = edge(w + 1, size.x); return Rect(x0, 0, std::max(x1 - x0 - 1, 1.0f), std::round(size.y)); }
static Rect blackRect(int wi, Pt size) {
    float bw = std::max(std::round(size.x / 15 * 0.6f / 2) * 2, 2.0f);
    float centre = edge(wi + 1, size.x) - 0.5f;
    return Rect(std::round(centre - bw / 2), 0, bw, std::round(size.y * 0.6f));
}
static std::optional<int> key(Pt p, Pt size) {
    for (int o = 0; o < 2; ++o)
        for (int j = 0; j < 5; ++j) if (blackRect(blackWhite[j] + o * 7, size).expanded(1, 0).contains(p)) return o * 12 + blackSemis[j];
    if (p.x < 0 || p.x > size.x) return std::nullopt;
    int w = 0;
    for (int k = 0; k < 15; ++k) if (edge(k, size.x) <= p.x) w = k;
    w = std::clamp(w, 0, 14);
    return w == 14 ? 24 : (w / 7) * 12 + whiteSemis[w % 7];
}
}

class KeysDisplay : public NativeDisplay {
public:
    using NativeDisplay::NativeDisplay;
    Rect inner(Rect r) const { return r.reduced(0, 4); }
    std::vector<LivePart> parts(Rect r) override {
        auto* k = dynamic_cast<KeysNode*>(dsp());
        if (!k) return {};
        auto* m = &model;
        return { part("keys", inner(r), [this, k, m] {
                int64_t h = m->isRunning ? int64_t(k->readouts[0]) : -1;
                LiveSig::mix(h, k->touchNote.load());
                LiveSig::mix(h, LiveSig::floats(k->latched.data(), KeysNode::keyCount));
                LiveSig::mix(h, LiveSig::patch(node));
                return h;
            }, [k, m](GC& g, Pt size) {
                using namespace KeysGeo;
                int sounding = m->isRunning ? int(k->readouts[0]) : -1;
                auto lit = [&](int key) { return k->touchNote.load() == key || k->latched[size_t(key)] > 0.5f || key == sounding; };
                auto gap = Theme::boxIsLight() ? Theme::border() : Theme::box();
                g.fill(Rect(0, 0, edge(15, size.x) - 1, std::round(size.y)), gap);
                for (int w = 0; w < 15; ++w) {
                    int key = w == 14 ? 24 : (w / 7) * 12 + whiteSemis[w % 7];
                    g.fill(whiteRect(w, size), lit(key) ? Theme::keyWhiteLit() : Theme::keyWhite());
                }
                for (int o = 0; o < 2; ++o)
                    for (int j = 0; j < 5; ++j) {
                        int key = o * 12 + blackSemis[j];
                        auto rr = blackRect(blackWhite[j] + o * 7, size);
                        g.fill(Rect(rr.getX() - 1, 0, rr.getWidth() + 2, rr.getHeight() + 1), Theme::box());
                        g.fill(rr, lit(key) ? Theme::keyBlackLit() : Theme::keyBlack());
                    }
            }) };
    }
    void hit(Pt p, Rect r) {
        auto i = inner(r);
        auto* k = dynamic_cast<KeysNode*>(dsp());
        if (!k) return;
        auto key = KeysGeo::key(p - i.getPosition(), { i.getWidth(), i.getHeight() });
        if (!key) return;
        if (p_latch()) { if (*key != lastKey) { k->toggleLatched(*key); lastKey = *key; } }
        else {
            if (*key != lastKey) { k->pressNote = *key; k->pressCount += 1; lastKey = *key; }
            k->touchNote = *key;
        }
    }
    bool p_latch() const { return p("latch", 0) > 0.5f; }
    bool press(Pt pt, Rect r, const PointerInfo&) override { if (!inner(r).contains(pt)) return false; lastKey = -1; hit(pt, r); return true; }
    void drag(Pt pt, Rect r, const PointerInfo&) override { hit(pt, r); }
    void release(Pt, Rect, const PointerInfo&) override { if (auto* k = dynamic_cast<KeysNode*>(dsp())) k->touchNote = -1; lastKey = -1; }
private:
    int lastKey = -1;
};

// ---------------------------------------------------------------- seq

class SeqDisplay : public NativeDisplay {
public:
    using NativeDisplay::NativeDisplay;
    static constexpr float range = 24, gateRow = 16;
    Rect inner(Rect r) const { return r.reduced(0, 4); }
    int cols() const { return std::max(16, SeqNode::length(p("len", 8))); }
    std::vector<LivePart> parts(Rect r) override {
        auto* s = dynamic_cast<SeqNode*>(dsp());
        if (!s) return {};
        auto* m = &model;
        return { part("seq", inner(r), [this, s, m] {
                int64_t h = m->isRunning ? int64_t(s->readouts[0]) : -1;
                LiveSig::mix(h, LiveSig::floats(s->pitches.data(), SeqNode::steps));
                LiveSig::mix(h, LiveSig::floats(s->gates.data(), SeqNode::steps));
                LiveSig::mix(h, LiveSig::patch(node));
                LiveSig::mix(h, LiveSig::q(paintGate.value_or(-1), 4));
                return h;
            }, [this, s, m](GC& g, Pt size) { draw(g, size, s, m); }) };
    }
    void draw(GC& g, Pt size, SeqNode* s, AppModel* m) {
        int n = cols();
        float colW = size.x / float(n), barH = size.y - gateRow - 2;
        int len = SeqNode::length(p("len", 8));
        int cur = m->isRunning ? int(s->readouts[0]) : -1;
        g.fill(Rect(0, 0, size.x, size.y), Theme::row());
        float semi = barH / (range * 2);
        auto yOf = [&](int st) { return barH / 2 - float(st) / range * barH / 2; };
        if (semi >= 2.5f) for (int st = -int(range); st <= int(range); ++st) if (st % 12 != 0) g.fill(Rect(0, yOf(st), size.x, 0.5f), Theme::faint().withMultipliedAlpha(0.35f));
        for (int st = -int(range); st <= int(range); st += 12) {
            g.fill(Rect(0, yOf(st), size.x, st == 0 ? 1.0f : 0.5f), st == 0 ? Theme::faint() : Theme::faint().withMultipliedAlpha(0.8f));
            g.textLeft(st == 0 ? juce::String("0") : (st > 0 ? "+" : "") + juce::String(st), { 2, std::clamp(yOf(st) + (st > 0 ? 5.0f : -5.0f), 4.0f, barH - 4) }, 7, Theme::dim());
        }
        for (int c = 0; c < n; ++c) {
            float x = float(c) * colW;
            bool active = c < len;
            if (c == cur) g.fill(Rect(x, 0, colW, size.y), Theme::text().withMultipliedAlpha(0.12f));
            float v = s->pitches[size_t(c)] / range;
            float y0 = barH / 2, y1 = barH / 2 - v * barH / 2, gp = colW < 10 ? 1.0f : 2.0f;
            g.fill(Rect(x + gp, std::min(y0, y1), colW - 2 * gp, std::max(std::abs(y1 - y0), 1.5f)), active ? Theme::text() : Theme::faint());
            g.fill(Rect(x + gp, barH + 2, colW - 2 * gp, gateRow - 2), s->gates[size_t(c)] > 0.5f ? (active ? Theme::text() : Theme::dim()) : Theme::box());
        }
        drawStepGrid(g, size, n, divOf(node));
        if (len < n) {
            float x0 = float(len) * colW;
            Rect off(x0, 0, size.x - x0, size.y);
            g.fill(off, Theme::box().withMultipliedAlpha(0.72f));
            juce::Path hatch;
            for (float hx = x0 - size.y; hx < size.x; hx += 6) { hatch.startNewSubPath(hx, size.y); hatch.lineTo(hx + size.y, 0); }
            g.clipped(off, [&] { g.stroke(hatch, Theme::faint().withMultipliedAlpha(0.35f), 0.5f); });
            g.fill(Rect(x0 - 0.75f, 0, 1.5f, size.y), Theme::text().withMultipliedAlpha(0.6f));
        }
    }
    void edit(Pt pt, Rect r, Pt start) {
        auto* s = dynamic_cast<SeqNode*>(dsp());
        if (!s) return;
        auto i = inner(r);
        Pt lp = pt - i.getPosition(), ls = start - i.getPosition();
        int n = cols();
        float colW = i.getWidth() / float(n);
        int col = std::clamp(int(lp.x / colW), 0, n - 1);
        float barH = i.getHeight() - gateRow - 2;
        if (ls.y > barH) {
            if (!paintGate) paintGate = s->gates[size_t(col)] > 0.5f ? 0.0f : 1.0f;
            s->gates[size_t(col)] = *paintGate;
        } else {
            float v = (1 - std::clamp(lp.y / barH, 0.0f, 1.0f)) * 2 - 1;
            s->pitches[size_t(col)] = std::round(v * range);
        }
    }
    bool press(Pt pt, Rect r, const PointerInfo& info) override { if (!inner(r).contains(pt)) return false; paintGate.reset(); edit(pt, r, info.start); return true; }
    void drag(Pt pt, Rect r, const PointerInfo& info) override { edit(pt, r, info.start); }
    void release(Pt, Rect, const PointerInfo&) override {
        paintGate.reset();
        auto* s = dynamic_cast<SeqNode*>(dsp());
        if (!s) return;
        model.setData(id, { { "pitch", std::vector<float>(s->pitches.begin(), s->pitches.end()) }, { "gate", std::vector<float>(s->gates.begin(), s->gates.end()) } });
    }
private:
    std::optional<float> paintGate;
};

// ---------------------------------------------------------------- turing

class TuringDisplay : public NativeDisplay {
public:
    using NativeDisplay::NativeDisplay;
    std::vector<LivePart> parts(Rect r) override {
        auto* t = dynamic_cast<TuringNode*>(dsp());
        if (!t) return {};
        auto* m = &model;
        return { part("turing", r.reduced(0, 4), [t, m] { return LiveSig::readouts(t, 24) + (m->isRunning ? 1 : 0); }, [t, m](GC& g, Pt size) {
            if (!m->isRunning) { g.fill(Rect(0, 0, size.x, size.y), Theme::row()); g.text("audio off", { size.x / 2, size.y / 2 }, 9, Theme::dim()); return; }
            auto& r = t->readouts;
            uint64_t reg = t->regNow.load();
            int len = std::max(std::min(int(fin(r[1])), TuringNode::maxLength), 2);
            const float regH = 12;
            float cw = size.x / float(len);
            for (int b = 0; b < len; ++b) {
                int bit = len - 1 - b;
                bool on = (reg >> bit) & 1;
                float cg = cw < 8 ? 0.5f : 1.0f;
                g.fill(Rect(float(b) * cw + cg, 0, cw - 2 * cg, regH - 3), on ? Theme::text() : Theme::row());
            }
            float top = regH + 3, bottom = size.y - 8;
            uint64_t gates = t->playsBits.load();
            std::vector<float> notes;
            for (int k = 0; k < len; ++k) notes.push_back(fin(t->loopNotes[size_t(k)]));
            float lo = *std::min_element(notes.begin(), notes.end()), hi = std::max(*std::max_element(notes.begin(), notes.end()), lo + 12);
            float sw = size.x / float(len);
            g.fill(Rect(0, top, size.x, bottom - top), Theme::row());
            g.fill(Rect(0, top, sw, bottom - top), Theme::text().withMultipliedAlpha(0.1f));
            for (int k = 0; k < len; ++k) {
                float y = bottom - (notes[size_t(k)] - lo) / (hi - lo) * (bottom - top - 4) - 4;
                float gp = sw < 8 ? 0.5f : 1.0f;
                g.fill(Rect(float(k) * sw + gp, y, sw - 2 * gp, 3), ((gates >> k) & 1) ? Theme::text() : Theme::box());
            }
            float cv = std::clamp(fin(r[2]), 0.0f, 1.0f);
            g.fill(Rect(0, size.y - 4, size.x, 3), Theme::row());
            g.fill(Rect(0, size.y - 4, size.x * cv, 3), Theme::text().withMultipliedAlpha(0.7f));
        }) };
    }
};

// ---------------------------------------------------------------- roll / drums

class GridDisplay : public NativeDisplay {
public:
    using NativeDisplay::NativeDisplay;
    bool isRoll() const { return spec.kind == "roll"; }
    Rect inner(Rect r) const { return r.reduced(0, isRoll() ? 4.0f : 3.0f); }
    // roll: the grid, with a scrollbar beside it (all 7 octaves, 2 on screen)
    static constexpr float bar = 7;
    Rect gridRect(Rect r) const { auto i = inner(r); return isRoll() ? i.withTrimmedRight(bar + 3) : i; }
    Rect barRect(Rect r) const { auto i = inner(r); return Rect(i.getRight() - bar, i.getY(), bar, i.getHeight()); }
    int rows() const { return isRoll() ? RollNode::shown : DrumsNode::lanes; }
    int stored() const { return isRoll() ? RollNode::rows : DrumsNode::lanes; }
    int maxBase() const { return RollNode::rows - RollNode::shown; }
    int base() const { return isRoll() ? std::clamp(int(std::round(p("low", -12))) - RollNode::lowest, 0, maxBase()) : 0; }
    int len() const { return int(std::round(p("len", 16))); }
    float* cells() {
        if (auto* n = dynamic_cast<RollNode*>(dsp())) return n->grid.data();
        if (auto* n = dynamic_cast<DrumsNode*>(dsp())) return n->hits.data();
        return nullptr;
    }
    bool isOn(int s, int r) { auto* c = cells(); return c && c[(r + base()) * StepPattern::steps + s] > 0.5f; }
    float rowY(int r, float rh, float h) const { return !isRoll() ? float(r) * rh : h - float(r + 1) * rh; }
    int rowAt(float y, float rh) const { int i = int(std::floor(y / rh)); return !isRoll() ? i : rows() - 1 - i; }
    Rect thumb(Pt size, int b) const {
        float h = std::max(size.y * float(RollNode::shown) / float(RollNode::rows), 14.0f);
        float t = maxBase() > 0 ? float(b) / float(maxBase()) : 0;
        return Rect(0, (1 - t) * (size.y - h), size.x, h);      // high notes at the top
    }
    std::vector<LivePart> parts(Rect r) override {
        auto* m = &model;
        std::vector<LivePart> list { part("grid", gridRect(r), [this, m] {
                auto* d = dsp();
                int64_t h = m->isRunning && d ? int64_t(d->readouts[0]) : -1;
                if (auto* c = cells()) LiveSig::mix(h, LiveSig::floats(c, StepPattern::steps * stored()));
                LiveSig::mix(h, LiveSig::patch(node));
                return h;
            }, [this, m](GC& g, Pt size) {
                auto* d = dsp();
                if (!d) return;
                int L = len(), R = rows(), B = base();
                float cw = size.x / float(std::max(L, 1)), rh = size.y / float(R);
                g.fill(Rect(0, 0, size.x, size.y), Theme::row());
                for (int r = 0; r < R; ++r) {
                    float y = rowY(r, rh, size.y);
                    int pc = (r + B) % 12;
                    bool shade = isRoll() ? (pc == 1 || pc == 3 || pc == 6 || pc == 8 || pc == 10) : r % 2 == 1;
                    if (shade) g.fill(Rect(0, y, size.x, rh), Theme::shade());
                    if (isRoll() && pc == 0) g.fill(Rect(0, y + rh - 0.5f, size.x, 0.5f), Theme::dim().withMultipliedAlpha(0.6f));
                }
                drawStepGrid(g, size, L, divOf(node));
                int ps = m->isRunning ? int(d->readouts[0]) : -1;
                if (ps >= 0 && ps < L) g.fill(Rect(float(ps) * cw, 0, cw, size.y), Theme::text().withMultipliedAlpha(0.12f));
                for (int s = 0; s < L; ++s)
                    for (int r = 0; r < R; ++r)
                        if (isOn(s, r)) g.fill(Rect(float(s) * cw + 1, rowY(r, rh, size.y) + 1, cw - 2, rh - 2), s == ps ? Theme::text() : Theme::text().withMultipliedAlpha(0.75f));
            }) };
        if (isRoll())
            list.push_back(part("scroll", barRect(r), [this] { return int64_t(base()); }, [this](GC& g, Pt size) {
                g.fillRounded(Rect(0, 0, size.x, size.y), 2, Theme::row());
                g.fillRounded(thumb(size, base()), 2, Theme::dim());
            }));
        return list;
    }
    void scrollTo(Pt pt, Rect r) {
        auto b = barRect(r);
        float th = thumb({ b.getWidth(), b.getHeight() }, 0).getHeight();
        float t = 1 - std::clamp((pt.y - b.getY() - th / 2) / std::max(b.getHeight() - th, 1.0f), 0.0f, 1.0f);
        int nb = int(std::round(t * float(maxBase())));
        int li = spec.paramIndex("low");
        if (li >= 0 && nb != base()) model.setParam(id, li, float(RollNode::lowest + nb));
    }
    void edit(Pt pt, Rect r) {
        auto i = gridRect(r);
        int L = len();
        float cw = i.getWidth() / float(std::max(L, 1)), rh = i.getHeight() / float(rows());
        int step = int((pt.x - i.getX()) / cw), row = rowAt(pt.y - i.getY(), rh);
        if (step < 0 || step >= L || row < 0 || row >= rows()) return;
        if (!paint) paint = isOn(step, row) ? 0.0f : 1.0f;
        if (auto* c = cells()) c[(row + base()) * StepPattern::steps + step] = *paint == 1 ? 1.0f : 0.0f;
    }
    bool press(Pt pt, Rect r, const PointerInfo&) override {
        if (isRoll() && barRect(r).expanded(3, 0).contains(pt)) { scrolling = true; scrollTo(pt, r); return true; }
        if (!gridRect(r).contains(pt)) return false;
        paint.reset(); edit(pt, r); return true;
    }
    void drag(Pt pt, Rect r, const PointerInfo&) override { if (scrolling) scrollTo(pt, r); else edit(pt, r); }
    void release(Pt, Rect, const PointerInfo&) override {
        if (scrolling) { scrolling = false; return; }
        paint.reset();
        auto* c = cells();
        if (!c) return;
        model.setData(id, isRoll() ? "grid" : "hits", std::vector<float>(c, c + StepPattern::steps * stored()));
    }
private:
    std::optional<float> paint;
    bool scrolling = false;
};

// ---------------------------------------------------------------- fm: the voice (< name >, bank, load a sysex), six operators, the selected one's envelope

class FMDisplay : public NativeDisplay {
public:
    using NativeDisplay::NativeDisplay;
    Rect inner(Rect r) const { return r.reduced(0, 4); }
    Rect nameRow(Rect r) const { auto i = inner(r); return Rect(i.getX(), i.getY(), i.getWidth(), 20); }
    Rect prevRect(Rect r) const { auto n = nameRow(r); return Rect(n.getX(), n.getY(), 18, n.getHeight()); }
    Rect syxRect(Rect r) const { auto n = nameRow(r); return Rect(n.getRight() - 36, n.getY(), 36, n.getHeight()); }
    Rect nextRect(Rect r) const { auto s = syxRect(r); return Rect(s.getX() - 22, s.getY(), 18, s.getHeight()); }
    Rect nameRect(Rect r) const { auto a = prevRect(r), b = nextRect(r); return Rect(a.getRight() + 4, a.getY(), std::max(b.getX() - 4 - a.getRight() - 4, 10.0f), a.getHeight()); }
    Rect tab(int k, Rect r) const { auto i = inner(r); float gap = 4, w = (i.getWidth() - gap * 5) / 6; return Rect(i.getX() + float(k) * (w + gap), i.getY() + 26, w, 24); }
    Rect envRect(Rect r) const { auto i = inner(r); return Rect(i.getX(), i.getY() + 56, i.getWidth(), std::max(i.getHeight() - 56, 10.0f)); }
    int sel() const { return std::clamp(int(std::round(p("sel", 0))), 0, 5); }
    const FMAlgorithm& alg() const { return fmAlgorithms()[size_t(std::clamp(int(std::round(p("algo", 1))) - 1, 0, 31))]; }
    float val(int i) { return model.value(node, i, spec); }
    int voiceIndex() const { auto it = node.data.find("voice"); return it == node.data.end() || it->second.empty() ? 0 : int(it->second[0]); }

    // the envelope: each rate gets a fixed share of the width (so moving one handle doesn't shift the others).
    // Points: start (level 4: where the attack starts and the release ends), the ends of stages 1, 2, 3, key off
    // (sustain = level 3), and the end of the release. Every one is a handle.
    static constexpr float segMax = 1.2f, sustainLen = 0.6f;
    float unit(Rect e) const { return (e.getWidth() - 12) / (segMax * 4 + sustainLen); }
    float envY(float l, Rect e) const { return e.getBottom() - 5 - std::clamp(l, 0.0f, 99.0f) / 99 * (e.getHeight() - 10); }
    std::vector<Pt> envPoints(Rect r) {
        auto e = envRect(r); int b = FMLayout::base(sel()); float u = unit(e);
        auto len = [&](int k) { return segMax - val(b + FMLayout::R + k) / 99; };
        float x = e.getX() + 6;
        std::vector<Pt> out { { x, envY(val(b + FMLayout::L + 3), e) } };
        for (int k = 0; k < 3; ++k) { x += len(k) * u; out.push_back({ x, envY(val(b + FMLayout::L + k), e) }); }
        x += sustainLen * u; out.push_back({ x, envY(val(b + FMLayout::L + 2), e) });
        x += len(3) * u; out.push_back({ x, envY(val(b + FMLayout::L + 3), e) });
        return out;
    }
    std::optional<int> grabbed;
    void dragHandle(Pt pt, Rect r) {
        if (!grabbed) return;
        int k = *grabbed;
        auto e = envRect(r); auto pts = envPoints(r); float u = unit(e);
        float level = std::clamp(std::round((e.getBottom() - 5 - pt.y) / (e.getHeight() - 10) * 99), 0.0f, 99.0f);
        auto rate = [&] { return std::clamp(std::round((segMax - std::clamp((pt.x - pts[size_t(k - 1)].x) / u, 0.2f, segMax)) * 99), 0.0f, 99.0f); };
        auto n = std::to_string(sel() + 1);
        if (k == 0) setParam("o" + n + "l4", level);                                     // where the attack starts (and the release ends)
        else if (k <= 3) { setParam("o" + n + "r" + std::to_string(k), rate()); setParam("o" + n + "l" + std::to_string(k), level); }
        else if (k == 4) setParam("o" + n + "l3", level);                                // key off: the sustain level
        else setParam("o" + n + "r4", rate());                                           // the release: its time only
    }

    void paintStatic(GC& g, Rect r) override {
        for (auto pr : { std::make_pair(prevRect(r), "<"), std::make_pair(nextRect(r), ">") }) {
            g.fillRounded(pr.first, 2, Theme::row());
            g.text(pr.second, pr.first.getCentre(), 9, Theme::dim());
        }
        auto n = nameRect(r);
        g.fillRounded(n, 2, Theme::row());
        auto bank = model.fmVoices(id).first;
        g.textLeft(fitText(model.fmVoiceName(node), 11, n.getWidth() - 70, true), { n.getX() + 6, n.getCentreY() }, 11, Theme::text(), true);
        g.textRight(fitText(bank + " " + juce::String(voiceIndex() + 1), 9, 64), { n.getRight() - 6, n.getCentreY() }, 9, Theme::dim());
        auto sy = syxRect(r);
        g.strokeRounded(sy.reduced(0.5f), 2, Theme::border(), 1);
        g.text(juce::String::fromUTF8("syx\xe2\x80\xa6"), sy.getCentre(), 9, Theme::dim());
        auto& a = alg();
        for (int op = 0; op < 6; ++op) {
            auto t = tab(op, r);
            bool car = std::find(a.carriers.begin(), a.carriers.end(), op) != a.carriers.end();
            g.fillRounded(t, 2, car ? Theme::text().withMultipliedAlpha(0.16f) : Theme::row());
            if (op == sel()) g.strokeRounded(t.reduced(0.75f), 2, Theme::text(), 1.5f);
            int lvl = int(std::round(val(FMLayout::base(op) + FMLayout::OL)));
            g.textLeft(juce::String(op + 1), { t.getX() + 5, t.getY() + 8 }, 10, Theme::text(), true);
            g.textRight(juce::String(lvl), { t.getRight() - 4, t.getY() + 8 }, 8, Theme::dim());
        }
        // the selected operator's envelope; the little circles are handles: drag up / down for level, sideways for rate
        auto e = envRect(r);
        int b = FMLayout::base(sel());
        g.fill(e, Theme::row());
        auto pts = envPoints(r);
        juce::Path path;
        path.startNewSubPath(pts[0]);
        for (size_t k = 1; k < pts.size(); ++k) path.lineTo(pts[k]);
        g.stroke(path, Theme::text().withMultipliedAlpha(0.8f), 1);
        for (auto q : pts) {
            Rect c(q.x - 3.5f, q.y - 3.5f, 7, 7);
            g.g.setColour(Theme::box()); g.g.fillEllipse(c);
            g.g.setColour(Theme::text()); g.g.drawEllipse(c.reduced(0.5f), 1);
        }
        g.textRight("op " + juce::String(sel() + 1) + " envelope", { e.getRight() - 4, e.getY() + 7 }, 8, Theme::faint());
    }

    std::vector<LivePart> parts(Rect r) override {
        auto* d = dsp();
        if (!d) return {};
        auto first = tab(0, r), last = tab(5, r);
        Rect area(first.getX(), first.getBottom() - 4, last.getRight() - first.getX(), 3);
        return { part("levels", area, [d] {
                int64_t h = 0;
                for (int op = 0; op < 6; ++op) LiveSig::mix(h, LiveSig::q(std::clamp(d->readouts[size_t(op)], 0.0f, 1.0f), 12));
                return h;
            }, [this, d, r, area](GC& g, Pt size) {
                for (int op = 0; op < 6; ++op) {
                    auto t = tab(op, r);
                    float w = std::clamp(d->readouts[size_t(op)], 0.0f, 1.0f) * (t.getWidth() - 6);
                    g.fill(Rect(t.getX() - area.getX() + 3, 0, w, size.y), Theme::text().withMultipliedAlpha(0.6f));
                }
            }, 2) };
    }

    void chooseSysex() {
        static std::unique_ptr<juce::FileChooser> chooser;
        chooser = std::make_unique<juce::FileChooser>("A DX7 sysex bank", juce::File(), "*.syx;*.SYX");
        auto* m = &model; auto nid = id;
        chooser->launchAsync(juce::FileBrowserComponent::openMode | juce::FileBrowserComponent::canSelectFiles, [m, nid](const juce::FileChooser& fc) {
            auto f = fc.getResult();
            if (!f.existsAsFile()) return;
            juce::MemoryBlock mb;
            if (!f.loadFileAsData(mb)) return;
            auto* b = static_cast<const uint8_t*>(mb.getData());
            m->loadSysex(nid, std::vector<uint8_t>(b, b + mb.getSize()), f.getFileNameWithoutExtension());
        });
    }
    void showVoices() {
        auto list = model.fmVoices(id);
        juce::PopupMenu menu;
        menu.addSectionHeader(list.first);
        int cur = voiceIndex();
        auto* m = &model; auto nid = id;
        for (int k = 0; k < int(list.second.size()); ++k) {
            auto nm = list.second[size_t(k)].first;
            menu.addItem(juce::String(k + 1) + "  " + (nm.isEmpty() ? "voice " + juce::String(k + 1) : nm), true, k == cur, [m, nid, k] { m->loadFMVoice(nid, k); });
        }
        menu.addSeparator();
        menu.addItem(juce::String::fromUTF8("Load sysex bank\xe2\x80\xa6"), [this] { chooseSysex(); });
        if (list.first != "built-in") menu.addItem("Built-in voices", [m, nid] { m->resetFMBank(nid); });
        menu.showMenuAsync(juce::PopupMenu::Options().withMousePosition());
    }

    bool press(Pt pt, Rect r, const PointerInfo&) override {
        auto pts = envPoints(r);
        grabbed.reset();
        float best = 9;
        for (int k = 0; k < int(pts.size()); ++k) if (pts[size_t(k)].getDistanceFrom(pt) < best) { best = pts[size_t(k)].getDistanceFrom(pt); grabbed = k; }
        return grabbed.has_value() || inner(r).contains(pt);
    }
    void drag(Pt pt, Rect r, const PointerInfo&) override { dragHandle(pt, r); }
    void release(Pt pt, Rect r, const PointerInfo& info) override {
        if (grabbed) { grabbed.reset(); return; }
        if (info.moved) return;
        int count = std::max(int(model.fmVoices(id).second.size()), 1);
        int k = voiceIndex();
        if (prevRect(r).contains(pt)) { model.loadFMVoice(id, (k - 1 + count) % count); return; }
        if (nextRect(r).contains(pt)) { model.loadFMVoice(id, (k + 1) % count); return; }
        if (syxRect(r).contains(pt)) { chooseSysex(); return; }
        if (nameRect(r).contains(pt)) { showVoices(); return; }
        for (int op = 0; op < 6; ++op) if (tab(op, r).contains(pt)) { setParam("sel", float(op)); return; }
    }
};

// ---------------------------------------------------------------- comp

class CompDisplay : public NativeDisplay {
public:
    using NativeDisplay::NativeDisplay;
    static constexpr float floorDB = -48;
    float yOf(float db, float h) const { return (1 - (std::clamp(db, floorDB, 0.0f) - floorDB) / -floorDB) * h; }
    std::vector<LivePart> parts(Rect r) override {
        if (!dsp()) return {};
        auto i = r.reduced(0, 4);
        float curve = std::min(i.getHeight(), i.getWidth() / 2);
        Rect hist(i.getX(), i.getY(), i.getWidth() - 6 - curve, i.getHeight());
        Rect cur(hist.getRight() + 6, i.getY() + (i.getHeight() - curve) / 2, curve, curve);
        return { part("history", hist, nullptr, [this](GC& g, Pt s) { drawHistory(g, s); }, 2),
                 part("curve", cur, nullptr, [this](GC& g, Pt s) { drawCurve(g, s); }, 2) };
    }
    void push(float a, float b, float c) {
        double t = juce::Time::getMillisecondCounterHiRes() * 0.001;
        if (t - last < 1.0 / 40) return;
        int steps = std::clamp(int((t - last) * 40), 1, length);
        last = t;
        for (int k = 0; k < steps; ++k) { rows[0][size_t(head)] = a; rows[1][size_t(head)] = b; rows[2][size_t(head)] = c; head = (head + 1) % length; }
    }
    float val(int c, int i) const { return rows[size_t(c)][size_t((head + i) % length)]; }
    void drawHistory(GC& g, Pt size) {
        auto* d = dsp();
        if (!d) return;
        auto& r = d->readouts;
        push(toDB(r[1]), toDB(r[2]), fin(r[0]));
        float w = size.x, h = size.y - 12;
        g.fill(Rect(0, 0, w, h), Theme::row());
        for (float db : { -12.0f, -24.0f, -36.0f }) g.fill(Rect(0, yOf(db, h), w, 0.5f), Theme::faint().withMultipliedAlpha(0.5f));
        int n = length;
        float dx = w / float(n - 1);
        juce::Path fillP; fillP.startNewSubPath(0, h);
        for (int i = 0; i < n; ++i) fillP.lineTo(float(i) * dx, yOf(val(0, i), h));
        fillP.lineTo(w, h); fillP.closeSubPath();
        g.fill(fillP, Theme::text().withMultipliedAlpha(0.16f));
        juce::Path out;
        for (int i = 0; i < n; ++i) { Pt p { float(i) * dx, yOf(val(1, i), h) }; if (i == 0) out.startNewSubPath(p); else out.lineTo(p); }
        g.stroke(out, Theme::text().withMultipliedAlpha(0.85f), 1);
        juce::Path gr; gr.startNewSubPath(0, 0);
        for (int i = 0; i < n; ++i) gr.lineTo(float(i) * dx, std::min(val(2, i) / 24, 1.0f) * h);
        gr.lineTo(w, 0); gr.closeSubPath();
        g.fill(gr, Theme::meterYellow.withMultipliedAlpha(0.75f));
        char b[96]; std::snprintf(b, sizeof b, "GR %4.1f dB   in %5.1f   out %5.1f", fin(r[0]), toDB(r[1]), toDB(r[2]));
        g.textLeft(b, { 0, size.y - 5 }, 9, Theme::dim());
    }
    void drawCurve(GC& g, Pt size) {
        auto* d = dsp();
        if (!d) return;
        auto& r = d->readouts;
        float thr = fin(r[3]), ratio = std::max(fin(r[4]), 1.0f), knee = std::max(fin(r[5]), 0.0f), makeup = fin(r[6]);
        float s = std::min(size.x, size.y);
        g.fill(Rect(0, 0, s, s), Theme::row());
        auto px = [&](float db) { return (std::clamp(db, floorDB, 0.0f) - floorDB) / -floorDB * s; };
        auto curve = [&](float x) {
            float over = x - thr, red;
            if (knee > 0 && std::abs(over) < knee / 2) { float t = over + knee / 2; red = (1 - 1 / ratio) * t * t / (2 * knee); }
            else red = over > 0 ? (1 - 1 / ratio) * over : 0;
            return x - red + makeup;
        };
        juce::Path diag; diag.startNewSubPath(0, s); diag.lineTo(s, 0);
        g.stroke(diag, Theme::faint().withMultipliedAlpha(0.6f), 0.5f);
        juce::Path p;
        for (int k = 0; k <= 40; ++k) {
            float x = floorDB + float(k) / 40 * -floorDB;
            Pt pt { px(x), s - px(curve(x)) };
            if (k == 0) p.startNewSubPath(pt); else p.lineTo(pt);
        }
        g.stroke(p, Theme::text().withMultipliedAlpha(0.85f), 1);
        g.fill(Rect(px(thr), 0, 0.5f, s), Theme::dim().withMultipliedAlpha(0.5f));
        float inDB = toDB(r[1]);
        if (inDB > floorDB) { Pt dot { px(inDB), s - px(curve(inDB)) }; g.fillEllipse(Rect(dot.x - 3, dot.y - 3, 6, 6), Theme::meterYellow); }
    }
private:
    static constexpr int length = 160;
    std::vector<std::vector<float>> rows = std::vector<std::vector<float>>(3, std::vector<float>(length, 0.0f));
    int head = 0; double last = 0;
};

// ---------------------------------------------------------------- lfo

class LFODisplay : public NativeDisplay {
public:
    using NativeDisplay::NativeDisplay;
    std::vector<LivePart> parts(Rect r) override {
        auto* d = dsp();
        if (!d) return {};
        return { part("lfo", r.reduced(0, 4), nullptr, [this, d](GC& g, Pt size) {
            auto& r = d->readouts;
            int shape = int(std::round(p("shape", 0)));
            float depth = p("depth", 0.5f), offset = p("offset", 0);
            float w = size.x - 44, h = size.y;
            auto y = [&](float v) { return (0.5f - std::clamp(fin(v), -1.0f, 1.0f) * 0.5f) * h; };
            g.fill(Rect(0, 0, w, h), Theme::row());
            g.fill(Rect(0, h / 2, w, 0.5f), Theme::faint());
            juce::Path path;
            if (shape == 4 || shape == 5) {
                // random: the last six values and the glide now under way, scrolling left as it plays (square random: steps)
                float ph = std::clamp(fin(r[1]), 0.0f, 1.0f);
                for (int i = 0; i <= 120; ++i) {
                    float u = float(i) / 120 * 6 + ph;
                    int k = std::min(int(u), 6); float f = u - float(k);
                    float a0 = r[size_t(2 + k)] * depth + offset, a1 = r[size_t(3 + k)] * depth + offset;
                    float kk = shape == 5 ? 1.0f : (1 - std::cos(juce::MathConstants<float>::pi * f)) / 2;
                    Pt pt { float(i) / 120 * w, y(a0 + (a1 - a0) * kk) };
                    if (i == 0) path.startNewSubPath(pt); else path.lineTo(pt);
                }
            } else {
                for (int k = 0; k <= 80; ++k) {
                    float ph = float(k) / 80, v;
                    switch (shape) { case 0: v = std::sin(2 * juce::MathConstants<float>::pi * ph); break; case 1: v = ph < 0.5f ? 4 * ph - 1 : 3 - 4 * ph; break;
                                     case 2: v = 2 * ph - 1; break; default: v = ph < 0.5f ? 1.0f : -1.0f; }
                    Pt pt { ph * w, y(v * depth + offset) };
                    if (k == 0) path.startNewSubPath(pt); else path.lineTo(pt);
                }
            }
            g.stroke(path, Theme::text().withMultipliedAlpha(0.75f), 1);
            float ph = std::clamp(fin(r[1]), 0.0f, 1.0f);
            float px = shape >= 4 ? w : ph * w;
            g.fill(Rect(px, 0, 0.5f, h), Theme::dim());
            g.fillEllipse(Rect(px - 3, y(r[0]) - 3, 6, 6), Theme::text());
            float bx = w + 8;
            g.fill(Rect(bx, 0, 6, h), Theme::row());
            float v0 = h / 2, v1 = y(r[0]);
            g.fill(Rect(bx, std::min(v0, v1), 6, std::abs(v1 - v0)), Theme::text().withMultipliedAlpha(0.8f));
            g.textRight(fmt("%+.1f", fin(r[0]) * 10), { size.x, h / 2 }, 9, Theme::dim());
        }, 1, true) };
    }
};

// ---------------------------------------------------------------- chord

class ChordDisplay : public NativeDisplay {
public:
    using NativeDisplay::NativeDisplay;
    static constexpr float top = 18;
    Rect inner(Rect r) const { return r.reduced(0, 4); }
    struct Shown { std::vector<int> notes; int root; int quality; };
    Shown chord() {
        auto* d = dsp();
        if (d) {
            auto& r = d->readouts;
            int n = std::clamp(int(fin(r[4])), 0, kMaxVoices);
            if (model.isRunning && n > 0) {
                std::vector<int> notes;
                for (int k = 0; k < n; ++k) notes.push_back(int(std::round(fin(r[size_t(k)]))));
                return { notes, std::clamp(int(fin(r[5])), 0, 11), int(fin(r[6])) };
            }
        }
        auto v = [&](const char* key) { int i = spec.paramIndex(key); return int(std::round(p(key, i >= 0 ? spec.params[size_t(i)].def : 0))); };
        auto c = Chords::build(v("mode"), v("key"), v("scale"), v("degree"), v("size"), v("type"), v("voices") + 3, v("inv"), v("spread"), v("oct"), 0, nullptr);
        std::vector<int> notes;
        for (float x : c.notes) notes.push_back(int(std::round(x)));
        return { notes, c.root, c.quality };
    }
    static std::pair<int, int> keyboard(const std::vector<int>& notes) {
        int lo = notes.empty() ? 0 : *std::min_element(notes.begin(), notes.end());
        int hi = notes.empty() ? 0 : *std::max_element(notes.begin(), notes.end());
        int start = int(std::floor(double(lo) / 12)) * 12;
        return { start, 2 + (hi - start >= 24 ? 1 : 0) };
    }
    std::vector<LivePart> parts(Rect r) override {
        auto* d = dsp();
        if (!d) return {};
        auto* m = &model;
        return { part("chord", inner(r), [this, d, m] { return LiveSig::readouts(d, 7, 100) + LiveSig::patch(node) * 7 + (m->isRunning ? 1 : 0); }, [this](GC& g, Pt size) {
            static const char* suffix[] = { "", "m", "7", "maj7", "m7", "sus2", "sus4", "dim", "aug", "6", "m6", "add9", "9", "m9", "m7\xe2\x99\xad" "5", "dim7" };
            static const char* intervals[] = { "R", "\xe2\x99\xad" "9", "9", "\xe2\x99\xad" "3", "3", "4", "\xe2\x99\xad" "5", "5", "\xe2\x99\xaf" "5", "6", "\xe2\x99\xad" "7", "7" };
            static const int whites[] = { 0, 2, 4, 5, 7, 9, 11 }, blacks[] = { 1, 3, 6, 8, 10 };
            auto c = chord();
            juce::String name = juce::String(Chords::keys[size_t(c.root)]) + (c.quality >= 0 && c.quality < 16 ? u8(suffix[c.quality]) : juce::String());
            juce::StringArray names;
            for (int n : c.notes) names.add(juce::String(Chords::keys[size_t(((n % 12) + 12) % 12)]) + juce::String(4 + int(std::floor(double(n) / 12))));
            g.textLeft(c.notes.empty() ? u8("\xe2\x80\x94") : name, { 0, 8 }, 13, Theme::text(), true);
            g.textRight(names.joinIntoString(" "), { size.x, 8 }, 9, Theme::dim());
            if (c.notes.empty()) return;
            float h = size.y - top;
            auto [start, span] = keyboard(c.notes);
            float ww = size.x / float(7 * span);
            auto lit = [&](int n) { return std::find(c.notes.begin(), c.notes.end(), n) != c.notes.end(); };
            auto label = [&](int n) { return u8(intervals[(((n - c.root) % 12) + 12) % 12]); };
            for (int o = 0; o < span; ++o) {
                for (int k = 0; k < 7; ++k) {
                    float x = float(o * 7 + k) * ww; int note = start + o * 12 + whites[k];
                    g.fill(Rect(x + 0.5f, top, ww - 1, h), lit(note) ? Theme::text() : Theme::row());
                    if (lit(note)) g.text(label(note), { x + ww / 2, top + h - 6 }, 7, Theme::box(), true);
                }
                for (int b : blacks) {
                    int k = 0; while (k < 7 && whites[k] <= b) ++k; k -= 1;
                    float x = float(o * 7 + k + 1) * ww - ww * 0.3f; int note = start + o * 12 + b;
                    g.fill(Rect(x, top, ww * 0.6f, h * 0.6f), lit(note) ? Theme::text() : Theme::dim());
                    if (lit(note)) g.text(label(note), { x + ww * 0.3f, top + h * 0.6f - 5 }, 6, Theme::box(), true);
                }
            }
        }) };
    }
    bool press(Pt pt, Rect r, const PointerInfo&) override { return inner(r).contains(pt); }
    void release(Pt pt, Rect r, const PointerInfo& info) override {
        if (info.moved) return;
        static const int whites[] = { 0, 2, 4, 5, 7, 9, 11 }, blacks[] = { 1, 3, 6, 8, 10 };
        auto i = inner(r);
        Pt lp = pt - i.getPosition();
        int ki = spec.paramIndex("key");
        if (lp.y < top || ki < 0) return;
        auto [start, span] = keyboard(chord().notes);
        float ww = i.getWidth() / float(7 * span), h = i.getHeight() - top;
        std::optional<int> note;
        if (lp.y < top + h * 0.6f)
            for (int o = 0; o < span; ++o)
                for (int b : blacks) {
                    int k = 0; while (k < 7 && whites[k] <= b) ++k; k -= 1;
                    float x = float(o * 7 + k + 1) * ww - ww * 0.3f;
                    if (lp.x >= x && lp.x <= x + ww * 0.6f) note = start + o * 12 + b;
                }
        if (!note) { int w = std::clamp(int(lp.x / ww), 0, 7 * span - 1); note = start + (w / 7) * 12 + whites[w % 7]; }
        model.setParam(id, ki, float(((*note % 12) + 12) % 12));
        model.scheduleAutosave();
    }
};

// ---------------------------------------------------------------- wave

class WaveDisplay : public NativeDisplay {
public:
    using NativeDisplay::NativeDisplay;
    Rect inner(Rect r) const { return r.reduced(0, 4); }
    Rect tabs(Rect r) const { auto i = inner(r); return Rect(i.getX(), i.getY(), i.getWidth(), 26); }
    Rect presetsRow(Rect r) const { auto i = inner(r); return Rect(i.getX(), i.getBottom() - 18, i.getWidth(), 18); }
    Rect mainR(Rect r) const { auto i = inner(r); return Rect(i.getX(), i.getY() + 26 + 4, i.getWidth(), std::max(i.getHeight() - 26 - 18 - 8, 10.0f)); }
    std::vector<std::string> buttonNames() const { auto v = WavetableNode::presets; v.push_back("smooth"); v.push_back("flip"); return v; }
    std::vector<std::pair<std::string, Rect>> buttons(Rect r) const {
        auto row = presetsRow(r); auto names = buttonNames();
        int n = int(names.size()); float gap = 3, bw = (row.getWidth() - gap * float(n - 1)) / float(n);
        std::vector<std::pair<std::string, Rect>> b;
        for (int k = 0; k < n; ++k) b.push_back({ names[size_t(k)], Rect(row.getX() + float(k) * (bw + gap), row.getY(), bw, row.getHeight()) });
        return b;
    }
    int editing() const { return std::clamp(int(std::round(p("edit", 0))), 0, WavetableNode::frames - 1); }
    static juce::Path path(Rect r, const std::function<float(int)>& value) {
        const int n = WavetableNode::points;
        juce::Path pp;
        for (int i = 0; i <= n; ++i) {
            float v = std::clamp(value(i % n), -1.0f, 1.0f);
            Pt pt { r.getX() + r.getWidth() * float(i) / float(n), r.getCentreY() - v * r.getHeight() / 2 };
            if (i == 0) pp.startNewSubPath(pt); else pp.lineTo(pt);
        }
        return pp;
    }
    std::vector<LivePart> parts(Rect r) override {
        auto* w = dynamic_cast<WavetableNode*>(dsp());
        if (!w) return {};
        auto sig = [this, w] { int64_t h = w->version; LiveSig::mix(h, editing()); LiveSig::mix(h, LiveSig::q(w->readouts[0], 50)); return h; };
        auto drawTabs = [this, w](GC& g, Pt size) {
            const int n = WavetableNode::frames; float gap = 4;
            float tw = (size.x - gap * float(n - 1)) / float(n), h = size.y - 5;
            for (int f = 0; f < n; ++f) {
                Rect rr(float(f) * (tw + gap), 0, tw, h);
                g.fill(rr, Theme::row());
                g.stroke(path(rr.reduced(3), [w, f](int i) { return w->drawn[size_t(f * WavetableNode::points + i)]; }), f == editing() ? Theme::text() : Theme::dim(), f == editing() ? 1.2f : 0.8f);
                if (f == editing()) g.strokeRect(rr.reduced(0.5f), Theme::text(), 1);
            }
            float pos = std::clamp(w->readouts[0], 0.0f, float(n - 1));
            float x = tw / 2 + pos * (tw + gap);
            g.fill(Rect(tw / 2, size.y - 2, x - tw / 2, 2), Theme::faint());
            g.fillEllipse(Rect(x - 3, size.y - 4, 6, 5), Theme::text());
        };
        auto drawMain = [this, w](GC& g, Pt size) {
            Rect rr(0, 0, size.x, size.y);
            g.fill(rr, Theme::row());
            g.fill(Rect(0, size.y / 2, size.x, 0.5f), Theme::faint());
            for (int k = 1; k < 4; ++k) g.fill(Rect(size.x * float(k) / 4, 0, 0.5f, size.y), Theme::faint().withMultipliedAlpha(0.5f));
            float pos = std::clamp(w->readouts[0], 0.0f, float(WavetableNode::frames - 1));
            int f0 = std::min(int(pos), WavetableNode::frames - 2); float t = pos - float(f0);
            int e = editing();
            if (std::abs(pos - float(e)) > 0.02f)
                g.stroke(path(rr, [w, f0, t](int i) { float a = w->drawn[size_t(f0 * WavetableNode::points + i)], b = w->drawn[size_t((f0 + 1) * WavetableNode::points + i)]; return a + (b - a) * t; }),
                         Theme::dim().withMultipliedAlpha(0.6f), 1);
            g.stroke(path(rr.reduced(0, 3), [w, e](int i) { return w->drawn[size_t(e * WavetableNode::points + i)]; }), Theme::text(), 1.6f);
            g.textLeft("wave " + juce::String(e + 1) + u8(" \xc2\xb7 draw here"), { 4, 8 }, 9, Theme::dim());
        };
        return { part("tabs", tabs(r), sig, drawTabs), part("main", mainR(r), sig, drawMain, 1, true) };
    }
    void paintStatic(GC& g, Rect r) override {
        for (auto& [s, b] : buttons(r)) {
            g.fill(b, Theme::row());
            g.text(fitText(s, 9, b.getWidth() - 2), b.getCentre(), 9, Theme::text());
        }
    }
    void paintAt(Pt pt, Rect r) {
        auto* w = dynamic_cast<WavetableNode*>(dsp());
        if (!w) return;
        auto m = mainR(r); const int n = WavetableNode::points;
        if (m.getWidth() <= 0 || m.getHeight() <= 6) return;
        int i = std::clamp(int((pt.x - m.getX()) / m.getWidth() * float(n)), 0, n - 1);
        float val = std::clamp(1 - (pt.y - m.getY() - 3) / (m.getHeight() - 6) * 2, -1.0f, 1.0f);
        float* base = w->drawn.data() + editing() * n;
        if (last && last->first != i) {
            int li = last->first; float lv = last->second, step = li < i ? 1.0f : -1.0f;
            int k = li;
            while (k != i) { k += int(step); base[k] = lv + (val - lv) * float(k - li) / float(i - li); }
        } else base[i] = val;
        last = std::make_pair(i, val);
        w->rebuild(editing());
    }
    void commit() {
        auto* w = dynamic_cast<WavetableNode*>(dsp());
        if (!w) return;
        model.setData(id, "wave", w->waveData());
        model.scheduleAutosave();
    }
    void set(const std::vector<float>& values) {
        auto* w = dynamic_cast<WavetableNode*>(dsp());
        if (!w) return;
        float* base = w->drawn.data() + editing() * WavetableNode::points;
        for (int i = 0; i < std::min(int(values.size()), WavetableNode::points); ++i) base[i] = std::clamp(values[size_t(i)], -1.0f, 1.0f);
        w->rebuild(editing());
        commit();
    }
    bool press(Pt pt, Rect r, const PointerInfo&) override {
        if (tabs(r).contains(pt)) {
            auto t = tabs(r); float gap = 4; const int n = WavetableNode::frames;
            float tw = (t.getWidth() - gap * float(n - 1)) / float(n);
            int f = std::clamp(int((pt.x - t.getX()) / (tw + gap)), 0, n - 1);
            model.setParam(id, 0, float(f)); model.scheduleAutosave();
            drawing = false;
            return true;
        }
        if (mainR(r).contains(pt)) { last.reset(); drawing = true; paintAt(pt, r); return true; }
        if (presetsRow(r).contains(pt)) { drawing = false; return true; }
        return false;
    }
    void drag(Pt pt, Rect r, const PointerInfo&) override { if (drawing) paintAt(pt, r); }
    void release(Pt pt, Rect r, const PointerInfo& info) override {
        if (drawing) { last.reset(); drawing = false; commit(); return; }
        auto* w = dynamic_cast<WavetableNode*>(dsp());
        if (info.moved || !w) return;
        for (auto& [s, b] : buttons(r)) {
            if (!b.contains(pt) || !b.contains(info.start)) continue;
            const int n = WavetableNode::points; float* base = w->drawn.data() + editing() * n;
            if (s == "smooth") {
                std::vector<float> v(static_cast<size_t>(n));
                for (int i = 0; i < n; ++i) { float sum = 0; for (int d = -3; d <= 3; ++d) sum += base[(i + d + n) % n]; v[size_t(i)] = sum / 7; }
                set(v);
            } else if (s == "flip") {
                std::vector<float> v(static_cast<size_t>(n));
                for (int i = 0; i < n; ++i) v[size_t(i)] = -base[i];
                set(v);
            } else set(WavetableNode::shape(s));
        }
    }
private:
    std::optional<std::pair<int, float>> last;
    bool drawing = false;
};

// ---------------------------------------------------------------- scope

class ScopeDisplay : public NativeDisplay {
public:
    using NativeDisplay::NativeDisplay;
    static juce::String volts(float v) { return fmt("%+.2f V", v * 10); }
    static juce::String note(float v) {
        static const char* names[] = { "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" };
        double semis = double(v) * 120;
        int n = int(std::round(semis)), cents = int(std::round((semis - n) * 100));
        juce::String s = juce::String(names[((n % 12) + 12) % 12]) + juce::String(4 + int(std::floor(double(n) / 12)));
        return cents == 0 ? s : s + fmt(" %+d", cents) + u8("\xc2\xa2");
    }
    static juce::String hz(float f) {
        if (f <= 0) return {};
        return f >= 1000 ? fmt("%.2f kHz", f / 1000) : (f >= 10 ? fmt("%.1f Hz", f) : fmt("%.2f Hz", f));
    }
    std::vector<LivePart> parts(Rect r) override {
        auto* s = dynamic_cast<ScopeNode*>(dsp());
        if (!s) return {};
        auto* m = &model; auto nid = id;
        return { part("scope", r.reduced(0, 4), [this, s, m, nid] {
                int64_t h = s->version;
                LiveSig::mix(h, LiveSig::patch(node));
                LiveSig::mix(h, (m->isPortConnected(nid, 0, false) ? 1 : 0) + (m->isPortConnected(nid, 1, false) ? 2 : 0));
                return h;
            }, [this, s, m, nid](GC& g, Pt size) {
                bool hasA = m->isPortConnected(nid, 0, false), hasB = m->isPortConnected(nid, 1, false);
                const int n = ScopeNode::points;
                auto& r = s->readouts;
                float w = size.x, top = hasA && hasB ? 34.0f : 20.0f, h = std::max(size.y - top - 14, 10.0f);
                static const float scaleValues[] = { 0, 1, 0.5f, 0.1f, 0.01f };
                float full = scaleValues[std::clamp(int(std::round(p("scale", 0))), 0, 4)];
                if (full == 0) {
                    float mx = 0;
                    for (int c = 0; c < 2; ++c) if (c == 0 ? hasA : hasB)
                        for (int q = 0; q < n; ++q) mx = std::max({ mx, std::abs(fin(s->shownMin[size_t(c * n + q)])), std::abs(fin(s->shownMax[size_t(c * n + q)])) });
                    full = 1;
                    for (float f : { 0.001f, 0.002f, 0.005f, 0.01f, 0.02f, 0.05f, 0.1f, 0.2f, 0.5f, 1.0f }) if (f >= mx * 1.05f) { full = f; break; }
                }
                auto y = [&](float v) { return top + (0.5f - std::clamp(fin(v) / full, -1.0f, 1.0f) * 0.5f) * h; };
                g.fill(Rect(0, top, w, h), Theme::row());
                for (int k = 1; k < 4; ++k) g.fill(Rect(0, top + h * float(k) / 4, w, 0.5f), Theme::faint());
                for (int k = 1; k < 8; ++k) g.fill(Rect(w * float(k) / 8, top, 0.5f, h), Theme::faint().withMultipliedAlpha(0.5f));
                for (int c : { 1, 0 }) {
                    if (!(c == 0 ? hasA : hasB)) continue;
                    juce::Path line;
                    for (int q = 0; q < n; ++q) {
                        float x = float(q) / float(n - 1) * w;
                        float lo = s->shownMin[size_t(c * n + q)], hi = s->shownMax[size_t(c * n + q)];
                        if (q == 0) line.startNewSubPath(x, y(hi)); else line.lineTo(x, y(hi));
                        line.lineTo(x, y(lo) + 0.5f);
                    }
                    g.stroke(line, c == 0 ? Theme::text() : Theme::dim(), 1);
                }
                auto reading = [&](int c) {
                    float mean = r[size_t(c * 4)], lo = r[size_t(c * 4 + 1)], hi = r[size_t(c * 4 + 2)], f = r[size_t(c * 4 + 3)];
                    juce::String s2 = juce::String(c == 0 ? "A " : "B ") + volts(mean);
                    if (hi - lo < 0.004f) s2 += "  " + note(mean);
                    else { s2 += "  " + fmt("%.1f", lo * 10) + u8("\xe2\x80\xa6") + fmt("%.1f V", hi * 10); if (f > 0) s2 += "  " + hz(f); }
                    return s2;
                };
                std::vector<std::pair<juce::String, C>> lines;
                if (hasA) lines.push_back({ reading(0), Theme::text() });
                if (hasB) lines.push_back({ reading(1), Theme::dim() });
                if (lines.empty()) lines.push_back({ "patch something into A or B", Theme::dim() });
                for (size_t k = 0; k < lines.size(); ++k) g.textLeft(lines[k].first, { 2, 8 + float(k) * 15 }, 11, lines[k].second);
                float ms = p("time", 20);
                juce::String timeText = ms >= 1000 ? fmt("%.1f s", ms / 1000) : fmt("%.0f ms", ms);
                juce::String fs = full * 10 >= 1 ? fmt("%g", full * 10) : fmt("%.2g", full * 10);
                g.textRight(u8("\xc2\xb1") + fs + u8(" V \xc2\xb7 ") + timeText, { w - 2, size.y - 5 }, 11, Theme::dim());
            }) };
    }
};

// ---------------------------------------------------------------- slider / knob

class ControlsDisplay : public NativeDisplay {
public:
    using NativeDisplay::NativeDisplay;
    bool slider() const { return spec.kind == "slider"; }
    Rect inner(Rect r) const { return r.reduced(0, 4); }
    int count() const { return ControlsLayout::count(p("count", 2)); }
    int range() const { float v = p("range", 0); return std::isfinite(v) ? std::clamp(int(std::round(v)), 0, 4) : 0; }
    std::vector<Rect> cells(Rect r) const {
        auto i = inner(r); int n = count();
        std::vector<Rect> out;
        if (slider()) {
            float cw = (i.getWidth() - float(n - 1) * 6) / float(n);
            for (int k = 0; k < n; ++k) out.push_back(Rect(i.getX() + float(k) * (cw + 6), i.getY(), cw, i.getHeight()));
            return out;
        }
        int cols = std::min(n, 4), rows = (n + cols - 1) / cols;
        float cw = i.getWidth() / float(cols), rh = i.getHeight() / float(rows);
        for (int k = 0; k < n; ++k) out.push_back(Rect(i.getX() + float(k % cols) * cw, i.getY() + float(k / cols) * rh, cw, rh));
        return out;
    }
    struct Target { juce::String module, param; std::function<juce::String()> value; };
    std::optional<Target> target(int k) {
        std::vector<const PatchCable*> cs;
        for (auto& c : model.patch.cables) if (c.fromNode == id && c.fromPort == k) cs.push_back(&c);
        if (cs.empty()) return std::nullopt;
        auto* c = cs.front();
        auto* n = model.nodeFor(c->toNode);
        auto* s = n ? Registry::spec(n->kind) : nullptr;
        if (!n || !s) return std::nullopt;
        juce::String more = cs.size() > 1 ? " +" + juce::String(int(cs.size()) - 1) : juce::String();
        Target t { model.label(*n), BoxLayout::inletName(*s, c->toPort) + more, nullptr };
        int pi = c->toPort - kParamPortBase;
        auto* d = model.node(n->id);
        if (pi >= 0 && pi < int(s->params.size()) && d) {
            auto ps = s->params[size_t(pi)];
            float pos = p("v" + std::to_string(k + 1), 0.5f);
            auto* m = &model;
            t.value = [m, ps, d, pi, pos] { return juce::String(m->isRunning ? ps.display(d->params[size_t(pi)]) : ps.display(ps.valueFromNormalized(pos))); };
        }
        return t;
    }
    float live(int k) {
        auto* d = dsp();
        float v = p("v" + std::to_string(k + 1), 0.5f);
        float r = model.isRunning && d ? d->readouts[size_t(k)] : v;
        return std::isfinite(r) ? std::clamp(r, 0.0f, 1.0f) : 0.0f;
    }
    juce::String label(int k, const std::optional<Target>& t) {
        if (t && t->value) return t->value();
        float v = ControlsNodeMap(live(k), range()) * 10;
        return fmt(std::abs(v) < 9.95f ? "%.2f" : "%.1f", v);
    }
    static float ControlsNodeMap(float x, int range) {
        float v = std::clamp(std::isfinite(x) ? x : 0.0f, 0.0f, 1.0f);
        switch (range) { case 1: return v * 2 - 1; case 2: return v * 0.5f; case 3: return v - 0.5f; case 4: return v * 0.1f; default: return v; }
    }
    static juce::String fit(const juce::String& s, float width) {
        int n = std::max(int(width / 5.6f), 1);
        return s.length() <= n ? s : s.substring(0, std::max(n - 1, 1)) + u8("\xe2\x80\xa6");
    }
    float drawTarget(GC& g, Pt size, bool twoLines, bool reserve, const std::optional<Target>& t) {
        if (!reserve) return 0;
        if (t) {
            g.text(fit(t->param, size.x), { size.x / 2, 6 }, 9, Theme::text());
            if (twoLines) g.text(fit(t->module, size.x), { size.x / 2, 17 }, 9, Theme::dim());
        }
        return twoLines ? 23.0f : 12.0f;
    }
    void drawCell(GC& g, Pt size, int k) {
        auto t = target(k);
        bool reserve = false;
        for (int j = 0; j < count(); ++j) if (target(j)) reserve = true;
        float lv = live(k);
        auto lab = label(k, t);
        juce::String text = fit(size.x < 44 ? lab : juce::String(k + 1) + "  " + lab, size.x);
        const float labelH = 14;
        if (slider()) {
            float top = std::max(drawTarget(g, size, size.y > 110, reserve, t), 0.0f) + 6;
            Rect track(size.x / 2 - 2, top, 4, std::max(size.y - labelH - 6 - top, 10.0f));
            g.fillRounded(track, 2, Theme::row());
            float y = track.getBottom() - lv * track.getHeight();
            g.fillRounded(Rect(track.getX(), y, 4, track.getBottom() - y), 2, Theme::text().withMultipliedAlpha(0.55f));
            float capW = std::min(size.x - 4, 44.0f);
            Rect cap(size.x / 2 - capW / 2, y - 6, capW, 12);
            g.fillRounded(cap, 2, Theme::text());
            g.fill(Rect(cap.getX() + 3, y - 0.5f, cap.getWidth() - 6, 1), Theme::box());
        } else {
            float top = drawTarget(g, size, size.y > 120, reserve, t);
            float avail = size.y - labelH - top;
            float rad = std::max(std::min(size.x / 2 - 6, (avail - 6) / (1 + 0.7071f)) * 0.82f, 6.0f);
            Pt c { size.x / 2, top + 3 + rad };
            auto point = [&](double deg) { double a = deg * juce::MathConstants<double>::pi / 180; return Pt { c.x + float(std::sin(a)) * rad, c.y - float(std::cos(a)) * rad }; };
            auto arc = [&](double a, double b) {
                juce::Path pp;
                int steps = std::max(int(std::abs(b - a) / 4), 1);
                for (int i = 0; i <= steps; ++i) { auto pt = point(a + (b - a) * double(i) / double(steps)); if (i == 0) pp.startNewSubPath(pt); else pp.lineTo(pt); }
                return pp;
            };
            float lw = std::max(std::min(rad * 0.18f, 4.0f), 2.0f);
            g.stroke(arc(-135, 135), Theme::dim().withMultipliedAlpha(Theme::boxIsLight() ? 0.55f : 0.75f), lw);
            if (lv > 0.001f) g.stroke(arc(-135, -135 + 270 * double(lv)), Theme::text(), lw);
        }
        g.text(text, { size.x / 2, size.y - labelH / 2 }, 9, Theme::dim());
    }
    std::vector<LivePart> parts(Rect r) override {
        std::vector<LivePart> list;
        auto cs = cells(r);
        for (int k = 0; k < int(cs.size()); ++k)
            list.push_back(part("cell" + std::to_string(k), cs[size_t(k)], [this, k] {
                int64_t h = LiveSig::q(live(k), 512);
                LiveSig::mix(h, label(k, target(k)).hashCode64());
                return h;
            }, [this, k](GC& g, Pt size) { drawCell(g, size, k); }, 2));
        return list;
    }
    bool press(Pt pt, Rect r, const PointerInfo& info) override {
        auto cs = cells(r);
        int k = -1;
        for (int j = 0; j < int(cs.size()); ++j) if (cs[size_t(j)].contains(pt)) k = j;
        if (k < 0) return false;
        grabbed = k;
        if (info.clickCount >= 2) { model.setParam(id, ControlsLayout::valueIndex(k), 0.5f); model.scheduleAutosave(); grabbed = -1; return true; }
        startV = p("v" + std::to_string(k + 1), 0.5f);
        return true;
    }
    void drag(Pt pt, Rect r, const PointerInfo& info) override {
        if (grabbed < 0 || !info.moved) return;
        auto cs = cells(r);
        auto c = cs[size_t(std::min(grabbed, int(cs.size()) - 1))];
        float tx = pt.x - info.start.x, ty = pt.y - info.start.y;
        float span = slider() ? std::max(c.getHeight() - 24, 40.0f) : 200.0f;
        float d = slider() ? -ty : (tx - ty);
        model.setParam(id, ControlsLayout::valueIndex(grabbed), std::clamp(startV + d / span, 0.0f, 1.0f));
    }
    void release(Pt, Rect, const PointerInfo&) override { grabbed = -1; model.scheduleAutosave(); }
private:
    int grabbed = -1; float startV = 0.5f;
};

// ---------------------------------------------------------------- peq

class EQDisplay : public NativeDisplay {
public:
    using NativeDisplay::NativeDisplay;
    static constexpr double fLo = 20, fHi = 20000, range = 18;
    static constexpr int N = 4096;
    Rect inner(Rect r) const { return r.reduced(0, 4); }
    float x(double f, float w) const { return float(std::log(std::max(f, fLo) / fLo) / std::log(fHi / fLo)) * w; }
    double f(float xx, float w) const { return fLo * std::pow(fHi / fLo, double(std::clamp(xx / std::max(w, 1.0f), 0.0f, 1.0f))); }
    float y(double db, float h) const { return h / 2 - float(std::max(std::min(db, range), -range) / range) * (h / 2 - 4); }
    double gain(float yy, float h) const { return double((h / 2 - yy) / (h / 2 - 4)) * range; }
    std::vector<std::pair<int, Pt>> bandPoints(Pt size) {
        auto* d = dsp();
        if (!d) return {};
        auto& p = d->base;
        int n = ParametricEQ::bandCount(p[0]);
        std::vector<std::pair<int, Pt>> out;
        for (int b = 0; b < n; ++b) out.push_back({ b, Pt { x(p[size_t(ParametricEQ::freqIndex(b))], size.x), y(p[size_t(ParametricEQ::gainIndex(b))], size.y) } });
        return out;
    }
    void updateSpectrum(const SpectrumSource* src) {
        double t = juce::Time::getMillisecondCounterHiRes() * 0.001;
        if (t - lastFFT < 1.0 / 30) return;
        lastFFT = t;
        if (window.empty()) {
            window.resize(N); db.assign(N / 2, -120); buf.resize(N); fft.resize(N);
            for (int i = 0; i < N; ++i) window[size_t(i)] = 0.5f - 0.5f * std::cos(2 * juce::MathConstants<float>::pi * float(i) / float(N));
        }
        src->copyRecent(buf.data(), N);
        analyze(db);
        if (src->copyRecentInput(buf.data(), N)) { if (dbIn.empty()) dbIn.assign(N / 2, -120); analyze(dbIn); hasIn = true; }
    }
    void analyze(std::vector<float>& out) {
        for (int i = 0; i < N; ++i) fft[size_t(i)] = { buf[size_t(i)] * window[size_t(i)], 0 };
        // in-place radix-2 FFT
        for (int i = 1, j = 0; i < N; ++i) { int bit = N >> 1; for (; j & bit; bit >>= 1) j ^= bit; j ^= bit; if (i < j) std::swap(fft[size_t(i)], fft[size_t(j)]); }
        for (int len = 2; len <= N; len <<= 1) {
            float ang = -2 * juce::MathConstants<float>::pi / float(len);
            std::complex<float> wl(std::cos(ang), std::sin(ang));
            for (int i = 0; i < N; i += len) {
                std::complex<float> w(1, 0);
                for (int j = 0; j < len / 2; ++j) { auto u = fft[size_t(i + j)], v = fft[size_t(i + j + len / 2)] * w; fft[size_t(i + j)] = u + v; fft[size_t(i + j + len / 2)] = u - v; w *= wl; }
            }
        }
        float scale = 8.0f / float(N);
        for (int k = 1; k < N / 2; ++k) { float v = 20 * std::log10(std::max(std::abs(fft[size_t(k)]) * scale, 1e-7f)); out[size_t(k)] = v > out[size_t(k)] ? v : out[size_t(k)] - 1.2f; }
    }
    void draw(GC& g, Pt size) {
        auto* d = dsp();
        if (!d) return;
        float w = size.x, h = size.y;
        double sr = model.host.sampleRate;
        g.fill(Rect(0, 0, w, h), Theme::row());
        for (double fr : { 100.0, 1000.0, 10000.0 }) g.fill(Rect(x(fr, w), 0, 0.5f, h), Theme::faint().withMultipliedAlpha(0.6f));
        for (double dbv : { -12.0, 0.0, 12.0 }) g.fill(Rect(0, y(dbv, h), w, 0.5f), dbv == 0 ? Theme::dim().withMultipliedAlpha(0.7f) : Theme::faint().withMultipliedAlpha(0.6f));
        bool connected = model.isPortConnected(id, 0, false) || model.isPortConnected(id, 1, false);
        if (connected && model.isRunning)
            if (auto* src = dynamic_cast<SpectrumSource*>(d)) {
                // what goes in, filled; what comes out (after the bands), as an outline over it
                updateSpectrum(src);
                const int half = N / 2; double binHz = sr / N;
                auto spectrum = [&](const std::vector<float>& dbs, bool closed) {
                    juce::Path sp;
                    for (int col = 0; col <= int(w); col += 2) {
                        double f0 = f(float(col), w), f1 = f(float(col + 1), w);
                        int k0 = std::max(1, int(f0 / binHz)), k1 = std::min(half - 1, std::max(k0, int(f1 / binHz)));
                        float m = -120;
                        for (int k = k0; k <= k1; ++k) m = std::max(m, dbs[size_t(k)]);
                        float yy = h - std::clamp((m + 90) / 90, 0.0f, 1.0f) * h;
                        if (col == 0) { if (closed) { sp.startNewSubPath(0, h); sp.lineTo(0, yy); } else sp.startNewSubPath(0, yy); }
                        else sp.lineTo(float(col), yy);
                    }
                    if (closed) { sp.lineTo(w, h); sp.closeSubPath(); }
                    return sp;
                };
                if (hasIn) g.fill(spectrum(dbIn, true), Theme::text().withMultipliedAlpha(0.11f));
                g.stroke(spectrum(db, false), Theme::text().withMultipliedAlpha(0.55f), 0.8f);
            }
        auto& p = d->params;
        juce::Path path;
        for (int i = 0; i <= int(w); ++i) {
            double fr = f(float(i), w);
            double dbv = ParametricEQ::responseDB([&](int k) { return p[size_t(k)]; }, fr, sr);
            Pt pt { float(i), y(std::isfinite(dbv) ? dbv : 0, h) };
            if (i == 0) path.startNewSubPath(pt); else path.lineTo(pt);
        }
        g.stroke(path, Theme::text(), 1.4f);
        for (auto& [b, pt] : bandPoints(size)) {
            float rr = band == b ? 7.0f : 5.0f;
            Rect e(pt.x - rr, pt.y - rr, rr * 2, rr * 2);
            g.fillEllipse(e, band == b ? Theme::text() : Theme::box());
            g.strokeEllipse(e, Theme::text(), 1.2f);
            g.text(juce::String(b + 1), { std::clamp(pt.x, 8.0f, w - 8), pt.y < h / 2 ? pt.y + 13 : pt.y - 13 }, 9, Theme::dim());
        }
        if (band >= 0) {
            double fr = d->base[size_t(ParametricEQ::freqIndex(band))]; float gg = d->base[size_t(ParametricEQ::gainIndex(band))];
            char b[64];
            if (fr >= 1000) std::snprintf(b, sizeof b, "%.1fk Hz  %+.1f dB", fr / 1000, gg); else std::snprintf(b, sizeof b, "%.0f Hz  %+.1f dB", fr, gg);
            g.text(b, { w / 2, 9 }, 9, Theme::text());
        }
    }
    std::vector<LivePart> parts(Rect r) override { return { part("eq", inner(r), nullptr, [this](GC& g, Pt s) { draw(g, s); }, 2) }; }
    bool press(Pt pt, Rect r, const PointerInfo& info) override {
        auto i = inner(r);
        if (!i.contains(pt)) return false;
        Pt lp = pt - i.getPosition();
        int best = -1; float bd = INFINITY;
        for (auto& [b, q] : bandPoints({ i.getWidth(), i.getHeight() })) { float dd = q.getDistanceFrom(lp); if (dd < bd) { bd = dd; best = b; } }
        if (best < 0 || bd >= 30) { band = -1; return true; }
        if (info.clickCount >= 2) { model.setParam(id, ParametricEQ::gainIndex(best), 0); band = -1; return true; }
        band = best;
        return true;
    }
    void drag(Pt pt, Rect r, const PointerInfo&) override {
        if (band < 0) return;
        auto i = inner(r);
        Pt lp = pt - i.getPosition();
        model.setParam(id, ParametricEQ::freqIndex(band), float(f(lp.x, i.getWidth())));
        double g = std::clamp(gain(lp.y, i.getHeight()), -18.0, 18.0);
        model.setParam(id, ParametricEQ::gainIndex(band), float(std::abs(g) < 0.4 ? 0 : g));
    }
    void release(Pt, Rect, const PointerInfo&) override { band = -1; }
private:
    int band = -1;
    double lastFFT = 0;
    std::vector<float> window, db, dbIn, buf;
    bool hasIn = false;
    std::vector<std::complex<float>> fft;
};

// ---------------------------------------------------------------- rack / drumsynth

class PadsDisplay : public NativeDisplay {
public:
    using NativeDisplay::NativeDisplay;
    virtual int lanes() const = 0;
    virtual float laneHeight() const = 0;
    virtual float labelWidth() const = 0;
    virtual float labelSize() const = 0;
    virtual int padRows() const = 0;
    virtual int padCols() const = 0;
    virtual int steps() const = 0;
    virtual float* hits() = 0;
    virtual juce::String laneName(int k) = 0;
    virtual void audition(int k) = 0;
    virtual int nameLines() const { return 1; }
    float padLevel(int k) { auto* d = dsp(); return d ? fin(d->readouts[size_t(1 + k)]) : 0.0f; }
    bool padPlaying(int k) { return padLevel(k) > 0.05f; }
    int len() const { return int(std::round(p("len", 16))); }
    int selected() const { return int(std::round(p("sel", 0))); }
    Rect inner(Rect r) const { return r.reduced(0, 4); }
    Rect rollRect(Rect r) const { auto i = inner(r); return Rect(i.getX(), i.getY(), i.getWidth(), float(lanes()) * laneHeight()); }
    Rect gridRect(Rect r) const { auto rr = rollRect(r); return Rect(rr.getX() + labelWidth(), rr.getY(), rr.getWidth() - labelWidth(), rr.getHeight()); }
    Rect padRect(int k, Rect r) const {
        auto i = inner(r); float top = rollRect(r).getBottom() + 8, gap = 4;
        float pw = (i.getWidth() - gap * float(padCols() - 1)) / float(padCols());
        int row = padRows() - 1 - k / padCols(), col = k % padCols();
        return Rect(i.getX() + float(col) * (pw + gap), top + float(row) * (42 + gap), pw, 42);
    }
    std::vector<std::pair<juce::String, Rect>> padButtons(int k, Rect r) const {
        auto pr = padRect(k, r);
        const char* names[] = { "M", "\xe2\x96\xb6", "S" };
        std::vector<std::pair<juce::String, Rect>> b;
        for (int j = 0; j < 3; ++j) b.push_back({ u8(names[j]), Rect(pr.getX() + 4 + float(j) * 17, pr.getBottom() - 4 - 12, 15, 12) });
        return b;
    }
    bool flag(const std::string& key) const { return p(key, 0) > 0.5f; }
    void select(int k) { setParam("sel", float(k)); }
    void toggle(const std::string& key) { setParam(key, flag(key) ? 0.0f : 1.0f); }
    void drawRollGrid(GC& g, Pt size, float rh) {
        auto* d = dsp();
        float* h = hits();
        if (!d || !h) return;
        int L = len();
        float cw = size.x / float(std::max(L, 1));
        g.fill(Rect(0, 0, size.x, size.y), Theme::row());
        for (int lane = 1; lane < lanes(); lane += 2) g.fill(Rect(0, float(lane) * rh, size.x, rh), Theme::shade());
        g.fill(Rect(0, float(selected()) * rh, size.x, rh), Theme::text().withMultipliedAlpha(0.08f));
        drawStepGrid(g, size, L, divOf(node));
        int ps = model.isRunning ? int(d->readouts[0]) : -1;
        if (ps >= 0 && ps < L) g.fill(Rect(float(ps) * cw, 0, cw, size.y), Theme::text().withMultipliedAlpha(0.12f));
        for (int lane = 0; lane < lanes(); ++lane)
            for (int s = 0; s < L; ++s)
                if (h[lane * steps() + s] > 0.5f) g.fill(Rect(float(s) * cw + 1, float(lane) * rh + 1, cw - 2, rh - 2), s == ps ? Theme::text() : Theme::text().withMultipliedAlpha(0.8f));
    }
    virtual void commit() = 0;
    std::vector<LivePart> parts(Rect r) override {
        auto* m = &model;
        auto roll = part("roll", gridRect(r), [this, m] {
            float* h0 = hits(); auto* d = dsp();
            if (!h0) return int64_t(0);
            int64_t h = m->isRunning && d ? int64_t(d->readouts[0]) : -1;
            LiveSig::mix(h, LiveSig::floats(h0, lanes() * steps()));
            LiveSig::mix(h, LiveSig::patch(node)); LiveSig::mix(h, selected());
            return h;
        }, [this](GC& g, Pt size) { drawRollGrid(g, size, laneHeight()); });
        int n = padRows() * padCols();
        float top = padRect(n - padCols(), r).getY();
        Rect padsArea(inner(r).getX(), top, inner(r).getWidth(), padRect(0, r).getBottom() - top);
        auto pads = part("pads", padsArea, [this, n] {
            int64_t h = 0;
            for (int k = 0; k < n; ++k) if (padPlaying(k)) h |= int64_t(1) << k;   // a pad lights while it plays: on / off, no fade
            return h;
        }, [this, n, r, padsArea](GC& g, Pt) {
            for (int k = 0; k < n; ++k) {
                auto pr = padRect(k, r).translated(-padsArea.getX(), -padsArea.getY());
                if (padPlaying(k)) g.fill(pr, Theme::text().withMultipliedAlpha(0.14f));
            }
        }, 1);
        return { roll, pads };
    }
    void paintStatic(GC& g, Rect r) override {
        auto rr = rollRect(r);
        for (int k = 0; k < lanes(); ++k) {
            float y = rr.getY() + float(k) * laneHeight() + laneHeight() / 2;
            g.textLeft(fitText(laneName(k), labelSize(), labelWidth() - 6), { rr.getX(), y }, labelSize(), k == selected() ? Theme::text() : Theme::dim());
        }
        for (int k = 0; k < padRows() * padCols(); ++k) {
            auto pr = padRect(k, r);
            bool muted = flag("m" + std::to_string(k + 1)), solo = flag("s" + std::to_string(k + 1));
            g.fill(pr, Theme::row());
            bool loading = model.loadingPads.count(id) && model.loadingPads[id].count(k);
            juce::String title = dropPad == k ? juce::String("drop to load") : (loading ? u8("loading\xe2\x80\xa6") : laneName(k));
            float maxW = pr.getWidth() - 8;
            juce::StringArray lines;
            juce::String rest = title;
            while (rest.isNotEmpty() && lines.size() < nameLines()) {
                juce::String cut = rest;
                while (cut.length() > 1 && textWidth(cut, 8.5f) > maxW) cut = cut.dropLastCharacters(1);
                if (lines.size() == nameLines() - 1 && cut.length() < rest.length()) { cut = fitText(rest, 8.5f, maxW); rest = {}; }
                else rest = rest.substring(cut.length());
                lines.add(cut);
            }
            for (int j = 0; j < lines.size(); ++j)
                g.textLeft(lines[j], { pr.getX() + 4, pr.getY() + 4 + 5.5f + float(j) * 11 }, 8.5f, muted ? Theme::faint() : (loading ? Theme::dim() : Theme::text()));
            for (auto& [s, b] : padButtons(k, r)) {
                bool on = (s == "M" && muted) || (s == "S" && solo);
                g.fill(b, on ? Theme::text() : Theme::box());
                g.text(s, b.getCentre(), 8, on ? Theme::inverse() : Theme::dim(), true);
            }
            bool sel = k == selected(), drop = dropPad == k;
            if (drop) g.fill(pr, Theme::text().withMultipliedAlpha(0.12f));
            float lw = drop ? 2.5f : (sel ? 1.5f : 0.5f);
            g.strokeRect(pr.reduced(lw / 2), sel || drop ? Theme::text() : Theme::border(), lw);
        }
    }
    void paintRoll(Pt pt, Rect r) {
        float* h = hits();
        if (!h) return;
        auto gr = gridRect(r);
        int L = len();
        float cw = gr.getWidth() / float(std::max(L, 1));
        int s = int((pt.x - gr.getX()) / cw), lane = int((pt.y - gr.getY()) / laneHeight());
        if (s < 0 || s >= L || lane < 0 || lane >= lanes()) return;
        int i = lane * steps() + s;
        if (!paint) paint = h[i] > 0.5f ? 0.0f : 1.0f;
        h[i] = *paint;
    }
    bool press(Pt pt, Rect r, const PointerInfo&) override {
        grabRoll = false;
        if (gridRect(r).contains(pt)) { paint.reset(); grabRoll = true; paintRoll(pt, r); return true; }
        auto rr = rollRect(r);
        if (rr.contains(pt)) {
            int k = int((pt.y - rr.getY()) / laneHeight());
            if (k >= 0 && k < lanes()) select(k);
            return true;
        }
        for (int k = 0; k < padRows() * padCols(); ++k) if (padRect(k, r).contains(pt)) { pressedPad = k; return true; }
        return false;
    }
    void drag(Pt pt, Rect r, const PointerInfo&) override { if (grabRoll) paintRoll(pt, r); }
    void release(Pt pt, Rect r, const PointerInfo& info) override {
        if (grabRoll) { paint.reset(); grabRoll = false; commit(); return; }
        int k = pressedPad; pressedPad = -1;
        if (k < 0 || info.moved || !padRect(k, r).contains(pt)) return;
        for (auto& [s, b] : padButtons(k, r))
            if (b.contains(pt)) {
                if (s == "M") toggle("m" + std::to_string(k + 1));
                else if (s == "S") toggle("s" + std::to_string(k + 1));
                else { audition(k); select(k); }
                return;
            }
        select(k);                   // the pad itself only selects it (the play button plays it)
    }
private:
    std::optional<float> paint;
    bool grabRoll = false;
    int pressedPad = -1;
};

class RackDisplay : public PadsDisplay {
public:
    using PadsDisplay::PadsDisplay;
    RackNode* rack() { return dynamic_cast<RackNode*>(dsp()); }
    int lanes() const override { return RackLayout::pads; }
    float laneHeight() const override { return BoxLayout::padLaneHeight(node); }
    float labelWidth() const override { return 64; }
    float labelSize() const override { return 7.5f; }
    int padRows() const override { return 4; }
    int padCols() const override { return 4; }
    int steps() const override { return RackLayout::steps; }
    int nameLines() const override { return 2; }
    float* hits() override { auto* r = rack(); return r ? r->hits.data() : nullptr; }
    juce::String laneName(int k) override { auto* r = rack(); return r ? juce::String::fromUTF8(r->padNames[size_t(k)].c_str()) : juce::String(); }
    void audition(int k) override { if (auto* r = rack()) r->audition = k; }
    void commit() override { if (auto* r = rack()) model.setData(id, "hits", std::vector<float>(r->hits.begin(), r->hits.end())); }
    std::optional<int> pad(Pt pt, Rect r) override { for (int k = 0; k < RackLayout::pads; ++k) if (padRect(k, r).contains(pt)) return k; return std::nullopt; }
    std::optional<std::vector<MenuItem>> menu(Pt pt, Rect r) override {
        auto k = pad(pt, r);
        if (!k) return std::nullopt;
        auto* m = &model; auto nid = id; int kk = *k;
        MenuItem it; it.title = "Back to the built-in " + juce::String(RackLayout::kitNames[size_t(kk)]); it.action = [m, nid, kk] { m->resetPad(nid, kk); };
        return std::vector<MenuItem> { it };
    }
};

class DrumSynthDisplay : public PadsDisplay {
public:
    using PadsDisplay::PadsDisplay;
    DrumSynthNode* synth() { return dynamic_cast<DrumSynthNode*>(dsp()); }
    int lanes() const override { return DrumSynthLayout::voices; }
    float laneHeight() const override { return BoxLayout::padLaneHeight(node); }
    float labelWidth() const override { return 52; }
    float labelSize() const override { return 8.5f; }
    int padRows() const override { return 1; }
    int padCols() const override { return DrumSynthLayout::voices; }
    int steps() const override { return DrumSynthLayout::steps; }
    float* hits() override { auto* s = synth(); return s ? s->hits.data() : nullptr; }
    juce::String laneName(int v) override {
        int e = int(std::round(p("e" + std::to_string(v + 1), float(DrumSynthLayout::engines[size_t(v)]))));
        return juce::String::fromUTF8(DrumSynthLayout::label(v, e).c_str());
    }
    void audition(int k) override { if (auto* s = synth()) s->audition = k; }
    void commit() override { if (auto* s = synth()) model.setData(id, "hits", std::vector<float>(s->hits.begin(), s->hits.end())); }
};

// ---------------------------------------------------------------- factory

std::unique_ptr<NativeDisplay> NativeDisplay::make(AppModel& m, const PatchNode& n, const ModuleSpec& s) {
    if (!BoxLayout::hasReadout(s.kind)) return nullptr;
    auto& k = s.kind;
    if (k == "looper" || k == "sampler" || k == "stretch") return std::make_unique<BufferDisplay>(m, n, s);
    if (k == "keys") return std::make_unique<KeysDisplay>(m, n, s);
    if (k == "seq") return std::make_unique<SeqDisplay>(m, n, s);
    if (k == "turing") return std::make_unique<TuringDisplay>(m, n, s);
    if (k == "roll" || k == "drums") return std::make_unique<GridDisplay>(m, n, s);
    if (k == "comp") return std::make_unique<CompDisplay>(m, n, s);
    if (k == "lfo") return std::make_unique<LFODisplay>(m, n, s);
    if (k == "chord") return std::make_unique<ChordDisplay>(m, n, s);
    if (k == "wave") return std::make_unique<WaveDisplay>(m, n, s);
    if (k == "fm") return std::make_unique<FMDisplay>(m, n, s);
    if (k == "scope") return std::make_unique<ScopeDisplay>(m, n, s);
    if (k == "drumsynth") return std::make_unique<DrumSynthDisplay>(m, n, s);
    if (k == "rack") return std::make_unique<RackDisplay>(m, n, s);
    if (k == "slider" || k == "knob") return std::make_unique<ControlsDisplay>(m, n, s);
    if (k == "peq") return std::make_unique<EQDisplay>(m, n, s);
    if (k == "clock") return std::make_unique<ClockDisplay>(m, n, s);
    return std::make_unique<TextReadout>(m, n, s);
}

} // namespace pn
