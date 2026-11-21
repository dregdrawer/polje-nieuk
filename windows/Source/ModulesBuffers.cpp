// rec, looper, grain, sampler — ports of Recorder.swift, Looper.swift, Granulator.swift, Sampler.swift.
#include "Modules.h"
#include "Buffers.h"

namespace pn {

// ---------------------------------------------------------------- audio files

namespace AudioFiles {
std::vector<float> resample(const std::vector<float>& x, double from, double to) {
    if (std::abs(from - to) <= 0.5 || x.empty()) return x;
    double ratio = from / to;
    size_t n = size_t(double(x.size()) / ratio);
    std::vector<float> y(n);
    for (size_t i = 0; i < n; ++i) {
        double p = double(i) * ratio;
        size_t k = size_t(p); float f = float(p - double(k));
        float a = x[std::min(k, x.size() - 1)], b = x[std::min(k + 1, x.size() - 1)];
        y[i] = a + (b - a) * f;
    }
    return y;
}

static juce::AudioFormatManager& formats() {
    static juce::AudioFormatManager m;
    static bool once = [] { m.registerBasicFormats(); return true; }();
    juce::ignoreUnused(once);
    return m;
}

StereoAudio read(const juce::File& f, double sampleRate, double maxSeconds) {
    std::unique_ptr<juce::AudioFormatReader> r(formats().createReaderFor(f));
    if (!r) return {};
    auto frames = (int) std::min<juce::int64>(r->lengthInSamples, juce::int64(maxSeconds * r->sampleRate));
    if (frames <= 0) return {};
    juce::AudioBuffer<float> b(int(std::max(1u, r->numChannels)), frames);
    r->read(&b, 0, frames, 0, true, true);
    std::vector<float> l(b.getReadPointer(0), b.getReadPointer(0) + frames);
    std::vector<float> rr = b.getNumChannels() > 1 ? std::vector<float>(b.getReadPointer(1), b.getReadPointer(1) + frames) : l;
    return StereoAudio(resample(l, r->sampleRate, sampleRate), resample(rr, r->sampleRate, sampleRate));
}

bool write(const StereoAudio& a, double sampleRate, const juce::File& f) {
    f.deleteFile();
    std::unique_ptr<juce::OutputStream> os(f.createOutputStream().release());
    if (!os) return false;
    juce::WavAudioFormat wav;
    std::unique_ptr<juce::AudioFormatWriter> w(wav.createWriterFor(os.get(), sampleRate, 2, 32, {}, 0));
    if (!w) return false;
    os.release();
    int n = a.count();
    const float* ch[2] = { a.left.data(), a.right.data() };
    juce::AudioBuffer<float> b(const_cast<float**>(ch), 2, n);
    return w->writeFromAudioSampleBuffer(b, 0, n);
}

bool isAudio(const juce::File& f) {
    static const juce::StringArray ext { "wav", "wave", "aif", "aiff", "aifc", "caf", "mp3", "m4a", "aac", "flac", "ogg" };
    return ext.contains(f.getFileExtension().trimCharactersAtStart(".").toLowerCase());
}
}

juce::File recordingsDirectory() {
    auto d = juce::File::getSpecialLocation(juce::File::userDocumentsDirectory).getChildFile("polje nieuk Recordings");
    d.createDirectory();
    return d;
}

std::vector<int> detectTransients(const float* buf, int count, double sampleRate, float sensitivity, int maxSlices) {
    const int hopN = 256, win = 512;
    if (count <= win * 2) return {};
    int frames = (count - win) / hopN;
    std::vector<float> logE(size_t(frames), 0), flux(size_t(frames), 0);
    for (int f = 0; f < frames; ++f) {
        float e = 0; int s = f * hopN;
        for (int i = 0; i < win; ++i) { float v = buf[s + i]; e += v * v; }
        logE[size_t(f)] = 10 * std::log10(e / float(win) + 1e-10f);
    }
    for (int f = 2; f < frames; ++f) flux[size_t(f)] = std::max(0.0f, logE[size_t(f)] - std::max(logE[size_t(f - 1)], logE[size_t(f - 2)]));
    float thr = 2 + (1 - std::clamp(sensitivity, 0.0f, 1.0f)) * 14;
    int minGap = std::max(1, int(0.06 * sampleRate) / hopN);
    std::vector<int> out;
    int lastF = -minGap;
    for (int f = 2; f < frames - 1; ++f) {
        auto F = [&](int k) { return flux[size_t(k)]; };
        if (!(F(f) >= thr && F(f) >= F(f - 1) && F(f) >= F(f + 1) && logE[size_t(f)] > -60 && f - lastF >= minGap)) continue;
        int s = f * hopN; float pk = 0;
        for (int i = 0; i < win; ++i) pk = std::max(pk, std::abs(buf[s + i]));
        int pos = s;
        for (int i = 0; i < win; ++i) if (std::abs(buf[s + i]) >= pk * 0.5f) { pos = std::max(0, s + i - 32); break; }
        if (pos > 0) out.push_back(pos);
        lastF = f;
        if (int(out.size()) >= maxSlices) break;
    }
    return out;
}

// ---------------------------------------------------------------- rec

class RecorderNode : public DSPNode, private juce::Thread {
public:
    RecorderNode(const ModuleSpec& s, double sr) : DSPNode(s, sr), juce::Thread("polje nieuk recorder") {
        capFrames = int(sr * 8);
        ring.assign(size_t(capFrames * 2), 0);
        startThread();
    }
    ~RecorderNode() override { stopThread(2000); writer.reset(); }

