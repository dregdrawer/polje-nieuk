// MIDI devices, the midi box and the note sender — ports of MIDIIO.swift and MIDINodes.swift.
#include "ModulesMIDI.h"
#include "ModulesShared.h"

namespace pn {

static const int kDrumNotes[8] = { 36, 38, 42, 46, 45, 39, 49, 51 };

// ---------------------------------------------------------------- hub

MidiHub& MidiHub::shared() { static MidiHub* h = new MidiHub(); return *h; }   // never destroyed: shutdown() closes the devices

void MidiHub::shutdown() {
    if (!started) return;
    listConnection.reset();
    for (auto& i : ins) i.dev->stop();
    { juce::SpinLock::ScopedLockType l(inLock); ins.clear(); }
    std::vector<std::unique_ptr<Out>> old;
    { juce::SpinLock::ScopedLockType l(outLock); outs.swap(old); }
    old.clear();
    started = false;
}

int32_t MidiHub::idFor(const juce::String& identifier) {
    auto h = int32_t(identifier.hashCode() & 0x7FFFFFFF);
    return h == 0 ? 1 : h;
}

void MidiHub::start() {
    if (started) return;
    started = true;
    listConnection = std::make_unique<juce::MidiDeviceListConnection>(
        juce::MidiDeviceListConnection::make([this] { rescan(); }));
    rescan();
}

void MidiHub::rescan() {
    if (!started) return;
    for (auto& i : ins) i.dev->stop();
    ins.clear();
    std::vector<Device> srcs, dsts;
    std::vector<int32_t> off;
    for (auto& d : juce::MidiInput::getAvailableDevices()) {
        auto id = idFor(d.identifier);
        srcs.push_back({ id, d.name, d.identifier });
        if (offIn.count(d.name)) off.push_back(id);
        if (auto dev = juce::MidiInput::openDevice(d.identifier, this)) { dev->start(); ins.push_back({ std::move(dev), id }); }
    }
    std::vector<std::unique_ptr<Out>> table;
    for (auto& d : juce::MidiOutput::getAvailableDevices()) {
        auto id = idFor(d.identifier);
        dsts.push_back({ id, d.name, d.identifier });
        if (auto dev = juce::MidiOutput::openDevice(d.identifier)) {
            auto o = std::make_unique<Out>();
            o->dev = std::move(dev); o->id = id; o->on = !offOut.count(d.name);
            o->buffer.ensureSize(8192);
            o->dev->startBackgroundThread();
            table.push_back(std::move(o));
        }
    }
    sources = srcs; destinations = dsts;
    { juce::SpinLock::ScopedLockType l(inLock); offInIDs = off; }
    { juce::SpinLock::ScopedLockType l(outLock); outs.swap(table); }
    table.clear();                                   // the old ones close here, outside the lock
    for (auto* b : boxes) b->resolve();
    if (onChange) onChange();
}

int32_t MidiHub::sourceID(const juce::String& name) const {
    if (name.isEmpty()) return 0;
    for (auto& d : sources) if (d.name == name) return d.id;
    return -1;
}
int32_t MidiHub::destinationID(const juce::String& name) const {
    if (name == "none") return -1;
    if (name.isEmpty()) return 0;
    for (auto& d : destinations) if (d.name == name) return d.id;
    return -1;
}
void MidiHub::registerBox(MIDIBoxNode* n) { if (std::find(boxes.begin(), boxes.end(), n) == boxes.end()) boxes.push_back(n); }
void MidiHub::unregisterBox(MIDIBoxNode* n) { boxes.erase(std::remove(boxes.begin(), boxes.end(), n), boxes.end()); }

void MidiHub::handleIncomingMidiMessage(juce::MidiInput* source, const juce::MidiMessage& m) {
    auto raw = m.getRawData();
    int size = m.getRawDataSize();
    if (size < 1) return;
    uint8_t s = raw[0];
    bool channel = s >= 0x80 && s < 0xF0, realtime = s == 0xF8 || s == 0xFA || s == 0xFB || s == 0xFC;
    if (!channel && !realtime) return;
    juce::SpinLock::ScopedLockType l(inLock);
    int32_t id = 0;
    for (auto& i : ins) if (i.dev.get() == source) id = i.id;
    bool global = std::find(offInIDs.begin(), offInIDs.end(), id) == offInIDs.end();
    int c = ringCount.load();
    if (c >= ringSize) return;
    ring[size_t(c)] = { id, s, uint8_t(size > 1 ? raw[1] & 0x7F : 0), uint8_t(size > 2 ? raw[2] & 0x7F : 0), global, 0 };
    ringCount.store(c + 1);
}

void MidiHub::pull(ProcessContext& ctx) {
    ctx.midiInCount = 0;
    if (!started || ringCount.load() == 0) return;
    juce::SpinLock::ScopedTryLockType l(inLock);
    if (!l.isLocked()) return;
    int n = std::min(ringCount.load(), ProcessContext::midiCapacity);
    std::copy(ring.begin(), ring.begin() + n, ctx.midiIn);
    ctx.midiInCount = n;
    ringCount.store(0);
}

void MidiHub::push(ProcessContext& ctx, double sampleRate) {
    int n = ctx.midiOutCount;
    if (n == 0) return;
    if (!started) { ctx.midiOutCount = 0; return; }
    juce::SpinLock::ScopedTryLockType l(outLock);
    if (!l.isLocked()) { for (int k = 0; k < n; ++k) ctx.midiOut[k].offset = 0; return; }   // devices changing: next buffer
    for (int k = 0; k < n; ++k) order[size_t(k)] = k;
    std::stable_sort(order.begin(), order.begin() + n, [&](int a, int b) { return ctx.midiOut[a].offset < ctx.midiOut[b].offset; });
    double now = juce::Time::getMillisecondCounterHiRes();
    for (auto& o : outs) {
        o->buffer.clear();
        for (int k = 0; k < n; ++k) {
            auto& m = ctx.midiOut[order[size_t(k)]];
            if (!(m.port == 0 ? o->on : m.port == o->id)) continue;
            uint8_t bytes[3] = { m.status, m.d1, m.d2 };
            int len = m.status >= 0xF0 ? 1 : ((m.status & 0xF0) == 0xC0 || (m.status & 0xF0) == 0xD0 ? 2 : 3);
            o->buffer.addEvent(bytes, len, int(m.offset));
        }
        if (!o->buffer.isEmpty()) o->dev->sendBlockOfMessages(o->buffer, now, sampleRate);
    }
    ctx.midiOutCount = 0;
}

// ---------------------------------------------------------------- note sender

MIDINoteSender::MIDINoteSender(const ModuleSpec& s) {
    auto find = [&](const char* n) { auto it = std::find(s.outputs.begin(), s.outputs.end(), n); return it == s.outputs.end() ? -1 : int(it - s.outputs.begin()); };
    pitchOut = find("pitch"); gateOut = find("gate"); velOut = find("vel");
    triggers = gateOut < 0;
}

void MIDINoteSender::off(int v, int i, ProcessContext& ctx) {
    if (held[size_t(v)] >= 0) { ctx.sendMIDI(uint8_t(0x80 | channel), uint8_t(held[size_t(v)]), 0, i, port); held[size_t(v)] = -1; }
}
void MIDINoteSender::retune(int ch, int32_t p, ProcessContext& ctx) {
    if (ch == channel && p == port) return;
    if (channel >= 0) for (int v = 0; v < 8; ++v) { off(v, 0, ctx); high[size_t(v)] = false; }
    channel = ch; port = p;
}

void MIDINoteSender::run(DSPNode& node, int ch, int frames, ProcessContext& ctx) {
    retune(ch, 0, ctx);
    if (ch < 0 || ch >= 16) return;
    if (triggers) {
        for (int k = 0; k < std::min(int(node.outputs.size()), 8); ++k) {
            const float* o = node.out(k);
            for (int i = 0; i < frames; ++i) {
                if (!high[size_t(k)] && o[i] > 0.2f) {
                    high[size_t(k)] = true; off(k, i, ctx);
                    ctx.sendMIDI(uint8_t(0x90 | ch), uint8_t(kDrumNotes[k]), 100, i);
                    held[size_t(k)] = kDrumNotes[k];
                } else if (high[size_t(k)] && o[i] < 0.1f) { high[size_t(k)] = false; off(k, i, ctx); }
            }
        }
        return;
    }
    notes(node.out(gateOut), node.outVoices[size_t(gateOut)],
          pitchOut >= 0 ? node.out(pitchOut) : nullptr, pitchOut >= 0 ? node.outVoices[size_t(pitchOut)] : 1,
          velOut >= 0 ? node.out(velOut) : nullptr, velOut >= 0 ? node.outVoices[size_t(velOut)] : 1, frames, ctx);
}

void MIDINoteSender::run(const float* gate, int voices, const float* pitch, int pv, const float* vel, int vv,
                         int ch, int32_t p, int frames, ProcessContext& ctx) {
    retune(ch, p, ctx);
    if (ch < 0 || ch >= 16 || p < 0) return;
    notes(gate, voices, pitch, pv, vel, vv, frames, ctx);
}

void MIDINoteSender::notes(const float* gate, int voices, const float* pitch, int pv, const float* vel, int vv, int frames, ProcessContext& ctx) {
    for (int v = 0; v < kMaxVoices; ++v) {
        if (v >= voices) { off(v, 0, ctx); high[size_t(v)] = false; continue; }
        const float* g = gate + v * kMaxBlock;
        const float* pin = pitch ? pitch + std::min(v, std::max(pv, 1) - 1) * kMaxBlock : nullptr;
        const float* vin = vel ? vel + std::min(v, std::max(vv, 1) - 1) * kMaxBlock : nullptr;
        for (int i = 0; i < frames; ++i) {
            float x = g[i];
            if (!high[size_t(v)] && x > 0.2f) {
                high[size_t(v)] = true; off(v, i, ctx);
                float velocity = vin ? std::clamp(vin[i], 0.0f, 1.0f) : 0.8f;
                if (velocity > 0) {
                    int n = int(std::clamp(std::round(60 + (pin ? cvSemitones(pin[i]) : 0.0f)), 0.0f, 127.0f));
                    ctx.sendMIDI(uint8_t(0x90 | channel), uint8_t(n), uint8_t(std::clamp(int(std::round(velocity * 127)), 1, 127)), i, port);
                    held[size_t(v)] = n;
                }
            } else if (high[size_t(v)] && x < 0.1f) { high[size_t(v)] = false; off(v, i, ctx); }
        }
    }
}

// ---------------------------------------------------------------- midi box

std::vector<float> MIDIBoxLayout::codes(const juce::String& s) {
    std::vector<float> v;
    auto u = s.toUTF8();
    for (auto* p = u.getAddress(); *p; ++p) v.push_back(float(uint8_t(*p)));
    return v;
}
juce::String MIDIBoxLayout::text(const std::vector<float>& v) {
    std::string s;
    for (float f : v) s.push_back(char(uint8_t(std::clamp(int(f), 0, 255))));
    return juce::String::fromUTF8(s.data(), int(s.size()));
}

MIDIBoxNode::MIDIBoxNode(const ModuleSpec& s, double sr) : DSPNode(s, sr) {}
MIDIBoxNode::~MIDIBoxNode() { MidiHub::shared().unregisterBox(this); }

void MIDIBoxNode::setData(const std::string& key, const std::vector<float>& values) {
    if (key == MIDIBoxLayout::inKey) inName = MIDIBoxLayout::text(values);
    else if (key == MIDIBoxLayout::outKey) outName = MIDIBoxLayout::text(values);
    else return;
    MidiHub::shared().registerBox(this);
    resolve();
}
void MIDIBoxNode::resolve() {
    inDev = MidiHub::shared().sourceID(inName);
    outDev = MidiHub::shared().destinationID(outName);
}

void MIDIBoxNode::noteOn(int n, float vel, int poly) {
    if (poly <= 1) {
        int k = 0;
        while (k < depth && stack[size_t(k)] != n) ++k;
        if (k < depth) { for (int j = k; j < depth - 1; ++j) { stack[size_t(j)] = stack[size_t(j + 1)]; stackVel[size_t(j)] = stackVel[size_t(j + 1)]; } --depth; }
        if (depth == int(stack.size())) { for (int j = 0; j < depth - 1; ++j) { stack[size_t(j)] = stack[size_t(j + 1)]; stackVel[size_t(j)] = stackVel[size_t(j + 1)]; } --depth; }
        if (depth > 0) vDip[0] = 48;
        stack[size_t(depth)] = n; stackVel[size_t(depth)] = vel; ++depth;
        return;
    }
    ++age;
    int pick = -1;
    for (int v = 0; v < poly; ++v) if (vNote[size_t(v)] == n) pick = v;
    if (pick < 0) for (int v = 0; v < poly; ++v) if (vNote[size_t(v)] < 0) { pick = v; break; }
    if (pick < 0) { pick = 0; for (int v = 1; v < poly; ++v) if (vAge[size_t(v)] < vAge[size_t(pick)]) pick = v; }
    if (vNote[size_t(pick)] >= 0) vDip[size_t(pick)] = 48;
    vNote[size_t(pick)] = n; vLast[size_t(pick)] = n; vVel[size_t(pick)] = vel; vAge[size_t(pick)] = age;
}

void MIDIBoxNode::noteOff(int n, int poly) {
    if (poly <= 1) {
        int k = 0;
        while (k < depth && stack[size_t(k)] != n) ++k;
        if (k >= depth) return;
        for (int j = k; j < depth - 1; ++j) { stack[size_t(j)] = stack[size_t(j + 1)]; stackVel[size_t(j)] = stackVel[size_t(j + 1)]; }
        --depth;
        return;
    }
    for (int v = 0; v < kMaxVoices; ++v) if (vNote[size_t(v)] == n) vNote[size_t(v)] = -1;
}

void MIDIBoxNode::process(int frames, const float* const* in, uint64_t con, ProcessContext& ctx) {
    using namespace MIDIBoxLayout;
    int inChannel = int(std::round(params[inCh])) - 1;
    int outChannel = int(std::round(params[outCh]));
    int poly = clampIndex(params[voices], 4) + 1;
    float range = params[MIDIBoxLayout::bend];
    int ccNum = int(std::round(params[cc]));
    int32_t dev = inDev.load();
    if (poly == 1) for (int v = 1; v < kMaxVoices; ++v) vNote[size_t(v)] = -1;

    for (int k = 0; k < ctx.midiInCount; ++k) {
        auto& m = ctx.midiIn[k];
        if (!(dev == 0 ? m.global : m.port == dev)) continue;
        uint8_t s = m.status;
        if (s >= 0xF8 || s == 0xFA) {
            if (s == 0xF8) clockLeft = std::max(16, int(sampleRate * 0.002));
            else if (s == 0xFA || s == 0xFB) resetLeft = std::max(16, int(sampleRate * 0.002));
            continue;
        }
        if (s < 0x80 || s >= 0xF0) continue;
        if (inChannel >= 0 && int(s & 0x0F) != inChannel) continue;
        inBlink = 8;
        switch (s & 0xF0) {
            case 0x90: if (m.d2 > 0) { noteOn(m.d1, float(m.d2) / 127, poly); break; } noteOff(m.d1, poly); break;
            case 0x80: noteOff(m.d1, poly); break;
            case 0xB0:
                if (int(m.d1) == ccNum) ccValue = float(m.d2) / 127;
                if (m.d1 == 123 || m.d1 == 120) { depth = 0; vNote.fill(-1); }
                break;
            case 0xE0: bend = (float((int(m.d2) << 7) | int(m.d1)) - 8192) / 8192; break;
            default: break;
        }
    }

    float b = bend * range;
    for (int v = 0; v < poly; ++v) {
        float* p = outVoice(0, v); float* g = outVoice(1, v); float* vo = outVoice(2, v);
        bool on; int note; float vel;
        if (poly == 1) {
            on = depth > 0;
            note = on ? stack[size_t(depth - 1)] : vLast[0];
            vel = on ? stackVel[size_t(depth - 1)] : 0;
            if (on) vLast[0] = note;
        } else { on = vNote[size_t(v)] >= 0; note = vLast[size_t(v)]; vel = on ? vVel[size_t(v)] : 0; }
        float pitch = pitchCV(float(note - 60) + b);
        for (int i = 0; i < frames; ++i) {
            p[i] = pitch;
            g[i] = on && vDip[size_t(v)] == 0 ? kGateHigh : 0.0f;
            vo[i] = vel;
            if (vDip[size_t(v)] > 0) --vDip[size_t(v)];
        }
    }
    for (int k = 0; k < 3; ++k) outVoices[size_t(k)] = poly;
    float* ccO = out(3); float* ck = out(4); float* rs = out(5);
    for (int i = 0; i < frames; ++i) {
        ccO[i] = ccValue;
        ck[i] = clockLeft > 0 ? kGateHigh : 0.0f;
        rs[i] = resetLeft > 0 ? kGateHigh : 0.0f;
        if (clockLeft > 0) --clockLeft;
        if (resetLeft > 0) --resetLeft;
    }

    int32_t port = outDev.load();
    int before = ctx.midiOutCount;
    bool hp = isConnected(con, 0), hv = isConnected(con, 2);
    sender.run(in[1], isConnected(con, 1) ? inVoices[1] : 0, hp ? in[0] : nullptr, inVoices[0], hv ? in[2] : nullptr, inVoices[2],
               outChannel, port, frames, ctx);
    if (isConnected(con, 3) && port >= 0) {
        float x = in[3][frames - 1];
        int v = int(std::round(std::clamp(std::isfinite(x) ? x : 0.0f, 0.0f, 1.0f) * 127));
        if (v != lastCC) { ctx.sendMIDI(uint8_t(0xB0 | outChannel), uint8_t(ccNum & 0x7F), uint8_t(v), frames - 1, port); lastCC = v; }
    }
    if (params[clock] > 0.5f && port >= 0) {
        if (ctx.running && !wasRunning) { ctx.sendMIDI(0xFA, 0, 0, 0, port); lastTick = -1; }
        if (!ctx.running && wasRunning) ctx.sendMIDI(0xFC, 0, 0, 0, port);
        if (ctx.running)
            for (int i = 0; i < frames; ++i) {
                double t = std::floor(ctx.beat[i] * 24);
                if (ctx.beat[i] >= 0 && t != lastTick) { ctx.sendMIDI(0xF8, 0, 0, i, port); lastTick = t; }
            }
    }
    wasRunning = ctx.running;
    if (ctx.midiOutCount > before) outBlink = 8;

    int heldCount = 0;
    if (poly == 1) heldCount = std::min(depth, 1); else for (int v = 0; v < poly; ++v) heldCount += vNote[size_t(v)] >= 0 ? 1 : 0;
    readouts[0] = float(heldCount);
    readouts[1] = inBlink > 0 ? 1.0f : 0.0f;
    readouts[2] = outBlink > 0 ? 1.0f : 0.0f;
    readouts[3] = float((inDev.load() < 0 ? 1 : 0) + (outDev.load() < 0 && outName != "none" ? 2 : 0));
    if (inBlink > 0) --inBlink;
    if (outBlink > 0) --outBlink;
}

Factory factoryMIDI(const std::string& k) {
    if (k == "midi") return make<MIDIBoxNode>();
    return nullptr;
}

} // namespace pn
