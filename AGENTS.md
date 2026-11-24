# AGENTS.md

swift-vhs drives and records Mac apps for demoreel and for agents. `README.md` explains it; demoreel's
`docs/adr/0001-drivers-share-one-recording-contract.md` is the contract it keeps.

- `Sources/VHSCore`: the lines and events.json, no AppKit. Tests are here: `just test`.
- `Sources/VHS`: the app side (socket, capture, input, accessibility), `@MainActor` and Debug-only in apps.
- `Sources/vhs-drive`: the client. Its commands and flags match Typecase's `typecase-drive`; keep them matching, since
  demoreel runs either the same way.

## Done

`just test` passes, and a change to `Sources/VHS` has been tried against a real app (Booth: `just debug-app`, then
`vhs-drive` commands, or `demoreel record` on Booth's `demo/`), with the frames looked at. `just install` puts the
new `vhs-drive` on the PATH.

## Gotchas

- Input brings the app forward (through `open -a`) and gives the front back; never click a control that opens the
  microphone or the camera in someone's app while testing.
- An app started by running its binary counts as part of the terminal, and macOS kills it when it asks for something
  private. Start apps with `open -n -g --env VHS_SOCKET=… -a App.app`.