    void process(int frames, const float* const* in, uint64_t con, ProcessContext&) override {
        bool on = params[0] > 0.5f;
        if (on && !wasOn) { session.fetch_add(1); recFrames = 0; }
        wasOn = on;
        recording.store(on, std::memory_order_release);
        if (on) {
            long w = writePos.load(std::memory_order_relaxed), r = readPos.load(std::memory_order_acquire);
            int n = std::max(0, std::min(frames, int(capFrames - (w - r))));
            const float* L = in[0]; const float* R = isConnected(con, 1) ? in[1] : in[0];
            for (int i = 0; i < n; ++i) {
                size_t idx = size_t(((w + i) % capFrames) * 2);
                ring[idx] = L[i]; ring[idx + 1] = R[i];
            }
            writePos.store(w + n, std::memory_order_release);
            recFrames += frames;
        }
        readouts[0] = float(double(recFrames) / sampleRate);
        readouts[1] = on ? 1.0f : 0.0f;
    }

private:
    void run() override {
        while (!threadShouldExit()) {
            wait(50);
            drain();
        }
        drain();
    }
    void drain() {
        long w = writePos.load(std::memory_order_acquire);
        int s = session.load();
        if (s != fileSession) { writer.reset(); fileSession = s; open(); }
        long r = readPos.load(std::memory_order_relaxed), pos = r;
        if (writer && w > r) {
            const int chunk = 4096;
            juce::AudioBuffer<float> b(2, chunk);
            while (pos < w) {
                int n = int(std::min<long>(chunk, w - pos));
                for (int i = 0; i < n; ++i) {
                    size_t idx = size_t(((pos + i) % capFrames) * 2);
                    b.setSample(0, i, ring[idx]); b.setSample(1, i, ring[idx + 1]);
                }
                writer->writeFromAudioSampleBuffer(b, 0, n);
                pos += n;
            }
        }
        readPos.store(w, std::memory_order_release);
        if (!recording.load(std::memory_order_acquire) && writer && writePos.load(std::memory_order_acquire) == w) writer.reset();
    }
    void open() {
        auto name = "polje nieuk " + juce::Time::getCurrentTime().formatted("%Y-%m-%d %H.%M.%S") + ".wav";
        auto f = recordingsDirectory().getChildFile(name);
        auto os = f.createOutputStream();
        if (!os) return;
        juce::WavAudioFormat wav;
        auto* raw = os.release();
        writer.reset(wav.createWriterFor(raw, sampleRate, 2, 32, {}, 0));
        if (!writer) delete raw;
    }
    int capFrames;
    std::vector<float> ring;
    std::atomic<long> writePos { 0 }, readPos { 0 };
    std::atomic<int> session { 0 };
    std::atomic<bool> recording { false };
    bool wasOn = false;
    long recFrames = 0;
    std::unique_ptr<juce::AudioFormatWriter> writer;
    int fileSession = 0;
};

// ---------------------------------------------------------------- looper

class LooperNode : public DSPNode, public SampleBufferNode {
public:
    enum State { empty = 0, armed, recordingS, playingS, overdub, stopped, closing };
    static constexpr int lengths[] = { 0, 1, 2, 4, 8, 16, 32 };
    LooperNode(const ModuleSpec& s, double sr) : DSPNode(s, sr) {
        cap = int(sr * 120);
        bufL.assign(size_t(cap), 0); bufR.assign(size_t(cap), 0);
    }

