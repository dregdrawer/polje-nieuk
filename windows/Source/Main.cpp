#include "UI.h"

class PoljeNieukApp : public juce::JUCEApplication {
public:
    const juce::String getApplicationName() override { return "polje nieuk"; }
    const juce::String getApplicationVersion() override { return "0.1.0"; }
    bool moreThanOneInstanceAllowed() override { return false; }

    void initialise(const juce::String&) override { window = std::make_unique<Window>(); }
    void shutdown() override { window.reset(); }
    void systemRequestedQuit() override { quit(); }

private:
    class Window : public juce::DocumentWindow {
    public:
        Window() : DocumentWindow("polje nieuk", juce::Colours::black, DocumentWindow::allButtons) {
            setUsingNativeTitleBar(true);
            setContentOwned(new pn::MainComponent(), true);
            setResizable(true, true);
            setResizeLimits(800, 500, 10000, 10000);
            centreWithSize(getWidth(), getHeight());
            setVisible(true);
        }
        void closeButtonPressed() override { juce::JUCEApplication::getInstance()->systemRequestedQuit(); }
    };
    std::unique_ptr<Window> window;
};

START_JUCE_APPLICATION(PoljeNieukApp)
