// plugin box (Plugin.swift): a VST3 plugin, loaded with JUCE's plugin hosting.
#include "ModulesPlugin.h"

namespace pn {

namespace {
juce::AudioPluginFormatManager& formats() {
    static juce::AudioPluginFormatManager m;
    static bool ready = false;
    if (!ready) {
        ready = true;
       #if JUCE_PLUGINHOST_VST3
        m.addFormat(new juce::VST3PluginFormat());
       #endif
    }
    return m;
}
}

namespace PluginCatalog {

std::vector<PluginInfo> scan() {
    std::vector<PluginInfo> out;
   #if JUCE_PLUGINHOST_VST3
    juce::VST3PluginFormat vst3;
    std::set<juce::String> seen;
    for (auto& path : vst3.searchPathsForPlugins(vst3.getDefaultLocationsToSearch(), true, false)) {
        juce::File f(path);
        auto name = f.getFileNameWithoutExtension();
        if (!seen.insert(name).second) continue;
        // the company: the folder it sits in, when it isn't the VST3 folder itself
        auto parent = f.getParentDirectory().getFileName();
        juce::String vendor = parent.equalsIgnoreCase("VST3") ? juce::String() : parent;
        out.push_back({ "vst3:" + path, name, vendor, "VST3", false });
    }
   #endif
    std::sort(out.begin(), out.end(), [](const PluginInfo& a, const PluginInfo& b) {
        if (a.vendor.compareIgnoreCase(b.vendor) != 0) return a.vendor.compareIgnoreCase(b.vendor) < 0;
        return a.name.compareIgnoreCase(b.name) < 0;
    });
    return out;
}

std::vector<float> codes(const juce::String& s) {
    std::vector<float> v;
    auto u = s.toStdString();
    for (unsigned char c : u) v.push_back(float(c));
    return v;
}
juce::String text(const std::vector<float>& v) {
    std::string s;
    for (float f : v) s += char(uint8_t(std::clamp(int(f), 0, 255)));
    return juce::String::fromUTF8(s.c_str(), int(s.size()));
}
std::vector<float> pack(const juce::MemoryBlock& d) {
    std::vector<float> out { float(d.getSize()) };
    auto* b = static_cast<const uint8_t*>(d.getData());
    size_t n = d.getSize();
    for (size_t i = 0; i < n; i += 3) {
        uint32_t x = b[i] | (i + 1 < n ? uint32_t(b[i + 1]) << 8 : 0u) | (i + 2 < n ? uint32_t(b[i + 2]) << 16 : 0u);
        out.push_back(float(x));
    }
    return out;
}
bool unpack(const std::vector<float>& v, juce::MemoryBlock& out) {
    if (v.empty() || !std::isfinite(v[0]) || v[0] < 0) return false;
    size_t n = size_t(v[0]);
    if (v.size() < 1 + (n + 2) / 3) return false;
    out.setSize(n);
    auto* b = static_cast<uint8_t*>(out.getData());
    for (size_t k = 0; k < n; ++k) b[k] = uint8_t((uint32_t(std::max(v[1 + k / 3], 0.0f)) >> (8 * (k % 3))) & 0xFF);
    return true;
}

} // namespace PluginCatalog

// the state, tagged so a Mac state (an Audio Unit's or the Mac VST3 host's) is never handed to this one
static const char* kTag = "PNJ1";

PluginNode::PluginNode(const ModuleSpec& s, double sr) : DSPNode(s, sr) {
    for (int k = 0; k < PluginLayout::macros; ++k) { map[size_t(k)] = k; sent[size_t(k)] = -1; }
    held.fill(-1);
    buffer.setSize(2, kMaxBlock);
    midi.ensureSize(2048);
}

PluginNode::~PluginNode() { swapIn(nullptr); }

std::map<std::string, std::vector<float>> PluginNode::defaultData() const {
    return { { "plugin", {} }, { "pname", {} }, { "state", {} }, { "map", { 0, 1, 2, 3 } } };
}

void PluginNode::setData(const std::string& key, const std::vector<float>& values) {
    if (key == "plugin") {
        auto id = PluginCatalog::text(values);
        if (id == requested) return;
        requested = id;
        open(id);
    } else if (key == "pname") {
        auto was = savedName;
        savedName = PluginCatalog::text(values);
        // the name came after the plugin it names, which wasn't here: try the one of that name now
        if (savedName != was && requested.isNotEmpty() && !instance && status.isNotEmpty()) open(requested);
    } else if (key == "state") {
        if (values == applied) return;
        juce::MemoryBlock mb;
        if (instance && values.size() > 1 && PluginCatalog::unpack(values, mb)) {
            if (mb.getSize() > 4 && memcmp(mb.getData(), kTag, 4) == 0)
                instance->setStateInformation(static_cast<const char*>(mb.getData()) + 4, int(mb.getSize() - 4));
            applied = values; pendingState.clear();
        } else {
            pendingState = values;
        }
    } else if (key == "map") {
        for (int k = 0; k < PluginLayout::macros; ++k) { map[size_t(k)] = k < int(values.size()) ? int(values[size_t(k)]) : -1; sent[size_t(k)] = -1; }
        ++generation;
    }
}

void PluginNode::open(const juce::String& id) {
    swapIn(nullptr);
    pluginID = id; status = {}; ++generation;
    if (id.isEmpty()) return;
    juce::String path = id.startsWith("vst3:") ? id.substring(5) : juce::String();
    // not here (a patch from another computer): the plugin of the same name, if there is one
    if (path.isEmpty() || !juce::File(path).exists()) {
        auto want = savedName;
        path = {};
        for (auto& p : PluginCatalog::scan()) if (p.name == want) { path = p.id.substring(5); break; }
        if (path.isEmpty()) { status = "not installed here"; ++generation; return; }
    }
    juce::OwnedArray<juce::PluginDescription> types;
    for (auto* f : formats().getFormats()) f->findAllTypesForFile(types, path);
    if (types.isEmpty()) { status = "couldn't read the plugin"; ++generation; return; }
    juce::String err;
    auto p = formats().createPluginInstance(*types[0], sampleRate, kMaxBlock, err);
    if (!p) { status = err.isEmpty() ? juce::String("couldn't open the plugin") : err; ++generation; return; }
    // stereo in (effects) and stereo out
    auto layout = p->getBusesLayout();
    if (layout.inputBuses.size() > 0) layout.inputBuses.getReference(0) = juce::AudioChannelSet::stereo();
    if (layout.outputBuses.size() > 0) layout.outputBuses.getReference(0) = juce::AudioChannelSet::stereo();
    p->setBusesLayout(layout);
    p->setPlayHead(this);
    p->prepareToPlay(sampleRate, kMaxBlock);
    buffer.setSize(std::max({ 2, p->getTotalNumInputChannels(), p->getTotalNumOutputChannels() }), kMaxBlock);
    automatable.clear();
    for (auto* prm : p->getParameters()) if (prm->isAutomatable()) automatable.push_back(prm);
    if (pendingState.size() > 1) {
        juce::MemoryBlock mb;
        if (PluginCatalog::unpack(pendingState, mb) && mb.getSize() > 4 && memcmp(mb.getData(), kTag, 4) == 0)
            p->setStateInformation(static_cast<const char*>(mb.getData()) + 4, int(mb.getSize() - 4));
        applied = pendingState;
    }
    pendingState.clear();
    for (int k = 0; k < PluginLayout::macros; ++k) {
        int i = map[size_t(k)];
        if (i >= 0 && i < int(automatable.size())) base[size_t(PluginLayout::firstMacro + k)] = automatable[size_t(i)]->getValue();
        sent[size_t(k)] = base[size_t(PluginLayout::firstMacro + k)];
    }
    swapIn(std::move(p));
    ++generation;
}

void PluginNode::swapIn(std::unique_ptr<juce::AudioPluginInstance> p) {
    std::unique_ptr<juce::AudioPluginInstance> old;
    {
        const juce::SpinLock::ScopedLockType sl(lock);
        old = std::move(instance);
        instance = std::move(p);
        high.fill(false); held.fill(-1);
    }
    if (old) old->releaseResources();
}

std::optional<std::vector<float>> PluginNode::captureState() {
    if (!instance) return std::nullopt;
    juce::MemoryBlock mb;
    instance->getStateInformation(mb);
    juce::MemoryBlock tagged(kTag, 4);
    tagged.append(mb.getData(), mb.getSize());
    applied = PluginCatalog::pack(tagged);
    return applied;
}

std::optional<float> PluginNode::knobValue(int i) {
    if (i < 0 || i >= int(automatable.size())) return std::nullopt;
    return automatable[size_t(i)]->getValue();
}

juce::Optional<juce::AudioPlayHead::PositionInfo> PluginNode::getPosition() const {
    PositionInfo info;
    info.setBpm(bpm);
    info.setPpqPosition(beat);
    info.setPpqPositionOfLastBarStart(std::floor(beat / 4) * 4);
    info.setTimeSignature(juce::AudioPlayHead::TimeSignature { 4, 4 });
    info.setIsPlaying(playing);
    info.setTimeInSamples(samplePos);
    return info;
}

void PluginNode::process(int frames, const float* const* in, uint64_t con, ProcessContext& ctx) {
    float* oL = out(0); float* oR = out(1);
    const juce::SpinLock::ScopedTryLockType sl(lock);
    bool hasL = isConnected(con, 0), hasR = isConnected(con, 1);
    const float* inL = hasL ? in[0] : (hasR ? in[1] : zero);
    const float* inR = hasR ? in[1] : inL;
    if (!sl.isLocked() || !instance) {
        for (int i = 0; i < frames; ++i) { oL[i] = inL[i]; oR[i] = inR[i]; }
        readouts[0] = 0;
        return;
    }
    auto* p = instance.get();
    midi.clear();
    bool hasPitch = isConnected(con, 2), hasGate = isConnected(con, 3), hasVel = isConnected(con, 4);
    int ng = hasGate ? inVoices[3] : 0, np = hasPitch ? inVoices[2] : 1, nv = hasVel ? inVoices[4] : 1;
    for (int v = 0; v < kMaxVoices; ++v) {
        auto& h = held[size_t(v)];
        if (v >= ng) {
            if (h >= 0) { midi.addEvent(juce::MidiMessage::noteOff(1, h), 0); h = -1; }
            high[size_t(v)] = false;
            continue;
        }
        const float* g = voice(in[3], v), * pin = voice(in[2], std::min(v, np - 1)), * vin = voice(in[4], std::min(v, nv - 1));
        for (int i = 0; i < frames; ++i) {
            float x = g[i];
            if (!high[size_t(v)] && x > 0.2f) {
                high[size_t(v)] = true;
                if (h >= 0) { midi.addEvent(juce::MidiMessage::noteOff(1, h), i); h = -1; }
                float vel = hasVel ? std::clamp(vin[i], 0.0f, 1.0f) : 0.8f;
                if (vel > 0) {
                    int n = std::clamp(int(std::round(60 + (hasPitch ? cvSemitones(pin[i]) : 0.0f))), 0, 127);
                    midi.addEvent(juce::MidiMessage::noteOn(1, n, vel), i);
                    h = n;
                }
            } else if (high[size_t(v)] && x < 0.1f) {
                high[size_t(v)] = false;
                if (h >= 0) { midi.addEvent(juce::MidiMessage::noteOff(1, h), i); h = -1; }
            }
        }
    }
    for (int k = 0; k < PluginLayout::macros; ++k) {
        int i = map[size_t(k)];
        if (i < 0 || i >= int(automatable.size())) continue;
        float v = params[size_t(PluginLayout::firstMacro + k)];
        if (std::abs(v - sent[size_t(k)]) > 0.0005f) { automatable[size_t(i)]->setValue(v); sent[size_t(k)] = v; }
    }
    beat = ctx.beat[0]; bpm = ctx.bpm(); playing = ctx.running;
    buffer.clear(0, frames);
    if (p->getTotalNumInputChannels() > 0) {
        buffer.copyFrom(0, 0, inL, frames);
        if (buffer.getNumChannels() > 1) buffer.copyFrom(1, 0, inR, frames);
    }
    juce::AudioBuffer<float> view(buffer.getArrayOfWritePointers(), buffer.getNumChannels(), frames);
    p->processBlock(view, midi);
    samplePos += frames;
    const float* wl = buffer.getReadPointer(0);
    const float* wr = p->getTotalNumOutputChannels() > 1 ? buffer.getReadPointer(1) : wl;
    float mix = params[size_t(PluginLayout::mix)], g = std::pow(10.0f, params[size_t(PluginLayout::gain)] / 20);
    float peak = 0;
    for (int i = 0; i < frames; ++i) {
        float l = (inL[i] * (1 - mix) + wl[i] * mix) * g, r = (inR[i] * (1 - mix) + wr[i] * mix) * g;
        if (!std::isfinite(l)) l = 0;
        if (!std::isfinite(r)) r = 0;
        oL[i] = l; oR[i] = r;
        peak = std::max({ peak, std::abs(l), std::abs(r) });
    }
    readouts[0] = std::max(peak, readouts[0] * 0.95f);
}

Factory factoryPlugin(const std::string& k) {
    if (k == "plugin") return make<PluginNode>();
    return nullptr;
}

} // namespace pn