    void process(int frames, const float* const* in, uint64_t con, ProcessContext& ctx) override {
        lengthBeats = lengths[clampIndex(params[4], 7)];
        quant = params[5] > 0.5f;
        double rate = params[6];
        if (!std::isfinite(rate) || rate < 0.05) rate = 1;
        if (std::abs(rate - 1) < 0.02) rate = 1;
        double speed = params[7] > 0.5f ? -rate : rate;
        float keep = params[8], level = params[9], dry = params[10];
        double qUnit = double(lengthBeats > 0 ? std::min(lengthBeats, 4) : 1);
        int freeTarget = (!quant && lengthBeats > 0) ? std::max(256, safeInt(double(lengthBeats) * ctx.samplesPerBeat)) : INT32_MAX;
        bool recPress = consumeTrigger(0), playPress = consumeTrigger(1), stopPress = consumeTrigger(2);
        if (consumeTrigger(3)) { state = empty; recLen = 0; loopLen = 0; ++version; }
        if (guard.busy()) { for (auto& o : outputs) std::fill(o.begin(), o.begin() + frames, 0.0f); return; }
        bool monitor = params[11] > 0.5f;
        double regionLo = std::clamp(params[12], 0.0f, 1.0f), regionHi = std::clamp(params[13], 0.0f, 1.0f);
        if (regionHi < regionLo) std::swap(regionLo, regionHi);
        bool fullRegion = regionLo <= 0.001 && regionHi >= 0.999;
        const float* inL = in[0]; const float* inR = isConnected(con, 1) ? in[1] : in[0];
        const float* recG = in[2]; const float* stopG = in[3];
        bool hasRecG = isConnected(con, 2), hasStopG = isConnected(con, 3);
        float* oL = out(0); float* oR = out(1);
        float* bl = bufL.data(); float* br = bufR.data();

        for (int i = 0; i < frames; ++i) {
            double b = ctx.beat[i];
            bool beatTick = crossed(prevBeat, b, 1), qTick = crossed(prevBeat, b, qUnit);
            prevBeat = b;
            if (hasRecG) { float g = recG[i]; if (!recGate && g > 0.2f) { recGate = true; recPress = true; } else if (recGate && g < 0.1f) recGate = false; }
            if (hasStopG) { float g = stopG[i]; if (!stopGate && g > 0.2f) { stopGate = true; stopPress = true; } else if (stopGate && g < 0.1f) stopGate = false; }
            if (recPress) { recPress = false; pressRec(); }
            if (playPress) { playPress = false; pressPlay(); }
            if (stopPress) { stopPress = false; pressStop(); }
            float xl = inL[i], xr = inR[i], yl = 0, yr = 0;
            bool listening = state == armed || state == recordingS || state == closing || state == overdub;
            if (state == armed && qTick) startRec();
            if (state == recordingS || state == closing) {
                if (beatTick && recLen > 0) ++recBeats;
                bool done = (quant && lengthBeats > 0 && recBeats >= lengthBeats) || (state == closing && beatTick && recLen > 0)
                         || recLen >= freeTarget || recLen >= cap;
                if (done) finishRec(); else { bl[recLen] = xl; br[recLen] = xr; ++recLen; }
            }
            if ((state == playingS || state == overdub) && loopLen > 0) {
                double fl = loopLen, lo = std::floor(regionLo * fl), hi = std::max(lo + 64, std::min(std::floor(regionHi * fl), fl)), span = hi - lo;
                if (beatTick) {
                    ++beatCounter;
                    if (fullRegion && quant && loopBeats > 0 && speed == 1 && beatCounter % loopBeats == 0) {
                        double f = play / fl;
                        if (f > 0.85 || f < 0.15) play = 0;
                    }
                }
                if (play < lo || play >= hi) play = speed >= 0 ? lo : hi - 1;
                yl = readLinear(bl, loopLen, play); yr = readLinear(br, loopLen, play);
                if (state == overdub) {
                    int ip = std::clamp(int(play), 0, loopLen - 1);
                    bl[ip] = bl[ip] * keep + xl; br[ip] = br[ip] * keep + xr;
                }
                play += speed;
                if (play >= hi) play -= span; else if (play < lo) play += span;
            }
            float thru = (monitor && listening) ? std::max(dry, 1.0f) : dry;
            oL[i] = xl * thru + yl * level;
            oR[i] = xr * thru + yr * level;
        }
        if (state == recordingS || state == closing || state == overdub) ++version;
        readouts[0] = float(state);
        switch (state) {
            case recordingS: case closing:
                readouts[1] = lengthBeats > 0 ? float(recBeats) / float(lengthBeats) : 0;
                readouts[2] = float(double(recLen) / sampleRate); break;
            case playingS: case overdub: case stopped:
                readouts[1] = loopLen > 0 ? float(play / double(loopLen)) : 0;
                readouts[2] = float(double(loopLen) / sampleRate); break;
            default: readouts[1] = 0; readouts[2] = 0;
        }
        readouts[3] = float(loopBeats);
        readouts[5] = (state == recordingS || state == closing) ? 1.0f : 0.0f;
        readouts[kBeatSamplesSlot] = float(loopBeats > 0 && loopLen > 0 ? double(loopLen) / double(loopBeats) : ctx.samplesPerBeat);
        readouts[kPlayheadSlot] = (state == playingS || state == overdub) && loopLen > 0 ? float(play / double(loopLen)) : -1.0f;
        for (int k = 1; k < 8; ++k) readouts[size_t(kPlayheadSlot + k)] = -1;
    }

