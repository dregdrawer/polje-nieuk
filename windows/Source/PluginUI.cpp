// plugin box (PluginSupport.swift): picking a plugin, mapping its knobs, its editor window, its state in the patch.
#include "Displays.h"
#include "ModulesPlugin.h"

namespace pn {

// ---------------------------------------------------------------- the model's side

const std::vector<PluginInfo>& AppModel::plugins(bool rescan) {
    static std::vector<PluginInfo> cache;
    static bool scanned = false;
    if (rescan || !scanned) { cache = PluginCatalog::scan(); scanned = true; }
    return cache;
}

PluginNode* AppModel::pluginNode(const juce::String& id) { return dynamic_cast<PluginNode*>(node(id)); }

void AppModel::choosePlugin(const juce::String& id, const PluginInfo* info) {
    int i = patch.index(id);
    if (i < 0) return;
    closePluginEditor(id);
    checkpoint();
    auto& n = patch.nodes[size_t(i)];
    auto pid = info ? PluginCatalog::codes(info->id) : std::vector<float> {};
    n.data["plugin"] = pid;
    n.data["pname"] = info ? PluginCatalog::codes(info->name) : std::vector<float> {};
    n.data["state"] = {};
    n.data["map"] = { 0, 1, 2, 3 };
    if (auto* d = pluginNode(id)) {
        d->setData("state", {});
        d->setData("map", n.data["map"]);
        d->setData("pname", n.data["pname"]);
        d->setData("plugin", pid);
    }
    checkpoint(); scheduleAutosave(); changed();
}

void AppModel::mapPluginKnob(const juce::String& id, int k, int param) {
    int i = patch.index(id);
    auto* d = pluginNode(id);
    auto* spec = Registry::spec("plugin");
    if (i < 0 || !d || !spec) return;
    checkpoint();
    auto& n = patch.nodes[size_t(i)];
    auto m = n.data.count("map") ? n.data["map"] : std::vector<float> { 0, 1, 2, 3 };
    while (int(m.size()) < PluginLayout::macros) m.push_back(-1);
    m[size_t(k)] = float(param);
    n.data["map"] = m;
    if (auto v = d->knobValue(param)) {
        int pi = PluginLayout::firstMacro + k;
        n.params[spec->params[size_t(pi)].key] = *v;
        d->base[size_t(pi)] = *v;
    }
    d->setData("map", m);
    checkpoint(); scheduleAutosave(); changed();
}

void AppModel::storePluginState(const juce::String& id) {
    int i = patch.index(id);
    auto* d = pluginNode(id);
    if (i < 0 || !d) return;
    if (auto s = d->captureState()) patch.nodes[size_t(i)].data["state"] = *s;
}

Patch AppModel::withPluginStates(Patch p) {
    for (auto& n : p.nodes)
        if (n.kind == "plugin")
            if (auto* d = pluginNode(n.id))
                if (auto s = d->captureState()) n.data["state"] = *s;
    return p;
}

// the editor: a window of its own, on top
namespace {
class EditorWindow : public juce::DocumentWindow {
public:
    EditorWindow(AppModel& m, juce::String nodeId, juce::AudioPluginInstance& p)
        : juce::DocumentWindow(p.getName(), juce::Colours::black, juce::DocumentWindow::closeButton | juce::DocumentWindow::minimiseButton),
          model(m), id(std::move(nodeId)), plugin(&p) {
        setUsingNativeTitleBar(true);
        if (auto* e = p.createEditorIfNeeded()) setContentOwned(e, true);
        setResizable(false, false);
        setAlwaysOnTop(true);
        centreWithSize(getWidth(), getHeight());
        setVisible(true);
    }
    void closeButtonPressed() override { model.closePluginEditor(id); }
    AppModel& model;
    juce::String id;
    juce::AudioPluginInstance* plugin;
};
std::map<juce::String, std::unique_ptr<EditorWindow>>& editors() {
    static std::map<juce::String, std::unique_ptr<EditorWindow>> e;
    return e;
}
}

void AppModel::openPluginEditor(const juce::String& id) {
    auto* d = pluginNode(id);
    if (!d || !d->plugin()) return;
    auto& e = editors();
    if (auto it = e.find(id); it != e.end()) {
        if (it->second->plugin == d->plugin()) { it->second->toFront(true); return; }
        e.erase(it);
    }
    if (!d->plugin()->hasEditor()) { audioError = d->plugin()->getName() + " has no editor."; changed(); return; }
    e[id] = std::make_unique<EditorWindow>(*this, id, *d->plugin());
}

void AppModel::closePluginEditor(const juce::String& id) {
    auto& e = editors();
    auto it = e.find(id);
    if (it == e.end()) return;
    auto* d = pluginNode(id);
    if (d && d->plugin() == it->second->plugin) {
        it->second->clearContentComponent();      // the editor goes before its plugin can
        storePluginState(id);
        scheduleAutosave();
    }
    e.erase(it);
}

void AppModel::closeStalePluginEditors() {
    auto& e = editors();
    for (auto it = e.begin(); it != e.end();) {
        auto* d = pluginNode(it->first);
        if (!d || d->plugin() != it->second->plugin) { it->second->clearContentComponent(); it = e.erase(it); }
        else ++it;
    }
}

// ---------------------------------------------------------------- the display

class PluginDisplay : public NativeDisplay {
public:
    using NativeDisplay::NativeDisplay;
    Rect nameRect(Rect r) const { return Rect(r.getX(), r.getY() + 4, r.getWidth() - 44, 20); }
    Rect editRect(Rect r) const { return Rect(r.getRight() - 40, r.getY() + 4, 40, 20); }
    Rect knobRect(int k, Rect r) const { return Rect(r.getX(), r.getY() + 42 + float(k) * 15, r.getWidth(), 14); }
    PluginNode* pn() { return dynamic_cast<PluginNode*>(dsp()); }

