#include "Window.h"

namespace pn {

static juce::String u8(const char* s) { return juce::String::fromUTF8(s); }
static juce::String nameOf(const std::string& s) { return juce::String::fromUTF8(s.c_str()); }

// ---------------------------------------------------------------- drawn top-bar icons (SF Symbols on the Mac)

namespace BarIcons {
static void stroke(juce::Graphics& g, const juce::Path& p, juce::Colour c, float w = 1.3f) {
    g.setColour(c);
    g.strokePath(p, juce::PathStrokeType(w, juce::PathStrokeType::curved, juce::PathStrokeType::rounded));
}
static void undo(juce::Graphics& g, Pt c, juce::Colour col, bool redo) {
    float d = redo ? -1.0f : 1.0f;
    juce::Path p;
    p.startNewSubPath(c.x + 5 * d, c.y + 4);
    p.cubicTo(c.x + 5 * d, c.y - 3, c.x - 1 * d, c.y - 3, c.x - 5 * d, c.y - 3);
    p.startNewSubPath(c.x - 2 * d, c.y - 6); p.lineTo(c.x - 5 * d, c.y - 3); p.lineTo(c.x - 2 * d, c.y);
    stroke(g, p, col);
}
static void sun(juce::Graphics& g, Pt c, juce::Colour col) {
    juce::Path p; p.addEllipse(c.x - 3, c.y - 3, 6, 6);
    for (int k = 0; k < 8; ++k) {
        float a = float(k) * juce::MathConstants<float>::pi / 4;
        p.startNewSubPath(c.x + std::cos(a) * 5, c.y + std::sin(a) * 5); p.lineTo(c.x + std::cos(a) * 7, c.y + std::sin(a) * 7);
    }
    stroke(g, p, col, 1.2f);
}
static void moon(juce::Graphics& g, Pt c, juce::Colour col) {
    // a crescent: the part of a circle not covered by a second one up and to the right
    const float R = 6, r = 5.2f; const Pt o { c.x + 3.4f, c.y - 2.6f };
    juce::Path p; bool started = false;
    for (int k = 0; k <= 96; ++k) {
        float a = float(k) / 96 * juce::MathConstants<float>::twoPi;
        Pt q { c.x + R * std::cos(a), c.y + R * std::sin(a) };
        if (q.getDistanceFrom(o) < r) continue;
        if (!started) { p.startNewSubPath(q); started = true; } else p.lineTo(q);
    }
    std::vector<Pt> inner;
    for (int k = 0; k <= 96; ++k) {
        float a = float(k) / 96 * juce::MathConstants<float>::twoPi;
        Pt q { o.x + r * std::cos(a), o.y + r * std::sin(a) };
        if (q.getDistanceFrom(c) <= R) inner.push_back(q);
    }
    // join the inner arc so the outline closes the short way round
    if (!inner.empty() && started) {
        auto end = p.getCurrentPosition();
        if (inner.front().getDistanceFrom(end) > inner.back().getDistanceFrom(end)) std::reverse(inner.begin(), inner.end());
        for (auto& q : inner) p.lineTo(q);
        p.closeSubPath();
    }
    stroke(g, p, col, 1.2f);
}
static void question(juce::Graphics& g, Pt c, juce::Colour col, bool filled) {
    g.setColour(col);
    if (filled) g.fillEllipse(c.x - 7, c.y - 7, 14, 14); else g.drawEllipse(c.x - 6.5f, c.y - 6.5f, 13, 13, 1.2f);
    GC gc(g); gc.text("?", c, 10, filled ? Theme::inverse() : col, true);
}
static void plus(juce::Graphics& g, Pt c, juce::Colour col) {
    juce::Path p; p.startNewSubPath(c.x - 6, c.y); p.lineTo(c.x + 6, c.y); p.startNewSubPath(c.x, c.y - 6); p.lineTo(c.x, c.y + 6);
    stroke(g, p, col, 1.4f);
}
static void dashedRect(juce::Graphics& g, Pt c, juce::Colour col, bool dot) {
    juce::Path r; r.addRoundedRectangle(c.x - 7, c.y - 5, 14, 10, 1.5f);
    juce::Path d; float dash[] = { 2.2f, 1.8f };
    juce::PathStrokeType(1.2f).createDashedStroke(d, r, dash, 2);
    g.setColour(col); g.fillPath(d);
    if (dot) g.fillEllipse(c.x + 3, c.y + 2, 6, 6);
}
static void trash(juce::Graphics& g, Pt c, juce::Colour col) {
    juce::Path p;
    p.startNewSubPath(c.x - 6, c.y - 4); p.lineTo(c.x + 6, c.y - 4);
    p.startNewSubPath(c.x - 2, c.y - 6); p.lineTo(c.x + 2, c.y - 6);
    p.startNewSubPath(c.x - 4.5f, c.y - 4); p.lineTo(c.x - 3.5f, c.y + 6); p.lineTo(c.x + 3.5f, c.y + 6); p.lineTo(c.x + 4.5f, c.y - 4);
    stroke(g, p, col, 1.2f);
}
}

// ---------------------------------------------------------------- top bar

TopBar::TopBar(AppModel& m) : model(m) {
    model.listeners.push_back([this] { repaint(); });
    startTimerHz(2);
}

void TopBar::timerCallback() {
    int c = int(fin(model.appCPU) * 100);
    if (c != lastCPU) { lastCPU = c; repaint(); }
}

void TopBar::layoutItems(juce::Graphics* g) {
    items.clear();
    const float font = 10, h = float(getHeight());
    const float cy = h / 2;
    auto tw = [&](const juce::String& s, bool bold = false) { return textWidth(s, font, bold); };
    bool running = model.isRunning;
    juce::String inLabel = model.inputUID == "none" ? juce::String("off") : (running ? model.inputName + u8(" \xc2\xb7 ") + juce::String(model.hw.inputs) + "ch" : u8("\xe2\x80\x94"));
    juce::String outLabel = model.outputUID == "off" ? juce::String("off") : (running ? model.outputName + u8(" \xc2\xb7 ") + juce::String(model.hw.outputs) + "ch" : u8("\xe2\x80\x94"));
    bool editable = model.tempoEditable();
    double tempo = std::clamp(double(fin(float(editable ? model.setTempoValue() : model.bpm()))), 0.0, 999.0);
    char tb[64]; std::snprintf(tb, sizeof tb, "%s %5.1f bpm", model.externalClock() ? "EXT" : "INT", tempo);
    juce::String tempoText = tb;
    char cb[32]; std::snprintf(cb, sizeof cb, "cpu %3.0f%%", std::min(fin(model.appCPU) * 100, 999.0f));
    juce::String cpuText = cb;
    int sel = int(model.selectedNodes.size());

    // the full bar if it fits; then without status / cpu; then without device names
    for (int mode = 0; mode < 3; ++mode) {
        bool compact = mode == 2, stats = mode == 0;
        float spacing = compact ? 6.0f : 8.0f;
        auto word = [&](const juce::String& w) { return tw(w) + 6; };
        float left = 12 + tw("polje nieuk", true) + 4 + spacing;
        left += word("audio") + spacing;
        left += tw("IN") + 4 + (compact ? 0 : tw(inLabel) + 4) + 10 + spacing;
        left += tw("OUT") + 4 + (compact ? 0 : tw(outLabel) + 4) + 10 + spacing;
        if (stats) left += tw(model.audioStatus) + spacing;
        float right = tw(tempoText) + (stats ? 10 + 54 : 0) + spacing;
        right += 30 * 6 + spacing * 6;               // undo redo scheme help + select
        if (sel > 0) right += word("duplicate") + (sel >= 2 ? word("group") + spacing : 0) + (!model.selectedGroups().empty() ? word("ungroup") + spacing : 0) + word("bypass") + tw(juce::String(sel)) + spacing * 3;
        right += 30 + spacing + word("browser") + spacing + word("view") + 9 + spacing + word("file") + 9 + 12;
        if (left + right + 8 > float(getWidth()) && mode < 2) continue;
        // lay out
        float x = 12;
        auto add = [&](const juce::String& id, float w, std::function<void(Pt)> a, const juce::String& tip = {}) {
            items.push_back({ id, { x, 0, w, h }, std::move(a), tip }); x += w + spacing;
        };
        if (g) { GC gc(*g); gc.textLeft("polje nieuk", { x, cy }, font, Theme::text(), true); }
        x += tw("polje nieuk", true) + 4 + spacing;
        add("audio", word("audio"), [this](Pt) { model.isRunning ? model.stopAudio() : model.restartAudio(); }, running ? "Stop audio" : "Start audio");
        add("in", tw("IN") + 4 + (compact ? 0 : tw(inLabel) + 4) + 10, [this](Pt p) { deviceMenu(true, p); },
            u8("Chooses the audio interface you record from \xe2\x80\x94 e.g. the disting NT. Its channels become in~'s outlets."));
        add("out", tw("OUT") + 4 + (compact ? 0 : tw(outLabel) + 4) + 10, [this](Pt p) { deviceMenu(false, p); },
            "Chooses where sound goes. Its channels become out~'s inlets.");
        if (stats) add("status", tw(model.audioStatus), nullptr);
        // right side, laid out from the right edge
        float rx = float(getWidth()) - 12;
        std::vector<Item> rightItems;
        auto addR = [&](const juce::String& id, float w, std::function<void(Pt)> a, const juce::String& tip = {}) {
            rx -= w; rightItems.push_back({ id, { rx, 0, w, h }, std::move(a), tip }); rx -= spacing;
        };
        addR("file", word("file") + 9, [this](Pt p) { fileMenu(p); });
        addR("view", word("view") + 9, [this](Pt p) { viewMenu(p); });
        addR("browser", word("browser"), [this](Pt) { model.showFiles = !model.showFiles; model.changed(); }, "Show / hide the browser");
        addR("delete", 30, [this](Pt) { model.removeSelection(); }, "Delete selection");
        if (sel > 0) {
            addR("count", tw(juce::String(sel)), nullptr);
            addR("bypassSel", word("bypass"), [this](Pt) { model.bypassSelection(); }, "Switch the selection off / on");
            if (!model.selectedGroups().empty()) addR("ungroup", word("ungroup"), [this](Pt) { model.ungroupSelection(); }, "Remove the group (the boxes stay where they are)");
            if (sel >= 2) addR("group", word("group"), [this](Pt) { model.groupSelection(); }, "Group the selection: one backdrop, moves together");
            addR("duplicate", word("duplicate"), [this](Pt) { model.duplicateSelection(); }, "Duplicate selection (Ctrl+D)");
        }
        addR("select", 30, [this](Pt) { model.selectMode = !model.selectMode; model.changed(); }, "Select tool: drag empty space to box-select, click titles to add / remove (Shift does the same)");
        addR("add", 30, [this](Pt p) { addMenu(p); }, "Add a module");
        addR("help", 30, [this](Pt) { model.helpMode = !model.helpMode; if (!model.helpMode) model.helpTopics.clear(); model.changed(); }, "Help: point at anything to see what it does");
        addR("scheme", 30, [this](Pt) { model.setLight(!model.lightScheme); }, model.lightScheme ? "Dark scheme" : "Light scheme");
        addR("redo", 30, [this](Pt) { model.redo(); }, "Redo (Ctrl+Shift+Z)");
        addR("undo", 30, [this](Pt) { model.undo(); }, "Undo (Ctrl+Z)");
        if (stats) addR("cpu", 54, nullptr, "cpu: everything the app uses \xe2\x80\x94 sound and drawing the screen. 100 % is one full core.");
        rx -= stats ? 2 : 0;
        addR("tempo", tw(tempoText), nullptr, editable ? "Tempo: drag up / down to change, double-click to type" : "Tempo from the modular's clock");
        for (auto& r : rightItems) items.push_back(r);
        for (auto& it : items) if (it.id == "tempo") tempoRect = it.r;
        if (g) {
            GC gc(*g);
            for (auto& it : items) {
                auto c = it.r.getCentre();
                auto on = [&](bool b) { return b ? Theme::text() : Theme::dim(); };
                if (it.id == "audio") gc.text("audio", c, font, on(running));
                else if (it.id == "in" || it.id == "out") {
                    bool in = it.id == "in";
                    float xx = it.r.getX();
                    gc.textLeft(in ? "IN" : "OUT", { xx, cy }, font, Theme::dim()); xx += tw(in ? "IN" : "OUT") + 4;
                    if (!compact) { gc.textLeft(in ? inLabel : outLabel, { xx, cy }, font, Theme::text()); xx += tw(in ? inLabel : outLabel) + 4; }
                    juce::Path ch; ch.startNewSubPath(xx + 1, cy - 1.5f); ch.lineTo(xx + 3.5f, cy + 1.5f); ch.lineTo(xx + 6, cy - 1.5f);
                    BarIcons::stroke(*g, ch, Theme::dim(), 1.4f);
                } else if (it.id == "status") gc.textLeft(model.audioStatus, { it.r.getX(), cy }, font, Theme::dim());
                else if (it.id == "tempo") {
                    gc.textLeft(tempoText, { it.r.getX(), cy }, font, editable ? Theme::text() : (model.externalClock() ? Theme::text() : Theme::dim()));
                    if (editable) gc.fill(Rect(it.r.getX(), cy + 6, it.r.getWidth(), 0.75f), Theme::faint());
                } else if (it.id == "cpu") gc.textLeft(cpuText, { it.r.getX(), cy }, font, model.appCPU > 0.85f ? Theme::rec : Theme::dim());
                else if (it.id == "undo" || it.id == "redo") BarIcons::undo(*g, c, on(it.id == "undo" ? model.canUndo() : model.canRedo()), it.id == "redo");
                else if (it.id == "scheme") { if (model.lightScheme) BarIcons::moon(*g, c, Theme::dim()); else BarIcons::sun(*g, c, Theme::dim()); }
                else if (it.id == "help") BarIcons::question(*g, c, on(model.helpMode), model.helpMode);
                else if (it.id == "add") BarIcons::plus(*g, c, Theme::dim());
                else if (it.id == "select") BarIcons::dashedRect(*g, c, on(model.selectMode), model.selectMode);
                else if (it.id == "delete") BarIcons::trash(*g, c, on(!(model.selectedNodes.empty() && model.selectedCable.isEmpty())));
                else if (it.id == "browser") gc.text("browser", c, font, on(model.showFiles));
                else if (it.id == "count") gc.text(juce::String(sel), c, font, Theme::dim());
                else if (it.id == "view" || it.id == "file") {
                    gc.textLeft(it.id, { it.r.getX() + 3, cy }, font, Theme::dim());
                    float xx = it.r.getRight() - 9;
                    juce::Path ch; ch.startNewSubPath(xx, cy - 1.5f); ch.lineTo(xx + 3, cy + 1.5f); ch.lineTo(xx + 6, cy - 1.5f);
                    BarIcons::stroke(*g, ch, Theme::text(), 1.6f);
                }
                else if (it.id == "duplicate" || it.id == "group" || it.id == "ungroup" || it.id == "bypassSel")
                    gc.text(it.id == "bypassSel" ? juce::String("bypass") : it.id, c, font, Theme::dim());
            }
        }
        return;
    }
}

void TopBar::paint(juce::Graphics& g) {
    g.fillAll(Theme::bar());
    g.setColour(Theme::border());
    g.fillRect(0.0f, float(getHeight()) - 1, float(getWidth()), 1.0f);
    layoutItems(&g);
}

void TopBar::mouseMove(const juce::MouseEvent& e) {
    juce::String tip;
    for (auto& it : items) if (it.r.contains(e.position)) tip = it.tip;
    if (tip != getTooltip()) setTooltip(tip);
    if (model.helpMode) {
        static std::map<juce::String, std::pair<const char*, const char*>> topics {
            { "audio", { "audio on / off", "Starts or stops the audio engine." } },
            { "in", { "audio input", "Chooses the audio interface you record from \xe2\x80\x94 e.g. the disting NT. Its channels become in~'s outlets." } },
            { "out", { "audio output", "Chooses where sound goes. Its channels become out~'s inlets. Changing it never changes the input." } },
            { "tempo", { "tempo", "The internal clock's tempo. Drag up or down on it to change it, or double-click and type a value (20\xe2\x80\x93" "300 BPM)." } },
            { "cpu", { "cpu", "How much the app uses \xe2\x80\x94 sound and drawing the screen together. 100 % is one full core." } },
            { "undo", { "undo", "Steps back through your edits \xe2\x80\x94 moves, cables, knob turns, added or deleted boxes. Ctrl+Z." } },
            { "redo", { "redo", "Steps forward again after an undo. Ctrl+Shift+Z." } },
            { "scheme", { "light / dark", "Switches the whole app between the dark and light colour schemes." } },
            { "help", { "help", "Switches help on: point at anything to see what it does. Click it again to switch help off." } },
            { "select", { "select tool", "When on, dragging empty space draws a selection box and clicking a box's title adds or removes it. You can also hold Shift." } },
            { "duplicate", { "duplicate", "Copies the selected boxes and the cables between them. Ctrl+D." } },
            { "group", { "group", "Puts the selected boxes on a shared backdrop. Drag the backdrop to move them all together." } },
            { "bypassSel", { "switch off / on", "Bypasses every selected box \xe2\x80\x94 or switches them all back on if they're all off." } },
            { "delete", { "delete", "Deletes the selected boxes or cable." } },
            { "browser", { "browser", "Shows your audio files. Drag one onto a looper~, sampler~ or stretch~ to load it." } },
            { "view", { "view", "How the patch is shown: hide the cables, colours, tidy, fold all boxes, reset the zoom." } },
        };
        for (auto& t : model.helpTopics) if (t.id.startsWith("tb-")) { model.hoverHelp(t, false); break; }
        for (auto& it : items) if (it.r.contains(e.position)) {
            auto f = topics.find(it.id);
            if (f != topics.end()) model.hoverHelp({ "tb-" + it.id, u8(f->second.first), u8(f->second.second) }, true);
        }
    }
}

void TopBar::mouseDown(const juce::MouseEvent& e) {
    dragStart = e.position;
    tempoDrag.reset();
    if (tempoRect.contains(e.position) && model.tempoEditable()) tempoDrag = model.setTempoValue();
}

void TopBar::mouseDrag(const juce::MouseEvent& e) {
    if (!tempoDrag) return;
    float d = ((e.position.x - dragStart.x) - (e.position.y - dragStart.y)) / 3;
    if (std::abs(d) >= 0.34f) model.setTempo(std::round(*tempoDrag + d));
}

void TopBar::mouseUp(const juce::MouseEvent& e) {
    bool wasDrag = tempoDrag && e.position.getDistanceFrom(dragStart) > 2;
    tempoDrag.reset();
    if (wasDrag || e.position.getDistanceFrom(dragStart) > 4) return;
    for (auto& it : items) if (it.r.contains(e.position) && it.action) { it.action({ it.r.getX(), it.r.getBottom() }); return; }
}

void TopBar::mouseDoubleClick(const juce::MouseEvent& e) {
    if (!tempoRect.contains(e.position) || !model.tempoEditable()) return;
    tempoEditor = std::make_unique<juce::TextEditor>();
    tempoEditor->setFont(Theme::mono(10));
    tempoEditor->setText(juce::String(int(std::round(model.setTempoValue()))), false);
    tempoEditor->setColour(juce::TextEditor::backgroundColourId, Theme::row());
    tempoEditor->setColour(juce::TextEditor::textColourId, Theme::text());
    tempoEditor->setColour(juce::TextEditor::outlineColourId, Theme::border());
    tempoEditor->setBounds(tempoRect.withWidth(60).reduced(0, 6).getSmallestIntegerContainer());
    auto commit = [this] {
        if (!tempoEditor) return;
        auto t = tempoEditor->getText().replace(",", ".");
        if (t.containsAnyOf("0123456789")) model.setTempo(t.getDoubleValue());
        juce::MessageManager::callAsync([sp = juce::Component::SafePointer<TopBar>(this)] { if (sp) sp->tempoEditor.reset(); });
    };
    tempoEditor->onReturnKey = commit;
    tempoEditor->onFocusLost = commit;
    tempoEditor->onEscapeKey = [this] { juce::MessageManager::callAsync([sp = juce::Component::SafePointer<TopBar>(this)] { if (sp) sp->tempoEditor.reset(); }); };
    addAndMakeVisible(*tempoEditor);
    tempoEditor->grabKeyboardFocus();
    tempoEditor->selectAll();
}

void TopBar::popup(juce::PopupMenu& m, Pt at) {
    auto p = localPointToGlobal(at.toInt());
    m.showMenuAsync(juce::PopupMenu::Options().withTargetScreenArea({ p.x, p.y, 1, 1 }));
}

void TopBar::deviceMenu(bool input, Pt at) {
    if (model.inputChoices.empty()) model.refreshDevices();
    juce::PopupMenu m;
    auto& choices = input ? model.inputChoices : model.outputChoices;
    auto selected = input ? model.inputUID : model.outputUID;
    for (auto& c : choices) {
        auto id = c.id;
        m.addItem(c.name, true, c.id == selected, [this, id, input] { input ? model.selectInput(id) : model.selectOutput(id); });
    }
    m.addSeparator();
    m.addItem("Refresh devices", [this] { model.refreshDevices(); });
    popup(m, at);
}

void TopBar::addMenu(Pt at) {
    juce::PopupMenu m;
    for (auto& cat : Registry::categories) {
        m.addSectionHeader(nameOf(cat));
        for (auto& s : Registry::all()) {
            if (s.category != cat) continue;
            auto kind = s.kind;
            m.addItem(nameOf(s.name) + u8("  \xe2\x80\x94  ") + nameOf(s.summary), [this, kind] { model.addNode(kind, model.viewCenterInCanvas()); });
        }
    }
    popup(m, at);
}

void TopBar::viewMenu(Pt at) {
    juce::PopupMenu m;
    m.addItem("Hide cables", true, model.hideCables, [this] {
        model.hideCables = !model.hideCables;
        settings().setValue("hideCables", model.hideCables);
        if (model.hideCables) model.selectedCable = {};
        model.changed();
    });
    m.addItem(u8("Colours\xe2\x80\xa6"), [this] { if (onColours) onColours(); });
    m.addSeparator();
    m.addItem("Tidy", [this] { model.tidy(); });
    m.addItem(model.allCollapsed() ? "Unfold all" : "Fold all", [this] { model.toggleCollapseAll(); });
    m.addSeparator();
    m.addItem("3D", true, model.threeD, [this] { model.threeD = !model.threeD; model.changed(); });
    juce::PopupMenu lift;
    for (auto& cat : Registry::categories) {
        if (model.sectionIndices(cat).empty()) continue;
        auto c = cat;
        lift.addItem(juce::String(cat), true, model.sectionLifted(cat), [this, c] { model.toggleLift(c); });
    }
    lift.addSeparator();
    lift.addItem("Layers by section", [this] { model.layerBySection(); });
    lift.addItem("Put everything down", [this] { model.putEverythingDown(); });
    m.addSubMenu("Lift in 3D", lift);
    m.addSeparator();
    m.addItem("Reset view", [this] { model.setView({ 30, 30 }, 1); });
    popup(m, at);
}

void TopBar::fileMenu(Pt at) {
    juce::PopupMenu m;
    m.addItem(u8("New\xe2\x80\xa6"), [this] { if (onNew) onNew(); });
    m.addItem(u8("Open\xe2\x80\xa6"), [this] { if (onOpen) onOpen(); });
    m.addItem(u8("Save As\xe2\x80\xa6"), [this] { if (onSave) onSave(); });
    m.addSeparator();
    m.addItem("Set as default", [this] { model.setAsDefault(); });
    m.addItem("Reset default", model.hasUserDefault, false, [this] { model.resetDefault(); });
    popup(m, at);
}

// ---------------------------------------------------------------- file browser

FileBrowser::FileBrowser(AppModel& m) : model(m) {
    formats.registerBasicFormats();
    search.setTextToShowWhenEmpty("search", Theme::faint());
    search.setFont(Theme::mono(11));
    search.setColour(juce::TextEditor::backgroundColourId, Theme::row());
    search.setColour(juce::TextEditor::textColourId, Theme::text());
    search.setColour(juce::TextEditor::outlineColourId, juce::Colours::transparentBlack);
    search.setColour(juce::TextEditor::focusedOutlineColourId, Theme::border());
    search.onTextChange = [this] { runSearch(); };
    addAndMakeVisible(search);
    rebuild();
}

FileBrowser::~FileBrowser() { stopPreview(); pool.removeAllJobs(true, 2000); }

void FileBrowser::resized() { search.setBounds(22, 34, getWidth() - 32, 20); }

static std::vector<std::pair<juce::String, juce::File>> places() {
    std::vector<std::pair<juce::String, juce::File>> p { { "Recordings", recordingsDirectory() } };
    auto home = juce::File::getSpecialLocation(juce::File::userHomeDirectory);
    p.push_back({ "Home", home });
    p.push_back({ "Desktop", juce::File::getSpecialLocation(juce::File::userDesktopDirectory) });
    p.push_back({ "Documents", juce::File::getSpecialLocation(juce::File::userDocumentsDirectory) });
    p.push_back({ "Downloads", home.getChildFile("Downloads") });
    p.push_back({ "Music", juce::File::getSpecialLocation(juce::File::userMusicDirectory) });
    juce::Array<juce::File> roots;
    juce::File::findFileSystemRoots(roots);
   #if JUCE_MAC
    for (auto& v : juce::File("/Volumes").findChildFiles(juce::File::findDirectories, false)) p.push_back({ v.getFileName(), v });
   #else
    for (auto& r : roots) p.push_back({ r.getFullPathName(), r });
   #endif
    std::vector<std::pair<juce::String, juce::File>> out;
    for (auto& x : p) if (x.second.isDirectory()) out.push_back(x);
    return out;
}

void FileBrowser::rebuild() {
    rows.clear();
    if (search.getText().trim().isNotEmpty()) {
        for (auto& f : results) rows.push_back({ Row::fileRow, f, f.getFileName(), 0, false, true });
        if (results.empty() || searching) rows.push_back({ Row::note, {}, searching ? u8("searching\xe2\x80\xa6") : juce::String("no audio files match"), 0 });
        repaint();
        return;
    }
    std::function<void(const juce::File&, const juce::String&, int, bool)> folder = [&](const juce::File& f, const juce::String& title, int depth, bool removable) {
        rows.push_back({ Row::folder, f, title, depth, removable });
        if (!open.count(f.getFullPathName())) return;
        auto kids = f.findChildFiles(juce::File::findFilesAndDirectories | juce::File::ignoreHiddenFiles, false);
        std::vector<juce::File> dirs, files;
        for (auto& k : kids) {
            if (k.isDirectory() && !k.getFileName().endsWithIgnoreCase(".app")) dirs.push_back(k);
            else if (AudioFiles::isAudio(k)) files.push_back(k);
        }
        auto byName = [](const juce::File& a, const juce::File& b) { return a.getFileName().compareNatural(b.getFileName()) < 0; };
        std::sort(dirs.begin(), dirs.end(), byName); std::sort(files.begin(), files.end(), byName);
        for (auto& d : dirs) folder(d, d.getFileName(), depth + 1, false);
        for (auto& x : files) rows.push_back({ Row::fileRow, x, x.getFileName(), depth + 1 });
        if (dirs.empty() && files.empty()) rows.push_back({ Row::note, {}, "no audio files", depth + 1 });
    };
    rows.push_back({ Row::section, {}, "places" });
    for (auto& [t, f] : places()) folder(f, t, 0, false);
    rows.push_back({ Row::section, {}, "collections" });
    for (auto& f : model.browserFolders) folder(f, f.getFileName(), 0, true);
    if (model.browserFolders.empty()) rows.push_back({ Row::add, {}, "+ add a folder" });
    rows.push_back({ Row::note, {}, u8("Drag a file onto a looper~, sampler~ or stretch~ \xe2\x80\x94 or select one and click a file. \xe2\x96\xb6 previews."), 0 });
    repaint();
}

void FileBrowser::refresh() { rebuild(); }

void FileBrowser::runSearch() {
    auto q = search.getText().trim().toLowerCase();
    int gen = ++searchGeneration;
    results.clear();
    if (q.length() < 2) { searching = false; rebuild(); return; }
    searching = true;
    rebuild();
    std::vector<juce::File> roots;
    for (auto& [t, f] : places()) if (f.getParentDirectory() != f) roots.push_back(f);
    for (auto& f : model.browserFolders) roots.push_back(f);
    std::vector<juce::File> unique;
    for (auto& r : roots) {
        bool inside = false;
        for (auto& o : roots) if (o != r && r.isAChildOf(o)) inside = true;
        if (!inside) unique.push_back(r);
    }
    juce::Component::SafePointer<FileBrowser> sp(this);
    pool.addJob([sp, unique, q, gen, this] {
        std::vector<juce::File> found;
        auto report = [&](bool done) {
            auto batch = found; found.clear();
            juce::MessageManager::callAsync([sp, batch, done, gen] {
                if (!sp || sp->searchGeneration.load() != gen) return;
                sp->results.insert(sp->results.end(), batch.begin(), batch.end());
                if (done) sp->searching = false;
                sp->rebuild();
            });
        };
        int total = 0;
        for (auto& root : unique) {
            for (const auto& entry : juce::RangedDirectoryIterator(root, true, "*", juce::File::findFiles | juce::File::ignoreHiddenFiles)) {
                if (searchGeneration.load() != gen) return;
                auto f = entry.getFile();
                if (f.getFileName().toLowerCase().contains(q) && AudioFiles::isAudio(f)) {
                    found.push_back(f);
                    if (++total >= 500) { report(true); return; }
                    if (found.size() >= 25) report(false);
                }
            }
        }
        report(true);
    });
}

void FileBrowser::paint(juce::Graphics& g) {
    g.fillAll(Theme::bar());
    GC gc(g);
    gc.textLeft("browser", { 10, 16 }, 11, Theme::text(), true);
    // refresh / add-folder icons
    gc.text(u8("\xe2\x9f\xb3"), { float(getWidth()) - 44, 16 }, 12, Theme::dim());
    gc.text("+", { float(getWidth()) - 18, 16 }, 13, Theme::dim(), true);
    g.setColour(Theme::row()); g.fillRoundedRectangle(8, 31, float(getWidth()) - 16, 26, 3);
    juce::Path mg; mg.addEllipse(14, 39, 7, 7); mg.startNewSubPath(19.5f, 44.5f); mg.lineTo(22, 47);
    g.setColour(Theme::dim()); g.strokePath(mg, juce::PathStrokeType(1.1f));
    g.setColour(Theme::border()); g.fillRect(0.0f, headerH - 1, float(getWidth()), 1.0f);
    juce::Graphics::ScopedSaveState s(g);
    g.reduceClipRegion(0, int(headerH), getWidth(), getHeight() - int(headerH));
    float y = headerH - scroll;
    float w = float(getWidth());
    for (int i = 0; i < int(rows.size()); ++i) {
        auto& r = rows[size_t(i)];
        float rh = r.kind == Row::note ? 0 : (r.kind == Row::section ? 22.0f : (r.showFolder ? 30.0f : rowH));
        if (r.kind == Row::note) {
            juce::AttributedString as; as.append(r.title, Theme::mono(9), Theme::faint()); as.setWordWrap(juce::AttributedString::byWord);
            juce::TextLayout tl; tl.createLayout(as, w - 20 - float(r.depth) * 12 - 12);
            rh = tl.getHeight() + 8;
            if (y + rh > headerH && y < float(getHeight())) tl.draw(g, Rect(10 + float(r.depth) * 12 + 12, y + 4, w - 20, tl.getHeight()));
            y += rh; continue;
        }
        if (y + rh > headerH && y < float(getHeight())) {
            float x = 10 + float(r.depth) * 12;
            if (r.kind == Row::section) gc.textLeft(r.title, { 10, y + 14 }, 9, Theme::faint());
            else if (r.kind == Row::add) gc.textLeft(r.title, { 10, y + rh / 2 }, 9, Theme::dim());
            else if (r.kind == Row::folder) {
                bool isOpen = open.count(r.file.getFullPathName()) > 0;
                juce::Path ch;
                if (isOpen) { ch.startNewSubPath(x, y + rh / 2 - 1.5f); ch.lineTo(x + 3.5f, y + rh / 2 + 1.5f); ch.lineTo(x + 7, y + rh / 2 - 1.5f); }
                else { ch.startNewSubPath(x + 2, y + rh / 2 - 3.5f); ch.lineTo(x + 5.5f, y + rh / 2); ch.lineTo(x + 2, y + rh / 2 + 3.5f); }
                g.setColour(Theme::text()); g.strokePath(ch, juce::PathStrokeType(1.4f));
                juce::Path fold; fold.addRoundedRectangle(x + 13, y + rh / 2 - 4, 11, 8, 1.2f);
                g.strokePath(fold, juce::PathStrokeType(1.0f));
                gc.textLeft(fitText(r.title, 11, w - x - 50), { x + 31, y + rh / 2 }, 11, Theme::text());
                if (r.removable) Icons::xmark(gc, { w - 16, y + rh / 2 }, 2.5f, Theme::faint());
            } else {
                bool isPlaying = playing == r.file;
                if (i == hoverRow) gc.fill(Rect(0, y, w, rh), Theme::row());
                auto col = (i == hoverRow || isPlaying) ? Theme::text() : Theme::dim();
                if (isPlaying) gc.fill(Rect(x + 3, y + 9.5f - 3, 6, 6), Theme::text());
                else { juce::Path tri; tri.addTriangle(x + 3, y + 9.5f - 3.5f, x + 9, y + 9.5f, x + 3, y + 9.5f + 3.5f); gc.fill(tri, Theme::faint()); }
                gc.textLeft(fitText(r.title, 9, w - x - 30), { x + 17, y + 9.5f }, 9, col);
                if (r.showFolder) {
                    auto dir = r.file.getParentDirectory().getFullPathName().replace(juce::File::getSpecialLocation(juce::File::userHomeDirectory).getFullPathName(), "~");
                    gc.textLeft(fitText(dir, 9, w - x - 30), { x + 17, y + 22 }, 9, Theme::faint());
                }
            }
        }
        y += rh;
    }
}

static int rowAt(const std::vector<int>& tops, float y) { for (int i = int(tops.size()) - 1; i >= 0; --i) if (y >= float(tops[size_t(i)])) return i; return -1; }

void FileBrowser::mouseMove(const juce::MouseEvent& e) {
    // find the row under the pointer (same heights as paint)
    float y = headerH - scroll; int h = -1;
    for (int i = 0; i < int(rows.size()); ++i) {
        auto& r = rows[size_t(i)];
        float rh = r.kind == Row::section ? 22.0f : (r.showFolder ? 30.0f : rowH);
        if (r.kind == Row::note) {
            juce::AttributedString as; as.append(r.title, Theme::mono(9)); as.setWordWrap(juce::AttributedString::byWord);
            juce::TextLayout tl; tl.createLayout(as, float(getWidth()) - 20 - float(r.depth) * 12 - 12); rh = tl.getHeight() + 8;
        }
        if (e.position.y >= y && e.position.y < y + rh && e.position.y > headerH) h = i;
        y += rh;
    }
    if (h != hoverRow) { hoverRow = h; repaint(); }
}
void FileBrowser::mouseExit(const juce::MouseEvent&) { hoverRow = -1; repaint(); }

void FileBrowser::mouseDown(const juce::MouseEvent& e) {
    mouseMove(e);
    pressRow = hoverRow; dragStarted = false;
    if (e.position.y < 28) {
        if (e.position.x > float(getWidth()) - 30) {
            chooser = std::make_unique<juce::FileChooser>("Add a folder to Collections");
            chooser->launchAsync(juce::FileBrowserComponent::openMode | juce::FileBrowserComponent::canSelectDirectories, [this](const juce::FileChooser& c) {
                if (c.getResult().isDirectory()) { model.addFolder(c.getResult()); rebuild(); }
            });
        } else if (e.position.x > float(getWidth()) - 56) rebuild();
    }
}

void FileBrowser::mouseDrag(const juce::MouseEvent& e) {
    if (pressRow < 0 || dragStarted || e.getDistanceFromDragStart() < 5) return;
    auto& r = rows[size_t(pressRow)];
    if (r.kind != Row::fileRow) return;
    dragStarted = true;
    juce::Image img(juce::Image::ARGB, 200, 22, true);
    { juce::Graphics g(img); g.setColour(Theme::box()); g.fillRect(0, 0, 200, 22); GC gc(g); gc.textLeft(fitText(r.title, 11, 190), { 6, 11 }, 11, Theme::text()); }
    startDragging(r.file.getFullPathName(), this, juce::ScaledImage(img), true);
}

void FileBrowser::mouseUp(const juce::MouseEvent& e) {
    if (dragStarted || pressRow < 0 || pressRow != hoverRow) return;
    auto r = rows[size_t(pressRow)];
    float x = 10 + float(r.depth) * 12;
    switch (r.kind) {
        case Row::folder:
            if (r.removable && e.position.x > float(getWidth()) - 26) { model.removeFolder(r.file); rebuild(); return; }
            if (open.count(r.file.getFullPathName())) open.erase(r.file.getFullPathName()); else open.insert(r.file.getFullPathName());
            rebuild();
            break;
        case Row::fileRow:
            if (e.position.x < x + 14) preview(r.file); else model.loadIntoSelection(r.file);
            break;
        case Row::add:
            chooser = std::make_unique<juce::FileChooser>("Add a folder to Collections");
            chooser->launchAsync(juce::FileBrowserComponent::openMode | juce::FileBrowserComponent::canSelectDirectories, [this](const juce::FileChooser& c) {
                if (c.getResult().isDirectory()) { model.addFolder(c.getResult()); rebuild(); }
            });
            break;
        default: break;
    }
}

void FileBrowser::mouseWheelMove(const juce::MouseEvent&, const juce::MouseWheelDetails& w) {
    scroll = std::max(0.0f, scroll - w.deltaY * 300);
    repaint();
}

void FileBrowser::preview(const juce::File& f) {
    if (playing == f) { stopPreview(); repaint(); return; }
    stopPreview();
    auto* reader = formats.createReaderFor(f);
    if (!reader) return;
    if (!previewDevice) {
        previewDevice = std::make_unique<juce::AudioDeviceManager>();
        previewDevice->initialise(0, 2, nullptr, true);
        player.setSource(&transport);
        previewDevice->addAudioCallback(&player);
    }
    previewSource = std::make_unique<juce::AudioFormatReaderSource>(reader, true);
    transport.setSource(previewSource.get(), 0, nullptr, reader->sampleRate);
    transport.setGain(0.8f);
    transport.start();
    playing = f;
    startTimer(200);
    repaint();
}

void FileBrowser::stopPreview() {
    transport.stop();
    transport.setSource(nullptr);
    previewSource.reset();
    playing = juce::File();
    stopTimer();
}

void FileBrowser::timerCallback() {
    if (playing.exists() && !transport.isPlaying()) { stopPreview(); repaint(); }
}

// ---------------------------------------------------------------- the colours panel

class ColourPanel : public juce::Component, private juce::ChangeListener {
public:
    explicit ColourPanel(AppModel& m) : model(m), selector(juce::ColourSelector::showColourspace | juce::ColourSelector::showSliders) {
        selector.addChangeListener(this);
        addChildComponent(selector);
        setSize(250, 130);
    }
    juce::Colour current(CustomColours::Slot s) { return s == CustomColours::background ? Theme::bg() : s == CustomColours::windows ? Theme::box() : Theme::cable(); }
    void paint(juce::Graphics& g) override {
        g.fillAll(Theme::box());
        GC gc(g);
        gc.textLeft(juce::String("colours ") + u8("\xc2\xb7 ") + (model.lightScheme ? "light" : "dark") + " scheme", { 14, 16 }, 11, Theme::text(), true);
        for (int s = 0; s < 3; ++s) {
            float y = 40 + float(s) * 24;
            gc.textLeft(CustomColours::title(CustomColours::Slot(s)), { 14, y }, 11, s == active ? Theme::text() : Theme::text());
            g.setColour(current(CustomColours::Slot(s))); g.fillRoundedRectangle(170, y - 8, 30, 16, 3);
            g.setColour(s == active ? Theme::text() : Theme::border()); g.drawRoundedRectangle(170, y - 8, 30, 16, 3, s == active ? 2.0f : 1.0f);
            gc.text(u8("\xe2\x86\xba"), { 222, y }, 12, CustomColours::colour(CustomColours::Slot(s)) ? Theme::dim() : Theme::faint());
        }
        gc.textLeft("Reset all to the scheme", { 14, 114 }, 9, CustomColours::anyCustom() ? Theme::text() : Theme::faint());
    }
    void mouseUp(const juce::MouseEvent& e) override {
        for (int s = 0; s < 3; ++s) {
            float y = 40 + float(s) * 24;
            if (Rect(166, y - 10, 38, 20).contains(e.position)) {
                active = active == s ? -1 : s;
                if (active >= 0) {
                    selector.setCurrentColour(current(CustomColours::Slot(s)), juce::dontSendNotification);
                    selector.setBounds(10, 130, 230, 220);
                    selector.setVisible(true);
                    setSize(250, 360);
                } else { selector.setVisible(false); setSize(250, 130); }
                repaint();
                return;
            }
            if (Rect(212, y - 10, 20, 20).contains(e.position)) { CustomColours::set(CustomColours::Slot(s), std::nullopt); model.coloursChanged(); repaint(); return; }
        }
        if (e.position.y > 104 && e.position.y < 124) { CustomColours::resetAll(); model.coloursChanged(); repaint(); }
    }
private:
    void changeListenerCallback(juce::ChangeBroadcaster*) override {
        if (active < 0) return;
        CustomColours::set(CustomColours::Slot(active), selector.getCurrentColour());
        model.coloursChanged();
        repaint();
    }
    AppModel& model;
    juce::ColourSelector selector;
    int active = -1;
};

// ---------------------------------------------------------------- the window's content

struct Look : juce::LookAndFeel_V4 {
    void apply() {
        setColour(juce::PopupMenu::backgroundColourId, Theme::box());
        setColour(juce::PopupMenu::textColourId, Theme::text());
        setColour(juce::PopupMenu::headerTextColourId, Theme::faint());
        setColour(juce::PopupMenu::highlightedBackgroundColourId, Theme::text());
        setColour(juce::PopupMenu::highlightedTextColourId, Theme::inverse());
        setColour(juce::TooltipWindow::backgroundColourId, Theme::text());
        setColour(juce::TooltipWindow::textColourId, Theme::inverse());
        setColour(juce::TooltipWindow::outlineColourId, Theme::border());
        setColour(juce::AlertWindow::backgroundColourId, Theme::box());
        setColour(juce::AlertWindow::textColourId, Theme::text());
        setColour(juce::AlertWindow::outlineColourId, Theme::border());
        setColour(juce::TextButton::buttonColourId, Theme::row());
        setColour(juce::TextButton::textColourOffId, Theme::text());
        setColour(juce::ResizableWindow::backgroundColourId, Theme::box());
        setColour(juce::CaretComponent::caretColourId, Theme::text());
        setColour(juce::ColourSelector::backgroundColourId, Theme::box());
        setColour(juce::ColourSelector::labelTextColourId, Theme::text());
        setColour(juce::TextEditor::backgroundColourId, Theme::row());
        setColour(juce::TextEditor::textColourId, Theme::text());
        setColour(juce::TextEditor::highlightColourId, Theme::fill());
    }
    juce::Font getPopupMenuFont() override { return Theme::mono(11); }
    juce::Font getAlertWindowTitleFont() override { return Theme::mono(12, true); }
    juce::Font getAlertWindowMessageFont() override { return Theme::mono(11); }
    juce::Font getTextButtonFont(juce::TextButton&, int) override { return Theme::mono(11); }
    juce::Rectangle<int> getTooltipBounds(const juce::String& tip, juce::Point<int> pos, juce::Rectangle<int> parent) override {
        int w = int(textWidth(tip, 10)) + 14, h = 22;
        return juce::Rectangle<int>(pos.x > parent.getCentreX() ? pos.x - (w + 12) : pos.x + 24,
                                    pos.y > parent.getCentreY() ? pos.y - (h + 6) : pos.y + 6, w, h).constrainedWithin(parent);
    }
    void drawTooltip(juce::Graphics& g, const juce::String& text, int w, int h) override {
        g.setColour(Theme::text()); g.fillRoundedRectangle(0, 0, float(w), float(h), 3);
        GC gc(g); gc.text(text, { float(w) / 2, float(h) / 2 }, 10, Theme::inverse());
    }
};

MainComponent::MainComponent() {
    look = std::make_unique<Look>();
    static_cast<Look*>(look.get())->apply();
    juce::LookAndFeel::setDefaultLookAndFeel(look.get());
    setLookAndFeel(look.get());
    addAndMakeVisible(bar);
    addAndMakeVisible(canvas);
    lastLight = model.lightScheme;
    model.listeners.push_back([this] { modelChanged(); });
    bar.onColours = [this] { showColours(); };
    bar.onNew = [this] {
        juce::AlertWindow::showAsync(juce::MessageBoxOptions().withTitle("Clear the canvas?")
                                         .withButton(model.hasUserDefault ? "New patch (your default)" : "New patch")
                                         .withButton("Empty canvas")
                                         .withButton(model.hasUserDefault ? "Built-in starter" : "Cancel")
                                         .withButton(model.hasUserDefault ? "Cancel" : ""),
                                     [this](int r) {
            if (r == 1) model.newPatch();
            else if (r == 2) model.load(Patch());
            else if (r == 3 && model.hasUserDefault) model.load(PatchStore::builtIn());
        });
    };
    bar.onOpen = [this] {
        chooser = std::make_unique<juce::FileChooser>("Open a patch", juce::File(), "*.json");
        chooser->launchAsync(juce::FileBrowserComponent::openMode | juce::FileBrowserComponent::canSelectFiles, [this](const juce::FileChooser& c) {
            if (c.getResult().existsAsFile()) model.openFile(c.getResult());
        });
    };
    bar.onSave = [this] {
        chooser = std::make_unique<juce::FileChooser>("Save the patch", juce::File::getSpecialLocation(juce::File::userDocumentsDirectory).getChildFile("My Patch.json"), "*.json");
        chooser->launchAsync(juce::FileBrowserComponent::saveMode | juce::FileBrowserComponent::warnAboutOverwriting, [this](const juce::FileChooser& c) {
            auto f = c.getResult();
            if (f != juce::File()) model.saveFile(f.withFileExtension("json"));
        });
    };
    setSize(1280, 800);
    juce::MessageManager::callAsync([this] { model.startAudio(); });
}

MainComponent::~MainComponent() { juce::LookAndFeel::setDefaultLookAndFeel(nullptr); setLookAndFeel(nullptr); }

void MainComponent::modelChanged() {
    bool layout = false;
    if (model.audioError != lastError) { lastError = model.audioError; layout = true; }
    if (model.showFiles != lastShowFiles) {
        lastShowFiles = model.showFiles;
        float before = browser ? float(browser->getWidth()) + 1 : 0;
        if (model.showFiles) { browser = std::make_unique<FileBrowser>(model); addAndMakeVisible(*browser); browser->setBounds(0, 0, 260, 10); }
        else browser.reset();
        float after = browser ? 261.0f : 0;
        // the canvas's left edge moves: move the view the other way, so the patch stays put on screen
        model.viewOffset.x -= after - before;
        layout = true;
    }
    if (model.lightScheme != lastLight || CustomColours::version != lastColours) {
        lastLight = model.lightScheme;
        lastColours = CustomColours::version;
        static_cast<Look*>(look.get())->apply();
        if (browser) { browser = std::make_unique<FileBrowser>(model); addAndMakeVisible(*browser); }
        repaint();
    }
    if (model.audioImportTarget.isNotEmpty() && importTarget.isEmpty()) {
        importTarget = model.audioImportTarget;
        chooser = std::make_unique<juce::FileChooser>("Load audio", juce::File(), "*.wav;*.wave;*.aif;*.aiff;*.aifc;*.flac;*.mp3;*.ogg;*.caf;*.m4a");
        chooser->launchAsync(juce::FileBrowserComponent::openMode | juce::FileBrowserComponent::canSelectFiles, [this](const juce::FileChooser& c) {
            auto id = importTarget;
            importTarget = {}; model.audioImportTarget = {};
            if (c.getResult().existsAsFile()) model.loadAudio(c.getResult(), id);
        });
    }
    if (model.showColours) {
        model.showColours = false;
        showColours();
    }
    if (layout) resized();
}

void MainComponent::showColours() {
    auto panel = std::make_unique<ColourPanel>(model);
    juce::CallOutBox::launchAsynchronously(std::move(panel), bar.localAreaToGlobal(juce::Rectangle<int>(bar.getWidth() - 140, bar.getHeight() - 4, 1, 1)), nullptr);
}

void MainComponent::resized() {
    auto r = getLocalBounds();
    bar.setBounds(r.removeFromTop(42));
    if (model.audioError.isNotEmpty()) r.removeFromTop(26);
    if (browser) { browser->setBounds(r.removeFromLeft(260)); r.removeFromLeft(1); }
    canvas.setBounds(r);
}

void MainComponent::paint(juce::Graphics& g) {
    g.fillAll(Theme::bg());
    if (model.audioError.isNotEmpty()) {
        auto r = juce::Rectangle<float>(0, 42, float(getWidth()), 26);
        g.setColour(Theme::rec.withAlpha(0.75f)); g.fillRect(r);
        GC gc(g); gc.textLeft(model.audioError, { 12, r.getCentreY() }, 11, juce::Colours::white);
    }
    if (browser) { g.setColour(Theme::border()); g.fillRect(260, 42 + (model.audioError.isNotEmpty() ? 26 : 0), 1, getHeight()); }
}

bool MainComponent::keyPressed(const juce::KeyPress& k) {
    auto m = k.getModifiers();
    if (m.isCommandDown() && k.getKeyCode() == 'Z') { m.isShiftDown() ? model.redo() : model.undo(); return true; }
    if (m.isCommandDown() && k.getKeyCode() == 'Y') { model.redo(); return true; }
    if (m.isCommandDown() && k.getKeyCode() == 'D') { model.duplicateSelection(); return true; }
    if (m.isCommandDown() && k.getKeyCode() == 'S') { bar.onSave(); return true; }
    if (m.isCommandDown() && k.getKeyCode() == 'O') { bar.onOpen(); return true; }
    return false;
}

} // namespace pn