    const float* waveBuffer() const override { return bufL.data(); }
    const float* waveBufferR() const override { return bufR.data(); }
    int waveLength() const override { return (state == recordingS || state == closing) ? recLen : loopLen; }
    int contentVersion() const override { return version; }
    bool waveRecording() const override { return state == recordingS || state == closing || state == overdub; }
    int bufferCapacity() const override { return cap; }
    StereoAudio snapshot() const override {
        if (loopLen <= 0) return {};
        return StereoAudio(std::vector<float>(bufL.begin(), bufL.begin() + loopLen), std::vector<float>(bufR.begin(), bufR.begin() + loopLen));
    }
    void load(const StereoAudio& a) override {
        guard.whileBusy([&] {
            int n = std::min(a.count(), cap);
            a.copyInto(bufL.data(), bufR.data(), n);
            loopLen = n; recLen = 0; loopBeats = 0; play = 0;
            state = n > 0 ? stopped : empty;
            ++version;
        });
    }

private:
    void startRec() { state = recordingS; recLen = 0; recBeats = 0; }
    void finishRec() {
        ++version;
        if (recLen < 256) { state = empty; recLen = 0; loopLen = 0; return; }
        loopLen = recLen;
        int fade = std::min(64, loopLen / 4);
        for (int i = 0; i < fade; ++i) {
            float g = float(i) / float(fade);
            bufL[size_t(i)] *= g; bufL[size_t(loopLen - 1 - i)] *= g;
            bufR[size_t(i)] *= g; bufR[size_t(loopLen - 1 - i)] *= g;
        }
        loopBeats = quant ? recBeats : 0;
        play = 0; beatCounter = 0; state = playingS;
    }
    void pressRec() {
        switch (state) {
            case empty: if (quant) state = armed; else startRec(); break;
            case armed: state = empty; break;
            case recordingS: if (quant) state = closing; else finishRec(); break;
            case closing: break;
            case playingS: state = overdub; break;
            case overdub: state = playingS; break;
            case stopped: play = 0; beatCounter = 0; state = overdub; break;
        }
    }
    void pressPlay() {
        if (loopLen <= 0) return;
        if (state == stopped) { play = 0; beatCounter = 0; }
        if (state == stopped || state == overdub) state = playingS;
    }
    void pressStop() {
        switch (state) {
            case recordingS: case closing: finishRec(); if (loopLen > 0) { state = stopped; play = 0; } break;
            case armed: state = empty; break;
            case playingS: case overdub: state = stopped; play = 0; break;
            default: break;
        }
    }
    int cap;
    std::vector<float> bufL, bufR;
    LoadGuard guard;
    int version = 0;
    State state = empty;
    int recLen = 0, loopLen = 0, recBeats = 0, loopBeats = 0, beatCounter = 0, lengthBeats = 4;
    double play = 0, prevBeat = 0;
    bool recGate = false, stopGate = false, quant = true;
};

// ---------------------------------------------------------------- grain

class GranulatorNode : public DSPNode {
public:
    struct Grain { bool active = false; double pos = 0, rate = 1; int age = 0, len = 1; float gl = 0, gr = 0; };
    static constexpr int maxGrains = 64, windowSize = 1024;
    GranulatorNode(const ModuleSpec& s, double sr) : DSPNode(s, sr) {
        len = int(sr * 10);
        buf.assign(size_t(len), 0); bufR.assign(size_t(len), 0);
        grains.assign(maxGrains, Grain());
        window.resize(windowSize + 1);
        for (int i = 0; i <= windowSize; ++i) { double sn = std::sin(juce::MathConstants<double>::pi * i / windowSize); window[size_t(i)] = float(sn * sn); }
    }
    void process(int frames, const float* const* in, uint64_t con, ProcessContext& ctx) override {
        bool freezeParam = params[10] > 0.5f;
        double density = params[2];
        bool sync = params[3] > 0.5f;
        double div = Divisions::beats(params[4]);
        float mix = params[11], level = params[12];
        double gps = sync ? sampleRate / std::max(div * ctx.samplesPerBeat, 1.0) : density;
        double overlap = gps * double(params[1]) / 1000;
        float norm = float(1 / std::max(1.0, std::sqrt(overlap)));
        const float* inp = in[0]; const float* inpR = isConnected(con, 1) ? in[1] : in[0];
        const float* trig = in[2]; const float* frz = in[3]; const float* posCV = in[4];
        bool hasTrig = isConnected(con, 2), hasFrz = isConnected(con, 3), hasPos = isConnected(con, 4);
        float* oL = out(0); float* oR = out(1);
        double flen = len; float wsize = float(windowSize);
        int maxActive = 0; bool frozenNow = freezeParam;
        for (int i = 0; i < frames; ++i) {
            float x = inp[i], xr = inpR[i];
            bool frozen = freezeParam || (hasFrz && frz[i] > 0.2f);
            frozenNow = frozen;
            if (!frozen) { buf[size_t(w)] = x; bufR[size_t(w)] = xr; if (++w >= len) w = 0; }
            bool fire = false;
            double b = ctx.beat[i];
            if (sync) { if (crossed(prevBeat, b, div)) fire = true; }
            else { phase += density / sampleRate; if (phase >= 1) { phase -= 1; fire = true; } }
            prevBeat = b;
            if (hasTrig) { float t = trig[i]; if (!trigHigh && t > 0.2f) { trigHigh = true; fire = true; } else if (trigHigh && t < 0.1f) trigHigh = false; }
            if (fire) { double p = params[0]; if (hasPos) p += posCV[i]; spawn(std::clamp(p, 0.0, 1.0), frozen); }
            float l = 0, r = 0; int active = 0;
            for (auto& g : grains) {
                if (!g.active) continue;
                ++active;
                float ph = float(g.age) / float(g.len) * wsize;
                int wi = std::min(int(ph), windowSize - 1);
                float wf = ph - float(wi);
                float env = window[size_t(wi)] + (window[size_t(wi + 1)] - window[size_t(wi)]) * wf;
                l += readLinear(buf.data(), len, g.pos) * env * g.gl * 1.414f;
                r += readLinear(bufR.data(), len, g.pos) * env * g.gr * 1.414f;
                double np = g.pos + g.rate;
                if (np >= flen) np -= flen; else if (np < 0) np += flen;
                g.pos = np;
                if (++g.age >= g.len) g.active = false;
            }
            maxActive = std::max(maxActive, active);
            float gg = norm * level * mix;
            oL[i] = x * (1 - mix) + l * gg;
            oR[i] = xr * (1 - mix) + r * gg;
        }
        readouts[0] = float(maxActive); readouts[1] = frozenNow ? 1.0f : 0.0f; readouts[2] = float(spawned);
    }
private:
    void spawn(double position, bool frozen) {
        int slot = -1;
        for (int g = 0; g < maxGrains; ++g) if (!grains[size_t(g)].active) { slot = g; break; }
        if (slot < 0) return;
        int glen = std::max(16, safeInt(double(params[1]) / 1000 * sampleRate, 16, len / 4));
        float semis = params[5] + params[6] * (rng.next() * 2 - 1);
        double rate = std::exp2(semis / 12);
        if (rng.next() < params[9]) rate = -rate;
        double maxBack = double(len) * 0.8;
        double delay = position * maxBack + double(params[7]) * double(rng.next()) * sampleRate * 0.5;
        if (!frozen && rate > 1) delay = std::max(delay, double(glen) * (rate - 1) + 8);
        delay = std::min(std::max(delay, 8.0), double(len) - double(glen) * std::abs(rate) - 8);
        float pan = params[8] * (rng.next() * 2 - 1);
        float angle = (pan + 1) * juce::MathConstants<float>::pi / 4;
        ++spawned;
        grains[size_t(slot)] = { true, wrap(double(w) - delay, double(len)), rate, 0, glen, std::cos(angle), std::sin(angle) };
    }
    int len, w = 0, spawned = 0;
    std::vector<float> buf, bufR, window;
    std::vector<Grain> grains;
    double phase = 0, prevBeat = 0;
    bool trigHigh = false;
    XorShift rng { 0xC0FFEE11u };
};

// ---------------------------------------------------------------- sampler

class SamplerNode : public DSPNode, public SampleBufferNode {
public:
    static constexpr double syncLengths[] = { 0, 1, 2, 4, 8, 16, 32 };
    static constexpr int chopCounts[] = { 0, 4, 8, 16, 32, 1, -1 };
    static constexpr double gridBeats[] = { 0, 0.125, 0.25, 0.5, 1, 2, 4 };
    static constexpr double autoDivs[] = { 0, 0.125, 0.25, 0.5, 1, 2, 4 };
    struct Voice { bool active = false; double pos = 0, inc = 1, lo = 0, hi = 0; float env = 0; int stage = 0; bool gated = false, fast = false; int age = 0; };

