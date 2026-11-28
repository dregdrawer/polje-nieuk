// pnrender <patch.json> <seconds>: renders a patch offline (no input) and prints every outlet's RMS.
// The Mac app's selftest has the same mode (--render), so the two engines can be compared number for number.
#include "Engine.h"
#include "ModulesMIDI.h"
#include <cstdio>

// pnrender --midi (Mac / Linux, where JUCE can make virtual ports): the JUCE MIDI path end to end.
struct Catcher : juce::MidiInputCallback {
    juce::CriticalSection lock;
    std::vector<std::array<int, 3>> got;
    void handleIncomingMidiMessage(juce::MidiInput*, const juce::MidiMessage& m) override {
        auto* r = m.getRawData();
        const juce::ScopedLock l(lock);
        got.push_back({ r[0], m.getRawDataSize() > 1 ? r[1] : 0, m.getRawDataSize() > 2 ? r[2] : 0 });
    }
    bool has(int s, int d1 = -1) { const juce::ScopedLock l(lock); for (auto& g : got) if (g[0] == s && (d1 < 0 || g[1] == d1)) return true; return false; }
};

static int midiTest() {
#if JUCE_WINDOWS
    std::printf("no virtual MIDI ports on Windows\n");
    return 0;
#else
    std::setvbuf(stdout, nullptr, _IONBF, 0);
    bool ok = true;
    auto expect = [&](bool c, const char* m) { std::printf(c ? "  PASS  %s\n" : "  FAIL  %s\n", m); if (!c) ok = false; };
    auto kb = juce::MidiOutput::createNewDevice("pn juce keyboard");
    Catcher catcher;
    auto synth = juce::MidiInput::createNewDevice("pn juce synth", &catcher);
    if (!kb || !synth) { std::printf("no virtual MIDI ports here\n"); return 0; }
    synth->start();
    auto& hub = pn::MidiHub::shared();
    for (auto& d : juce::MidiOutput::getAvailableDevices()) if (d.name != "pn juce synth") hub.offOut.insert(d.name);
    hub.start();
    juce::Thread::sleep(300); hub.rescan();
    bool sees = false; for (auto& d : hub.sources) sees |= d.name.contains("pn juce keyboard");
    expect(sees, "the hub sees the test keyboard");
    pn::Patch p;
    pn::PatchNode keys; keys.id = juce::Uuid().toString(); keys.kind = "keys"; keys.params["midiout"] = 1;
    pn::PatchNode box; box.id = juce::Uuid().toString(); box.kind = "midi"; box.params["voices"] = 3; box.params["outch"] = 2;
    pn::PatchNode seq; seq.id = juce::Uuid().toString(); seq.kind = "seq"; seq.params["midiout"] = 2;
    p.nodes = { keys, box, seq };
    pn::PatchCable c1; c1.id = juce::Uuid().toString(); c1.fromNode = keys.id; c1.fromPort = 0; c1.toNode = box.id; c1.toPort = 0;
    pn::PatchCable c2 = c1; c2.id = juce::Uuid().toString(); c2.fromPort = 1; c2.toPort = 1;
    p.cables = { c1, c2 };
    pn::GraphHost h(48000);
    h.load(p);
    std::vector<float> o0(256), o1(256);
    float* op[2] = { o0.data(), o1.data() };
    auto run = [&](int n) { for (int b = 0; b < n; ++b) h.process(256, nullptr, 0, op, 2); };
    run(4); juce::Thread::sleep(100);
    kb->sendMessageNow(juce::MidiMessage::noteOn(1, 64, uint8_t(100)));
    kb->sendMessageNow(juce::MidiMessage::noteOn(1, 67, uint8_t(90)));
    juce::Thread::sleep(100); run(2); juce::Thread::sleep(150);
    auto* k = h.node(keys.id); auto* b = h.node(box.id);
    expect(k->outputs[1][63] > 0.4f, "keys: a MIDI note opens the gate");
    expect(std::abs(k->outputs[0][63] - 7.0f / 120) < 1e-4f, "keys: the newest note (G) plays");
    expect(std::abs(k->outputs[2][63] - 90.0f / 127) < 0.01f, "keys: its velocity comes through");
    expect(b->outVoices[1] == 4 && b->outVoice(1, 0)[63] > 0.4f && b->outVoice(1, 1)[63] > 0.4f, "midi box: both notes on two voices");
    expect(std::abs(b->outVoice(0, 0)[63] - 4.0f / 120) < 1e-4f && std::abs(b->outVoice(0, 1)[63] - 7.0f / 120) < 1e-4f, "midi box: E and G");
    expect(catcher.has(0x90, 67), "keys midi out: note on G, channel 1");
    expect(catcher.has(0x92, 67), "midi box out: the patched note on channel 3");
    kb->sendMessageNow(juce::MidiMessage::noteOff(1, 67)); kb->sendMessageNow(juce::MidiMessage::noteOff(1, 64));
    juce::Thread::sleep(100); run(30); juce::Thread::sleep(150);
    expect(k->outputs[1][63] < 0.1f, "keys: gate closes when the notes are let go");
    expect(catcher.has(0x80, 67), "keys midi out: note off");
    expect(catcher.has(0x91) && catcher.has(0x81), "seq midi out: notes on and off, channel 2");
    synth->stop();
    hub.shutdown();
    std::printf(ok ? "MIDI OK\n" : "MIDI FAILED\n");
    return ok ? 0 : 1;
#endif
}

int main(int argc, char** argv) {
    juce::ScopedJuceInitialiser_GUI init;
    if (argc >= 2 && juce::String(argv[1]) == "--midi") return midiTest();
    if (argc < 3) { std::printf("usage: pnrender patch.json seconds\n"); return 1; }
    auto json = juce::File(juce::String::fromUTF8(argv[1])).loadFileAsString();
    auto parsed = pn::Patch::fromJSON(json);
    if (!parsed) { std::printf("can't read patch\n"); return 1; }
    auto p = parsed->migrated();
    double seconds = std::atof(argv[2]);
    pn::GraphHost h(48000);
    h.load(p);
    const int block = 256, chans = 8;
    std::vector<std::vector<float>> ins(chans, std::vector<float>(block, 0.0f)), outs(chans, std::vector<float>(block, 0.0f));
    std::vector<const float*> ip; std::vector<float*> op;
    for (auto& b : ins) ip.push_back(b.data());
    for (auto& b : outs) op.push_back(b.data());
    std::vector<std::vector<double>> sums;
    for (auto& n : p.nodes) { auto* d = h.node(n.id); sums.emplace_back(d ? d->outputs.size() : 0, 0.0); }
    int blocks = int(seconds * 48000) / block, total = 0;
    for (int b = 0; b < blocks; ++b) {
        for (auto& o : outs) std::fill(o.begin(), o.end(), 0.0f);
        h.process(block, ip.data(), chans, op.data(), chans);
        for (size_t i = 0; i < p.nodes.size(); ++i)
            if (auto* d = h.node(p.nodes[i].id))
                for (size_t k = 0; k < d->outputs.size(); ++k)
                    for (int s = 0; s < 64; ++s) { double v = d->outputs[k][size_t(s)]; sums[i][k] += v * v; }
        total += 64;
    }
    for (size_t i = 0; i < p.nodes.size(); ++i) {
        std::printf("%d %s", int(i), p.nodes[i].kind.c_str());
        for (double s : sums[i]) std::printf(" %.4f", std::sqrt(s / std::max(total, 1)));
        std::printf("\n");
    }
    return 0;
}
