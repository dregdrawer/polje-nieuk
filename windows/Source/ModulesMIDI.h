// MIDI: devices in and out (JUCE), the midi box, and the "midi out" channel of keyboards / sequencers.
// A port of MIDIIO.swift and MIDINodes.swift.
#pragma once
#include "Modules.h"

namespace pn {

/// Every MIDI device: what comes in is handed to the graph once per audio buffer, what modules send goes out
/// at the end of it. The top bar's midi menu switches devices on / off; a midi box can pick one for itself.
class MidiHub : private juce::MidiInputCallback {
public:
    static MidiHub& shared();
    struct Device { int32_t id; juce::String name, identifier; };

    // main thread
    void start();
    void rescan();
    /// Closes every device (before JUCE shuts down).
    void shutdown();
    std::vector<Device> sources, destinations;
    std::function<void()> onChange;
    std::set<juce::String> offIn, offOut;           // switched off in the midi menu (by name; the UI saves them)
    bool isOnIn(const juce::String& n) const { return !offIn.count(n); }
    bool isOnOut(const juce::String& n) const { return !offOut.count(n); }
    void setInput(const juce::String& n, bool on) { if (on) offIn.erase(n); else offIn.insert(n); rescan(); }
    void setOutput(const juce::String& n, bool on) { if (on) offOut.erase(n); else offOut.insert(n); rescan(); }
    int32_t sourceID(const juce::String& name) const;
    int32_t destinationID(const juce::String& name) const;
    void registerBox(class MIDIBoxNode* n);
    void unregisterBox(class MIDIBoxNode* n);
    bool started = false;

    // audio thread
    void pull(ProcessContext& ctx);
    void push(ProcessContext& ctx, double sampleRate);

    static int32_t idFor(const juce::String& identifier);

private:
    void handleIncomingMidiMessage(juce::MidiInput* source, const juce::MidiMessage& m) override;
    struct In { std::unique_ptr<juce::MidiInput> dev; int32_t id; };
    struct Out { std::unique_ptr<juce::MidiOutput> dev; int32_t id; bool on; juce::MidiBuffer buffer; };
    std::vector<In> ins;
    std::vector<std::unique_ptr<Out>> outs;
    juce::SpinLock inLock, outLock;
    static constexpr int ringSize = 1024;
    std::array<MidiMsg, ringSize> ring;
    std::atomic<int> ringCount { 0 };
    std::vector<int32_t> offInIDs;
    std::vector<MIDIBoxNode*> boxes;
    std::array<int, ProcessContext::midiCapacity> order {};
    std::unique_ptr<juce::MidiDeviceListConnection> listConnection;
};

/// Plays pitch / gate (and vel) signals — up to four notes on one cable — or trigger outlets as MIDI notes.
class MIDINoteSender {
public:
    explicit MIDINoteSender(const ModuleSpec& s);
    MIDINoteSender(int pitch, int gate, int vel) : pitchOut(pitch), gateOut(gate), velOut(vel), triggers(false) {}
    void run(DSPNode& node, int channel, int frames, ProcessContext& ctx);
    void run(const float* gate, int voices, const float* pitch, int pitchVoices, const float* vel, int velVoices,
             int channel, int32_t port, int frames, ProcessContext& ctx);
private:
    void off(int v, int i, ProcessContext& ctx);
    void retune(int ch, int32_t p, ProcessContext& ctx);
    void notes(const float* gate, int voices, const float* pitch, int pitchVoices, const float* vel, int velVoices, int frames, ProcessContext& ctx);
    int pitchOut, gateOut, velOut;
    bool triggers;
    std::array<bool, 8> high {};
    std::array<int, 8> held { -1, -1, -1, -1, -1, -1, -1, -1 };
    int channel = -1;
    int32_t port = 0;
};

namespace MIDIBoxLayout {
    constexpr int inCh = 0, outCh = 1, voices = 2, bend = 3, cc = 4, clock = 5;
    inline const std::string inKey = "indev", outKey = "outdev";
    std::vector<float> codes(const juce::String& s);
    juce::String text(const std::vector<float>& v);
}

class MIDIBoxNode : public DSPNode {
public:
    MIDIBoxNode(const ModuleSpec& s, double sr);
    ~MIDIBoxNode() override;
    void process(int frames, const float* const* in, uint64_t con, ProcessContext& ctx) override;
    void setData(const std::string& key, const std::vector<float>& values) override;
    std::map<std::string, std::vector<float>> defaultData() const override { return { { MIDIBoxLayout::inKey, {} }, { MIDIBoxLayout::outKey, {} } }; }
    void resolve();
    juce::String inName, outName;              // "" = all devices that are on, "none" = don't send
private:
    void noteOn(int n, float vel, int poly);
    void noteOff(int n, int poly);
    std::atomic<int32_t> inDev { 0 }, outDev { 0 };
    std::array<int, 16> stack {};
    std::array<float, 16> stackVel {};
    int depth = 0;
    std::array<int, kMaxVoices> vNote { -1, -1, -1, -1 }, vLast { 60, 60, 60, 60 }, vAge {}, vDip {};
    std::array<float, kMaxVoices> vVel {};
    int age = 0, clockLeft = 0, resetLeft = 0, lastCC = -1, inBlink = 0, outBlink = 0;
    float bend = 0, ccValue = 0;
    double lastTick = -1;
    bool wasRunning = false;
    MIDINoteSender sender { 0, 1, 2 };
};

Factory factoryMIDI(const std::string& kind);

} // namespace pn