    SamplerNode(const ModuleSpec& s, double sr) : DSPNode(s, sr) {
        cap = int(sr * 60);
        bufL.assign(size_t(cap), 0); bufR.assign(size_t(cap), 0);
        markers.assign(maxMarkers, 0);
        voices.assign(8, Voice());
    }
    std::atomic<int> auditionSlice { -1 };
    double beatSamples = 24000;

    void setMarkers(const std::vector<int>& m) {
        int n = std::min(int(m.size()), maxMarkers);
        markerTotal = 0;
        for (int i = 0; i < n; ++i) markers[size_t(i)] = m[size_t(i)];
        markerTotal = n;
    }
    void analyze() {
        if (recording || length <= 0) return;
        std::vector<float> mono(static_cast<size_t>(length));
        for (int i = 0; i < length; ++i) mono[size_t(i)] = (bufL[size_t(i)] + bufR[size_t(i)]) * 0.5f;
        setMarkers(detectTransients(mono.data(), length, sampleRate, base[4]));
    }
    int sliceAt(double x) {
        if (length <= 0) return 0;
        auto [rs, re] = region();
        int n = sliceCount(rs, re), p = int(x * length);
        for (int k = 0; k < n; ++k) { auto [a, b] = sliceBounds(k, n, rs, re); if (p >= a && p < b) return k; }
        return p < rs ? 0 : n - 1;
    }

