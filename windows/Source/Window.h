// The window around the canvas (RootView.swift, FileBrowserView.swift, CustomColours.swift): the top bar, the
// error line, the file browser and the colours panel.
#pragma once
#include "Canvas.h"

namespace pn {

class TopBar : public juce::Component, private juce::Timer, public juce::SettableTooltipClient {
public:
    explicit TopBar(AppModel& m);
    void paint(juce::Graphics&) override;
    void mouseDown(const juce::MouseEvent&) override;
    void mouseDrag(const juce::MouseEvent&) override;
    void mouseUp(const juce::MouseEvent&) override;
    void mouseMove(const juce::MouseEvent&) override;
    void mouseDoubleClick(const juce::MouseEvent&) override;
    std::function<void()> onNew, onOpen, onSave, onColours;
private:
    struct Item { juce::String id; juce::Rectangle<float> r; std::function<void(Pt)> action; juce::String tip; };
    void timerCallback() override;
    void layoutItems(juce::Graphics* g);
    void deviceMenu(bool input, Pt at);
    void addMenu(Pt at);
    void viewMenu(Pt at);
    void fileMenu(Pt at);
    void popup(juce::PopupMenu& m, Pt at);
    AppModel& model;
    std::vector<Item> items;
    juce::Rectangle<float> tempoRect;
    std::optional<double> tempoDrag;
    Pt dragStart;
    std::unique_ptr<juce::TextEditor> tempoEditor;
    int lastCPU = -1;
};

class FileBrowser : public juce::Component, public juce::DragAndDropContainer, private juce::Timer {
public:
    explicit FileBrowser(AppModel& m);
    ~FileBrowser() override;
    void paint(juce::Graphics&) override;
    void resized() override;
    void mouseDown(const juce::MouseEvent&) override;
    void mouseDrag(const juce::MouseEvent&) override;
    void mouseUp(const juce::MouseEvent&) override;
    void mouseMove(const juce::MouseEvent&) override;
    void mouseExit(const juce::MouseEvent&) override;
    void mouseWheelMove(const juce::MouseEvent&, const juce::MouseWheelDetails&) override;
    void refresh();
private:
    struct Row { enum Kind { section, folder, fileRow, note, add } kind; juce::File file; juce::String title; int depth = 0; bool removable = false; bool showFolder = false; };
    void timerCallback() override;
    void rebuild();
    void runSearch();
    void preview(const juce::File& f);
    void stopPreview();
    AppModel& model;
    std::vector<Row> rows;
    std::set<juce::String> open;
    juce::TextEditor search;
    float scroll = 0;
    int hoverRow = -1, pressRow = -1;
    bool dragStarted = false;
    std::vector<juce::File> results;
    std::atomic<int> searchGeneration { 0 };
    bool searching = false;
    juce::File playing;
    std::unique_ptr<juce::AudioDeviceManager> previewDevice;
    std::unique_ptr<juce::AudioFormatReaderSource> previewSource;
    juce::AudioTransportSource transport;
    juce::AudioSourcePlayer player;
    juce::AudioFormatManager formats;
    juce::ThreadPool pool { 1 };
    std::unique_ptr<juce::FileChooser> chooser;
    static constexpr float rowH = 19, headerH = 64;
};

class MainComponent : public juce::Component, public juce::DragAndDropContainer {
public:
    MainComponent();
    ~MainComponent() override;
    void resized() override;
    void paint(juce::Graphics&) override;
    bool keyPressed(const juce::KeyPress&) override;
    AppModel model;
private:
    void modelChanged();
    void showColours();
    Canvas canvas { model };
    TopBar bar { model };
    std::unique_ptr<FileBrowser> browser;
    std::unique_ptr<juce::FileChooser> chooser;
    juce::String lastError;
    bool lastLight = false, lastShowFiles = false;
    juce::String importTarget;
    juce::TooltipWindow tooltips { this, 600 };
    std::unique_ptr<juce::LookAndFeel_V4> look;
};

} // namespace pn
