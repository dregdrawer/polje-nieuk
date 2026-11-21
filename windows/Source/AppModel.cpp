#include "AppModel.h"
#if JUCE_WINDOWS
 #include <windows.h>
#else
 #include <sys/resource.h>
#endif

namespace pn {

static double now() { return juce::Time::getMillisecondCounterHiRes() * 0.001; }
static float paramOr(const PatchNode& n, const std::string& key, float def) { auto it = n.params.find(key); return it == n.params.end() ? def : it->second; }

// ---------------------------------------------------------------- ControlLink (Controls.swift)

namespace ControlLink {
bool isControl(const Patch& p, const juce::String& id) {
    int i = p.index(id);
    return i >= 0 && (p.nodes[size_t(i)].kind == "slider" || p.nodes[size_t(i)].kind == "knob");
}
std::vector<Update> updates(const Patch& patch, const juce::String& id, int index, float value) {
    int ni = patch.index(id);
    if (ni < 0) return {};
    auto& n = patch.nodes[size_t(ni)];
    auto* spec = Registry::spec(n.kind);
    if (!spec || index < 0 || index >= int(spec->params.size())) return {};
    std::vector<Update> out;
    auto targets = [&](const juce::String& ctl, int k, float position, const juce::String* skipNode, int skipParam) {
        for (auto& c : patch.cables) {
            if (c.fromNode != ctl || c.fromPort != k || c.toPort < kParamPortBase) continue;
            int pi = c.toPort - kParamPortBase;
            if (skipNode && *skipNode == c.toNode && skipParam == pi) continue;
            int ti = patch.index(c.toNode);
            if (ti < 0) continue;
            auto* ts = Registry::spec(patch.nodes[size_t(ti)].kind);
            if (!ts || pi >= int(ts->params.size()) || ts->params[size_t(pi)].isTrigger()) continue;
            out.push_back({ c.toNode, pi, ts->params[size_t(pi)].valueFromNormalized(position) });
        }
    };
    if (n.kind == "slider" || n.kind == "knob") {
        int k = index - ControlsLayout::valueIndex(0);
        if (k < 0 || k >= ControlsLayout::maxControls) return {};
        targets(id, k, std::clamp(std::isfinite(value) ? value : 0.0f, 0.0f, 1.0f), nullptr, -1);
    } else {
        if (spec->params[size_t(index)].isTrigger()) return {};
        float pos = spec->params[size_t(index)].normalized(value);
        for (auto& c : patch.cables)
            if (c.toNode == id && c.toPort == kParamPortBase + index && isControl(patch, c.fromNode)) {
                out.push_back({ c.fromNode, ControlsLayout::valueIndex(c.fromPort), pos });
                targets(c.fromNode, c.fromPort, pos, &id, index);
            }
    }
    return out;
}
Patch reconciled(const Patch& patch) {
    Patch p = patch;
    for (auto& n : patch.nodes) {
        if (n.kind != "slider" && n.kind != "knob") continue;
        auto* spec = Registry::spec(n.kind);
        if (!spec) continue;
        for (int k = 0; k < ControlsLayout::maxControls; ++k) {
            int vi = ControlsLayout::valueIndex(k);
            float pos = paramOr(n, spec->params[size_t(vi)].key, spec->params[size_t(vi)].def);
            for (auto& u : updates(patch, n.id, vi, pos)) {
                int ti = p.index(u.node);
                if (ti < 0) continue;
                auto* ts = Registry::spec(p.nodes[size_t(ti)].kind);
                if (ts) p.nodes[size_t(ti)].params[ts->params[size_t(u.index)].key] = u.value;
            }
        }
    }
    return p;
}
}

// ---------------------------------------------------------------- TidyLayout (TidyLayout.swift)

namespace TidyLayout {
std::map<juce::String, Pt> layout(const Patch& patch, const HardwareCounts& hw) {
    const float grid = 24, colGap = 72, rowGap = 36;
    const Pt origin { 48, 48 };
    std::vector<const PatchNode*> nodes;
    std::map<juce::String, const PatchNode*> byID;
    for (auto& n : patch.nodes) if (Registry::spec(n.kind)) { nodes.push_back(&n); byID[n.id] = &n; }
    if (nodes.empty()) return {};
    auto spec = [](const PatchNode* n) { return Registry::spec(n->kind); };
    auto size = [&](const PatchNode* n) { return Pt { BoxLayout::width(*n), BoxLayout::height(*n, *spec(n), hw) }; };
    auto outY = [&](const PatchNode* n, int port) { return BoxLayout::outlet(*n, *spec(n), hw, port).y - float(n->y); };
    auto inY = [&](const PatchNode* n, int port) {
        auto d = BoxLayout::destination(*n, *spec(n), hw, port);
        return (d ? d->y : float(n->y) + BoxLayout::header) - float(n->y);
    };
    std::vector<PatchCable> cables;
    for (auto& c : patch.cables) if (c.fromNode != c.toNode && byID.count(c.fromNode) && byID.count(c.toNode)) cables.push_back(c);
    std::vector<const PatchNode*> texts, boxes;
    for (auto* n : nodes) (n->kind == "text" ? texts : boxes).push_back(n);
    std::set<juce::String> wired;
    for (auto& c : cables) { wired.insert(c.fromNode); wired.insert(c.toNode); }
    std::vector<const PatchNode*> controllers, loose, flowNodes;
    for (auto* n : boxes) {
        bool anyOut = false, anyIn = false, allParam = true;
        for (auto& c : cables) { if (c.fromNode == n->id) { anyOut = true; if (c.toPort < kParamPortBase) allParam = false; } if (c.toNode == n->id) anyIn = true; }
        if (anyOut && !anyIn && allParam && n->kind != "in") controllers.push_back(n);
    }
    std::set<juce::String> ctlIDs;
    for (auto* n : controllers) ctlIDs.insert(n->id);
    for (auto* n : boxes) {
        if (!wired.count(n->id)) loose.push_back(n);
        else if (!ctlIDs.count(n->id)) flowNodes.push_back(n);
    }
    std::set<juce::String> flowIDs;
    for (auto* n : flowNodes) flowIDs.insert(n->id);
    std::vector<PatchCable> edges;
    for (auto& c : cables) if (flowIDs.count(c.fromNode) && flowIDs.count(c.toNode)) edges.push_back(c);
    // 1. break feedback loops
    {
        std::map<juce::String, int> state;
        std::set<juce::String> back;
        std::map<juce::String, std::vector<PatchCable>> outs;
        for (auto& e : edges) outs[e.fromNode].push_back(e);
        std::function<void(const juce::String&)> visit = [&](const juce::String& id) {
            state[id] = 1;
            for (auto& e : outs[id]) {
                auto it = state.find(e.toNode);
                if (it == state.end()) visit(e.toNode);
                else if (it->second == 1) back.insert(e.id);
            }
            state[id] = 2;
        };
        auto sorted = flowNodes;
        std::stable_sort(sorted.begin(), sorted.end(), [](auto* a, auto* b) { return a->x < b->x; });
        for (auto* n : sorted) if (!state.count(n->id)) visit(n->id);
        edges.erase(std::remove_if(edges.begin(), edges.end(), [&](auto& e) { return back.count(e.id) > 0; }), edges.end());
    }
    std::map<juce::String, std::vector<PatchCable>> succ, pred;
    for (auto& e : edges) { succ[e.fromNode].push_back(e); pred[e.toNode].push_back(e); }
    // 2. columns
    std::map<juce::String, int> layer;
    std::function<int(const juce::String&)> longest = [&](const juce::String& id) -> int {
        auto it = layer.find(id);
        if (it != layer.end()) return it->second;
        int l = 0;
        for (auto& e : pred[id]) l = std::max(l, longest(e.fromNode) + 1);
        layer[id] = l;
        return l;
    };
    for (auto* n : flowNodes) longest(n->id);
    std::vector<juce::String> order;
    for (auto* n : flowNodes) order.push_back(n->id);
    std::stable_sort(order.begin(), order.end(), [&](auto& a, auto& b) { return layer[a] > layer[b]; });
    for (auto& id : order) {
        if (succ[id].empty() || byID[id]->kind == "in") continue;
        int m = INT32_MAX;
        for (auto& e : succ[id]) m = std::min(m, layer[e.toNode] - 1);
        layer[id] = m;
    }
    int last = 0;
    for (auto& [k, v] : layer) last = std::max(last, v);
    for (auto* n : flowNodes) if (n->kind == "out") layer[n->id] = std::max(last, 1);
    for (auto* n : flowNodes) if (n->kind == "in") layer[n->id] = 0;
    int minL = INT32_MAX;
    for (auto& [k, v] : layer) minL = std::min(minL, v);
    if (layer.empty()) minL = 0;
    for (auto& [k, v] : layer) v -= minL;
    int nLayers = 1;
    for (auto& [k, v] : layer) nLayers = std::max(nLayers, v + 1);
    // 3. order inside each column
    std::map<juce::String, int> rank;
    int counter = 0;
    std::function<void(const juce::String&)> walk = [&](const juce::String& id) {
        if (rank.count(id)) return;
        rank[id] = counter++;
        auto ins = pred[id];
        std::stable_sort(ins.begin(), ins.end(), [&](auto& a, auto& b) {
            if (a.toPort != b.toPort) return a.toPort < b.toPort;
            return byID[a.fromNode]->y < byID[b.fromNode]->y;
        });
        for (auto& e : ins) walk(e.fromNode);
    };
    std::vector<const PatchNode*> sinks;
    for (auto* n : flowNodes) if (succ[n->id].empty()) sinks.push_back(n);
    std::stable_sort(sinks.begin(), sinks.end(), [](auto* a, auto* b) {
        int ka = a->kind == "out" ? 0 : 1, kb = b->kind == "out" ? 0 : 1;
        if (ka != kb) return ka < kb;
        return a->y < b->y;
    });
    for (auto* s : sinks) walk(s->id);
    auto byY = flowNodes;
    std::stable_sort(byY.begin(), byY.end(), [](auto* a, auto* b) { return a->y < b->y; });
    for (auto* n : byY) walk(n->id);
    std::vector<std::vector<juce::String>> cols(static_cast<size_t>(nLayers));
    for (auto* n : flowNodes) cols[size_t(layer[n->id])].push_back(n->id);
    for (auto& c : cols) std::stable_sort(c.begin(), c.end(), [&](auto& a, auto& b) { return rank[a] < rank[b]; });
    // 4. column x
    std::vector<float> colX(size_t(nLayers), origin.x);
    float x = origin.x;
    for (int c = 0; c < nLayers; ++c) {
        colX[size_t(c)] = x;
        float w = 0;
        for (auto& id : cols[size_t(c)]) w = std::max(w, size(byID[id]).x);
        x += w + colGap;
    }
    // 5. controllers along the top
    std::map<juce::String, Pt> pos;
    float ctlBottom = origin.y;
    {
        auto targetX = [&](const PatchNode* n) {
            float sum = 0; int cnt = 0;
            for (auto& c : cables) if (c.fromNode == n->id && layer.count(c.toNode)) { sum += colX[size_t(layer[c.toNode])]; ++cnt; }
            return cnt == 0 ? origin.x : sum / float(cnt);
        };
        auto sorted = controllers;
        std::stable_sort(sorted.begin(), sorted.end(), [&](auto* a, auto* b) { return targetX(a) < targetX(b); });
        float right = origin.x - colGap;
        for (auto* n : sorted) {
            float px = std::max(targetX(n), right + colGap / 2);
            pos[n->id] = { px, origin.y };
            right = px + size(n).x;
            ctlBottom = std::max(ctlBottom, origin.y + size(n).y);
        }
    }
    float top = controllers.empty() ? origin.y : ctlBottom + rowGap * 2;
    // 6. heights
    std::map<juce::String, float> y;
    for (auto& col : cols) { float yy = top; for (auto& id : col) { y[id] = yy; yy += size(byID[id]).y + rowGap; } }
    auto settle = [&](const std::vector<juce::String>& col, const std::map<juce::String, float>& want) {
        std::vector<float> placed;
        for (size_t k = 0; k < col.size(); ++k) {
            auto it = want.find(col[k]);
            float v = it != want.end() ? it->second : y[col[k]];
            if (k > 0) v = std::max(v, placed[k - 1] + size(byID[col[k - 1]]).y + rowGap);
            placed.push_back(std::max(v, top));
        }
        for (int k = int(col.size()) - 2; k >= 0; --k) {
            float limit = placed[size_t(k + 1)] - size(byID[col[size_t(k)]]).y - rowGap;
            auto it = want.find(col[size_t(k)]);
            float w = it != want.end() ? it->second : placed[size_t(k)];
            if (placed[size_t(k)] > w && limit > placed[size_t(k)] - 0.5f)
                placed[size_t(k)] = std::max(std::min(limit, placed[size_t(k)]), std::max(w, top));
        }
        for (size_t k = 0; k < col.size(); ++k) y[col[k]] = placed[k];
    };
    for (int pass = 0; pass < 6; ++pass) {
        for (int c = nLayers - 2; c >= 0; --c) {
            std::map<juce::String, float> want;
            for (auto& id : cols[size_t(c)]) {
                auto& es = succ[id];
                if (es.empty()) continue;
                float sum = 0;
                for (auto& e : es) sum += y[e.toNode] + inY(byID[e.toNode], e.toPort) - outY(byID[id], e.fromPort);
                want[id] = sum / float(es.size());
            }
            settle(cols[size_t(c)], want);
        }
        for (int c = 1; c < std::max(nLayers, 1); ++c) {
            std::map<juce::String, float> want;
            for (auto& id : cols[size_t(c)]) {
                float sum = 0; int cnt = 0;
                for (auto& e : pred[id]) if (e.toPort < kParamPortBase) { sum += y[e.fromNode] + outY(byID[e.fromNode], e.fromPort) - inY(byID[id], e.toPort); ++cnt; }
                if (cnt) want[id] = sum / float(cnt);
            }
            settle(cols[size_t(c)], want);
        }
        if (!y.empty()) {
            float lowest = INFINITY;
            for (auto& [k, v] : y) lowest = std::min(lowest, v);
            if (lowest > top) for (auto& [k, v] : y) v -= lowest - top;
        }
    }
    for (int c = 0; c < nLayers; ++c) for (auto& id : cols[size_t(c)]) pos[id] = { colX[size_t(c)], y[id] };
    // 7. unpatched boxes underneath
    float graphBottom = top;
    bool anyPos = false;
    for (auto& [id, p] : pos) if (byID.count(id)) { float b = p.y + size(byID[id]).y; graphBottom = anyPos ? std::max(graphBottom, b) : b; anyPos = true; }
    float lx = origin.x, ly = (flowNodes.empty() && controllers.empty()) ? origin.y : graphBottom + rowGap * 2;
    auto ls = loose;
    std::stable_sort(ls.begin(), ls.end(), [](auto* a, auto* b) { return a->y != b->y ? a->y < b->y : a->x < b->x; });
    for (auto* n : ls) { pos[n->id] = { lx, ly }; lx += size(n).x + colGap / 2; }
    // 8. snap
    for (auto& [id, p] : pos) p = { std::round(p.x / grid) * grid, std::round(p.y / grid) * grid };
    // 9. notes travel with the nearest box
    auto dist = [](Pt p, Rect r) {
        float dx = std::max({ r.getX() - p.x, 0.0f, p.x - r.getRight() }), dy = std::max({ r.getY() - p.y, 0.0f, p.y - r.getBottom() });
        return std::sqrt(dx * dx + dy * dy);
    };
    for (auto* t : texts) {
        Pt tp { float(t->x), float(t->y) };
        const PatchNode* nearest = nullptr; float best = INFINITY;
        for (auto* b : boxes) {
            auto s = size(b);
            float d = dist(tp, Rect(float(b->x), float(b->y), s.x, s.y));
            if (d < best) { best = d; nearest = b; }
        }
        if (nearest && pos.count(nearest->id)) { auto np = pos[nearest->id]; pos[t->id] = { np.x + (tp.x - float(nearest->x)), np.y + (tp.y - float(nearest->y)) }; }
        else pos[t->id] = tp;
    }
    return pos;
}
}

// ---------------------------------------------------------------- PatchStore

namespace PatchStore {
juce::File folder() {
   #if JUCE_MAC
    // the Mac build of the JUCE version keeps its own files (the Mac app's are in "polje nieuk")
    auto d = juce::File::getSpecialLocation(juce::File::userApplicationDataDirectory).getChildFile("Application Support/polje nieuk (JUCE)");
   #else
    auto d = juce::File::getSpecialLocation(juce::File::userApplicationDataDirectory).getChildFile("polje nieuk");
   #endif
    d.createDirectory();
    return d;
}
juce::File autosaveFile() { return folder().getChildFile("autosave.json"); }
juce::File defaultFile() { return folder().getChildFile("default.json"); }
juce::File defaultAudioFolder() { auto d = folder().getChildFile("Default"); d.createDirectory(); return d; }
static std::optional<Patch> read(const juce::File& f) {
    if (!f.existsAsFile()) return std::nullopt;
    auto p = Patch::fromJSON(f.loadFileAsString());
    if (!p) return std::nullopt;
    return p->migrated();
}
std::optional<Patch> loadAutosave() { return read(autosaveFile()); }
void saveAutosave(const Patch& p) {
    auto tmp = autosaveFile().getSiblingFile("autosave.tmp");
    if (tmp.replaceWithText(p.toJSON())) tmp.moveFileTo(autosaveFile());
}
std::optional<Patch> loadUserDefault() { return read(defaultFile()); }
Patch builtIn() {
    Patch p;
    auto make = [](const char* k, double x, double y) { PatchNode n; n.id = Patch::newID(); n.kind = k; n.x = x; n.y = y; return n; };
    auto clock = make("clock", 30, 40), hwIn = make("in", 30, 260), mix = make("mix", 230, 40), hwOut = make("out", 470, 40);
    p.nodes = { hwIn, clock, mix, hwOut };
    return p;
}
Patch makeDefault() {
    if (auto p = loadUserDefault()) return p->withFreshIDs().first;
    return builtIn();
}
}

// ---------------------------------------------------------------- the model

const std::set<std::string> AppModel::patternKinds { "rack", "drumsynth", "drums", "roll" };

AppModel::AppModel() {
    auto& s = settings();
    lightScheme = Theme::light = s.getBoolValue("lightScheme", false);
    hideCables = s.getBoolValue("hideCables", false);
    for (auto& c : juce::StringArray::fromLines(s.getValue("typeHighlights"))) if (c.isNotEmpty()) typeHighlights.insert(c.toStdString());
    hw.inputs = s.getIntValue("hwInputs", 12);
    hw.outputs = s.getIntValue("hwOutputs", 8);
    inputUID = s.getValue("inputUID", "");
    outputUID = s.getValue("outputUID", "");
    viewOffset = { float(s.getDoubleValue("viewOffsetX", 30)), float(s.getDoubleValue("viewOffsetY", 30)) };
    viewScale = std::clamp(float(s.getDoubleValue("viewScale", 1)), 0.12f, 2.0f);
    for (auto& f : juce::StringArray::fromLines(s.getValue("browserFolders"))) if (f.isNotEmpty()) browserFolders.push_back(juce::File(f));
    hasUserDefault = PatchStore::defaultFile().existsAsFile();
    patch = PatchStore::loadAutosave().value_or(PatchStore::makeDefault());
    patch = ControlLink::reconciled(patch);
    history.reset(patch, false);
    BoxLayout::rebuildUsage(patch);
    followClockInputs();
    host.load(patch);
    restoreBuffers();
    devices.addAudioCallback(this);
    startTimerHz(120);
}

AppModel::~AppModel() {
    stopTimer();
    audioJobs.removeAllJobs(true, 4000);
    devices.removeAudioCallback(this);
    devices.closeAudioDevice();
    PatchStore::saveAutosave(patch);
    flushBuffersToDisk();
    settings().saveIfNeeded();
    background.removeAllJobs(false, 3000);
}

void AppModel::handleAsyncUpdate() {
    for (auto& l : listeners) l();
}

void AppModel::patchChanged() {
    BoxLayout::rebuildUsage(patch);
    if (!restoringHistory) checkpointAt = now() + 0.4;
    changed();
}

// ---------------------------------------------------------------- view

void AppModel::setView(Pt offset, float scale) {
    viewOffset = offset; viewScale = scale;
    viewSaveAt = now() + 0.5;
    if (onViewport) onViewport();
}

void AppModel::zoomBy(float factor, Pt anchor) {
    float old = viewScale, nw = std::clamp(old * factor, 0.12f, 2.0f);
    if (nw == old) return;
    float cx = (anchor.x - viewOffset.x) / old, cy = (anchor.y - viewOffset.y) / old;
    setView({ anchor.x - cx * nw, anchor.y - cy * nw }, nw);
}

void AppModel::saveView() {
    auto& s = settings();
    s.setValue("viewScale", double(viewScale)); s.setValue("viewOffsetX", double(viewOffset.x)); s.setValue("viewOffsetY", double(viewOffset.y));
}

bool AppModel::hasContent(Pt c) {
    const float m = 14;
    for (auto& n : patch.nodes) {
        float h;
        if (n.kind == "text") h = BoxLayout::textSize(n).y;
        else if (auto* s = Registry::spec(n.kind)) h = BoxLayout::height(n, *s, hw); else continue;
        if (Rect(float(n.x) - m, float(n.y) - m, BoxLayout::width(n) + 2 * m, h + 2 * m).contains(c)) return true;
    }
    for (auto& g : patch.groups) if (auto r = groupRect(g); r && r->contains(c)) return true;
    return false;
}

// ---------------------------------------------------------------- timer: undo steps, autosave, automation, buffers

void AppModel::timerCallback() {
    double t = now();
    if (checkpointAt > 0 && t >= checkpointAt) checkpoint();
    if (autosaveAt > 0 && t >= autosaveAt) {
        autosaveAt = 0;
        auto snapshot = patch;
        background.addJob([snapshot] { PatchStore::saveAutosave(snapshot); });
    }
    if (viewSaveAt > 0 && t >= viewSaveAt) { viewSaveAt = 0; saveView(); }
    if (analyzeAt > 0 && t >= analyzeAt) { analyzeAt = 0; samplerAnalyze(node(analyzeID)); changed(); }
    for (auto it = rescaleBase.begin(); it != rescaleBase.end();) { if (t >= it->second.until) it = rescaleBase.erase(it); else ++it; }
    if (!autoRecording.empty()) autoTick();
    if (layoutStep >= 0) {
        // tidy: glide into place (18 steps at 60 Hz, ease out)
        layoutStep += 1;
        const int steps = 36;
        double u = double(layoutStep) / steps, e = 1 - std::pow(1 - u, 3);
        for (auto& n : patch.nodes) {
            auto a = layoutStart.find(n.id), b = layoutTarget.find(n.id);
            if (a == layoutStart.end() || b == layoutTarget.end()) continue;
            n.x = a->second.x + (b->second.x - a->second.x) * e;
            n.y = a->second.y + (b->second.y - a->second.y) * e;
        }
        if (layoutStep >= steps) { layoutStep = -1; scheduleAutosave(); }
        patchChanged();
    }
    if (t >= nextBufferWatch) { nextBufferWatch = t + 0.25; watchBuffers(); }
    if (t >= nextCPU) { nextCPU = t + 1; sampleAppCPU(); }
}

void AppModel::sampleAppCPU() {
    double cpu = 0;
   #if JUCE_WINDOWS
    FILETIME c, e, k, u;
    if (GetProcessTimes(GetCurrentProcess(), &c, &e, &k, &u)) {
        auto toS = [](FILETIME f) { return double((uint64_t(f.dwHighDateTime) << 32) | f.dwLowDateTime) * 1e-7; };
        cpu = toS(k) + toS(u);
    }
   #else
    rusage r {};
    getrusage(RUSAGE_SELF, &r);
    cpu = double(r.ru_utime.tv_sec) + double(r.ru_utime.tv_usec) / 1e6 + double(r.ru_stime.tv_sec) + double(r.ru_stime.tv_usec) / 1e6;
   #endif
    double wall = now();
    if (lastCPU >= 0 && wall - lastWall > 0.1) {
        float v = float((cpu - lastCPU) / (wall - lastWall));
        appCPU = appCPU == 0 ? v : appCPU * 0.6f + v * 0.4f;
    }
    lastCPU = cpu; lastWall = wall;
}

// ---------------------------------------------------------------- editing

void AppModel::addNode(const std::string& kind, Pt p) {
    if (!Registry::spec(kind)) return;
    PatchNode n; n.id = Patch::newID(); n.kind = kind; n.x = std::round(p.x); n.y = std::round(p.y);
    patch.nodes.push_back(n);
    selectedNodes = { n.id }; selectedCable = {};
    topologyChanged();
}

void AppModel::beginReplace(const juce::String& id) {
    auto* n = nodeFor(id);
    if (!n) return;
    finderAt = Pt { float(n->x), float(n->y) + 24 };
    replaceTarget = id;
    changed();
}

void AppModel::replaceNode(const juce::String& id, const std::string& kind) {
    auto r = patch.replacing(id, kind);
    if (!r) return;
    patch = r->first;
    selectedNodes = { r->second }; selectedCable = {};
    topologyChanged();
}

void AppModel::duplicate(const juce::String& id) {
    auto* src = nodeFor(id);
    if (!src) return;
    PatchNode copy = *src;
    copy.id = Patch::newID(); copy.x = src->x + 24; copy.y = src->y + 24;
    patch.nodes.push_back(copy);
    topologyChanged();
    auto* a = dynamic_cast<SampleBufferNode*>(node(id));
    auto* b = dynamic_cast<SampleBufferNode*>(node(copy.id));
    if (a && b) { auto audio = a->snapshot(); if (!audio.empty()) b->load(audio); }
    copyRackPads(id, copy.id);
    select(copy.id);
}

void AppModel::removeSelection() {
    if (selectedCable.isNotEmpty()) {
        auto c = selectedCable;
        patch.cables.erase(std::remove_if(patch.cables.begin(), patch.cables.end(), [&](auto& x) { return x.id == c; }), patch.cables.end());
        selectedCable = {};
        topologyChanged();
        return;
    }
    if (selectedNodes.empty()) return;
    auto ids = selectedNodes;
    patch.nodes.erase(std::remove_if(patch.nodes.begin(), patch.nodes.end(), [&](auto& n) { return ids.count(n.id) > 0; }), patch.nodes.end());
    patch.cables.erase(std::remove_if(patch.cables.begin(), patch.cables.end(), [&](auto& c) { return ids.count(c.fromNode) || ids.count(c.toNode); }), patch.cables.end());
    for (auto& g : patch.groups) g.members.erase(std::remove_if(g.members.begin(), g.members.end(), [&](auto& m) { return ids.count(m) > 0; }), g.members.end());
    patch.groups.erase(std::remove_if(patch.groups.begin(), patch.groups.end(), [](auto& g) { return g.members.size() < 2; }), patch.groups.end());
    selectedNodes.clear();
    topologyChanged();
}

void AppModel::removeNode(const juce::String& id) {
    sampleFile(id).deleteFile();
    selectedNodes = { id }; selectedCable = {};
    removeSelection();
}

void AppModel::removeCable(const juce::String& id) {
    patch.cables.erase(std::remove_if(patch.cables.begin(), patch.cables.end(), [&](auto& c) { return c.id == id; }), patch.cables.end());
    if (selectedCable == id) selectedCable = {};
    topologyChanged();
}

void AppModel::select(const juce::String& id) { selectedNodes = { id }; selectedCable = {}; changed(); }
void AppModel::toggleSelected(const juce::String& id) {
    if (selectedNodes.count(id)) selectedNodes.erase(id); else selectedNodes.insert(id);
    selectedCable = {}; changed();
}
void AppModel::clearSelection() { selectedNodes.clear(); selectedCable = {}; changed(); }

void AppModel::selectIn(Rect r, bool adding) {
    std::set<juce::String> hits;
    for (auto& n : patch.nodes) {
        auto* s = Registry::spec(n.kind);
        if (!s) continue;
        if (Rect(float(n.x), float(n.y), BoxLayout::width(n), BoxLayout::height(n, *s, hw)).intersects(r)) hits.insert(n.id);
    }
    if (adding) selectedNodes.insert(hits.begin(), hits.end()); else selectedNodes = hits;
    selectedCable = {}; changed();
}

void AppModel::duplicateSelection() {
    auto ids = selectedNodes;
    if (ids.empty()) return;
    std::map<juce::String, juce::String> map;
    std::vector<PatchNode> copies;
    for (auto& n : patch.nodes) if (ids.count(n.id)) { PatchNode c = n; c.id = Patch::newID(); c.x = n.x + 30; c.y = n.y + 30; map[n.id] = c.id; copies.push_back(c); }
    patch.nodes.insert(patch.nodes.end(), copies.begin(), copies.end());
    std::vector<PatchCable> add;
    for (auto& c : patch.cables) if (ids.count(c.fromNode) && ids.count(c.toNode)) {
        PatchCable d; d.id = Patch::newID(); d.fromNode = map[c.fromNode]; d.fromPort = c.fromPort; d.toNode = map[c.toNode]; d.toPort = c.toPort;
        add.push_back(d);
    }
    patch.cables.insert(patch.cables.end(), add.begin(), add.end());
    topologyChanged();
    for (auto& [o, nw] : map) {
        auto* a = dynamic_cast<SampleBufferNode*>(node(o)); auto* b = dynamic_cast<SampleBufferNode*>(node(nw));
        if (a && b) { auto audio = a->snapshot(); if (!audio.empty()) b->load(audio); }
        copyRackPads(o, nw);
    }
    selectedNodes.clear();
    for (auto& [o, nw] : map) selectedNodes.insert(nw);
    changed();
}

std::vector<PatchGroup> AppModel::selectedGroups() const {
    std::vector<PatchGroup> r;
    for (auto& g : patch.groups) for (auto& m : g.members) if (selectedNodes.count(m)) { r.push_back(g); break; }
    return r;
}

void AppModel::groupSelection() {
    std::vector<juce::String> ids;
    for (auto& n : patch.nodes) if (selectedNodes.count(n.id)) ids.push_back(n.id);
    if (ids.size() < 2) return;
    auto gs = patch.groups;
    for (auto& g : gs) g.members.erase(std::remove_if(g.members.begin(), g.members.end(), [&](auto& m) { return std::find(ids.begin(), ids.end(), m) != ids.end(); }), g.members.end());
    gs.erase(std::remove_if(gs.begin(), gs.end(), [](auto& g) { return g.members.size() < 2; }), gs.end());
    int k = int(gs.size()) + 1;
    auto taken = [&](int n) { for (auto& g : gs) if (g.name == "group " + juce::String(n)) return true; return false; };
    while (taken(k)) ++k;
    PatchGroup g; g.id = Patch::newID(); g.name = "group " + juce::String(k); g.members = ids;
    gs.push_back(g);
    patch.groups = gs;
    patchChanged(); scheduleAutosave();
}

void AppModel::ungroupSelection() {
    auto hit = selectedGroups();
    if (hit.empty()) return;
    std::set<juce::String> h; for (auto& g : hit) h.insert(g.id);
    patch.groups.erase(std::remove_if(patch.groups.begin(), patch.groups.end(), [&](auto& g) { return h.count(g.id) > 0; }), patch.groups.end());
    patchChanged(); scheduleAutosave();
}

void AppModel::selectGroup(const PatchGroup& g) { selectedNodes = std::set<juce::String>(g.members.begin(), g.members.end()); selectedCable = {}; changed(); }

void AppModel::renameGroup(const juce::String& id, const juce::String& name) {
    for (auto& g : patch.groups) if (g.id == id) { if (name.isNotEmpty()) g.name = name; }
    patchChanged(); scheduleAutosave();
}

std::optional<Rect> AppModel::groupRect(const PatchGroup& g) const {
    std::optional<Rect> r;
    for (auto& id : g.members) {
        auto* n = nodeFor(id);
        if (!n) continue;
        auto* s = Registry::spec(n->kind);
        if (!s) continue;
        Rect b(float(n->x), float(n->y), BoxLayout::width(*n), BoxLayout::height(*n, *s, hw));
        r = r ? r->getUnion(b) : b;
    }
    if (!r) return std::nullopt;
    return Rect(r->getX() - 14, r->getY() - 30, r->getWidth() + 28, r->getHeight() + 44);
}

void AppModel::bypassSelection() {
    std::vector<juce::String> ids; bool allOff = true;
    for (auto& n : patch.nodes) {
        auto* s = Registry::spec(n.kind);
        if (selectedNodes.count(n.id) && s && s->bypass() != BypassMode::none) { ids.push_back(n.id); allOff = allOff && n.bypassed; }
    }
    if (ids.empty()) return;
    for (auto& id : ids) if (auto* n = nodeFor(id); n && n->bypassed == allOff) toggleBypass(id);
}

void AppModel::beginGroupDrag() {
    groupDragStart.clear();
    for (auto& n : patch.nodes) if (selectedNodes.count(n.id)) groupDragStart[n.id] = { float(n.x), float(n.y) };
}
void AppModel::groupDrag(Pt d) {
    std::set<juce::String> ids;
    for (auto& [k, v] : groupDragStart) ids.insert(k);
    dragMove(ids, d);
}
void AppModel::endGroupDrag() { endDragMove(); groupDragStart.clear(); }

void AppModel::nativeDragBegan(const juce::String& id) {
    nativeID = id;
    nativeGroup = selectedNodes.count(id) && selectedNodes.size() > 1;
    if (nativeGroup) beginGroupDrag();
}
void AppModel::nativeDragMoved(Pt screen, Pt point) {
    if (nativeID.isEmpty()) return;
    Pt d { screen.x / viewScale, screen.y / viewScale };
    if (nativeGroup) groupDrag(d);
    else { dragMove({ nativeID }, d); updateInsertCandidate(nativeID, point); }
}
void AppModel::nativeDragEnded() {
    if (nativeID.isEmpty()) return;
    auto id = nativeID; nativeID = {};
    if (nativeGroup) endGroupDrag(); else { endDragMove(); finishInsert(id); select(id); }
    nativeGroup = false;
    scheduleAutosave();
}
void AppModel::dragMove(const std::set<juce::String>& ids, Pt d) {
    dragState.ids = ids; dragState.delta = d;
    if (onDragMoved) onDragMoved();
}
void AppModel::endDragMove() {
    auto d = dragState.delta; auto ids = dragState.ids;
    if (ids.empty()) return;
    for (auto& n : patch.nodes) if (ids.count(n.id)) {
        n.x = std::max(-2000.0, std::round(n.x + d.x));
        n.y = std::max(-2000.0, std::round(n.y + d.y));
    }
    dragState.ids.clear(); dragState.delta = {};
    patchChanged();
}

void AppModel::moveNode(const juce::String& id, Pt p) {
    int i = index(id);
    if (i < 0) return;
    patch.nodes[size_t(i)].x = std::max(-2000.0f, std::round(p.x));
    patch.nodes[size_t(i)].y = std::max(-2000.0f, std::round(p.y));
    patchChanged();
}

void AppModel::resizeNode(const juce::String& id, std::optional<float> width, std::optional<float> display) {
    int i = index(id);
    if (i < 0) return;
    auto& n = patch.nodes[size_t(i)];
    n.w = width ? std::optional<double>(std::round(std::max(*width, BoxLayout::defaultWidth(n)))) : std::nullopt;
    n.dh = display ? std::optional<double>(std::round(std::max(*display, BoxLayout::defaultReadoutHeight(n)))) : std::nullopt;
    patchChanged();
}

void AppModel::toggleBypass(const juce::String& id) {
    int i = index(id);
    if (i < 0) return;
    auto& n = patch.nodes[size_t(i)];
    n.bypassed = !n.bypassed;
    auto* s = Registry::spec(n.kind);
    if (!n.bypassed && s && s->bypass() == BypassMode::through && !dynamic_cast<SampleBufferNode*>(node(id))) {
        host.renew(id, patch);           // back on: empty delay lines / tails
        restoreBuffers();
    } else if (auto* d = node(id)) d->bypassed = n.bypassed;
    patchChanged(); scheduleAutosave();
}

// ---------------------------------------------------------------- view > Select type

const std::map<std::string, juce::String> AppModel::categoryColours {
    { "I/O", "#8d8d8d" }, { "Clock", "#ffc53d" }, { "Sequencing", "#0090ff" }, { "Loop & Grain", "#12a594" }, { "Instruments", "#e5484d" },
    { "Effects", "#8e4ec6" }, { "Dynamics", "#f76b15" }, { "Modulation", "#30a46c" }, { "Utility", "#e93d82" } };
void AppModel::setTypeHighlights(std::set<std::string> s) {
    typeHighlights = std::move(s);
    juce::StringArray a; for (auto& c : typeHighlights) a.add(juce::String(c));
    settings().setValue("typeHighlights", a.joinIntoString("\n"));
    changed();
}
void AppModel::toggleTypeHighlight(const std::string& category) {
    auto s = typeHighlights;
    if (s.count(category)) s.erase(category); else s.insert(category);
    setTypeHighlights(s);
}
std::optional<juce::String> AppModel::typeColour(const PatchNode& n) const {
    if (typeHighlights.empty()) return std::nullopt;
    auto* sp = Registry::spec(n.kind);
    if (!sp || !typeHighlights.count(sp->category)) return std::nullopt;
    auto it = categoryColours.find(sp->category);
    return it == categoryColours.end() ? std::nullopt : std::optional<juce::String>(it->second);
}
bool AppModel::hasSection(const std::string& category) const {
    for (auto& n : patch.nodes) if (auto* sp = Registry::spec(n.kind); sp && sp->category == category) return true;
    return false;
}

// ---------------------------------------------------------------- drop a box onto a cable

static Pt bezier(Pt a, Pt b, float t, float scale) {
    float d = std::min(140 * scale, std::max(30 * scale, std::abs(b.x - a.x) * 0.45f + std::abs(b.y - a.y) * 0.15f));
    Pt c1 { a.x + d, a.y }, c2 { b.x - d, b.y };
    float u = 1 - t;
    return { u*u*u*a.x + 3*u*u*t*c1.x + 3*u*t*t*c2.x + t*t*t*b.x, u*u*u*a.y + 3*u*u*t*c1.y + 3*u*t*t*c2.y + t*t*t*b.y };
}

void AppModel::updateInsertCandidate(const juce::String& id, Pt screen) {
    auto* n = nodeFor(id);
    auto* spec = n ? Registry::spec(n->kind) : nullptr;
    bool wired = false;
    for (auto& c : patch.cables) if (c.fromNode == id || c.toNode == id) wired = true;
    if (!spec || spec->inputs.empty() || spec->outputs.empty() || wired) {
        if (!insertCandidates.empty()) { insertCandidates.clear(); changed(); }
        return;
    }
    const PatchCable* best = nullptr; float bestD = INFINITY;
    for (auto& c : patch.cables) {
        if (c.toPort >= kParamPortBase) continue;
        auto* a = nodeFor(c.fromNode); auto* b = nodeFor(c.toNode);
        if (!a || !b) continue;
        auto* sa = Registry::spec(a->kind); auto* sb = Registry::spec(b->kind);
        if (!sa || !sb) continue;
        auto dest = BoxLayout::destination(*b, *sb, hw, c.toPort);
        if (!dest) continue;
        Pt pa = toScreen(BoxLayout::outlet(*a, *sa, hw, c.fromPort)), pb = toScreen(*dest);
        for (int k = 0; k <= 32; ++k) {
            Pt q = bezier(pa, pb, float(k) / 32, viewScale);
            float d = q.getDistanceFrom(screen);
            if (d < 26 && d < bestD) { bestD = d; best = &c; }
        }
    }
    std::set<juce::String> ids;
    if (best) for (auto& c : patch.cables) if (c.fromNode == best->fromNode && c.toNode == best->toNode && c.toPort < kParamPortBase) ids.insert(c.id);
    if (ids != insertCandidates) { insertCandidates = ids; changed(); }
}

void AppModel::finishInsert(const juce::String& id) {
    auto cands = insertCandidates;
    insertCandidates.clear();
    auto* n = nodeFor(id);
    auto* spec = n ? Registry::spec(n->kind) : nullptr;
    if (cands.empty() || !spec) return;
    std::vector<PatchCable> old;
    for (auto& c : patch.cables) if (cands.count(c.id)) old.push_back(c);
    std::stable_sort(old.begin(), old.end(), [](auto& a, auto& b) { return a.toPort < b.toPort; });
    if (old.empty()) return;
    auto idx = [](const std::vector<std::string>& v, auto pred) { for (size_t i = 0; i < v.size(); ++i) if (pred(v[i])) return int(i); return -1; };
    int lIn = std::max(idx(spec->inputs, [](auto& s) { return s == "L"; }), 0);
    int rIn = idx(spec->inputs, [](auto& s) { return s == "R"; });
    if (rIn < 0) rIn = idx(spec->inputs, [](auto& s) { return s == "B"; });
    int lOut = std::max(idx(spec->outputs, [](auto& s) { return !s.empty() && s.back() == 'L'; }), 0);
    int rOut = idx(spec->outputs, [](auto& s) { return !s.empty() && s.back() == 'R'; });
    if (rOut < 0) rOut = idx(spec->outputs, [](auto& s) { return s == "B"; });
    auto isRight = [&](const PatchCable& c, int k) {
        if (auto* a = nodeFor(c.fromNode)) if (auto* sa = Registry::spec(a->kind))
            if (c.fromPort < int(sa->outputs.size()) && !sa->outputs[size_t(c.fromPort)].empty() && sa->outputs[size_t(c.fromPort)].back() == 'R') return true;
        if (auto* b = nodeFor(c.toNode)) if (auto* sb = Registry::spec(b->kind))
            if (c.toPort < int(sb->inputs.size()) && sb->inputs[size_t(c.toPort)] == "R") return true;
        return old.size() > 1 && k > 0;
    };
    patch.cables.erase(std::remove_if(patch.cables.begin(), patch.cables.end(), [&](auto& c) { return cands.count(c.id) > 0; }), patch.cables.end());
    std::set<juce::String> made;
    for (int k = 0; k < int(old.size()); ++k) {
        auto& c = old[size_t(k)];
        bool right = isRight(c, k);
        int inP = right ? (rIn >= 0 ? rIn : lIn) : lIn, outP = right ? (rOut >= 0 ? rOut : lOut) : lOut;
        auto key = c.fromNode + "-" + juce::String(c.fromPort) + "-" + juce::String(inP);
        if (!made.count(key)) {
            PatchCable a; a.id = Patch::newID(); a.fromNode = c.fromNode; a.fromPort = c.fromPort; a.toNode = id; a.toPort = inP;
            patch.cables.push_back(a); made.insert(key);
        }
        PatchCable b; b.id = Patch::newID(); b.fromNode = id; b.fromPort = outP; b.toNode = c.toNode; b.toPort = c.toPort;
        patch.cables.push_back(b);
    }
    topologyChanged();
}

// ---------------------------------------------------------------- layout helpers

bool AppModel::allCollapsed() const {
    if (patch.nodes.empty()) return false;
    for (auto& n : patch.nodes) if (!n.collapsed) return false;
    return true;
}
void AppModel::toggleCollapseAll() {
    bool target = !allCollapsed();
    for (auto& n : patch.nodes) n.collapsed = target;
    patchChanged(); scheduleAutosave();
}
void AppModel::tidy() {
    isZooming = false;
    if (patch.nodes.empty()) return;
    layoutTarget = TidyLayout::layout(patch, hw);
    layoutStart.clear();
    for (auto& n : patch.nodes) layoutStart[n.id] = { float(n.x), float(n.y) };
    layoutStep = 0;
    setView({ 20, 20 }, viewScale);
}
void AppModel::toggleCollapsed(const juce::String& id) {
    int i = index(id);
    if (i < 0) return;
    patch.nodes[size_t(i)].collapsed = !patch.nodes[size_t(i)].collapsed;
    patchChanged(); scheduleAutosave();
}

// ---------------------------------------------------------------- parameters

float AppModel::value(const PatchNode& n, int i, const ModuleSpec& s) const { return paramOr(n, s.params[size_t(i)].key, s.params[size_t(i)].def); }

void AppModel::setParam(const juce::String& id, int idx, float v, bool linked) {
    int i = index(id);
    if (i < 0) return;
    auto* spec = Registry::spec(patch.nodes[size_t(i)].kind);
    if (!spec || idx >= int(spec->params.size())) return;
    auto& ps = spec->params[size_t(idx)];
    auto key = ps.key;
    auto& pn = patch.nodes[size_t(i)];
    if (!ps.isTrigger() && paramOr(pn, key, ps.def) == v) return;
    if (spec->kind == "chord") {
        int mi = spec->paramIndex("mode");
        float want = key == "type" ? 1.0f : ((key == "degree" || key == "size" || key == "scale") ? 0.0f : -1.0f);
        if (mi >= 0 && want >= 0 && paramOr(pn, "mode", spec->params[size_t(mi)].def) != want) {
            pn.params["mode"] = want;
            if (auto* d = node(id)) d->base[size_t(mi)] = want;
        }
    }
    if (spec->kind == "seq" && key == "len") {
        if (auto* seq = dynamic_cast<SeqNode*>(node(id))) {
            int old = SeqNode::length(paramOr(pn, key, ps.def)), nw = SeqNode::length(v);
            if (nw > old) {
                for (int k = old; k < nw; ++k) { seq->pitches[size_t(k)] = seq->pitches[size_t(k % old)]; seq->gates[size_t(k)] = seq->gates[size_t(k % old)]; }
                pn.data["pitch"] = std::vector<float>(seq->pitches.begin(), seq->pitches.end());
                pn.data["gate"] = std::vector<float>(seq->gates.begin(), seq->gates.end());
            }
        }
    }
    if (key == "div" && patternKinds.count(spec->kind)) rescalePattern(id, *spec, paramOr(pn, key, ps.def), v);
    if (autoRecording.count(id) && !ps.isTrigger()) recordAutomation(id, idx, v, paramOr(patch.nodes[size_t(i)], key, ps.def));
    patch.nodes[size_t(i)].params[key] = v;
    if (auto* d = node(id)) d->base[size_t(idx)] = v;
    followSync(i, id, *spec, key);
    if (spec->kind == "sampler" && key == "sens") { analyzeID = id; analyzeAt = now() + 0.15; }
    if (spec->kind == "peq" && key == "bands") {
        int n = ParametricEQ::bandCount(v);
        auto fs = ParametricEQ::defaultFrequencies(n);
        for (int b = 0; b < n; ++b) {
            int fi = ParametricEQ::freqIndex(b), qi = ParametricEQ::qIndex(b);
            float q = (b == 0 || b == n - 1) ? 0.7f : 1.0f;
            patch.nodes[size_t(i)].params[spec->params[size_t(fi)].key] = fs[size_t(b)];
            patch.nodes[size_t(i)].params[spec->params[size_t(qi)].key] = q;
            if (auto* d = node(id)) { d->base[size_t(fi)] = fs[size_t(b)]; d->base[size_t(qi)] = q; }
        }
    }
    patchChanged();
    scheduleAutosave();
    if (linked) syncLinked(id, idx, v);
}

void AppModel::syncLinked(const juce::String& id, int idx, float v) {
    for (auto& u : ControlLink::updates(patch, id, idx, v)) setParam(u.node, u.index, u.value, false);
}

void AppModel::followSync(int i, const juce::String& id, const ModuleSpec& s, const std::string& key) {
    int si = s.paramIndex("sync");
    if (si < 0 || s.paramIndex("div") < 0) return;
    bool timing = key == "time" || key == "rate";
    bool hasFree = s.paramIndex("time") >= 0 || s.paramIndex("rate") >= 0;
    if (!(key == "div" || (timing && hasFree))) return;
    float want = key == "div" ? 1.0f : 0.0f;
    if (paramOr(patch.nodes[size_t(i)], "sync", s.params[size_t(si)].def) == want) return;
    patch.nodes[size_t(i)].params["sync"] = want;
    if (auto* d = node(id)) d->base[size_t(si)] = want;
}

void AppModel::rescalePattern(const juce::String& id, const ModuleSpec& spec, float from, float to) {
    auto* n = node(id);
    int i = index(id), li = spec.paramIndex("len");
    if (!n || i < 0 || li < 0) return;
    std::string key; int lanes; float* ptr;
    if (auto* r = dynamic_cast<RackNode*>(n)) { key = "hits"; lanes = RackLayout::pads; ptr = r->hits.data(); }
    else if (auto* d = dynamic_cast<DrumSynthNode*>(n)) { key = "hits"; lanes = DrumSynthLayout::voices; ptr = d->hits.data(); }
    else if (auto* dr = dynamic_cast<DrumsNode*>(n)) { key = "hits"; lanes = DrumsNode::lanes; ptr = dr->hits.data(); }
    else if (auto* ro = dynamic_cast<RollNode*>(n)) { key = "grid"; lanes = RollNode::rows; ptr = ro->grid.data(); }
    else return;
    const int steps = 32;
    if (!rescaleBase.count(id)) {
        int len = int(std::round(paramOr(patch.nodes[size_t(i)], "len", spec.params[size_t(li)].def)));
        rescaleBase[id] = { from, std::vector<float>(ptr, ptr + lanes * steps), len, 0 };
    }
    auto& base = rescaleBase[id];
    base.until = now() + 0.8;
    auto r = patternRescale(base.values, lanes, steps, base.len, base.div, to, 0);
    setData(id, key, r.first, false);
    patch.nodes[size_t(i)].params["len"] = float(r.second);
    n->base[size_t(li)] = float(r.second);
}

void AppModel::setText(const juce::String& id, const juce::String& text) {
    int i = index(id);
    if (i < 0) return;
    patch.nodes[size_t(i)].text = text.isEmpty() ? std::nullopt : std::optional<juce::String>(text);
    patchChanged(); scheduleAutosave();
}

void AppModel::setData(const juce::String& id, const std::map<std::string, std::vector<float>>& entries, bool step) {
    int i = index(id);
    if (i < 0) return;
    if (step && !restoringHistory) checkpoint();
    for (auto& [k, v] : entries) {
        patch.nodes[size_t(i)].data[k] = v;
        if (auto* d = node(id)) d->setData(k, v);
    }
    if (step && !restoringHistory) checkpoint();
    patchChanged();
    scheduleAutosave();
}

void AppModel::clearPattern(const juce::String& id) {
    auto* n = nodeFor(id);
    if (!n) return;
    if (n->kind == "rack") setData(id, "hits", std::vector<float>(size_t(RackLayout::pads * RackLayout::steps), 0.0f));
    else if (n->kind == "drumsynth") setData(id, "hits", std::vector<float>(size_t(DrumSynthLayout::voices * DrumSynthLayout::steps), 0.0f));
    else if (n->kind == "drums") setData(id, "hits", std::vector<float>(size_t(DrumsNode::steps * DrumsNode::lanes), 0.0f));
    else if (n->kind == "roll") setData(id, "grid", std::vector<float>(size_t(RollNode::steps * RollNode::rows), 0.0f));
}

bool AppModel::isModulated(const juce::String& id, int param) const {
    for (auto& c : patch.cables) if (c.toNode == id && c.toPort == kParamPortBase + param && !ControlLink::isControl(patch, c.fromNode)) return true;
    return false;
}

bool AppModel::isPortConnected(const juce::String& id, int port, bool output) const {
    for (auto& c : patch.cables) if (output ? (c.fromNode == id && c.fromPort == port) : (c.toNode == id && c.toPort == port)) return true;
    return false;
}

// ---------------------------------------------------------------- automation

bool AppModel::hasAutomation(const PatchNode& n) const {
    for (auto& [k, v] : n.data) if (k.rfind("auto.", 0) == 0) return true;
    return false;
}
bool AppModel::isAutomated(const PatchNode& n, int i, const ModuleSpec& s) const {
    return i < int(s.params.size()) && n.data.count(DSPNode::autoKey(s.params[size_t(i)].key)) > 0;
}
bool AppModel::canAutomate(const ModuleSpec& s) const {
    if (s.kind == "out" || s.kind == "in") return false;
    for (auto& p : s.params) if (!p.isTrigger()) return true;
    return false;
}
void AppModel::startAutoRecord(const juce::String& id) {
    if (autoRecording.count(id) || !node(id)) return;
    autoRecording.insert(id);
    if (auto* k = dynamic_cast<KeysNode*>(node(id))) k->recordingKeys = true;
    autoTouched[id] = {};
    changed();
}
void AppModel::stopAutoRecord(const juce::String& id) {
    if (!autoRecording.count(id)) return;
    autoTick();
    autoRecording.erase(id);
    auto touched = autoTouched[id];
    autoTouched.erase(id);
    auto* n = node(id);
    int i = index(id);
    changed();
    if (!n || i < 0) return;
    if (auto* k = dynamic_cast<KeysNode*>(n)) {
        k->recordingKeys = false;
        if (k->recordedKeys) {
            k->recordedKeys = false;
            patch.nodes[size_t(i)].data[KeysNode::laneKey] = std::vector<float>(k->keyLane.begin(), k->keyLane.end());
            patchChanged(); scheduleAutosave();
        }
    }
    for (auto& [p, last] : touched) {
        juce::ignoreUnused(last);
        const float* lane = n->autoLane.data() + p * DSPNode::autoSlots;
        patch.nodes[size_t(i)].data[DSPNode::autoKey(n->spec.params[size_t(p)].key)] = std::vector<float>(lane, lane + DSPNode::autoSlots);
        n->autoHold[size_t(p)] = 0;
    }
    if (!touched.empty()) { patchChanged(); scheduleAutosave(); }
}
void AppModel::clearAutomation(const juce::String& id) {
    int i = index(id);
    if (i < 0) return;
    if (autoRecording.count(id)) stopAutoRecord(id);
    auto* n = node(id);
    auto* spec = Registry::spec(patch.nodes[size_t(i)].kind);
    if (n && spec)
        for (int k = 0; k < int(spec->params.size()); ++k)
            if (n->autoOn[size_t(k)] && !spec->params[size_t(k)].isTrigger()) {
                float v = n->params[size_t(k)];
                if (std::isfinite(v)) { patch.nodes[size_t(i)].params[spec->params[size_t(k)].key] = v; n->base[size_t(k)] = v; }
            }
    auto& data = patch.nodes[size_t(i)].data;
    for (auto it = data.begin(); it != data.end();) { if (it->first.rfind("auto.", 0) == 0) it = data.erase(it); else ++it; }
    if (n) {
        n->loadAutomation(data);
        for (auto& [key, start] : n->defaultData()) if (key.rfind("auto.", 0) == 0) n->setData(key, start);
    }
    patchChanged(); scheduleAutosave();
}
void AppModel::recordAutomation(const juce::String& id, int idx, float v, float previous) {
    auto* n = node(id);
    if (!n) return;
    int slot = std::min(int(n->autoPosition), DSPNode::autoSlots - 1);
    float* lane = n->autoLane.data() + idx * DSPNode::autoSlots;
    if (!autoTouched[id].count(idx)) {
        if (!n->autoOn[size_t(idx)]) {
            std::fill(lane, lane + DSPNode::autoSlots, previous);
            n->autoOn[size_t(idx)] = 1;
            n->autoCount += 1;
        }
        n->autoHold[size_t(idx)] = 1;
        autoTouched[id][idx] = slot;
    }
    lane[slot] = v;
}
void AppModel::autoTick() {
    for (auto& id : autoRecording) {
        auto* n = node(id);
        if (!n || !autoTouched.count(id)) continue;
        int cur = std::min(int(n->autoPosition), DSPNode::autoSlots - 1);
        for (auto& [p, last] : autoTouched[id]) {
            float* lane = n->autoLane.data() + p * DSPNode::autoSlots;
            float v = n->base[size_t(p)];
            int k = last, guard = 0;
            while (k != cur && guard < DSPNode::autoSlots) { k = (k + 1) % DSPNode::autoSlots; lane[k] = v; ++guard; }
            lane[cur] = v;
            last = cur;
        }
    }
}

// ---------------------------------------------------------------- cables

void AppModel::finishCable(Pt screen) {
    auto pc = pendingCable;
    pendingCable.reset();
    changed();
    if (!pc) return;
    Pt p = toCanvas(screen);
    float radius = 24 / viewScale;
    juce::String bestNode; int bestPort = 0; float bestD = INFINITY;
    auto consider = [&](const juce::String& id, int port, std::optional<Pt> q) {
        if (!q) return;
        float d = q->getDistanceFrom(p);
        if (d < radius && d < bestD) { bestD = d; bestNode = id; bestPort = port; }
    };
    for (auto& n : patch.nodes) {
        if (n.id == pc->node) continue;
        auto* spec = Registry::spec(n.kind);
        if (!spec) continue;
        auto ports = BoxLayout::ports(n, *spec, hw);
        if (n.collapsed) {
            if (pc->fromOutput) for (int k : BoxLayout::collapsedLeft(n, *spec)) consider(n.id, k, BoxLayout::destination(n, *spec, hw, k));
            else for (int k : BoxLayout::collapsedRight(n, *spec)) consider(n.id, k, BoxLayout::outlet(n, *spec, hw, k));
            continue;
        }
        if (pc->fromOutput) {
            for (int k = 0; k < int(ports.ins.size()); ++k) consider(n.id, k, BoxLayout::inlet(n, *spec, hw, k));
            for (int k : BoxLayout::rowParams(*spec, n)) consider(n.id, kParamPortBase + k, BoxLayout::paramInlet(n, *spec, hw, k));
        } else for (int k = 0; k < int(ports.outs.size()); ++k) consider(n.id, k, BoxLayout::outlet(n, *spec, hw, k));
    }
    if (bestNode.isEmpty()) return;
    if (pc->fromOutput) connect(pc->node, pc->port, bestNode, bestPort);
    else connect(bestNode, bestPort, pc->node, pc->port);
}

void AppModel::connect(const juce::String& a, int ap, const juce::String& b, int bp) {
    auto* bn = nodeFor(b);
    if (ControlLink::isControl(patch, a) && bp < kParamPortBase && bp < MixerLayout::maxChannels && bn && bn->kind == "mix")
        if (auto* ms = Registry::spec("mix")) { int level = ms->paramIndex("g" + std::to_string(bp + 1)); if (level >= 0) bp = kParamPortBase + level; }
    for (auto& c : patch.cables) if (c.fromNode == a && c.fromPort == ap && c.toNode == b && c.toPort == bp) return;
    PatchCable c; c.id = Patch::newID(); c.fromNode = a; c.fromPort = ap; c.toNode = b; c.toPort = bp;
    patch.cables.push_back(c);
    if (ControlLink::isControl(patch, a) && bp >= kParamPortBase && bn) {
        if (auto* ts = Registry::spec(bn->kind)) {
            int pi = bp - kParamPortBase;
            if (pi < int(ts->params.size()) && !ts->params[size_t(pi)].isTrigger())
                setParam(a, ControlsLayout::valueIndex(ap), ts->params[size_t(pi)].normalized(value(*bn, pi, *ts)), false);
        }
    }
    topologyChanged();
}

bool AppModel::pickUpCable(const juce::String& nodeID, int port, Pt point) {
    const PatchCable* found = nullptr;
    for (auto& c : patch.cables) if (c.toNode == nodeID && c.toPort == port) found = &c;
    if (!found) return false;
    auto c = *found;
    patch.cables.erase(std::remove_if(patch.cables.begin(), patch.cables.end(), [&](auto& x) { return x.id == c.id; }), patch.cables.end());
    topologyChanged();
    pendingCable = PendingCable { c.fromNode, c.fromPort, true, point };
    return true;
}

// ---------------------------------------------------------------- tempo

static const PatchNode* clockOf(const Patch& p) { for (auto& n : p.nodes) if (n.kind == "clock") return &n; return nullptr; }
bool AppModel::tempoEditable() const { auto* c = clockOf(patch); return !c || paramOr(*c, "source", 0) > 0.5f; }
double AppModel::setTempoValue() const { if (auto* c = clockOf(patch)) return paramOr(*c, "bpm", 120); return patch.tempo.value_or(120); }
void AppModel::setTempo(double bpm) {
    double b = std::clamp(std::isfinite(bpm) ? bpm : 120.0, 20.0, 300.0);
    auto* c = clockOf(patch);
    auto* spec = Registry::spec("clock");
    if (c && spec && spec->paramIndex("bpm") >= 0) setParam(c->id, spec->paramIndex("bpm"), float(b));
    else { patch.tempo = b; host.defaultBPM = b; patchChanged(); scheduleAutosave(); }
}

// ---------------------------------------------------------------- files, undo

std::vector<juce::String> AppModel::audioFileNames(const juce::String& id) const {
    std::vector<juce::String> r { id + ".wav" };
    for (int k = 0; k < RackLayout::pads; ++k) { r.push_back(id + "-pad" + juce::String(k) + ".wav"); r.push_back(id + "-pad" + juce::String(k) + ".txt"); }
    return r;
}

void AppModel::newPatch() {
    auto saved = PatchStore::loadUserDefault();
    if (!saved) { load(PatchStore::builtIn()); return; }
    auto [p, map] = saved->withFreshIDs();
    auto src = PatchStore::defaultAudioFolder(), dst = samplesFolder();
    for (auto& [o, nw] : map)
        for (auto& name : audioFileNames(o)) {
            auto from = src.getChildFile(name);
            if (!from.existsAsFile()) continue;
            auto to = dst.getChildFile(name.replace(o, nw));
            to.deleteFile(); from.copyFileTo(to);
        }
    load(p);
}

void AppModel::setAsDefault() {
    flushBuffersToDisk();
    auto dir = PatchStore::defaultAudioFolder();
    for (auto& f : dir.findChildFiles(juce::File::findFiles, false)) f.deleteFile();
    for (auto& n : patch.nodes)
        for (auto& name : audioFileNames(n.id)) {
            auto from = samplesFolder().getChildFile(name);
            if (from.existsAsFile()) from.copyFileTo(dir.getChildFile(name));
        }
    PatchStore::defaultFile().replaceWithText(patch.toJSON());
    hasUserDefault = true;
    changed();
}

void AppModel::resetDefault() {
    PatchStore::defaultFile().deleteFile();
    PatchStore::defaultAudioFolder().deleteRecursively();
    hasUserDefault = false;
    changed();
}

void AppModel::load(const Patch& p) {
    patch = p;
    selectedNodes.clear(); selectedCable = {};
    topologyChanged();
}

bool AppModel::openFile(const juce::File& f) {
    auto p = Patch::fromJSON(f.loadFileAsString());
    if (!p) { audioError = "Couldn't read that patch file."; changed(); return false; }
    load(p->migrated());
    return true;
}

bool AppModel::saveFile(const juce::File& f) { return f.replaceWithText(patch.toJSON()); }

void AppModel::scheduleAutosave() { autosaveAt = now() + 1; }

void AppModel::checkpoint() { checkpointAt = 0; history.commit(patch); }

namespace BackgroundPicture {
static juce::File file() { return PatchStore::folder().getChildFile("background-picture"); }
static juce::Image cached; static bool loaded = false;
const juce::Image& image() {
    if (!loaded) { loaded = true; cached = file().existsAsFile() ? juce::ImageFileFormat::loadFrom(file()) : juce::Image(); }
    return cached;
}
bool set(const juce::File& f) {
    if (!juce::ImageFileFormat::loadFrom(f).isValid()) return false;
    if (!f.copyFileTo(file())) return false;
    loaded = false; CustomColours::version++;
    return true;
}
void remove() { file().deleteFile(); loaded = false; CustomColours::version++; }
}

const std::vector<juce::String> AppModel::highlightColours { "#5aa9ff", "#ff5f5f", "#ffc030", "#b77be8" };
void AppModel::setHighlight(const juce::String& id, std::optional<juce::String> hex) {
    int i = patch.index(id);
    if (i < 0 || patch.nodes[size_t(i)].highlight == hex) return;
    checkpoint();
    patch.nodes[size_t(i)].highlight = hex;
    checkpoint();
    scheduleAutosave();
    changed();
}

void AppModel::undo() { checkpoint(); if (auto p = history.undo()) restore(*p); }
void AppModel::redo() { checkpoint(); if (auto p = history.redo()) restore(*p); }

void AppModel::restore(const Patch& p) {
    restoringHistory = true;
    patch = p;
    std::set<juce::String> keep;
    for (auto& id : selectedNodes) if (p.index(id) >= 0) keep.insert(id);
    selectedNodes = keep; selectedCable = {}; pendingCable.reset();
    topologyChanged();
    history.reset(patch, true);
    restoringHistory = false;
}

void AppModel::followClockInputs() {
    std::map<juce::String, bool> seen;
    for (auto& n : patch.nodes) {
        if (n.kind != "clock") continue;
        bool patched = false;
        for (auto& c : patch.cables) if (c.toNode == n.id && c.toPort == 0) patched = true;
        auto it = clockInletPatched.find(n.id);
        if (!restoringHistory && it != clockInletPatched.end() && it->second != patched) n.params["source"] = patched ? 0.0f : 1.0f;
        seen[n.id] = patched;
    }
    clockInletPatched = seen;
}

void AppModel::topologyChanged() {
    followClockInputs();
    patch = ControlLink::reconciled(patch);
    host.load(patch);
    restoreBuffers();
    scheduleAutosave();
    patchChanged();
}

// ---------------------------------------------------------------- buffers

juce::File AppModel::samplesFolder() { auto d = PatchStore::folder().getChildFile("Samples"); d.createDirectory(); return d; }
juce::File AppModel::sampleFile(const juce::String& id) const { return samplesFolder().getChildFile(id + ".wav"); }
juce::File AppModel::padFile(const juce::String& id, int k) const { return samplesFolder().getChildFile(id + "-pad" + juce::String(k) + ".wav"); }
juce::File AppModel::padNameFile(const juce::String& id, int k) const { return samplesFolder().getChildFile(id + "-pad" + juce::String(k) + ".txt"); }

void AppModel::restoreBuffers() {
    restoreRacks();
    for (auto& n : patch.nodes) {
        auto* dsp = node(n.id);
        auto* b = dynamic_cast<SampleBufferNode*>(dsp);
        if (!b || seenVersion.count(dsp)) continue;
        seenVersion[dsp] = b->contentVersion();
        auto f = sampleFile(n.id);
        if (!f.existsAsFile()) continue;
        auto audio = AudioFiles::read(f, host.sampleRate, 120);
        if (audio.empty()) continue;
        b->load(audio);
        samplerAnalyze(dsp);
        seenVersion[dsp] = b->contentVersion();
    }
}

void AppModel::flushBuffersToDisk() {
    for (auto& n : patch.nodes) {
        auto* dsp = node(n.id);
        auto* b = dynamic_cast<SampleBufferNode*>(dsp);
        if (!b || b->waveRecording()) continue;
        auto audio = b->snapshot();
        if (audio.empty()) sampleFile(n.id).deleteFile(); else AudioFiles::write(audio, host.sampleRate, sampleFile(n.id));
        seenVersion[dsp] = b->contentVersion();
    }
}

void AppModel::watchBuffers() {
    double sr = host.sampleRate;
    for (auto& n : patch.nodes) {
        auto* dsp = node(n.id);
        auto* b = dynamic_cast<SampleBufferNode*>(dsp);
        if (!b || b->waveRecording()) continue;
        auto it = seenVersion.find(dsp);
        if (it != seenVersion.end() && it->second == b->contentVersion()) continue;
        seenVersion[dsp] = b->contentVersion();
        samplerAnalyze(dsp);
        auto audio = b->snapshot();
        auto f = sampleFile(n.id);
        background.addJob([audio, f, sr] { if (audio.empty()) f.deleteFile(); else AudioFiles::write(audio, sr, f); });
        changed();
    }
}

bool AppModel::loadAudio(const juce::File& f, const juce::String& id) {
    auto* b = dynamic_cast<SampleBufferNode*>(node(id));
    if (!b) return false;
    auto audio = AudioFiles::read(f, host.sampleRate, double(b->bufferCapacity()) / host.sampleRate);
    if (audio.empty()) { audioError = "Couldn't read " + f.getFileName() + " (or it has no audio)."; changed(); return false; }
    b->load(audio);
    audioError = {};
    changed();
    return true;
}

void AppModel::loadIntoSelection(const juce::File& f) {
    for (auto& id : selectedNodes)
        if (dynamic_cast<RackNode*>(node(id))) {
            auto* n = nodeFor(id);
            loadPads(id, int(std::round(paramOr(*n, "sel", 0))), { f });
            return;
        }
    for (auto& id : selectedNodes) if (dynamic_cast<SampleBufferNode*>(node(id))) { loadAudio(f, id); return; }
    audioError = juce::String::fromUTF8("Select a looper, sampler, stretch or rack first \xe2\x80\x94 or drag the file onto one (or onto a rack pad).");
    changed();
}

bool AppModel::loadPads(const juce::String& id, int k, const juce::Array<juce::File>& files) {
    if (!dynamic_cast<RackNode*>(node(id)) || files.isEmpty() || k < 0 || k >= RackLayout::pads) return false;
    double sr = host.sampleRate;
    juce::Component::SafePointer<juce::Component> none;
    for (int j = 0; j < std::min(files.size(), RackLayout::pads - k); ++j) {
        int pad = k + j;
        auto f = files[j];
        auto pf = padFile(id, pad), nf = padNameFile(id, pad);
        loadingPads[id].insert(pad);
        background.addJob([this, id, pad, f, pf, nf, sr, j] {
            auto audio = AudioFiles::read(f, sr, 20);
            auto name = f.getFileNameWithoutExtension();
            if (!audio.empty()) { AudioFiles::write(audio, sr, pf); nf.replaceWithText(name); }
            juce::MessageManager::callAsync([this, id, pad, audio, name, f, j] {
                loadingPads[id].erase(pad);
                if (!audio.empty()) {
                    if (auto* r = dynamic_cast<RackNode*>(node(id))) r->loadPad(pad, audio, name.toStdString());
                    audioError = {};
                    if (j == 0) if (auto* s = Registry::spec("rack")) setParam(id, s->paramIndex("sel"), float(pad));
                } else audioError = "Couldn't read " + f.getFileName() + ".";
                changed();
            });
        });
    }
    changed();
    return true;
}

void AppModel::resetPad(const juce::String& id, int k) {
    auto* r = dynamic_cast<RackNode*>(node(id));
    if (!r) return;
    r->resetPad(k);
    padFile(id, k).deleteFile(); padNameFile(id, k).deleteFile();
    changed();
}

void AppModel::restoreRacks() {
    for (auto& n : patch.nodes) {
        if (n.kind != "rack") continue;
        auto* r = dynamic_cast<RackNode*>(node(n.id));
        if (!r || restoredRacks.count(r)) continue;
        restoredRacks.insert(r);
        for (int k = 0; k < RackLayout::pads; ++k) {
            auto f = padFile(n.id, k);
            if (!f.existsAsFile()) continue;
            auto audio = AudioFiles::read(f, host.sampleRate, 20);
            if (audio.empty()) continue;
            auto nf = padNameFile(n.id, k);
            r->loadPad(k, audio, nf.existsAsFile() ? nf.loadFileAsString().toStdString() : "sample");
        }
    }
}

void AppModel::copyRackPads(const juce::String& a, const juce::String& b) {
    auto* rb = dynamic_cast<RackNode*>(node(b));
    if (!dynamic_cast<RackNode*>(node(a)) || !rb) return;
    for (int k = 0; k < RackLayout::pads; ++k) {
        auto src = padFile(a, k);
        if (!src.existsAsFile()) continue;
        src.copyFileTo(padFile(b, k));
        padNameFile(a, k).copyFileTo(padNameFile(b, k));
        auto audio = AudioFiles::read(src, host.sampleRate, 20);
        if (!audio.empty()) rb->loadPad(k, audio, padNameFile(a, k).existsAsFile() ? padNameFile(a, k).loadFileAsString().toStdString() : "sample");
    }
}

void AppModel::copyBuffer(const juce::String& src, const juce::String& dst) {
    auto* a = dynamic_cast<SampleBufferNode*>(node(src)); auto* b = dynamic_cast<SampleBufferNode*>(node(dst));
    if (!a || !b) return;
    auto audio = a->snapshot();
    if (audio.empty()) { audioError = "That module has no audio yet."; changed(); return; }
    int n = std::min(audio.count(), b->bufferCapacity());
    audio.left.resize(size_t(n)); audio.right.resize(size_t(n));
    b->load(audio);
}

juce::String AppModel::label(const PatchNode& n) const {
    auto* s = Registry::spec(n.kind);
    juce::String name = s ? juce::String::fromUTF8(s->name.c_str()) : juce::String(n.kind);
    int count = 0, mine = 0;
    for (auto& m : patch.nodes) if (m.kind == n.kind) { ++count; if (m.id == n.id) mine = count; }
    return count > 1 ? name + " " + juce::String(mine) : name;
}

void AppModel::audition(const juce::String& id, double x) { samplerAudition(node(id), samplerSliceAt(node(id), x)); }

void AppModel::addFolder(const juce::File& f) {
    for (auto& b : browserFolders) if (b == f) return;
    browserFolders.push_back(f);
    juce::StringArray a; for (auto& b : browserFolders) a.add(b.getFullPathName());
    settings().setValue("browserFolders", a.joinIntoString("\n"));
    changed();
}
void AppModel::removeFolder(const juce::File& f) {
    browserFolders.erase(std::remove(browserFolders.begin(), browserFolders.end(), f), browserFolders.end());
    juce::StringArray a; for (auto& b : browserFolders) a.add(b.getFullPathName());
    settings().setValue("browserFolders", a.joinIntoString("\n"));
    changed();
}

void AppModel::hoverHelp(const HelpTopic& t, bool inside) {
    helpTopics.erase(std::remove(helpTopics.begin(), helpTopics.end(), t), helpTopics.end());
    if (inside) helpTopics.push_back(t);
    changed();
}

void AppModel::setLight(bool l) {
    lightScheme = Theme::light = l;
    CustomColours::schemeChanged();
    settings().setValue("lightScheme", l);
    changed();
}

// ---------------------------------------------------------------- audio

// All the device work happens on its own thread: opening an audio device can stall for seconds (an interface
// being plugged in or out, a busy driver), and the window must keep working meanwhile.
void AppModel::refreshDevices() {
    audioJobs.addJob([this] {
        std::vector<DeviceChoice> ins { { "none", "off" }, { "", "automatic (disting NT if connected)" } };
        std::vector<DeviceChoice> outs { { "off", "off (patch keeps running, silent)" }, { "", "default" } };
        if (devices.getAvailableDeviceTypes().isEmpty()) return;
        if (auto* type = devices.getCurrentDeviceTypeObject()) {
            type->scanForDevices();
            for (auto& n : type->getDeviceNames(true)) ins.push_back({ n, n });
            for (auto& n : type->getDeviceNames(false)) outs.push_back({ n, n });
        }
        juce::MessageManager::callAsync([this, ins, outs] { inputChoices = ins; outputChoices = outs; changed(); });
    });
}

void AppModel::selectInput(const juce::String& uid) { inputUID = uid; settings().setValue("inputUID", uid); restartAudio(); }
void AppModel::selectOutput(const juce::String& uid) { outputUID = uid; settings().setValue("outputUID", uid); restartAudio(); }

void AppModel::startAudio() {
    refreshDevices();
    restartAudio();
}

void AppModel::stopAudio() {
    wantsAudio = false;
    isRunning = false;
    audioStatus = "audio off";
    changed();
    audioJobs.addJob([this] {
        devices.closeAudioDevice();
        juce::MessageManager::callAsync([this] { host.clearReadouts(); changed(); });
    });
}

void AppModel::restartAudio() {
    wantsAudio = true;
    isRunning = false;
    audioStatus = juce::String::fromUTF8("starting audio\xe2\x80\xa6");
    changed();
    muteOut = outputUID == "off";
    auto inUID = inputUID, outUID = outputUID;
    int job = ++audioJob;
    double started = juce::Time::getMillisecondCounterHiRes();
    juce::Timer::callAfterDelay(2000, [this, job] {
        if (audioJob.load() == job && !isRunning && wantsAudio && audioError.isEmpty()) {
            audioStatus = juce::String::fromUTF8("waiting for the system audio\xe2\x80\xa6");
            changed();
        }
    });
    juce::ignoreUnused(started);
    audioJobs.addJob([this, inUID, outUID, job] {
        if (audioJob.load() != job) return;          // a newer request replaced this one
        juce::String err;
        if (devices.getAvailableDeviceTypes().isEmpty() || !devices.getCurrentDeviceTypeObject()) {
            if (devices.getAvailableDeviceTypes().size() > 0) devices.setCurrentAudioDeviceType(devices.getAvailableDeviceTypes()[0]->getTypeName(), true);
        }
        auto* type = devices.getCurrentDeviceTypeObject();
        if (!type) {
            juce::MessageManager::callAsync([this] { audioStatus = "audio off"; audioError = "No audio devices."; changed(); });
            return;
        }
        type->scanForDevices();
        auto ins = type->getDeviceNames(true), outs = type->getDeviceNames(false);
        juce::String in;
        if (inUID == "none") in = {};
        else if (inUID.isEmpty()) {
            for (auto& n : ins) if (n.containsIgnoreCase("disting")) in = n;
            if (in.isEmpty() && !ins.isEmpty()) in = ins[std::max(0, type->getDefaultDeviceIndex(true))];
        } else in = ins.contains(inUID) ? inUID : (ins.isEmpty() ? juce::String() : ins[std::max(0, type->getDefaultDeviceIndex(true))]);
        juce::String out = (outUID.isEmpty() || outUID == "off" || !outs.contains(outUID))
                             ? (outs.isEmpty() ? juce::String() : outs[std::max(0, type->getDefaultDeviceIndex(false))]) : outUID;
        juce::AudioDeviceManager::AudioDeviceSetup setup = devices.getAudioDeviceSetup();
        setup.inputDeviceName = in;
        setup.outputDeviceName = out;
        setup.useDefaultInputChannels = false; setup.useDefaultOutputChannels = false;
        setup.inputChannels.clear(); setup.outputChannels.clear();
        setup.inputChannels.setRange(0, in.isEmpty() ? 0 : kMaxHardwareChannels, true);
        setup.outputChannels.setRange(0, kMaxHardwareChannels, true);
        err = devices.setAudioDeviceSetup(setup, true);
        auto* dev = devices.getCurrentAudioDevice();
        if (err.isNotEmpty() || !dev) {
            if (err.isEmpty()) err = "Couldn't start audio.";
            juce::MessageManager::callAsync([this, err] { isRunning = false; audioStatus = "audio off"; audioError = err; changed(); });
            return;
        }
        HardwareCounts counts { std::max(dev->getActiveInputChannels().countNumberOfSetBits(), in.isEmpty() ? 0 : 1),
                                std::max(dev->getActiveOutputChannels().countNumberOfSetBits(), 1) };
        double sr = dev->getCurrentSampleRate();
        int buf = dev->getCurrentBufferSizeSamples();
        double lat = double(dev->getOutputLatencyInSamples() + dev->getInputLatencyInSamples() + buf) / sr * 1000;
        juce::MessageManager::callAsync([this, counts, sr, buf, lat, in, out] {
            isRunning = true;
            audioError = {};
            inputName = in.isEmpty() ? juce::String("off") : in;
            outputName = out;
            if (!(counts == hw)) { hw = counts; settings().setValue("hwInputs", hw.inputs); settings().setValue("hwOutputs", hw.outputs); topologyChanged(); }
            juce::String khz = std::fmod(sr / 1000, 1.0) == 0 ? juce::String(int(sr / 1000)) : juce::String(sr / 1000, 1);
            audioStatus = khz + juce::String::fromUTF8("k \xc2\xb7 ") + juce::String(buf) + juce::String::fromUTF8(" \xc2\xb7 ") + juce::String(lat, 1) + "ms";
            changed();
        });
    });
    refreshDevices();
}

void AppModel::audioDeviceAboutToStart(juce::AudioIODevice* d) {
    double sr = d->getCurrentSampleRate();
    if (sr != host.sampleRate) {
        // the nodes are rebuilt for the new rate on the message thread; the audio waits (silent) until then
        juce::WaitableEvent done;
        juce::MessageManager::callAsync([this, sr, &done] { host.setSampleRate(sr); done.signal(); });
        done.wait(3000);
        juce::MessageManager::callAsync([this] { seenVersion.clear(); restoredRacks.clear(); restoreBuffers(); changed(); });
    }
}

void AppModel::audioDeviceIOCallbackWithContext(const float* const* in, int numIn, float* const* out, int numOut, int n,
                                                const juce::AudioIODeviceCallbackContext&) {
    auto t0 = juce::Time::getHighResolutionTicks();
    for (int c = 0; c < numOut; ++c) if (out[c]) std::fill(out[c], out[c] + n, 0.0f);
    static thread_local std::vector<float> silence;
    if (int(silence.size()) < n) silence.assign(size_t(std::max(n, 8192)), 0.0f);
    const float* ins[64]; float* outs[64];
    int ni = std::min(numIn, 64), no = std::min(numOut, 64);
    for (int c = 0; c < ni; ++c) ins[c] = in[c] ? in[c] : silence.data();
    for (int c = 0; c < no; ++c) outs[c] = out[c];
    host.process(n, ins, ni, outs, no);
    if (muteOut.load()) for (int c = 0; c < numOut; ++c) if (out[c]) std::fill(out[c], out[c] + n, 0.0f);
    double secs = juce::Time::highResolutionTicksToSeconds(juce::Time::getHighResolutionTicks() - t0);
    float l = float(secs / (double(n) / host.sampleRate));
    load_.store(load_.load() * 0.9f + l * 0.1f);
}

} // namespace pn