    void process(int frames, const float* const* in, uint64_t con, ProcessContext& ctx) override {
        float* oL = out(0); float* oR = out(1);
        if (guard.busy()) { std::fill(oL, oL + frames, 0.0f); std::fill(oR, oR + frames, 0.0f); return; }
        if (consumeTrigger(0)) { recording = true; recLen = 0; stopped = false; }
        if (consumeTrigger(1)) {
            if (recording) finishRecording();
            else { playing = false; playArmed = false; stopped = true; for (auto& v : voices) if (v.active) { v.stage = 2; v.fast = true; } }
        }
        if (consumeTrigger(2)) { length = 0; recording = false; playing = false; markerTotal = 0; ++version; }
        double autoDiv = autoDivs[clampIndex(params[7], 7)];
        bool gateMode = params[9] > 0.5f;
        float sr = float(sampleRate);
        float attInc = 1 / std::max(params[12] * 0.001f * sr, 1.0f);
        float decCoef = 1 - std::exp(-1 / std::max(params[13] * 0.001f * sr / 3, 1.0f));
        float sus = std::clamp(params[14], 0.0f, 1.0f);
        float relSamples = std::max(params[15] * 0.001f * sr, 1.0f);
        float relMul = std::exp(std::log(1e-4f) / relSamples), fastMul = std::exp(std::log(1e-4f) / (0.005f * sr));
        float level = params[18]; bool monitor = params[19] > 0.5f;
        beatSamples = ctx.samplesPerBeat;
        const float* inL = in[0]; const float* inR = isConnected(con, 1) ? in[1] : in[0];
        const float* trig = in[2]; const float* recIn = in[3];
        bool hasTrig = isConnected(con, 2), hasRec = isConnected(con, 3);
        int aud = auditionSlice.exchange(-1);
        if (aud >= 0) hit(aud, false);
        bool sync = params[23] > 0.5f, loop = params[22] > 0.5f;
        bool hasPlayGate = isConnected(con, 4); const float* playIn = in[4];
        if (consumeTrigger(21)) {
            if (playing || playArmed) { playing = false; playArmed = false; }
            else if (stopped && (autoDiv > 0 || hasTrig || hasPlayGate)) stopped = false;
            else if (length > 256) { stopped = false; if (sync) playArmed = true; else startPlay(); }
        }
        int prs = 0, pre = 0;
        if (length > 0) { auto r = region(); prs = r.first; pre = r.second; }
        auto sr2 = length > 0 ? syncRatio(prs, pre) : std::make_pair(1.0, 4.0);
        double playRate = double(std::exp2(params[11] / 12)) * (sync ? sr2.first : 1);
        float fadeStep = 1 / (0.004f * sr);

        for (int i = 0; i < frames; ++i) {
            float xl = inL[i], xr = inR[i];
            if (hasRec && recGate.rising(recIn[i])) { if (recording) finishRecording(); else { recording = true; recLen = 0; } }
            if (recording) { if (recLen < cap) { bufL[size_t(recLen)] = xl; bufR[size_t(recLen)] = xr; ++recLen; } else finishRecording(); }
            if (hasTrig) {
                float t = trig[i];
                if (!trigGate && t > 0.2f) { trigGate = true; if (!stopped) hit(-1, gateMode); }
                else if (trigGate && t < 0.1f) {
                    trigGate = false;
                    if (gateMode) for (auto& v : voices) if (v.gated) { v.gated = false; v.stage = 2; }
                }
            }
            double b = ctx.beat[i];
            if (!stopped && autoDiv > 0 && crossed(prevBeat, b, autoDiv)) hit(-1, false);
            if (hasPlayGate && playGate.rising(playIn[i]) && length > 256 && !stopped) startPlay();
            if (crossed(prevBeat, b, 1)) {
                if (playArmed && crossed(prevBeat, b, std::min(sr2.second, 4.0))) { playArmed = false; startPlay(); }
                else if (playing && sync && loop) {
                    ++playBeats;
                    if (playBeats % std::max(int(sr2.second), 1) == 0) playPos = prs;
                }
            }
            prevBeat = b;
            float sumL = 0, sumR = 0;
            if (!recording && length > 0) {
                for (auto& vo : voices) {
                    if (!vo.active) continue;
                    switch (vo.stage) {
                        case 0: vo.env += attInc; if (vo.env >= 1) { vo.env = 1; vo.stage = 1; } break;
                        case 1: vo.env += (sus - vo.env) * decCoef; break;
                        default: vo.env *= vo.fast ? fastMul : relMul; if (vo.env < 1e-4f) vo.active = false;
                    }
                    if (!vo.gated && vo.stage < 2) {
                        double remaining = vo.inc > 0 ? (vo.hi - vo.pos) / vo.inc : (vo.pos - vo.lo) / -vo.inc;
                        if (float(remaining) <= relSamples) vo.stage = 2;
                    }
                    if (vo.active) {
                        sumL += readLinear(bufL.data(), length, vo.pos) * vo.env;
                        sumR += readLinear(bufR.data(), length, vo.pos) * vo.env;
                        vo.pos += vo.inc;
                        if (vo.pos >= vo.hi || vo.pos < vo.lo) vo.active = false;
                    }
                    ++vo.age;
                }
            }
            if (playing && !recording && pre > prs) {
                playEnv = std::min(playEnv + fadeStep, 1.0f);
                if (playPos < prs || playPos >= pre) playPos = prs;
                double remaining = (double(pre) - playPos) / playRate;
                float edge = loop ? 1.0f : std::min(1.0f, float(remaining) * fadeStep);
                sumL += readLinear(bufL.data(), length, playPos) * playEnv * edge;
                sumR += readLinear(bufR.data(), length, playPos) * playEnv * edge;
                playPos += playRate;
                if (playPos >= pre) { if (loop) playPos -= double(pre - prs); else playing = false; }
            }
            float mon = (recording && monitor) ? 1.0f : 0.0f;
            oL[i] = sumL * level + xl * mon;
            oR[i] = sumR * level + xr * mon;
        }
        if (recording) ++version;
        readouts[0] = recording ? 1.0f : (length > 0 ? 2.0f : 0.0f);
        readouts[1] = float(double(recording ? recLen : length) / sampleRate);
        if (length > 0 && !recording) { auto [rs, re] = region(); readouts[2] = float(sliceCount(rs, re)); } else readouts[2] = 0;
        readouts[3] = float(lastSlice + 1);
        readouts[kBeatSamplesSlot] = float(beatSamples);
        for (int v = 0; v < 7; ++v)
            readouts[size_t(kPlayheadSlot + v)] = voices[size_t(v)].active && length > 0 ? float(voices[size_t(v)].pos / double(length)) : -1.0f;
        readouts[kPlayheadSlot + 7] = playing && length > 0 ? float(playPos / double(length)) : -1.0f;
        readouts[4] = playing ? 1.0f : (playArmed ? 2.0f : (stopped ? 3.0f : 0.0f));
        readouts[7] = sync ? float(sr2.second) : 0.0f;
    }