    std::vector<LivePart> parts(Rect r) override {
        return { part("plugin", r, [this] {
            auto* n = pn();
            return n ? int64_t(n->generation) * 4 + (n->plugin() ? 0 : 2) : int64_t(0);
        }, [this, r](GC& g, Pt) {
            auto at = [r](Rect q) { return q.translated(-r.getX(), -r.getY()); };
            auto* n = pn();
            auto* p = n ? n->plugin() : nullptr;
            auto nr = at(nameRect(r)), er = at(editRect(r));
            auto saved = PluginCatalog::text(node.data.count("pname") ? node.data.at("pname") : std::vector<float> {});
            g.fill(nr, Theme::row());
            juce::String title = p ? p->getName() : (saved.isEmpty() ? juce::String::fromUTF8("choose a plugin\xe2\x80\xa6") : saved);
            g.textLeft(fitText(title + juce::String::fromUTF8("  \xe2\x96\xbe"), 11, nr.getWidth() - 12), { nr.getX() + 6, nr.getCentreY() }, 11,
                       p == nullptr && saved.isEmpty() ? Theme::dim() : Theme::text(), p != nullptr);
            g.fill(er, p ? Theme::row() : Theme::row().withMultipliedAlpha(0.5f));
            g.text("edit", { er.getCentreX(), er.getCentreY() }, 9, p ? Theme::text() : Theme::faint());
            juce::String line;
            if (n && n->status.isNotEmpty()) line = n->status;
            else if (p) line = juce::String("VST3 ") + juce::String::fromUTF8("\xc2\xb7 ") + (p->acceptsMidi() ? "instrument" : "effect");
            else if (saved.isNotEmpty()) line = "not installed here";
            else line = "VST3 effects and instruments";
            g.textLeft(fitText(line, 8, r.getWidth() - 4), { nr.getX() + 2, nr.getBottom() + 8 }, 8, Theme::faint());
            for (int k = 0; k < PluginLayout::macros; ++k) {
                auto kr = at(knobRect(k, r));
                int i = n ? n->map[size_t(k)].load() : -1;
                juce::String pname = i < 0 ? juce::String::fromUTF8("\xe2\x80\x94") : "parameter " + juce::String(i + 1);
                if (n && i >= 0 && i < int(n->automatable.size())) {
                    auto nm = n->automatable[size_t(i)]->getName(64);
                    if (nm.isNotEmpty()) pname = nm;
                }
                g.fill(kr, Theme::row().withMultipliedAlpha(0.6f));
                g.textLeft("knob " + juce::String(k + 1), { kr.getX() + 5, kr.getCentreY() }, 8, Theme::dim());
                g.textLeft(fitText(pname, 9, kr.getWidth() - 60), { kr.getX() + 50, kr.getCentreY() }, 9, Theme::text());
            }
        }) };
    }

