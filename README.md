# polje nieuk

A Max/Pd-style patcher for iPad, Mac and Windows that processes your Eurorack through the **disting NT** over USB:
loopers, granulators, delays, reverb, filters, drive, LFOs and recording, all locked to your modular's clock.

## Using it

Signal flows **left → right**: inlets on the left edge of a box, outlets on the right.

| Do this | How |
|---|---|
| Add a module | Double-tap (double-click) empty space and type a name: `delay`, `grain`, `lfo`, `comp`, `verb`… Or use the **+** in the top bar |
| Connect audio | Drag from an outlet (right edge ●) to an inlet (left edge ○) |
| Modulate a parameter | Drag any outlet onto the small ○ at the left of a parameter row. Dashed cable = modulation; a white tick shows the live value. ±1.0 (≈ ±10 V from the disting) sweeps the full range, so use `atten~` to scale — except semitone rows (frequency, pitch, tune): those take patched CV at 1 V/oct, like the pitch inlets |
| Bypass a module | Click the circle left of its name: filled = on, hollow = bypassed (audio passes straight through, modulators go silent, with a click-free crossfade). Switching an effect back on starts it with empty buffers — no old echoes or tails |
| Delete a cable | Tap it, then tap the **×** in the middle |
| Move a cable | Drag its input end to another inlet (drop on empty space to remove it) |
| Collapse a box | Chevron in the title bar: patched ports stay visible on small rows |
| Delete a box | Tap its title, then **×** (or trash / ⌫ on Mac) |
| Change a value | Drag across a row · double-tap to reset. Choice rows (types, shapes, divisions…) slide through their options too; the ▾ at the end opens the full list |
| Colours | **view ▸ Colours…** in the top bar: pick your own background, window (box) and patch-cord colours. The dark and light schemes each keep their own; ↺ or "Reset all" goes back to the scheme |
| Help | The ? icon: point at anything to see what it does |
| Replace a box | Long-press its title, pick the new module: it takes the same place, keeps settings with the same names, and cables reconnect to the same-named (or same-position) ports |
| Select several | The select tool (dashed box) in the top bar: drag empty space to box-select, tap titles to add / remove (on Mac also ⇧-click / ⇧-drag). Then duplicate (⌘D) — cables between them come along — switch them all off / on, delete, or drag any one to move them all |
| Group | Select boxes, press **group**: they sit on a shared backdrop. Drag the backdrop to move them together, tap it to select them, double-tap its name to rename; **ungroup** removes it |
| 3D | **view ▸ 3D** tilts the patch board away in perspective; **view ▸ Lift in 3D**: lift a section (effects, instruments, sequencers … as in the device menu) to raise all its boxes off the board — again to put them down; **Layers by section** stacks every section on its own level; **Put everything down**. In 3D: settings work as usual (rows, toggles, menus); drag a box by its title to slide it around the board, drag its dot up / down to raise or lower it (a shadow and a stem show how high), drag empty board to pan, pinch to zoom, and orbit with **three fingers** (iPad) or a **right-click drag** (Mac). Live displays hold still in 3D; patching cables needs the flat view. Heights are saved with the patch; the flat view ignores them |
| View / scheme | The **view** menu holds the display options: **Hide cables** (the cords aren't drawn or pickable; the one you drag while patching still shows), Colours, Tidy, **Fold all** / Unfold all (closes every box down to its title and patched ports), 3D and Reset view. The moon / sun switches between the light and dark schemes |
| Tidy | **view ▸ Tidy**: signal flows left → right in columns (in~ first, out~ last), each chain keeps its place all the way into the mixer, boxes line up with what they connect to so cables run straight, knobs / faders / free LFOs sit in a row on top above what they control, unpatched boxes wait underneath, and text notes move with the box beside them. Undo puts everything back |
| Undo / redo | ↶ ↷ in the top bar (⌘Z / ⇧⌘Z on Mac). Every tap or painted stroke on a roll / sequencer is its own step; a knob or fader drag is one step once you let go. The sound always follows: undoing a pattern edit puts those exact hits back in the drum machine. (Audio loaded into loopers, samplers and pads isn't part of undo.) |
| CPU | **cpu** in the top bar: everything the app uses — sound and drawing the screen (100 % = one core). If the iPad gets warm, that's the number to watch. Live displays redraw at 20 Hz only while they're on screen and something in them changes |
| Automation | Each box (except in~ / out~) has two small icons in its title bar. **●** record: hold it and move that box's controls — the movements are recorded into a 4-bar loop (following the clock) and play back from then on; a quick tap latches recording on (tap again to stop), handy with a mouse. Automated rows get a red edge and their bar moves by itself. **↺** reset removes the box's automation (parameters stay where they are). Undo covers both |
| Text | **add → text** (or double-tap the canvas and type `text`): free-floating words on the canvas, no box. Drag to move, double-click (double-tap) to edit, click away to finish; select it and press × to delete |
| Resize a box | Drag the grip in its bottom-right corner (keys, seq, rolls, waveforms, faders … get bigger displays); double-tap the grip for the default size |
| Move / pan / zoom | Drag a title (or the empty space between a box's inlets and outlets) · drag empty space · pinch |
| Transport | **▶ ❚❚ ■** on the `clock` box. Pause holds the beat where it is (sequencers, rolls, synced LFOs and clock outs wait); stop also rewinds, so ▶ starts everything from step one. Sequencers fed by a patched clock wait too |
| Audio devices | **IN** and **OUT** menus (either can be **off**: IN off = no input; OUT off = the patch keeps running — clocks, meters, recording — but nothing is sent out) in the top bar, chosen independently (changing one never changes the other). *Automatic* input = the disting NT if connected, otherwise the system input. On Mac they can be different interfaces (combined automatically with drift correction); unplugging/replugging or changing a device's sample rate restarts the engine by itself. On iPad you choose the input; the output follows the connected device |

Patches autosave; **file → Save As / Open** for named patch files (JSON). **file → Set as default** makes the current patch (with any looper / sampler audio and rack pads) what **New** starts from; **Reset default** goes back to the built-in starter (clock, in~, mix~, out~).
Recordings from `rec~` go to *Documents/polje nieuk Recordings* (on iPad: Files → On My iPad → polje nieuk — and on a Mac, with the iPad plugged in: Finder → the iPad → **Files** → polje nieuk, to drag them across).

## Modules

Most modules are stereo: with only **L** patched, **R** follows L. Effects with a **type** row switch between algorithms.

**I/O**
- `in~`: every hardware input as an outlet, with meters
- `out~`: every hardware output as an inlet, with meters
- `rec~`: records a stereo WAV to Recordings

**Clock**
- `clock`: starts on its own tempo; patch a clock into its inlet and it switches to following it (unpatch → back to its own tempo). Follows a clock from any input (1/2/4/8/24 PPQN) or runs internally. If the external clock stops or hasn't started, it keeps time at the last tempo so quantised and synced modules keep working, then snaps back when pulses return.

**Sequencing**: pitch out is 1 V/oct in the app's scale (0.1 = 1 octave, 0 = middle C); gates ≈ +5 V
- `div~`: clock divider. One clock in (or the app clock at a chosen division, as fast as 1/64, when nothing is patched), eight outs, each faster (×2 … ×16) or slower (÷2 … ÷64) than the clock — by default ×4, ×2, ×1, ÷2, ÷3, ÷4, ÷8, ÷16. Faster outs follow the measured clock, patched or internal. Pulses that keep the input's width, or 50 % square waves; an offset shifts them; a pulse on reset lines them all up.
- `keys~`: two-octave keyboard (finger, mouse or Pencil) with glide and an arpeggiator (up, down, up-down, random, as played), clock-synced, 1–3 octaves. **latch** lets you tap in a chord and let it run. Hold (or tap to latch) its **●** record icon while you play: the notes go into the 4-bar automation loop and play back through keys~ (gate, glide and arp included); ↺ clears them.
- `seq~`: up to 64 steps — the length slides 1 … 16, then jumps to 32 and 64 (growing it copies the pattern into the new steps). Drag the pitch bars, tap gates on and off. Length, division, direction (forward, backward, ping-pong, random), gate length, scale quantise, transpose. Follows the clock, or its own clock/reset inlets.
- `chord~`: chords from a **degree** (I–VII) of a key and scale — patch a sequencer or turing~ into degree for progressions that stay in key — or a chosen chord type (maj, min, 7, maj7, m7, sus, dim, aug, 6, add9, 9 …). Size (triad / seventh / ninth / sus), 3 or 4 voices, inversion, spread (close / open / drop 2 / wide), octave, **voice leading** (each chord takes the inversion closest to the last), **strum** up / down / alternating. A root CV transposes; a gate strums each chord (without one it rings and re-strikes on every change). The whole chord leaves on one pitch / gate cable.
- `turing~`: looping random shift register. **change** at 0 locks the loop; turn it up and the loop mutates. Length 2 … 16, then 32 or 64, range, scale. Outputs pitch, gate and raw CV. Division works on the app clock and on a patched clock (patched pulses count as 1/16 notes: 1/8 = every 2nd pulse, 1/32 = two steps per pulse) — the same goes for `seq~`.
- `roll~`: piano roll, 2 octaves × up to 32 steps, **chords too** — tap or drag to draw, any number of notes per step. Up to 4 notes per step play, all on the one pitch / gate / vel cable — patch it into a synth and it plays the whole chord (a mono module gets the lowest note).
- `drums~`: drum roll, 8 lanes × up to 32 steps, with 8 trigger outputs.

**Loop & grain**
- `looper~`: stereo looper with a waveform view.
  - Recording: bar-quantised, with overdub and speed/reverse. The **monitor rec** row lets you hear the input while recording.
  - Sections: drag across the waveform to loop just that part; double-tap to go back to the whole loop.
  - Grid: snaps your selection to the beat.
  - Gate inlets for rec and stop.
- `sampler~`: Simpler-style slice sampler.
  - Getting audio in: REC, load a file, drag a file onto it, or copy audio from a looper (waveform menu in the title bar).
  - Chopping: by transients (with sensitivity), into equal slices, or on the grid.
  - Playback: slice order forward / reverse / random / ping-pong / CV, played forward, reversed or at random.
  - Shaping: ADSR envelope, one-shot or gate mode, mono (choke) or poly.
  - Triggering: from the trig inlet or the clock. Tap a slice to audition it.
  - **PLAY** plays the selected section, looped or once. **sync to clock** stretches it to a whole number of beats or bars at the clock tempo, starts it on the beat and re-aligns every loop. Synced slices follow the tempo too. The **play** inlet restarts playback from a gate.
  - **STOP** stops everything: section playback, clock-triggered slices and gates on the trig/play inlets stay silent until you press PLAY again.
- `stretch~`: Paulstretch-style extreme time stretch, 1×–1000×, with selectable window size, freeze and a section select. Stereo.
- `grain~`: stereo live granulator, free-running, clock-triggered or gate-triggered.
- `repeat~`: Beat Repeat-style stutter.
- `haze~`: granular texture / delay (Gillet DSP) with four media (dirty tape, clean tape, vintage digital, digital), time/size/shape/pitch with random-walk or per-grain randomness, density, feedback, freeze and reverb. Grains run freely; patch the seed inlet to gate them or (seed input: clock) to divide a clock. Size fully up turns it into a delay.

**Instruments**: built on Émilie Gillet's open-source Eurorack DSP (see Credits)
- `texture~`: granular texture processor with granular, stretch, looping-delay and spectral modes, freeze, feedback and reverb. Trig/freeze inlets.
- `resonator~`: modal and sympathetic-string resonator with six models and polyphony 1/2/4. Excite it with audio or strum it with gates; pitch CV inlet.
- `macro~`: macro oscillator with 24 engines (analog, FM, wavetable, chords, speech, swarm, particles, string, modal, kick/snare/hat …). Trig, pitch and level inlets. **attack** fades each triggered note in (the low-pass gate still shapes the tail).
- `modal~`: modal voice with bow, blow and strike exciters into modal/string resonators, plus reverb. Gate and pitch inlets, and external blow/strike audio inputs.
- `drumsynth~`: synth drum machine in the same layout as rack~: four voices (kick, snare, hi-hat and perc by default — Gillet DSP's bass drum, snare, hi-hat and modal engines — but each can use any of the 24 engines). Per voice: engine, tune, harmonics, timbre, morph, analog / synthetic model, attack and decay envelope, LPG decay and colour, level, pan, and **M ▶ S** on its pad, under a 4-lane drum roll (app clock or clock inlet, division, swing).
- `rack~`: sampling drum machine. A drum roll (16 lanes × up to 32 steps, app clock or clock inlet, division, swing) above 4 × 4 pads, each with **M ▶ S** (mute, play, solo). Tap a pad to select it — its tune, attack, decay, level and pan show as rows — and hear it when nothing is patched into the clock inlet (▶ always plays). Changing the division keeps the pattern in time — 1/16 → 1/32 turns 16 steps into 32 finer ones with the hits on the same beats (same in drumsynth~, drums~ and roll~) — and the grid shows beat and bar lines, and the bin in the title bar clears the pattern (undo brings it back). Drop an audio file on a pad (it lights up as you drag over it; several files fill that pad and the ones after it; dropped elsewhere on the rack, it goes to the selected pad), or select the rack and click a file in the browser, to load it — files load in the background, so nothing freezes; right-click / long-press a pad to go back to the built-in sound. Starts with a synthesized kit (kick, snare, hats, clap, toms, crash, ride, cowbell, shaker, clave, 808, zap) and a starter beat. Pad samples are kept with the patch.
- **Chords on one cable**: roll~ and chord~ send every note of a chord down their single pitch / gate cable (up to 4). wave~, shapes~ and macro~ play every note that arrives on their pitch / trig inlet — one voice each; anything mono reading the cable (out~, a filter's CV …) gets the lowest note.
- `wave~`: wavetable synth with **four waves you draw yourself** — Apple Pencil, finger or mouse, straight onto the box (tap a wave's tab to draw on it; strokes join up, so quick lines stay solid). **position** morphs smoothly through the four (patch an LFO into it to sweep the timbre). Ready-made sine / tri / saw / square / pulse / noise, plus smooth and flip for the wave being drawn. Every wave is played band-limited (cleanly, without aliasing, at any pitch). Pitch in (1 V/oct) and trig in with attack / decay (decay 0 = drone).
- `shapes~`: macro oscillator with 47 shapes (analog, sync, triple, swarm, filters, vowels, FM, plucked/bowed/blown, bell, drums, wavetables, noise). Trig and pitch inlets; optional decay envelope (0 = drone). **attack** fades each triggered note in; decay 0 = drone; with nothing in trig it always drones.

Every voice takes **pitch first**, then its gate / trigger — the same order the sequencers send them (pitch, gate). Pitch inlets are 1 V/oct in the app's scale: 0.1 = 1 octave (±1.0 = ±10 V) — the same for pitch coming in through `in~`. `out~`'s **audio gain** leaves channels fed by sequencers, keys, clocks and modulators alone, so pitch leaves at exactly 1 V/oct and gates keep their level however the audio is set. (This assumes the interface's full scale is ±10 V, as on Expert Sleepers interfaces; check with `scope~` and a tuner.)

**Effects**
- `delay~`: digital, tape (wow, flutter, saturation) or analog BBD; synced or free, with ping-pong. Moving **division** switches sync on, moving **free time** switches it off (same for the rate of lfo~, tremolo and the other synced modules).
- `reverb~`: room (Freeverb), plate (Dattorro), hall (8-line FDN) or spring (dispersive allpass loops — the boing and drip of a spring tank), all with freeze and level-matched. True stereo: a mono input comes out wide and decorrelated, a panned input keeps its side.
- `filter~`: clean SVF, Moog-style ladder or MS-20-style screamer; LP / BP / HP / notch; 1 V/oct-style cv inlet.
- `drive~`: soft, tube, hard clip, wavefold, fuzz or rectify.
- `chorus~`: chorus, ensemble or vibrato.
- `phaser~`: phaser or flanger.
- `autopan~`: tremolo / auto-pan.
- `redux~`: bit and sample-rate reducer.
- `shift~`: pitch shifter.
- `freqshift~`: Bode-style frequency shifter with up and down outputs.
- `xmod~`: cross-modulator (Gillet DSP): carrier × modulator through nine morphing algorithms (crossfade, fold, analog/digital ring, XOR, compare, vocoder …); internal sine/triangle/saw carrier with pitch CV.
- `eq3~`: DJ-style three-band EQ with kills.
- `eq~`: parametric EQ with 3, 5 or 8 bands and a response curve.

**Dynamics**
- `comp~`: LA-3A opto (peak reduction + gain), 1176-style FET or SSL-style VCA bus; sidechain inlet. The display scrolls input level, output level and gain reduction, next to the transfer curve with the signal's live position on it.
- `limit~`: lookahead limiter.
- `gate~`: noise gate with a sidechain inlet.

**Modulation**
- `slider~` / `knob~`: 1, 2, 4 or 8 big faders or knobs, each with its own CV outlet (0…10 V, ±10 V, 0…5 V, ±5 V or 0…1 V, with smoothing). Several fingers can move several controls at once; double-tap returns a control to the middle. Made for live playing: patch them into any parameter. Patched into a parameter, a control *sets* it across its whole range (other modulation still adds on top), and shows the target's name and live value. Dropped on a `mix~` channel inlet, a fader / knob controls that channel's level.
- `chance~`: random gates T1–T3 and quantised voltages X1–X3 + Y (Gillet DSP), seven T models, déjà-vu looping, six scales; follows the app clock or external clock inlets.
- `lfo~`: sine, triangle, saw, square or random (a smooth random wander); free or clock-synced (1/32 up to every 16 bars); the display shows the waveform with a moving playhead and the current value.
- `env~`
- `atten~`: attenuverter, offset and slew; outputs a constant when nothing is patched in.

**Utility**
- `gain~`: gain, balance, width, mono, phase invert, mute.
- `scope~`: two-channel oscilloscope for anything — audio, LFOs, envelopes, gates, pitch CV. Shows the waveforms (A bright, B dim) and measures each: average, range and frequency in volts (0.1 = 1 V); a steady voltage also reads as the note it plays at 1 V/oct (0 V = C4), with cents. Time window 1 ms – 10 s, trigger free / on A rising / on the bar, auto or fixed scale, hold.
- `mix~`: four-input mixer.

## Files

The **browser** (*browser* in the top bar, between *view* and *file*) works like a DAW's:
- **Places** — Recordings, your home folder, Desktop, Documents, Downloads, Music, iCloud Drive and every mounted drive (Mac). On iPad: Recordings and *On this iPad*.
- **Collections** — folders you add with + (any folder, including on iPad from the Files app).
- **Search** — type two or more letters: audio files whose name matches, from all places and collections (not the whole system disk).
- **▶** previews a file; drag a file onto a `looper~`, `sampler~` or `stretch~` to load it, or select one of those and click the file.
- macOS asks once for permission the first time you open Desktop, Documents or Downloads.

## Hooking up the disting NT

1. Connect it over USB-C. The top bar shows **IN disting NT · 12ch** and **OUT … · 8ch**.
2. On the disting, route signals to its USB-to-host channels and USB-from-host back to its outputs. Those channel numbers are the port numbers on `in~` / `out~`.
3. **Clock:** patch the `in~` outlet carrying your clock into `clock` (the starter patch — clock, in~, mix~, out~ — comes unpatched). Set **ppqn** to match your clock; lower **threshold** if pulses are missed. The clock box shows **EXT** and the BPM when locked.
4. Avoid feedback: don't send an `out~` channel to a disting channel that also feeds an `in~` you're listening to.

## Building

### iPad + Mac app (needs Xcode)

1. Install **Xcode** from the Mac App Store, open it once, and let it install the iOS platform.
2. Open `polje nieuk.xcodeproj` (regenerate it any time with `xcodegen` after editing `project.yml`).
3. Select the **polje nieuk** target → *Signing & Capabilities* → choose your Team (a free Apple ID works; apps signed that way need re-installing every 7 days).
4. Plug in the iPad, pick it as the run destination, press **Run**. For the Mac, pick **My Mac**.
   The first time, enable *Developer Mode* on the iPad (Settings → Privacy & Security) and trust the developer certificate.

### Reinstall on the iPad (every 7 days with a free Apple ID, or after changes)

```bash
scripts/install-ipad.sh
```

### Mac only, without Xcode

```bash
scripts/build-mac.sh test   # builds and runs the offline DSP self-test
scripts/build-mac.sh run    # builds ".build/manual/polje nieuk.app" and opens it
```

The app is **universal**: built for Apple Silicon and Intel and joined into one app (Intel runs natively on
Intel Macs). That takes about four minutes; while developing, `ARCHS=arm64 scripts/build-mac.sh run` builds
only the Apple Silicon half. Ready-made DMGs are on the repo's Releases page.

The build is signed with your **Apple Development** certificate when there is one, so macOS remembers the
microphone permission across rebuilds (ad-hoc signed builds ask again every time). Audio devices are opened
off the main thread: if macOS audio is busy — a permission prompt waiting, an interface being plugged in —
the window keeps working and the top bar says "waiting for the system audio…".

### Windows

Download `polje-nieuk-windows-x64.zip` from the Releases page, unzip it and run `polje nieuk.exe` (Windows 10 / 11,
64-bit). It is the same app: the same modules with the same sound, the same boxes, rows, cables and displays,
and the same patch files, so a patch saved on the Mac or iPad opens on Windows and back. Audio goes through
Windows Audio (WASAPI); pick the disting NT (or any interface) under IN / OUT in the top bar.

The Windows version is written with JUCE (C++) in `windows/`. It builds on any platform with CMake:

```bash
cmake -S windows -B windows/build -DCMAKE_BUILD_TYPE=Release
cmake --build windows/build --config Release
```

On Windows use Visual Studio 2022 or newer with the clang-cl toolset (`-T ClangCL`). Every push builds it on
GitHub Actions, which also renders two test patches through the Windows engine and checks every module's output
against the Mac engine's (`windows/tests`). The module list itself comes from the Mac app
(`selftest --dump-specs windows/Source/specs.json`), so both always offer the same modules and settings.

## Layout

- `Sources/PoljeNieukCore` — audio engine: RemoteIO/AUHAL duplex I/O, lock-free graph swapping (modules keep their loops when you re-patch), DSP modules, clock follower.
- `Sources/PoljeNieukUI` — SwiftUI patcher shared by iPad and Mac.
- `Sources/SelfTest` — renders a patch with a synthetic modular clock and checks clock lock, tempo changes, looper sync, grains, NaN safety.
- `App` — app entry point for the Xcode target.
- `windows` — the Windows version (JUCE / C++): `Engine`, `Modules*` (the DSP), `Canvas`, `Boxes`, `Displays`, `Window` (the interface).

To add a module: subclass `DSPNode` (no allocation or locks in `process`), then add a `ModuleSpec` to `ModuleRegistry.all`. The UI is generated from the spec.

## Credits

polje nieuk stands on a lot of other people's work. Thank you to all of them.

### Code used directly

- **Émilie Gillet**: `texture~`, `resonator~`, `macro~`, `modal~`, `shapes~`, `xmod~`, `chance~` and `haze~` run the DSP source code of her Eurorack modules ([github.com/pichenettes/eurorack](https://github.com/pichenettes/eurorack)), released under the MIT licence (`Vendor/mutable`; every source file carries its copyright notice, and the licence text is in `Vendor/mutable/stmlib/LICENSE`). Only the DSP is used, through a thin bridge (`Vendor/mutable/bridge`). Following her guidelines for derivative works, the original brand and module names aren't used in the app.
- **JUCE** (Raw Material Software): the Windows version is built with the [JUCE](https://juce.com) framework, used under its open-source licence (AGPLv3).

### The patcher itself

- **Max** (Miller Puckette, David Zicarelli and **Cycling '74**) and **Pure Data** (Miller Puckette): the whole idea and look of the app come from them: boxes named `thing~`, patch cords, double-click to make an object, a canvas drawn the way Pd draws it.
- **Eurorack** (Doepfer's format, and everyone who builds for it): the 1 V/oct pitch, gates, clocks and CV that every module here speaks.
- **Expert Sleepers** (Andrew Ostler): the app was made to run alongside the **disting NT**, and its *Automatic* input looks for it.

### Designs the modules are modelled on

None of these use the original code; they're our own versions of famous designs, and the credit goes to the people who made the originals.

- `turing~`: the **Turing Machine** by Tom Whitwell (**Music Thing Modular**): a looping random shift register you can lock or let mutate.
- `filter~`: the **Moog** transistor ladder (Robert Moog), the **Korg MS-20** filter, and the zero-delay-feedback state-variable filter described by **Andrew Simper** (Cytomic).
- `reverb~`: **Freeverb** by Jezar at Dreampoint (room), **Jon Dattorro**'s plate from *Effect Design, Part 1* (plate), feedback delay networks after **Jean-Marc Jot** and **Michael Gerzon** (hall), and the classic spring tank (spring).
- `comp~`: the **Teletronix / UREI LA-3A** opto and **UREI 1176** FET compressors, and the **SSL**-style VCA bus compressor.
- `delay~`: tape echo (wow, flutter, saturation) and analog **BBD** (bucket-brigade) delays.
- `stretch~`: **Paulstretch** by Nasca Octavian Paul.
- `gain~`: **Ableton**'s Utility device.
- `rack~`, `drumsynth~` and `drums~`: the **Roland TR-808 / TR-909** drum machines and the step-sequencer drum roll they made famous; the built-in kit is synthesized from scratch.
- `roll~` and the piano-roll editors: the piano roll found in every DAW.
- The sampler, looper and beat-repeat ideas come from the samplers, loopers and glitch effects musicians have used for decades.

If we've missed you or got something wrong, please open an issue.
