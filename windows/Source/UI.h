#pragma once
#include "Engine.h"

namespace pn {

/// The app's state: the patch, the engine, audio I/O, undo, autosave. (AppModel.swift, much reduced.)
class Model : public juce::AudioIODeviceCallback, public juce::ChangeListener, private juce::Timer {
public:
    Model();
    ~Model() override;

    Patch patch;
    GraphHost host;
    juce::AudioDeviceManager devices;
    int hwIns = 2, hwOuts = 2;
    bool lightScheme = false, hideCables = false;
    std::function<void()> onChange;          // repaint request

    // edits (each commits an undo step unless noted)
    void changed(bool structural, bool undoable = true);
    void setParam(const juce::String& id, int index, float value, bool commit);
    void beginGesture();                      // a drag starts: one undo step for the whole drag
    juce::String addNode(const std::string& kind, double x, double y);
    void removeNodes(const std::set<juce::String>& ids);
    void removeCable(const juce::String& id);
    void connect(const juce::String& from, int fromPort, const juce::String& to, int toPort);
    void undo(); void redo();
    bool canUndo() const { return !undoStack.empty(); }
    bool canRedo() const { return !redoStack.empty(); }
    void newPatch();
    bool open(const juce::File& f);
    bool saveAs(const juce::File& f);

    juce::File dataFolder() const;
    float cpu() const { return cpuLoad.load(); }

    // audio
    void audioDeviceIOCallbackWithContext(const float* const* in, int numIn, float* const* out, int numOut, int numSamples,
                                          const juce::AudioIODeviceCallbackContext&) override;
    void audioDeviceAboutToStart(juce::AudioIODevice*) override {}
    void audioDeviceStopped() override {}
    void changeListenerCallback(juce::ChangeBroadcaster*) override;

private:
    void timerCallback() override;
    void restartEngineForDevice();
    void pushUndo();
    std::vector<Patch> undoStack, redoStack;
    bool gestureOpen = false;
    bool dirty = false;
    juce::uint32 lastEdit = 0;
    std::atomic<float> cpuLoad { 0 };
};

/// Box geometry, as on the Mac (Theme.swift BoxLayout).
namespace Box {
    constexpr float header = 22, portRow = 15, row = 20, port = 9;
    float width(const PatchNode& n);
    float readoutHeight(const PatchNode& n);
    std::vector<std::string> ins(const PatchNode& n, const ModuleSpec& s, const Model& m);
    std::vector<std::string> outs(const PatchNode& n, const ModuleSpec& s, const Model& m);
    std::vector<int> rowParams(const ModuleSpec& s, const PatchNode& n, const Patch& p);
    bool hasTriggerRow(const ModuleSpec& s);
    float bodyHeight(const PatchNode& n, const ModuleSpec& s, const Model& m);
    float height(const PatchNode& n, const ModuleSpec& s, const Model& m);
    juce::Point<float> inlet(const PatchNode& n, int i);
    juce::Point<float> outlet(const PatchNode& n, const ModuleSpec& s, const Model& m, int i);
    std::optional<float> paramRowY(const PatchNode& n, const ModuleSpec& s, const Model& m, int param);
    std::optional<juce::Point<float>> destination(const PatchNode& n, const ModuleSpec& s, const Model& m, int port);
}

class Canvas : public juce::Component, private juce::Timer {
public:
    explicit Canvas(Model& m);
    void paint(juce::Graphics&) override;
    void mouseDown(const juce::MouseEvent&) override;
    void mouseDrag(const juce::MouseEvent&) override;
    void mouseUp(const juce::MouseEvent&) override;
    void mouseDoubleClick(const juce::MouseEvent&) override;
    void mouseMove(const juce::MouseEvent&) override;
    void mouseWheelMove(const juce::MouseEvent&, const juce::MouseWheelDetails&) override;
    void mouseMagnify(const juce::MouseEvent&, float scale) override;
    bool keyPressed(const juce::KeyPress&) override;
    void resetView();
    void showAddMenu(juce::Point<float> canvasPoint);

    juce::Point<float> offset { 30, 30 };
    float scale = 1;
    std::set<juce::String> selected;
    juce::String selectedCable;
private:
    void timerCallback() override { repaint(); }
    juce::Point<float> toCanvas(juce::Point<float> p) const { return (p - offset) / scale; }
    juce::Point<float> toScreen(juce::Point<float> p) const { return p * scale + offset; }
    void drawBox(juce::Graphics&, const PatchNode&, const ModuleSpec&);
    void drawCable(juce::Graphics&, juce::Point<float> a, juce::Point<float> b, juce::Colour, float w, bool dashed);
    juce::Path cablePath(juce::Point<float> a, juce::Point<float> b) const;

    struct Hit {
        enum Kind { none, header, bypass, collapse, outlet, inlet, paramInlet, row, trigger, body, cableHit } kind = none;
        juce::String node, cable; int index = -1;
    };
    Hit hitTest(juce::Point<float> screen);
    void zoom(float factor, juce::Point<float> anchor);

    Model& model;
    // gestures
    enum class Drag { none, pan, move, cable, row, marquee } drag = Drag::none;
    juce::Point<float> dragStart, panStart;
    std::map<juce::String, juce::Point<double>> moveStart;
    juce::String dragNode; int dragIndex = -1; float rowStart = 0; bool dragFromOutput = true;
    juce::Point<float> pointer;
    juce::Rectangle<float> marquee;
};

class TopBar : public juce::Component, private juce::Timer {
public:
    TopBar(Model& m, Canvas& c);
    void paint(juce::Graphics&) override;
    void mouseDown(const juce::MouseEvent&) override;
private:
    void timerCallback() override { repaint(); }
    struct Item { juce::String label; juce::Rectangle<int> area; std::function<void()> action; bool on = false; };
    std::vector<Item> layout();
    Model& model; Canvas& canvas;
    std::vector<Item> items;
};

class MainComponent : public juce::Component {
public:
    MainComponent();
    void resized() override;
    void paint(juce::Graphics&) override;
    Model model;
    Canvas canvas { model };
    TopBar bar { model, canvas };
};

/// colours: black and white, dark or light (Theme.swift)
namespace Theme {
    juce::Colour bg(); juce::Colour box(); juce::Colour text(); juce::Colour dim(); juce::Colour faint();
    juce::Colour border(); juce::Colour row(); juce::Colour fill(); juce::Colour cable(); juce::Colour selected();
    juce::Colour bar(); juce::Colour rec();
    juce::Font mono(float size = 11, bool bold = false);
    void setLight(bool light);
}

} // namespace pn
