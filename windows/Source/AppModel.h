// The app's state and every edit (AppModel.swift): the patch, undo, selection, cables, groups, automation,
// audio devices, files, autosave, audio buffers. Same behaviour as the Mac / iPad app.
#pragma once
#include "UIBase.h"

namespace pn {

struct PendingCable { juce::String node; int port = 0; bool fromOutput = true; Pt point; };
struct DeviceChoice { juce::String id, name; };
struct HelpTopic { juce::String id, title, body; bool operator==(const HelpTopic& o) const { return id == o.id; } };

namespace ControlLink {
    struct Update { juce::String node; int index; float value; };
    bool isControl(const Patch& p, const juce::String& id);
    Patch reconciled(const Patch& p);
    std::vector<Update> updates(const Patch& p, const juce::String& id, int index, float value);
}

namespace TidyLayout { std::map<juce::String, Pt> layout(const Patch& p, const HardwareCounts& hw); }

namespace PatchStore {
    juce::File folder();
    juce::File autosaveFile();
    juce::File defaultFile();
    juce::File defaultAudioFolder();
    std::optional<Patch> loadAutosave();
    void saveAutosave(const Patch& p);
    std::optional<Patch> loadUserDefault();
    Patch builtIn();
    Patch makeDefault();
}

/// A photo behind the whole canvas (colours panel -> background picture): fills the window, stays still while
/// you pan and zoom. Copied into the app's folder.
namespace BackgroundPicture {
    const juce::Image& image();          // invalid when none is set
    bool set(const juce::File& f);
    void remove();
}

class AppModel : public juce::AudioIODeviceCallback, private juce::AsyncUpdater, private juce::Timer {
public:
    AppModel();
    ~AppModel() override;

    // ---------------------------------------------------------------- state
    Patch patch;
    GraphHost host;
    std::set<juce::String> selectedNodes;
    juce::String selectedCable;
    std::optional<PendingCable> pendingCable;
    std::optional<Pt> finderAt;               // canvas point where the module list is open
    juce::String replaceTarget;
    Pt viewOffset { 30, 30 };
    float viewScale = 1;
    bool isZooming = false;
    Pt viewSize;
    bool selectMode = false, helpMode = false, showFiles = false, showColours = false, hideCables = false, lightScheme = false;
    std::vector<HelpTopic> helpTopics;
    // 3D mode: the board tilted in perspective, boxes floating at their heights (PatchNode.z)
    bool threeD = false;
    double orbitPitch = 52, orbitYaw = 0;
    void orbit(double pitch, double yaw) { orbitPitch = std::clamp(pitch, 8.0, 78.0); orbitYaw = std::fmod(yaw, 360.0); changed(); }
    static constexpr double liftHeight = 170;
    std::vector<int> sectionIndices(const std::string& category) const;
    bool sectionLifted(const std::string& category) const;
    void toggleLift(const std::string& category);
    void layerBySection();
    void putEverythingDown();
    void setHeight(const juce::String& id, double z);
    bool isRunning = false;
    int transport = 0;                        // 0 play, 1 pause, 2 stop
    juce::String audioStatus = "audio off";
    juce::String audioError;
    HardwareCounts hw;
    std::vector<DeviceChoice> inputChoices, outputChoices;
    juce::String inputUID, outputUID;         // "" = automatic / default, "none" / "off"
    juce::String inputName = juce::String::fromUTF8("\xe2\x80\x94"), outputName = juce::String::fromUTF8("\xe2\x80\x94");
    std::vector<juce::File> browserFolders;
    std::set<juce::String> autoRecording, insertCandidates;
    std::map<juce::String, std::set<int>> loadingPads;
    juce::String audioImportTarget;
    bool hasUserDefault = false;
    float appCPU = 0;

    /// boxes being dragged (canvas points); the patch is written once when they're let go
    struct DragState { std::set<juce::String> ids; Pt delta; Pt offset(const juce::String& id) const { return ids.count(id) ? delta : Pt(); } } dragState;
    std::function<void()> onDragMoved;

    // listeners: the canvas, the top bar … (called once per message-loop turn after changes)
    std::vector<std::function<void()>> listeners;
    void changed() { triggerAsyncUpdate(); }

