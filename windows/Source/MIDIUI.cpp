// MIDI in the UI (MIDISupport.swift): the top bar's midi menu and the midi box's device pickers.
#include "Displays.h"
#include "ModulesMIDI.h"

namespace pn {

/// Starts MIDI once, with the devices switched off last time.
void startMIDI() {
    auto& hub = MidiHub::shared();
    if (hub.started) return;
    for (auto& n : juce::StringArray::fromLines(settings().getValue("midiOffIn"))) if (n.isNotEmpty()) hub.offIn.insert(n);
    for (auto& n : juce::StringArray::fromLines(settings().getValue("midiOffOut"))) if (n.isNotEmpty()) hub.offOut.insert(n);
    hub.start();
}

static void saveMIDI() {
    auto& hub = MidiHub::shared();
    juce::StringArray a, b;
    for (auto& n : hub.offIn) a.add(n);
    for (auto& n : hub.offOut) b.add(n);
    settings().setValue("midiOffIn", a.joinIntoString("\n"));
    settings().setValue("midiOffOut", b.joinIntoString("\n"));
}

void addMIDIBarMenu(juce::PopupMenu& m) {
    auto& hub = MidiHub::shared();
    m.addSectionHeader("receive from");
    if (hub.sources.empty()) m.addItem("no MIDI devices", false, false, [] {});
    for (auto& d : hub.sources) {
        auto n = d.name;
        m.addItem(n, true, hub.isOnIn(n), [n] { auto& h = MidiHub::shared(); h.setInput(n, !h.isOnIn(n)); saveMIDI(); });
    }
    m.addSeparator();
    m.addSectionHeader("send to");
    if (hub.destinations.empty()) m.addItem("no MIDI devices", false, false, [] {});
    for (auto& d : hub.destinations) {
        auto n = d.name;
        m.addItem(n, true, hub.isOnOut(n), [n] { auto& h = MidiHub::shared(); h.setOutput(n, !h.isOnOut(n)); saveMIDI(); });
    }
    m.addSeparator();
    m.addItem("Refresh MIDI devices", [] { MidiHub::shared().rescan(); });
}

class MIDIBoxDisplay : public NativeDisplay {
public:
    using NativeDisplay::NativeDisplay;
    Rect row(int k, Rect r) const { return Rect(r.getX(), r.getY() + 4 + float(k) * 22, r.getWidth(), 19); }
    MIDIBoxNode* mn() { return dynamic_cast<MIDIBoxNode*>(dsp()); }

    std::vector<LivePart> parts(Rect r) override {
        return { part("midi", r, [this] {
            auto* n = mn();
            if (!n) return int64_t(0);
            return int64_t(n->readouts[1]) | int64_t(n->readouts[2]) << 1 | int64_t(n->readouts[3]) << 2
                 | int64_t(n->inName.hashCode() & 0xFFFF) << 4 | int64_t(n->outName.hashCode() & 0xFFFF) << 20;
        }, [this, r](GC& g, Pt) {
            auto* n = mn();
            for (int k = 0; k < 2; ++k) {
                auto q = row(k, r).translated(-r.getX(), -r.getY());
                g.fill(q, Theme::row());
                juce::String name = n ? (k == 0 ? n->inName : n->outName) : juce::String();
                bool missing = n && ((int(n->readouts[3]) >> k) & 1) == 1;
                juce::String shown = name.isEmpty() ? juce::String("all devices") : (missing ? name + " (not connected)" : name);
                bool lit = n && n->readouts[size_t(k + 1)] > 0;
                g.fill(Rect(q.getX() + 6, q.getCentreY() - 3, 6, 6), lit ? Theme::text() : Theme::faint());
                g.textLeft(k == 0 ? "in" : "out", { q.getX() + 17, q.getCentreY() }, 9, Theme::dim());
                g.textLeft(fitText(shown + juce::String::fromUTF8("  \xe2\x96\xbe"), 10, q.getWidth() - 46), { q.getX() + 40, q.getCentreY() }, 10,
                           missing ? Theme::dim() : Theme::text());
            }
        }) };
    }

    void showDevices(bool input) {
        auto& hub = MidiHub::shared();
        auto* m = &model; auto nid = id;
        auto key = input ? MIDIBoxLayout::inKey : MIDIBoxLayout::outKey;
        auto current = MIDIBoxLayout::text(node.data.count(key) ? node.data.at(key) : std::vector<float> {});
        auto pick = [m, nid, key](const juce::String& name) { m->setData(nid, key, MIDIBoxLayout::codes(name)); };
        juce::PopupMenu menu;
        menu.addItem("all devices (on in the midi menu)", true, current.isEmpty(), [pick] { pick({}); });
        if (!input) menu.addItem("none", true, current == "none", [pick] { pick("none"); });
        menu.addSeparator();
        bool found = false;
        for (auto& d : input ? hub.sources : hub.destinations) {
            auto n = d.name;
            found |= n == current;
            menu.addItem(n, true, n == current, [pick, n] { pick(n); });
        }
        if (!found && current.isNotEmpty() && current != "none") menu.addItem(current + "  (not connected)", false, true, [] {});
        menu.showMenuAsync(juce::PopupMenu::Options().withMousePosition());
    }

    bool press(Pt pt, Rect r, const PointerInfo&) override { return row(0, r).contains(pt) || row(1, r).contains(pt); }
    void release(Pt pt, Rect r, const PointerInfo& info) override {
        if (info.moved) return;
        for (int k = 0; k < 2; ++k) if (row(k, r).contains(pt)) { showDevices(k == 0); return; }
    }
};

std::unique_ptr<NativeDisplay> makeMIDIDisplay(AppModel& m, const PatchNode& n, const ModuleSpec& s) {
    return std::make_unique<MIDIBoxDisplay>(m, n, s);
}

} // namespace pn
