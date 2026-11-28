// arrange — a port of Arrange.swift.
#include "ModulesArrange.h"

namespace pn {

std::vector<float> ArrangeLayout::defaultTracks() {
    std::vector<float> t;
    for (int k = 0; k < tracks; ++k) t.insert(t.end(), { 1, 0, 0, 0, 0 });
    return t;
}

// ---------------------------------------------------------------- clips

std::vector<ArrangeClip> ArrangeClip::decode(const std::vector<float>& v) {
    // a version mark (-9), then 9 numbers a clip; older ones: 8 a clip, no mark
    bool isNew = !v.empty() && v[0] == -9.0f;
    size_t n = isNew ? 9 : 8, from = isNew ? 1 : 0;
    std::vector<ArrangeClip> out;
    for (size_t i = from; i + n <= v.size(); i += n) {
        ArrangeClip c;
        c.track = int(v[i]); c.start = v[i + 1]; c.length = v[i + 2]; c.offset = v[i + 3];
        c.gain = v[i + 4]; c.fadeIn = v[i + 5]; c.fadeOut = v[i + 6]; c.file = int(v[i + 7]);
        c.transpose = isNew && std::isfinite(v[i + 8]) ? std::clamp(v[i + 8], -48.0f, 48.0f) : 0.0f;
        if (c.track < 0 || c.track >= ArrangeLayout::tracks || !(c.length > 0) || c.file < 0
            || !std::isfinite(c.start) || !std::isfinite(c.offset) || !std::isfinite(c.gain)) continue;
        out.push_back(c);
    }
    return out;
}
std::vector<float> ArrangeClip::encode(const std::vector<ArrangeClip>& cs) {
    std::vector<float> v { -9.0f };
    for (auto& c : cs) v.insert(v.end(), { float(c.track), float(c.start), float(c.length), float(c.offset), c.gain,
                                            float(c.fadeIn), float(c.fadeOut), float(c.file), c.transpose });
    return v;
}
std::vector<juce::String> ArrangeClip::decodeFiles(const std::vector<float>& v) {
    std::string s;
    for (float f : v) s.push_back(char(uint8_t(std::clamp(int(f), 0, 255))));
    std::vector<juce::String> out;
    if (s.empty()) return out;
    for (auto& line : juce::StringArray::fromTokens(juce::String::fromUTF8(s.data(), int(s.size())), "\n", "")) out.push_back(line);
    return out;
}
std::vector<float> ArrangeClip::encodeFiles(const std::vector<juce::String>& f) {
    juce::StringArray a;
    for (auto& s : f) a.add(s);
    std::vector<float> v;
    auto u = a.joinIntoString("\n").toUTF8();
    for (auto* p = u.getAddress(); *p; ++p) v.push_back(float(uint8_t(*p)));
    return v;
}

std::pair<float, float> ClipAudio::minMax(int a, int b) const {
    a = std::max(a, 0); b = std::min(std::max(b, a + 1), frames());
    if (a >= b) return { 0.0f, 0.0f };
    float lo = 1, hi = -1;
    if (b - a >= 4096) {
        for (int k = a / 1024; k <= std::min((b - 1) / 1024, int(lo1k.size()) - 1); ++k) { lo = std::min(lo, lo1k[size_t(k)]); hi = std::max(hi, hi1k[size_t(k)]); }
    } else if (b - a >= 128) {
        for (int k = a / 32; k <= std::min((b - 1) / 32, int(lo32.size()) - 1); ++k) { lo = std::min(lo, lo32[size_t(k)]); hi = std::max(hi, hi32[size_t(k)]); }
    } else {
        for (int i = a; i < b; ++i) { float x = (left[size_t(i)] + right[size_t(i)]) * 0.5f; lo = std::min(lo, x); hi = std::max(hi, x); }
    }
    return { lo, hi };
}

// ---------------------------------------------------------------- the audio pool

ArrangeAudio& ArrangeAudio::shared() { static ArrangeAudio* a = new ArrangeAudio(); return *a; }

juce::String ArrangeAudio::resolve(const juce::String& path) {
    if (juce::File::isAbsolutePath(path) && juce::File(path).existsAsFile()) return path;
    auto name = path.fromLastOccurrenceOf("/", false, false).fromLastOccurrenceOf("\\", false, false);
    auto dir = recordingsDirectory();
    for (auto d : { dir, dir.getChildFile("Takes"), dir.getChildFile("Imported") })
        if (d.getChildFile(name).existsAsFile()) return d.getChildFile(name).getFullPathName();
    return path;
}

std::shared_ptr<ClipAudio> ArrangeAudio::read(const juce::File& f) {
    juce::AudioFormatManager fm;
    fm.registerBasicFormats();
    std::unique_ptr<juce::AudioFormatReader> r(fm.createReaderFor(f));
    if (!r || r->lengthInSamples <= 0) return nullptr;
    auto a = std::make_shared<ClipAudio>();
    a->rate = r->sampleRate;
    int n = int(std::min<juce::int64>(r->lengthInSamples, juce::int64(r->sampleRate * 60 * 30)));
    juce::AudioBuffer<float> b(2, n);
    r->read(&b, 0, n, 0, true, true);
    int rc = r->numChannels > 1 ? 1 : 0;
    a->left.assign(b.getReadPointer(0), b.getReadPointer(0) + n);
    a->right.assign(b.getReadPointer(rc), b.getReadPointer(rc) + n);
    auto summary = [&](int block, std::vector<float>& lo, std::vector<float>& hi) {
        size_t c = size_t((n + block - 1) / block);
        lo.assign(c, 0); hi.assign(c, 0);
        for (size_t k = 0; k < c; ++k) {
            float l = 1, h = -1;
            for (int i = int(k) * block; i < std::min(int(k + 1) * block, n); ++i) { float x = (a->left[size_t(i)] + a->right[size_t(i)]) * 0.5f; l = std::min(l, x); h = std::max(h, x); }
            lo[k] = l; hi[k] = h;
        }
    };
    summary(32, a->lo32, a->hi32);
    summary(1024, a->lo1k, a->hi1k);
    return a;
}

std::shared_ptr<ClipAudio> ArrangeAudio::audio(const juce::String& path) {
    auto p = resolve(path);
    if (auto it = loaded.find(p); it != loaded.end()) return it->second;
    if (loading.count(p) || failed.count(p)) return nullptr;
    loading.insert(p);
    pool.addJob([this, p] {
        auto a = read(juce::File(p));
        juce::MessageManager::callAsync([this, p, a] {
            loading.erase(p);
            if (a) loaded[p] = a; else failed.insert(p);
            ++generation;
            for (auto* n : nodes) n->rebuild();
        });
    });
    return nullptr;
}
bool ArrangeAudio::isMissing(const juce::String& path) const { return failed.count(resolve(path)) > 0; }
void ArrangeAudio::registerNode(ArrangeNode* n) { if (std::find(nodes.begin(), nodes.end(), n) == nodes.end()) nodes.push_back(n); }
void ArrangeAudio::unregisterNode(ArrangeNode* n) { nodes.erase(std::remove(nodes.begin(), nodes.end(), n), nodes.end()); }

// ---------------------------------------------------------------- the node

std::function<void(ArrangeNode*, std::vector<ArrangeTake>)> ArrangeNode::onTakes;
static std::set<ArrangeNode*>& liveNodes() { static std::set<ArrangeNode*> s; return s; }

ArrangeNode::ArrangeNode(const ModuleSpec& s, double sr) : DSPNode(s, sr), juce::Thread("polje nieuk arrange rec") {
    trackData = ArrangeLayout::defaultTracks();
    for (size_t i = 0; i < mix.size(); ++i) mix[i] = trackData[i];
    capFrames = int(sr * 6);
    for (auto& r : rings) r.store(nullptr);
    if (juce::MessageManager::getInstanceWithoutCreating()) liveNodes().insert(this);
    startThread();
}
ArrangeNode::~ArrangeNode() {
    stopThread(2000);
    liveNodes().erase(this);
    if (juce::MessageManager::getInstanceWithoutCreating()) ArrangeAudio::shared().unregisterNode(this);
    slot.store(nullptr);
}

std::map<std::string, std::vector<float>> ArrangeNode::defaultData() const {
    return { { ArrangeLayout::clipsKey, {} }, { ArrangeLayout::filesKey, {} }, { ArrangeLayout::tracksKey, ArrangeLayout::defaultTracks() },
             { ArrangeLayout::loopKey, { 0, 16 } } };
}

void ArrangeNode::setData(const std::string& key, const std::vector<float>& v) {
    if (key == ArrangeLayout::clipsKey) clips = ArrangeClip::decode(v);
    else if (key == ArrangeLayout::filesKey) files = ArrangeClip::decodeFiles(v);
    else if (key == ArrangeLayout::tracksKey) {
        auto t = ArrangeLayout::defaultTracks();
        for (size_t i = 0; i < std::min(v.size(), t.size()); ++i) if (std::isfinite(v[i])) t[i] = v[i];
        trackData = t;
        for (int k = 0; k < ArrangeLayout::tracks; ++k)
            if (t[size_t(k * ArrangeLayout::trackFields + 4)] > 0.5f && !ringStore[size_t(k)]) {
                ringStore[size_t(k)].reset(new float[size_t(capFrames * 2)]());
                rings[size_t(k)].store(ringStore[size_t(k)].get());
            }
        for (size_t i = 0; i < mix.size(); ++i) mix[i] = t[i];
        return;
    } else if (key == ArrangeLayout::loopKey) {
        if (v.size() >= 2 && std::isfinite(v[0]) && std::isfinite(v[1]) && v[1] > v[0]) loopRange = { v[0], v[1] };
    } else return;
    if (juce::MessageManager::getInstanceWithoutCreating()) ArrangeAudio::shared().registerNode(this);
    rebuild();
}

std::shared_ptr<ClipAudio> ArrangeNode::audioFor(const ArrangeClip& c) {
    if (c.file < 0 || c.file >= int(files.size())) return nullptr;
    if (!juce::MessageManager::getInstanceWithoutCreating()) {
        // the offline renderer: read it right here
        static std::map<juce::String, std::shared_ptr<ClipAudio>> cache;
        auto p = ArrangeAudio::resolve(files[size_t(c.file)]);
        if (!cache.count(p)) cache[p] = ArrangeAudio::read(juce::File(p));
        return cache[p];
    }
    return ArrangeAudio::shared().audio(files[size_t(c.file)]);
}

void ArrangeNode::fades(const std::vector<ArrangeClip>& clips, std::vector<double>& fin, std::vector<double>& fout) {
    fin.resize(clips.size()); fout.resize(clips.size());
    for (size_t i = 0; i < clips.size(); ++i) { fin[i] = clips[i].fadeIn; fout[i] = clips[i].fadeOut; }
    // crossfades: where a clip starts inside the one before it on its track, both fade over the overlap
    for (int t = 0; t < ArrangeLayout::tracks; ++t) {
        std::vector<size_t> idx;
        for (size_t i = 0; i < clips.size(); ++i) if (clips[i].track == t) idx.push_back(i);
        std::sort(idx.begin(), idx.end(), [&](size_t a, size_t b) { return clips[a].start < clips[b].start; });
        for (size_t k = 0; k < idx.size(); ++k)
            for (size_t j = k + 1; j < idx.size(); ++j) {
                auto &a = clips[idx[k]], &b = clips[idx[j]];
                if (b.start >= a.end()) continue;
                double overlap = std::min({ a.end() - b.start, b.length, a.length });
                fout[idx[k]] = std::max(fout[idx[k]], overlap);
                fin[idx[j]] = std::max(fin[idx[j]], overlap);
            }
    }
}

void ArrangeNode::rebuild() {
    auto snap = std::make_shared<Snapshot>();
    std::vector<double> fin, fout;
    fades(clips, fin, fout);
    for (size_t i = 0; i < clips.size(); ++i) {
        auto& c = clips[i];
        auto a = audioFor(c);
        if (!a || a->frames() < 2) continue;
        snap->keep.push_back(a);
        snap->clips.push_back({ c.track, c.start, c.end(), c.offset * a->rate, c.gain, std::min(fin[i], c.length), std::min(fout[i], c.length),
                                a->left.data(), a->right.data(), a->frames(), a->rate / sampleRate * c.speed() });
    }
    snap->loopStart = loopRange.first; snap->loopEnd = loopRange.second;
    // the audio thread reads the raw pointer; the shared copies keep it (and the old ones, for a while) alive
    slot.store(snap.get(), std::memory_order_release);
    auto now = juce::Time::getMillisecondCounter();
    if (live) retired.emplace_back(live, now);
    live = snap;
    retired.erase(std::remove_if(retired.begin(), retired.end(), [&](auto& r) { return now - r.second > 2000; }), retired.end());
}

double ArrangeNode::position(double beat, bool loop, double a, double b) {
    // looping, the transport's start is the loop's start
    if (!loop || b <= a) return beat;
    return a + std::fmod(std::max(beat, 0.0), b - a);
}

ArrangeNode::Render ArrangeNode::render(double a, double b, double rate, double secondsPerBeat) {
    Render out;
    int frames = std::max(int((b - a) * secondsPerBeat * rate), 0);
    if (frames <= 0) return out;
    int count = ArrangeLayout::count(base[size_t(ArrangeLayout::trackCount)]);
    std::vector<double> fin, fout;
    fades(clips, fin, fout);
    out.l.assign(size_t(frames), 0); out.r.assign(size_t(frames), 0);
    bool anySolo = false;
    for (int t = 0; t < count; ++t) if (trackData[size_t(t * ArrangeLayout::trackFields + 3)] > 0.5f) anySolo = true;
    double bpf = 1 / (secondsPerBeat * rate);
    for (int t = 0; t < count; ++t) {
        std::vector<size_t> mine;
        for (size_t i = 0; i < clips.size(); ++i) if (clips[i].track == t && clips[i].end() > a && clips[i].start < b) mine.push_back(i);
        if (mine.empty()) continue;
        std::vector<float> l(size_t(frames), 0), r(size_t(frames), 0);
        for (size_t i : mine) {
            auto& c = clips[i];
            if (c.file >= int(files.size())) continue;
            auto au = ArrangeAudio::read(juce::File(ArrangeAudio::resolve(files[size_t(c.file)])));
            if (!au) continue;
            int first = std::max(int((c.start - a) / bpf), 0), last = std::min(int((c.end() - a) / bpf) + 1, frames);
            for (int k = first; k < last; ++k) {
                double p = a + double(k) * bpf;
                if (p < c.start || p >= c.end()) continue;
                double pos = (c.offset + (p - c.start) * secondsPerBeat * c.speed()) * au->rate;
                int j = int(pos);
                if (j < 0 || j + 1 >= au->frames()) continue;
                float f = float(pos - double(j)), g = c.gain;
                if (fin[i] > 0 && p - c.start < fin[i]) g *= std::sin(float((p - c.start) / fin[i]) * juce::MathConstants<float>::halfPi);
                if (fout[i] > 0 && c.end() - p < fout[i]) g *= std::sin(float((c.end() - p) / fout[i]) * juce::MathConstants<float>::halfPi);
                l[size_t(k)] += (au->left[size_t(j)] + (au->left[size_t(j + 1)] - au->left[size_t(j)]) * f) * g;
                r[size_t(k)] += (au->right[size_t(j)] + (au->right[size_t(j + 1)] - au->right[size_t(j)]) * f) * g;
            }
        }
        int fi = t * ArrangeLayout::trackFields;
        float vol = std::clamp(trackData[size_t(fi)], 0.0f, 2.0f), pan = std::clamp(trackData[size_t(fi + 1)], -1.0f, 1.0f);
        float q = (pan + 1) * juce::MathConstants<float>::pi / 4;
        float gl = std::min(vol * std::cos(q) * 1.41421356f, vol), gr = std::min(vol * std::sin(q) * 1.41421356f, vol);
        for (int k = 0; k < frames; ++k) { l[size_t(k)] *= gl; r[size_t(k)] *= gr; }
        bool audible = trackData[size_t(fi + 2)] < 0.5f && (!anySolo || trackData[size_t(fi + 3)] > 0.5f);
        if (audible) for (int k = 0; k < frames; ++k) { out.l[size_t(k)] += l[size_t(k)]; out.r[size_t(k)] += r[size_t(k)]; }
        out.tracks[t] = { std::move(l), std::move(r) };
    }
    float master = std::pow(10.0f, base[size_t(ArrangeLayout::level)] / 20);
    for (int k = 0; k < frames; ++k) { out.l[size_t(k)] = soft(out.l[size_t(k)] * master); out.r[size_t(k)] = soft(out.r[size_t(k)] * master); }
    return out;
}

void ArrangeNode::process(int frames, const float* const* in, uint64_t con, ProcessContext& ctx) {
    using namespace ArrangeLayout;
    Snapshot* snap = slot.load(std::memory_order_acquire);
    float master = std::pow(10.0f, params[level] / 20);
    bool looping = params[loop] > 0.5f;
    double la = snap ? snap->loopStart : 0, lb = snap ? snap->loopEnd : 0;
    double spb = ctx.samplesPerBeat;
    int count = ArrangeLayout::count(params[trackCount]);
    float* oL = out(0); float* oR = out(1);
    std::fill(oL, oL + frames, 0.0f); std::fill(oR, oR + frames, 0.0f);
    bool anySolo = false;
    for (int t = 0; t < count; ++t) if (mix[size_t(t * trackFields + 3)] > 0.5f) anySolo = true;
    for (int t = 0; t < count; ++t) {
        int f = t * trackFields;
        float vol = std::clamp(mix[size_t(f)], 0.0f, 2.0f), pan = std::clamp(mix[size_t(f + 1)], -1.0f, 1.0f);
        bool audible = mix[size_t(f + 2)] < 0.5f && (!anySolo || mix[size_t(f + 3)] > 0.5f);
        bool hasL = isConnected(con, 2 * t), hasR = isConnected(con, 2 * t + 1);
        if (hasL || hasR) {
            const float* iL = hasL ? in[2 * t] : in[2 * t + 1]; const float* iR = hasR ? in[2 * t + 1] : iL;
            std::copy(iL, iL + frames, busL); std::copy(iR, iR + frames, busR);
        } else { std::fill(busL, busL + frames, 0.0f); std::fill(busR, busR + frames, 0.0f); }
        if (snap && ctx.running) {
            double b0 = position(ctx.beat[0], looping, la, lb), b1 = position(ctx.beat[frames - 1], looping, la, lb);
            double lo = std::min(b0, b1), hi = std::max(b0, b1);
            bool wrapped = b1 < b0;
            for (auto& c : snap->clips) {
                if (c.track != t || !(wrapped || (c.end > lo && c.start <= hi))) continue;
                for (int i = 0; i < frames; ++i) {
                    double p = position(ctx.beat[i], looping, la, lb);
                    if (p < c.start || p >= c.end) continue;
                    double pos = c.offsetFrames + (p - c.start) * spb * c.ratio;
                    int k = int(pos);
                    if (k < 0 || k + 1 >= c.frames) continue;
                    float fr = float(pos - double(k));
                    float g = c.gain;
                    if (c.fadeIn > 0 && p - c.start < c.fadeIn) g *= std::sin(float((p - c.start) / c.fadeIn) * juce::MathConstants<float>::halfPi);
                    if (c.fadeOut > 0 && c.end - p < c.fadeOut) g *= std::sin(float((c.end - p) / c.fadeOut) * juce::MathConstants<float>::halfPi);
                    busL[i] += (c.l[k] + (c.l[k + 1] - c.l[k]) * fr) * g;
                    busR[i] += (c.r[k] + (c.r[k + 1] - c.r[k]) * fr) * g;
                }
            }
        }
        float q = (pan + 1) * juce::MathConstants<float>::pi / 4;
        float gl = audible ? vol * std::cos(q) * 1.41421356f : 0, gr = audible ? vol * std::sin(q) * 1.41421356f : 0;
        float* tL = out(firstTrackOutlet + 2 * t); float* tR = out(firstTrackOutlet + 1 + 2 * t);
        float pk = 0;
        for (int i = 0; i < frames; ++i) {
            float l = busL[i] * std::min(gl, vol), r = busR[i] * std::min(gr, vol);
            tL[i] = l; tR[i] = r; oL[i] += l; oR[i] += r;
            pk = std::max({ pk, std::abs(l), std::abs(r) });
        }
        levels[size_t(t)] = std::max(pk, levels[size_t(t)] * 0.94f);
    }
    for (int t = count; t < tracks; ++t) levels[size_t(t)] = 0;
    float mpk = 0;
    for (int i = 0; i < frames; ++i) {
        oL[i] = soft(oL[i] * master); oR[i] = soft(oR[i] * master);
        mpk = std::max({ mpk, std::abs(oL[i]), std::abs(oR[i]) });
    }
    levels[32] = std::max(mpk, levels[32] * 0.94f);
    readouts[mixSlot] = levels[32];
    readouts[posSlot] = float(position(ctx.beat[frames - 1], looping, la, lb));
    readouts[secondsPerBeatSlot] = float(spb / sampleRate);
    record(frames, in, con, ctx, looping, la, lb);
}

void ArrangeNode::record(int frames, const float* const* in, uint64_t con, ProcessContext& ctx, bool looping, double la, double lb) {
    using namespace ArrangeLayout;
    bool want = params[rec] > 0.5f;
    uint32_t armed = 0;
    int count = ArrangeLayout::count(params[trackCount]);
    for (int t = 0; t < count; ++t) if (mix[size_t(t * trackFields + 4)] > 0.5f) armed |= 1u << t;
    if (recState == 2 && (!want || !ctx.running)) {
        takeLength.store(std::max(recTo - recFrom, 0.0));
        takeActive.store(false);
        recState = 0;
    }
    if (!want) recState = 0;
    if (want && recState == 0 && armed) recState = 1;
    int startAt = -1;
    if (recState == 1 && ctx.running) {
        if (ctx.beat[0] < 0.02) startAt = 0;
        else for (int i = 1; i < frames; ++i) if (std::floor(ctx.beat[i] / 4) != std::floor(ctx.beat[i - 1] / 4)) { startAt = i; break; }
        if (startAt >= 0) {
            recArmed = armed;
            for (int t = 0; t < tracks; ++t) startPos[size_t(t)].store(writePos[size_t(t)].load());
            takeArmed.store(armed);
            takeStart.store(position(ctx.beat[startAt], looping, la, lb));
            takeSession.fetch_add(1);
            takeActive.store(true);
            readouts[recStartSlot] = float(position(ctx.beat[startAt], looping, la, lb));
            recFrom = ctx.beat[startAt]; recTo = recFrom;
            recState = 2;
        }
    }
    if (recState == 2) {
        int from = std::max(startAt, 0);
        recTo = ctx.beat[frames - 1];
        for (int t = 0; t < tracks; ++t) {
            if (!(recArmed & (1u << t))) continue;
            float* ring = rings[size_t(t)].load();
            if (!ring) continue;
            bool hasL = isConnected(con, 2 * t), hasR = isConnected(con, 2 * t + 1);
            const float* iL = hasL ? in[2 * t] : (hasR ? in[2 * t + 1] : nullptr);
            const float* iR = hasR ? in[2 * t + 1] : iL;
            long w = writePos[size_t(t)].load(std::memory_order_relaxed), r = readPos[size_t(t)].load(std::memory_order_acquire);
            int n = std::max(0, std::min(frames - from, int(capFrames - (w - r))));
            for (int i = 0; i < n; ++i) {
                size_t idx = size_t(((w + i) % capFrames) * 2);
                ring[idx] = iL ? iL[from + i] : 0; ring[idx + 1] = iR ? iR[from + i] : 0;
            }
            writePos[size_t(t)].store(w + n, std::memory_order_release);
        }
    }
    readouts[recSlot] = recState == 2 ? 1.0f : (recState == 1 ? 0.5f : 0.0f);
}

void ArrangeNode::run() {
    while (!threadShouldExit()) { wait(50); drain(); }
    drain();
    finish();
}

void ArrangeNode::drain() {
    int s = takeSession.load();
    bool active = takeActive.load();
    if (s != writerSession) {            // a new take (even one that's already over: write it all)
        finish();
        writerSession = s;
        uint32_t armed = takeArmed.load();
        auto dir = recordingsDirectory().getChildFile("Takes");
        dir.createDirectory();
        auto stamp = juce::Time::getCurrentTime().formatted("%Y-%m-%d %H.%M.%S");
        for (int t = 0; t < ArrangeLayout::tracks; ++t) {
            if (!(armed & (1u << t))) continue;
            readPos[size_t(t)].store(startPos[size_t(t)].load());
            auto f = dir.getChildFile("take " + stamp + " track " + juce::String(t + 1) + ".wav");
            auto os = f.createOutputStream();
            if (!os) continue;
            juce::WavAudioFormat wav;
            auto* raw = os.release();
            std::unique_ptr<juce::AudioFormatWriter> w(wav.createWriterFor(raw, sampleRate, 2, 32, {}, 0));
            if (!w) { delete raw; continue; }
            writers[t] = std::move(w); writerFiles[t] = f; writerFrames[t] = 0;
        }
    }
    for (auto& [t, w] : writers) {
        float* ring = rings[size_t(t)].load();
        if (!ring) continue;
        long wp = writePos[size_t(t)].load(std::memory_order_acquire), pos = readPos[size_t(t)].load();
        if (wp <= pos) continue;
        juce::AudioBuffer<float> b(2, 4096);
        while (pos < wp) {
            int n = int(std::min<long>(4096, wp - pos));
            for (int i = 0; i < n; ++i) {
                size_t idx = size_t(((pos + i) % capFrames) * 2);
                b.setSample(0, i, ring[idx]); b.setSample(1, i, ring[idx + 1]);
            }
            w->writeFromAudioSampleBuffer(b, 0, n);
            pos += n; writerFrames[t] += n;
        }
        readPos[size_t(t)].store(wp, std::memory_order_release);
    }
    if (!active && !writers.empty()) finish();
}

void ArrangeNode::finish() {
    if (writers.empty()) return;
    double start = takeStart.load(), length = takeLength.load();
    std::vector<ArrangeTake> takes;
    for (auto& [t, w] : writers) {
        long frames = writerFrames[t];
        if (frames > 0) takes.push_back({ t, writerFiles[t], start, length > 0 ? length : double(frames) / (sampleRate * 0.5) });
    }
    writers.clear(); writerFiles.clear(); writerFrames.clear();     // the files close here
    if (takes.empty() || !juce::MessageManager::getInstanceWithoutCreating()) return;
    auto* self = this;
    juce::MessageManager::callAsync([self, takes] {
        if (liveNodes().count(self) && onTakes) onTakes(self, takes);
    });
}

Factory factoryArrange(const std::string& k) {
    if (k == "arrange") return make<ArrangeNode>();
    return nullptr;
}

} // namespace pn