    // ---------------------------------------------------------------- coordinates
    Pt toCanvas(Pt p) const { return { (p.x - viewOffset.x) / viewScale, (p.y - viewOffset.y) / viewScale }; }
    Pt toScreen(Pt p) const { return { p.x * viewScale + viewOffset.x, p.y * viewScale + viewOffset.y }; }
    Pt viewCenterInCanvas() const { return toCanvas({ viewSize.x / 2 - 90, viewSize.y / 3 }); }
    void zoomBy(float factor, Pt anchor);
    void setView(Pt offset, float scale);
    std::function<void()> onViewport;
    bool hasContent(Pt c);

    // ---------------------------------------------------------------- editing
    DSPNode* node(const juce::String& id) { return host.node(id); }
    int index(const juce::String& id) const { return patch.index(id); }
    const PatchNode* nodeFor(const juce::String& id) const { int i = patch.index(id); return i < 0 ? nullptr : &patch.nodes[size_t(i)]; }
    void addNode(const std::string& kind, Pt p);
    void beginReplace(const juce::String& id);
    void replaceNode(const juce::String& id, const std::string& kind);
    void duplicate(const juce::String& id);
    void removeSelection();
    void removeNode(const juce::String& id);
    void removeCable(const juce::String& id);
    void select(const juce::String& id);
    void toggleSelected(const juce::String& id);
    void selectIn(Rect r, bool adding);
    void duplicateSelection();
    void clearSelection();
    std::vector<PatchGroup> selectedGroups() const;
    void groupSelection();
    void ungroupSelection();
    void selectGroup(const PatchGroup& g);
    void renameGroup(const juce::String& id, const juce::String& name);
    std::optional<Rect> groupRect(const PatchGroup& g) const;
    void bypassSelection();
    void beginGroupDrag();
    void groupDrag(Pt d);
    void endGroupDrag();
    void nativeDragBegan(const juce::String& id);
    void nativeDragMoved(Pt screenDelta, Pt point);
    void nativeDragEnded();
    void dragMove(const std::set<juce::String>& ids, Pt d);
    void endDragMove();
    void moveNode(const juce::String& id, Pt p);
    void resizeNode(const juce::String& id, std::optional<float> width, std::optional<float> display);
    void toggleBypass(const juce::String& id);
    void updateInsertCandidate(const juce::String& id, Pt screen);
    void finishInsert(const juce::String& id);
    bool allCollapsed() const;
    void toggleCollapseAll();
    void tidy();
    void toggleCollapsed(const juce::String& id);
    void setParam(const juce::String& id, int index, float value, bool linked = true);
    float value(const PatchNode& n, int index, const ModuleSpec& s) const;
    void fire(const juce::String& id, int index) { if (auto* n = node(id)) n->base[size_t(index)] = 1; }
    bool isModulated(const juce::String& id, int param) const;
    bool isPortConnected(const juce::String& id, int port, bool output) const;
    void setText(const juce::String& id, const juce::String& text);
    struct HighlightColour { const char* name; const char* hex; };
    static const std::vector<HighlightColour> highlightColours;
    void setHighlight(const juce::String& id, std::optional<juce::String> hex);
    void setData(const juce::String& id, const std::map<std::string, std::vector<float>>& entries, bool step = true);
    void setData(const juce::String& id, const std::string& key, const std::vector<float>& v, bool step = true) { setData(id, { { key, v } }, step); }
    static const std::set<std::string> patternKinds;
    void clearPattern(const juce::String& id);

    // automation
    bool hasAutomation(const PatchNode& n) const;
    bool isAutomated(const PatchNode& n, int index, const ModuleSpec& s) const;
    bool canAutomate(const ModuleSpec& s) const;
    void startAutoRecord(const juce::String& id);
    void stopAutoRecord(const juce::String& id);
    void clearAutomation(const juce::String& id);

    // cables
    void finishCable(Pt screen);
    void connect(const juce::String& a, int ap, const juce::String& b, int bp);
    bool pickUpCable(const juce::String& node, int port, Pt point);