    void showPlugins() {
        auto* m = &model; auto nid = id;
        auto* n = pn();
        juce::PopupMenu menu;
        if (n && n->plugin()) {
            menu.addSectionHeader(n->plugin()->getName());
            menu.addItem("Open editor", [m, nid] { m->openPluginEditor(nid); });
            menu.addItem("Remove plugin", [m, nid] { m->choosePlugin(nid, nullptr); });
            menu.addSeparator();
        }
        auto cur = n ? n->pluginID : juce::String();
        auto& all = m->plugins();
        // by company (the folder the plugin sits in); loose ones at the end
        std::map<juce::String, juce::PopupMenu> groups;
        juce::PopupMenu loose;
        for (auto& p : all) {
            auto info = p;
            auto item = [m, nid, info] { m->choosePlugin(nid, &info); };
            if (p.vendor.isEmpty()) loose.addItem(p.name, true, p.id == cur, item);
            else groups[p.vendor].addItem(p.name, true, p.id == cur, item);
        }
        for (auto& [v, sub] : groups) menu.addSubMenu(v, sub);
        if (loose.getNumItems() > 0) { if (!groups.empty()) menu.addSeparator(); for (juce::PopupMenu::MenuItemIterator it(loose); it.next();) menu.addItem(it.getItem()); }
        if (all.empty()) menu.addItem("no VST3 plugins found", false, false, [] {});
        menu.addSeparator();
        menu.addItem("Rescan plugins", [m] { m->plugins(true); });
        menu.showMenuAsync(juce::PopupMenu::Options().withMousePosition());
    }

    void showKnob(int k) {
        auto* n = pn();
        juce::PopupMenu menu;
        if (!n || !n->plugin()) { menu.addItem("no plugin loaded", false, false, [] {}); menu.showMenuAsync(juce::PopupMenu::Options().withMousePosition()); return; }
        auto* m = &model; auto nid = id;
        int cur = n->map[size_t(k)];
        menu.addSectionHeader("knob " + juce::String(k + 1) + " moves");
        menu.addItem("nothing", true, cur < 0, [m, nid, k] { m->mapPluginKnob(nid, k, -1); });
        int count = std::min(int(n->automatable.size()), 1024);
        auto row = [&](juce::PopupMenu& into, int i) {
            auto nm = n->automatable[size_t(i)]->getName(64);
            into.addItem(nm.isEmpty() ? "parameter " + juce::String(i + 1) : nm, true, i == cur, [m, nid, k, i] { m->mapPluginKnob(nid, k, i); });
        };
        if (count <= 40) for (int i = 0; i < count; ++i) row(menu, i);
        else for (int s = 0; s < count; s += 40) {
            juce::PopupMenu sub;
            int e = std::min(s + 40, count);
            for (int i = s; i < e; ++i) row(sub, i);
            menu.addSubMenu(juce::String(s + 1) + juce::String::fromUTF8("\xe2\x80\x93") + juce::String(e) + "  " + n->automatable[size_t(s)]->getName(32) + juce::String::fromUTF8("\xe2\x80\xa6"), sub);
        }
        menu.showMenuAsync(juce::PopupMenu::Options().withMousePosition());
    }

    bool press(Pt pt, Rect r, const PointerInfo&) override {
        if (nameRect(r).contains(pt) || editRect(r).contains(pt)) return true;
        for (int k = 0; k < PluginLayout::macros; ++k) if (knobRect(k, r).contains(pt)) return true;
        return false;
    }
    void release(Pt pt, Rect r, const PointerInfo& info) override {
        if (info.moved) return;
        if (nameRect(r).contains(pt)) { showPlugins(); return; }
        if (editRect(r).contains(pt)) { model.openPluginEditor(id); return; }
        for (int k = 0; k < PluginLayout::macros; ++k) if (knobRect(k, r).contains(pt)) { showKnob(k); return; }
    }
};

std::unique_ptr<NativeDisplay> makePluginDisplay(AppModel& m, const PatchNode& n, const ModuleSpec& s) {
    return std::make_unique<PluginDisplay>(m, n, s);
}

} // namespace pn
