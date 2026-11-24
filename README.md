# swift-vhs

Drives a Mac app from outside and records it: clicks, keys, typing, menus, screenshots, and recordings of clean frames
with an `events.json` of what was done on which frame. It is the Swift driver in
[demoreel](https://github.com/phin-tech/demoreel)'s recording contract (its
`docs/adr/0001-drivers-share-one-recording-contract.md`). It speaks the same lines as Typecase's driver, so one script
runs against a GPUI app, a web page or a SwiftUI/AppKit app, and demoreel's `record` drives any of them.

- **VHS**, the library: linked into an app's Debug build, it listens on a Unix socket.
- **vhs-drive**, the client: sends lines, runs scripts and records them. Its commands and flags are `typecase-drive`'s.
- **VHSCore**: the line protocol and `events.json`, with no AppKit, tested by `swift test`.

## Add it to an app

In `project.yml` (XcodeGen), for the Developer ID target only:

```yaml
packages:
  VHS:
    url: https://github.com/phin-tech/swift-vhs
    from: 0.1.0
targets:
  MyApp:
    dependencies:
      - package: VHS
        product: VHS
```

And at launch, only in Debug:

```swift
#if DEBUG && !APP_STORE
import VHS
#endif

init() {
    #if DEBUG && !APP_STORE
    VHS.start()   // listens only when launched with VHS_SOCKET set
    #endif
}
```

An app can add commands of its own: `VHS.command("open", help: "open <file>  opens a document") { rest in … }`.

An app that plays sound can say so, and a recording running then has it as a `sound` event, which demoreel plays under
the clip: `VHS.noteSound(url, from: 2.5)` when a take starts playing. A `menu` line that chooses an item is noted too
(`{"kind":"menu","path":"File > Save"}`), since a menu itself is drawn outside the window and isn't in the frames.

## Drive it

```sh
just install                                  # builds vhs-drive into ~/.local/bin

open -n -g --env VHS_SOCKET=/tmp/my.sock -a MyApp.app
export VHS_SOCKET=/tmp/my.sock
vhs-drive --wait 20 windows                   # * 0  1440×900 @2x  My Window
vhs-drive shot out.png
vhs-drive elements                            # roles, labels, #ids and where they are
vhs-drive click Edit Script                   # by label, #id, or X,Y in points from the window's top-left
vhs-drive cmd-e
vhs-drive type Hello there
vhs-drive menu File > New Window
vhs-drive demo walk.script walk/ --events     # frames and events.json, for demoreel
vhs-drive demo walk.script walk.mp4           # or a video
vhs-drive help                                # everything
```

A script is a line a command, `#` for comments: `click 118,162`, `click #save`, `click Open Project…`, `cmd-k`,
`type some words`, `move:640,300`, `scroll:640,300,200`, `drag:10,20,300,20`, `wait:600`.

`VHS_WINDOW_SIZE=1440x900` in the app's environment sizes its first window, so recordings are the same size every
time; `size 1440 900` does it later.

## With demoreel

A clip scene records itself with `"driver": "vhs"`, which runs `vhs-drive` and tells the app its socket in
`VHS_SOCKET`:

```json
{ "type": "clip", "id": "studio",
  "record": { "driver": "vhs", "command": ["../scripts/driven", "build/sample"], "script": "studio.script",
              "env": { "VHS_WINDOW_SIZE": "1440x900" } } }
```

`command` should start the app through Launch Services (`open -n -W -g --env VHS_SOCKET=… -a MyApp.app`), not by
running its binary: started from a shell, an app counts as part of the terminal, and macOS stops it the moment it asks
for something private such as the microphone. Booth's `scripts/driven` is an example.

## How it works, and what it costs

- **Pictures** come from the window server (`CGWindowListCreateImage` on the app's own window), which an app may do
  without the Screen Recording permission. They are what is on screen, materials and video included, in about 12 ms
  for a 2880×1800 window, behind other windows or not. The call is deprecated and missing from code built for macOS 15,
  so it's looked up at run time; without it, the window is drawn the way printing draws it, which misses materials
  (sidebars, toolbars), and each `AVPlayerLayer`'s current frame is drawn in over its place (that last part hasn't
  been seen working yet: in the one run without the window server, the video was blank).
- **Recordings** take a frame on the main run loop as often as the rate asks and write PNGs on other threads. A frame
  that took longer than the interval is saved as many times as frames were due, so the video keeps the app's pace.
  Events are noted on the next frame saved. Frames are numbered from 00000, as events.json counts them.
  A locked screen or a sleeping display draws every window blank, so `shot` and `record` refuse then and say so.
- **Which window** a command acts on is the front one that can become key (or the one `window N` chose): a tooltip,
  or the Writing Tools button macOS puts beside selected text, is a window of its own in front, and is passed over.
- **Finding things** goes through the accessibility API on the app's own process, which needs no Accessibility
  permission. Asking that way is also what makes SwiftUI build its accessibility tree, which it leaves empty until
  something asks. A label that isn't there yet is looked for again for a second and a half, since SwiftUI updates the
  tree a moment after a view changes.
- **Input** is NSEvents made in the app. Mouse events are posted to the app's queue, not handed to the window, so a
  control that runs a tracking loop inside its mouse-down gets the mouse-up it waits for.
- **Focus: input takes it.** AppKit treats a click in a window that isn't key as the click that brings the app forward,
  and most views ignore it (a table won't select a row), and an app that isn't active has no key window. An app can't
  bring itself forward either (macOS 14's cooperative activation), so `vhs-drive` does it through Launch Services
  (`open -a`) before the first line of input, again if something else took the front, and gives the front back to the
  app that had it when it's done. While a script with input runs, the keyboard goes to the app. Shots, element lists,
  windows and menus don't take focus.
- **Debug builds only.** The socket lets anything on the Mac drive the app.