    // transport / tempo
    void setTransport(int t) { transport = t; host.transport(t); changed(); }
    bool tempoEditable() const;
    double setTempoValue() const;
    void setTempo(double bpm);
    double bpm() const { return host.clockBPM(); }
    bool externalClock() const { return host.externalClock(); }

    // files
    void newPatch();
    void load(const Patch& p);
    bool openFile(const juce::File& f);
    bool saveFile(const juce::File& f);
    void setAsDefault();
    void resetDefault();
    void scheduleAutosave();

    // undo
    bool canUndo() const { return history.canUndo() || patch != history.committed; }
    bool canRedo() const { return history.canRedo() && patch == history.committed; }
    void undo();
    void redo();
    void patchChanged();                      // call after editing `patch` directly: an undo step once edits pause

    // audio
    void startAudio();
    void stopAudio();
    void restartAudio();
    void refreshDevices();
    void selectInput(const juce::String& uid);
    void selectOutput(const juce::String& uid);
    float cpuLoad() const { return load_.load(); }

    // buffers, rack pads
    static juce::File samplesFolder();
    bool loadAudio(const juce::File& f, const juce::String& id);
    void loadIntoSelection(const juce::File& f);
    bool loadPads(const juce::String& id, int from, const juce::Array<juce::File>& files);
    void resetPad(const juce::String& id, int k);
    void copyBuffer(const juce::String& src, const juce::String& dst);
    juce::String label(const PatchNode& n) const;
    void audition(const juce::String& id, double x);

    // browser folders
    void addFolder(const juce::File& f);
    void removeFolder(const juce::File& f);

    // help
    void hoverHelp(const HelpTopic& t, bool inside);

    // colours
    void setLight(bool l);
    void coloursChanged() { CustomColours::version++; changed(); }

    // audio callback
    void audioDeviceIOCallbackWithContext(const float* const* in, int numIn, float* const* out, int numOut, int n,
                                          const juce::AudioIODeviceCallbackContext&) override;
    void audioDeviceAboutToStart(juce::AudioIODevice*) override;
    void audioDeviceStopped() override {}

    juce::AudioDeviceManager devices;

private:
    void handleAsyncUpdate() override;
    void timerCallback() override;
    void topologyChanged();
    void followClockInputs();
    void syncLinked(const juce::String& id, int index, float value);
    void followSync(int i, const juce::String& id, const ModuleSpec& s, const std::string& key);
    void rescalePattern(const juce::String& id, const ModuleSpec& s, float from, float to);
    void recordAutomation(const juce::String& id, int index, float value, float previous);
    void autoTick();
    void checkpoint();
    void restore(const Patch& p);
    void restoreBuffers();
    void restoreRacks();
    void watchBuffers();
    void flushBuffersToDisk();
    void copyRackPads(const juce::String& a, const juce::String& b);
    juce::File sampleFile(const juce::String& id) const;
    juce::File padFile(const juce::String& id, int k) const;
    juce::File padNameFile(const juce::String& id, int k) const;
    std::vector<juce::String> audioFileNames(const juce::String& id) const;
    void sampleAppCPU();
    void saveView();

    UndoHistory history;
    bool restoringHistory = false;
    double checkpointAt = 0, autosaveAt = 0, viewSaveAt = 0, analyzeAt = 0;
    juce::String analyzeID;
    std::map<juce::String, Pt> groupDragStart;
    juce::String nativeID; bool nativeGroup = false;
    std::map<juce::String, std::map<int, int>> autoTouched;
    struct RescaleBase { float div; std::vector<float> values; int len; double until; };
    std::map<juce::String, RescaleBase> rescaleBase;
    std::map<juce::String, bool> clockInletPatched;
    std::map<const DSPNode*, int> seenVersion;
    std::set<const DSPNode*> restoredRacks;
    std::map<juce::String, Pt> layoutStart, layoutTarget;
    int layoutStep = -1;
    std::atomic<float> load_ { 0 };
    std::atomic<bool> muteOut { false };
    double lastCPU = -1, lastWall = 0;
    bool wantsAudio = false;
    juce::ThreadPool background { 1 };
    juce::ThreadPool audioJobs { 1 };
    std::atomic<int> audioJob { 0 };
    double nextBufferWatch = 0, nextCPU = 0;
};

} // namespace pn