    const float* waveBuffer() const override { return bufL.data(); }
    const float* waveBufferR() const override { return bufR.data(); }
    int waveLength() const override { return recording ? recLen : length; }
    int contentVersion() const override { return version; }
    bool waveRecording() const override { return recording; }
    int bufferCapacity() const override { return cap; }
    int markerCount() const override { return chopCounts[clampIndex(params[3], 7)] == 0 ? markerTotal : 0; }
    int marker(int i) const override { return markers[size_t(std::clamp(i, 0, maxMarkers - 1))]; }
    StereoAudio snapshot() const override {
        if (length <= 0) return {};
        return StereoAudio(std::vector<float>(bufL.begin(), bufL.begin() + length), std::vector<float>(bufR.begin(), bufR.begin() + length));
    }
    void load(const StereoAudio& a) override {
        guard.whileBusy([&] {
            int c = std::min(a.count(), cap);
            a.copyInto(bufL.data(), bufR.data(), c);
            length = c; recording = false; markerTotal = 0; lastSlice = -1;
            for (auto& v : voices) v.active = false;
            ++version;
        });
    }

private:
    std::pair<double, double> syncRatio(int rs, int re) {
        double spb = std::max(beatSamples, 1.0), len = double(re - rs);
        double beats = syncLengths[clampIndex(params[24], 7)];
        if (beats == 0) beats = std::pow(2.0, std::max(0.0, std::min(6.0, std::round(std::log2(std::max(len / spb, 0.5))))));
        return { len / (beats * spb), beats };
    }
    std::pair<int, int> region() const {
        double lo = std::clamp(params[16], 0.0f, 1.0f), hi = std::clamp(params[17], 0.0f, 1.0f);
        if (hi < lo) std::swap(lo, hi);
        int a = int(lo * length);
        return { a, std::max(a + 64, std::min(int(hi * length), length)) };
    }
    int gridUnit() const {
        double g = gridBeats[clampIndex(params[20], 7)];
        if (g == 0) g = 0.25;
        return std::max(64, safeInt(g * beatSamples));
    }
    int sliceCount(int rs, int re) const {
        int chop = chopCounts[clampIndex(params[3], 7)];
        if (chop < 0) return std::min(std::max(1, (re - rs + gridUnit() - 1) / gridUnit()), 256);
        if (chop > 0) return chop;
        int n = 1;
        for (int i = 0; i < markerTotal; ++i) if (markers[size_t(i)] > rs + 32 && markers[size_t(i)] < re - 32) ++n;
        return n;
    }
    std::pair<int, int> sliceBounds(int k, int n, int rs, int re) const {
        int chop = chopCounts[clampIndex(params[3], 7)];
        if (chop < 0) { int u = gridUnit(); return { std::min(rs + k * u, re - 1), std::min(rs + (k + 1) * u, re) }; }
        if (chop > 0) { double span = re - rs; return { rs + int(span * k / n), rs + int(span * (k + 1) / n) }; }
        int a = rs, b = re, idx = 0;
        for (int i = 0; i < markerTotal; ++i) {
            int m = markers[size_t(i)];
            if (!(m > rs + 32 && m < re - 32)) continue;
            ++idx;
            if (idx == k) a = m;
            if (idx == k + 1) { b = m; break; }
        }
        return { a, b };
    }
    int pickSlice(int n) {
        if (n <= 1) return 0;
        switch (clampIndex(params[5], 5)) {
            case 0: lastSlice = (lastSlice + 1) % n; break;
            case 1: lastSlice = lastSlice <= 0 ? n - 1 : lastSlice - 1; break;
            case 2: lastSlice = std::min(int(rng.next() * float(n)), n - 1); break;
            case 3:
                if (lastSlice < 0) { lastSlice = 0; pingDir = 1; }
                else {
                    if (lastSlice + pingDir >= n || lastSlice + pingDir < 0) pingDir = -pingDir;
                    lastSlice = std::clamp(lastSlice + pingDir, 0, n - 1);
                }
                break;
            default: lastSlice = std::min(clampIndex(params[6] * float(n - 1), n), n - 1);
        }
        return lastSlice;
    }
    void hit(int forced, bool gated) {
        if (length <= 256) return;
        auto [rs, re] = region();
        int n = sliceCount(rs, re);
        int k = forced >= 0 ? std::clamp(forced, 0, n - 1) : pickSlice(n);
        if (forced >= 0) lastSlice = k;
        auto [a, b] = sliceBounds(k, n, rs, re);
        if (b - a <= 32) return;
        int dirMode = clampIndex(params[8], 3);
        bool reverse = dirMode == 1 || (dirMode == 2 && rng.next() < 0.5f);
        double rate = std::exp2(params[11] / 12);
        if (params[23] > 0.5f) rate *= syncRatio(rs, re).first;
        if (params[10] < 0.5f) for (auto& v : voices) if (v.active) { v.stage = 2; v.fast = true; }
        int slot = -1, oldest = -1, oldestAge = -1;
        for (int v = 0; v < int(voices.size()); ++v) {
            if (!voices[size_t(v)].active) { slot = v; break; }
            if (voices[size_t(v)].age > oldestAge) { oldestAge = voices[size_t(v)].age; oldest = v; }
        }
        if (slot < 0) slot = oldest;
        voices[size_t(slot)] = { true, reverse ? double(b - 1) : double(a), reverse ? -rate : rate, double(a), double(b), 0, 0, gated, false, 0 };
    }
    void startPlay() { playing = true; playArmed = false; playPos = region().first; playEnv = 0; playBeats = 0; }
    void finishRecording() { recording = false; length = recLen; markerTotal = 0; lastSlice = -1; ++version; }

