// arrange: 1–32 tracks of audio clips on a timeline, recorded per track (a port of Arrange.swift).
#pragma once
#include "Modules.h"
#include "Buffers.h"

namespace pn {

namespace ArrangeLayout {
    constexpr int tracks = 32, defaultTrackCount = 8, trackFields = 5;
    constexpr int trackCount = 0, level = 1, snap = 2, loop = 3, rec = 4;
    constexpr int posSlot = 0, recSlot = 1, recStartSlot = 2, secondsPerBeatSlot = 3, mixSlot = 4;
    constexpr int multiOutlet = 2, firstTrackOutlet = 3;
    inline const std::string clipsKey = "clips", filesKey = "files", tracksKey = "tracks", loopKey = "loop";
    inline const double snapBeats[] = { 0, -1, 0.25, 0.5, 1, 2, 4 };
    constexpr int snapCount = 7;
    std::vector<float> defaultTracks();
    inline int count(float v) { return std::clamp(std::isfinite(v) ? int(std::lround(v)) : defaultTrackCount, 1, tracks); }
}

struct ArrangeClip {
    int track = 0;
    double start = 0, length = 1, offset = 0;   // beats, beats, seconds into the file
    float gain = 1;
    double fadeIn = 0, fadeOut = 0;             // beats
    int file = 0;
    float transpose = 0;                        // semitones (re-pitched: up = higher and faster)
    double end() const { return start + length; }
    double speed() const { return std::pow(2.0, double(transpose) / 12); }
    bool operator==(const ArrangeClip& o) const {
        return track == o.track && start == o.start && length == o.length && offset == o.offset && gain == o.gain
            && fadeIn == o.fadeIn && fadeOut == o.fadeOut && file == o.file && transpose == o.transpose;
    }
    static std::vector<ArrangeClip> decode(const std::vector<float>& v);
    static std::vector<float> encode(const std::vector<ArrangeClip>& c);
    static std::vector<juce::String> decodeFiles(const std::vector<float>& v);
    static std::vector<float> encodeFiles(const std::vector<juce::String>& f);
};

/// A file's audio in memory at its own rate, with waveform summaries.
struct ClipAudio {
    std::vector<float> left, right;
    double rate = 48000;
    std::vector<float> lo32, hi32, lo1k, hi1k;
    int frames() const { return int(left.size()); }
    double seconds() const { return double(left.size()) / std::max(rate, 1.0); }
    std::pair<float, float> minMax(int a, int b) const;
};

class ArrangeNode;

/// Every audio file arrange boxes use, loaded once in the background (main thread API).
class ArrangeAudio {
public:
    static ArrangeAudio& shared();
    std::shared_ptr<ClipAudio> audio(const juce::String& path);   // nullptr while it loads
    bool isMissing(const juce::String& path) const;
    void registerNode(ArrangeNode* n);
    void unregisterNode(ArrangeNode* n);
    int generation = 0;
    static juce::String resolve(const juce::String& path);
    static std::shared_ptr<ClipAudio> read(const juce::File& f);
private:
    std::map<juce::String, std::shared_ptr<ClipAudio>> loaded;
    std::set<juce::String> loading, failed;
    std::vector<ArrangeNode*> nodes;
    juce::ThreadPool pool { 2 };
};

struct ArrangeTake { int track; juce::File file; double start, length; };

class ArrangeNode : public DSPNode, private juce::Thread {
public:
    ArrangeNode(const ModuleSpec& s, double sr);
    ~ArrangeNode() override;
    void process(int frames, const float* const* in, uint64_t con, ProcessContext& ctx) override;
    void setData(const std::string& key, const std::vector<float>& values) override;
    std::map<std::string, std::vector<float>> defaultData() const override;
    // main thread
    std::vector<ArrangeClip> clips;
    std::vector<juce::String> files;
    std::vector<float> trackData;
    std::pair<double, double> loopRange { 0, 16 };
    std::shared_ptr<ClipAudio> audioFor(const ArrangeClip& c);
    void rebuild();
    /// The clips from beat a to b rendered offline: the mix and each track with clips there (stems).
    struct Render { std::vector<float> l, r; std::map<int, std::pair<std::vector<float>, std::vector<float>>> tracks; };
    Render render(double a, double b, double rate, double secondsPerBeat);
    std::array<float, 33> levels {};               // each track's level, then the mix (UI)
    static std::function<void(ArrangeNode*, std::vector<ArrangeTake>)> onTakes;
    static double position(double beat, bool loop, double a, double b);
    static void fades(const std::vector<ArrangeClip>& clips, std::vector<double>& fin, std::vector<double>& fout);
    static float soft(float x) { float a = std::abs(x); return a <= 2 ? x : (x < 0 ? -1.0f : 1.0f) * (2 + 2 * std::tanh((a - 2) / 2)); }

private:
    struct RTClip { int track; double start, end, offsetFrames; float gain; double fadeIn, fadeOut; const float* l; const float* r; int frames; double ratio; };
    struct Snapshot { std::vector<RTClip> clips; std::vector<std::shared_ptr<ClipAudio>> keep; double loopStart = 0, loopEnd = 16; };
    std::atomic<Snapshot*> slot { nullptr };
    std::shared_ptr<Snapshot> live;
    std::vector<std::pair<std::shared_ptr<Snapshot>, juce::uint32>> retired;
    std::array<float, 32 * 5> mix {};
    float busL[kMaxBlock] = {}, busR[kMaxBlock] = {};
    // recording: a ring per track, made (main thread) the first time the track is armed
    void record(int frames, const float* const* in, uint64_t con, ProcessContext& ctx, bool looping, double la, double lb);
    void run() override;
    void drain();
    void finish();
    int capFrames;
    std::array<std::unique_ptr<float[]>, 32> ringStore;
    std::array<std::atomic<float*>, 32> rings {};
    std::array<std::atomic<long>, 32> writePos {}, readPos {}, startPos {};
    std::atomic<uint32_t> takeArmed { 0 };
    std::atomic<int> takeSession { 0 };
    std::atomic<bool> takeActive { false };
    std::atomic<double> takeStart { 0 }, takeLength { 0 };
    int recState = 0;
    uint32_t recArmed = 0;
    double recFrom = 0, recTo = 0;
    std::map<int, std::unique_ptr<juce::AudioFormatWriter>> writers;
    std::map<int, juce::File> writerFiles;
    std::map<int, long> writerFrames;
    int writerSession = 0;
};

Factory factoryArrange(const std::string& kind);

} // namespace pn
