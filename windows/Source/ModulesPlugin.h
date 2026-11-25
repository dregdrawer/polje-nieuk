// plugin: hosts a VST3 plugin in a box (Plugin.swift; the Mac / iPad apps also load Audio Units there).
#pragma once
#include "Modules.h"

namespace pn {

namespace PluginLayout {
    constexpr int macros = 4, mix = 0, gain = 1, firstMacro = 2;
}

struct PluginInfo { juce::String id, name, vendor, format; bool instrument = false; };

namespace PluginCatalog {
    /// Installed VST3 plugins (the bundle files; nothing is loaded).
    std::vector<PluginInfo> scan();
    std::vector<float> codes(const juce::String& s);
    juce::String text(const std::vector<float>& v);
    std::vector<float> pack(const juce::MemoryBlock& d);
    bool unpack(const std::vector<float>& v, juce::MemoryBlock& out);
}

class PluginNode : public DSPNode, private juce::AudioPlayHead {
public:
    PluginNode(const ModuleSpec& s, double sr);
    ~PluginNode() override;
    void process(int frames, const float* const* in, uint64_t con, ProcessContext& ctx) override;
    void setData(const std::string& key, const std::vector<float>& values) override;
    std::map<std::string, std::vector<float>> defaultData() const override;

    // main thread
    juce::AudioPluginInstance* plugin() { return instance.get(); }
    juce::String pluginID, status, savedName;
    int generation = 0;
    std::array<std::atomic<int>, PluginLayout::macros> map;
    std::vector<juce::AudioProcessorParameter*> automatable;     // what a knob can move
    std::optional<std::vector<float>> captureState();
    std::optional<float> knobValue(int param);

private:
    juce::Optional<juce::AudioPlayHead::PositionInfo> getPosition() const override;
    void open(const juce::String& id);
    void swapIn(std::unique_ptr<juce::AudioPluginInstance> p);
    std::unique_ptr<juce::AudioPluginInstance> instance;
    juce::SpinLock lock;
    juce::AudioBuffer<float> buffer;
    juce::MidiBuffer midi;
    std::array<float, PluginLayout::macros> sent {};
    std::array<bool, kMaxVoices> high {};
    std::array<int, kMaxVoices> held {};
    std::vector<float> pendingState, applied;
    juce::String requested;
    double beat = 0, bpm = 120; bool playing = false; int64_t samplePos = 0;
    float zero[kMaxBlock] = {}, wetL[kMaxBlock] = {}, wetR[kMaxBlock] = {};
};

Factory factoryPlugin(const std::string& kind);

} // namespace pn