    static constexpr int maxMarkers = 128;
    int cap, length = 0, recLen = 0, version = 0, markerTotal = 0, lastSlice = -1, pingDir = 1, playBeats = 0;
    std::vector<float> bufL, bufR;
    std::vector<int> markers;
    std::vector<Voice> voices;
    bool recording = false, trigGate = false, playing = false, stopped = false, playArmed = false;
    LoadGuard guard;
    EdgeDetector recGate, playGate;
    XorShift rng { 0x5A3B1E55u };
    double prevBeat = 0, playPos = 0;
    float playEnv = 0;
};

Factory factoryBuffers(const std::string& k) {
    if (k == "rec") return make<RecorderNode>();
    if (k == "looper") return make<LooperNode>();
    if (k == "grain") return make<GranulatorNode>();
    if (k == "sampler") return make<SamplerNode>();
    return nullptr;
}

// UI access (the nodes' classes stay private to this file)
void samplerAnalyze(DSPNode* n) { if (auto* s = dynamic_cast<SamplerNode*>(n)) s->analyze(); }
void samplerAudition(DSPNode* n, int slice) { if (auto* s = dynamic_cast<SamplerNode*>(n)) s->auditionSlice = slice; }
int samplerSliceAt(DSPNode* n, double x) { if (auto* s = dynamic_cast<SamplerNode*>(n)) return s->sliceAt(x); return 0; }

} // namespace pn
