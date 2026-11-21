// Buffers.swift: audio held by buffer modules (looper, sampler, stretch …), file I/O, shared helpers.
#pragma once
#include "Engine.h"
#include <thread>

namespace pn {

constexpr int kPlayheadSlot = 16;     // readouts 16…23: playheads (0…1 of the buffer, -1 = none)
constexpr int kBeatSamplesSlot = 6;   // readout: one beat in samples (waveform grid)

struct StereoAudio {
    std::vector<float> left, right;
    StereoAudio() = default;
    StereoAudio(std::vector<float> l, std::vector<float> r) : left(std::move(l)), right(std::move(r)) {}
    explicit StereoAudio(std::vector<float> l) : left(l), right(std::move(l)) {}
    int count() const { return int(std::min(left.size(), right.size())); }
    bool empty() const { return count() == 0; }
    std::vector<float> mono() const {
        std::vector<float> m(static_cast<size_t>(count()));
        for (size_t i = 0; i < m.size(); ++i) m[i] = (left[i] + right[i]) * 0.5f;
        return m;
    }
    void copyInto(float* l, float* r, int n) const {
        if (n <= 0) return;
        std::copy(left.begin(), left.begin() + n, l);
        std::copy(right.begin(), right.begin() + n, r);
    }
};

/// Lets the main thread swap a buffer while the audio thread runs: the node goes silent while busy.
class LoadGuard {
public:
    bool busy() const { return flag.load(std::memory_order_acquire); }
    template <class F> void whileBusy(F body) {
        flag.store(true);
        std::this_thread::sleep_for(std::chrono::milliseconds(30));
        body();
        flag.store(false);
    }
private:
    std::atomic<bool> flag { false };
};

/// Modules whose audio the UI can draw, load into and copy from.
class SampleBufferNode {
public:
    virtual ~SampleBufferNode() = default;
    virtual const float* waveBuffer() const = 0;
    virtual const float* waveBufferR() const = 0;
    virtual int waveLength() const = 0;
    virtual int contentVersion() const = 0;
    virtual bool waveRecording() const = 0;
    virtual int bufferCapacity() const = 0;
    virtual StereoAudio snapshot() const = 0;
    virtual void load(const StereoAudio& audio) = 0;
    virtual int markerCount() const { return 0; }
    virtual int marker(int) const { return 0; }
};

namespace AudioFiles {
    StereoAudio read(const juce::File& f, double sampleRate, double maxSeconds = 60);
    std::vector<float> resample(const std::vector<float>& x, double from, double to);
    bool write(const StereoAudio& a, double sampleRate, const juce::File& f);
    bool isAudio(const juce::File& f);
}

/// Free-running or clock-locked phase accumulator.
struct PhaseClock {
    double phase = 0;
    double advance(bool sync, double hz, double divBeats, double beat, double sampleRate) {
        if (sync) { double p = beat / divBeats; phase = p - std::floor(p); }
        else { phase += hz / sampleRate; if (phase >= 1) phase -= std::floor(phase); }
        return phase;
    }
};

/// Drum / piano rolls: a new division keeps the pattern in time (DSPUtil.swift PatternRescale).
inline std::pair<std::vector<float>, int> patternRescale(const std::vector<float>& values, int lanes, int steps, int length,
                                                         float oldDiv, float newDiv, float empty) {
    double r = Divisions::beats(oldDiv) / Divisions::beats(newDiv);
    if (!std::isfinite(r) || r <= 0 || std::abs(r - 1) <= 1e-9) return { values, length };
    int newLen = std::clamp(int(std::round(double(length) * r)), 1, steps);
    std::vector<float> out(size_t(lanes * steps), empty);
    for (int lane = 0; lane < lanes; ++lane)
        for (int i = 0; i < std::min(length, steps); ++i) {
            int k = lane * steps + i;
            if (k >= int(values.size()) || values[size_t(k)] == empty || !std::isfinite(values[size_t(k)])) continue;
            double pos = double(i) * r;
            int j = r >= 1 ? int(std::round(pos)) : int(std::floor(pos) + 1e-9);
            if (j < 0 || j >= newLen) continue;
            size_t d = size_t(lane * steps + j);
            if (out[d] == empty || (empty == 0 && values[size_t(k)] > out[d])) out[d] = values[size_t(k)];
        }
    return { out, newLen };
}

/// Onset positions (sampler transient chop), main thread only.
std::vector<int> detectTransients(const float* buf, int count, double sampleRate, float sensitivity, int maxSlices = 128);

/// Where rec writes (Documents/polje nieuk Recordings).
juce::File recordingsDirectory();

} // namespace pn
