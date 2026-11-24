import Foundation
import Testing
@testable import VHSCore

// The same readings as Typecase's crates/drive, so one script runs against either driver.

@Test func targetsArePointsIdsOrLabels() throws {
    #expect(try Drive.Target.parse("120, 40") == .point(x: 120, y: 40))
    #expect(try Drive.Target.parse("#save") == .id("save"))
    #expect(try Drive.Target.parse("Open Project…") == .label("Open Project…"))
    #expect(throws: Drive.Problem.self) { try Drive.Target.parse("  ") }
}

@Test func stepsReadAsTypecaseReadsThem() throws {
    #expect(try Drive.Step.parseAll("j cmd-k wait wait:250 type:hi move:#x") ==
        [.key("j"), .key("cmd-k"), .wait(500), .wait(250), .type("hi"), .move(.id("x"))])
    #expect(try Drive.Step.parse("cmd-click:10,20") == .click(.point(x: 10, y: 20), right: false, modifiers: "cmd"))
    #expect(try Drive.Step.parse("right-click:#row") == .click(.id("row"), right: true, modifiers: ""))
    #expect(try Drive.Step.parse("scroll:300,200,-120") == .scroll(.point(x: 300, y: 200), dy: -120))
    #expect(try Drive.Step.parse("drag:1,2,3,4") == .drag(from: .point(x: 1, y: 2), to: .point(x: 3, y: 4)))
    #expect(try Drive.Step.parse("cmd--") == .key("cmd--"))
    #expect(try Drive.Step.parse("f5") == .key("f5"))
}

@Test func aWordThatIsNotAKeySaysHowToTypeIt() {
    #expect(throws: Drive.Problem("`hello` isn't a key: a word to type is `type:hello`, or `type …` on a line of its own")) {
        try Drive.Step.parse("hello")
    }
    #expect(throws: Drive.Problem.self) { try Drive.Step.parse("scroll:300,200") }
    #expect(throws: Drive.Problem.self) { try Drive.Step.parse("shiftclick:1,2") }
}

@Test func commandsReadTheRestOfTheLine() throws {
    #expect(try Drive.Command.parse("click Open Project…") == .steps([.click(.label("Open Project…"), right: false, modifiers: "")]))
    #expect(try Drive.Command.parse("type Hello there") == .type("Hello there"))
    #expect(try Drive.Command.parse("record /tmp/f 24 --events") == .record(folder: "/tmp/f", fps: 24, events: true))
    #expect(try Drive.Command.parse("record /tmp/my frames") == .record(folder: "/tmp/my frames", fps: 30, events: false))
    #expect(try Drive.Command.parse("window 1") == .window(1))
    #expect(try Drive.Command.parse("window") == .window(nil))
    #expect(try Drive.Command.parse("menu File > Open Project…") == .menu(["File", "Open Project…"]))
    #expect(try Drive.Command.parse("menu") == .menu([]))
    #expect(throws: Drive.Problem.self) { try Drive.Command.parse("record /tmp/f 0") }
}

@Test func eventsAreWrittenInTheShapeDemoreelReads() throws {
    var events = Drive.Events(fps: 30)
    events.note(15, .key("cmd-k"))
    events.note(76, .click(x: 552, y: 312.5, held: ""))
    events.note(90, .hover(x: 40, y: 40))
    events.note(100, .scroll(x: 300, y: 200, dy: -120))
    events.note(110, .drag(x: 10, y: 20, x2: 30, y2: 40.5))
    events.note(111, .key("\""))
    let json = try JSONSerialization.jsonObject(with: Data(events.json(frames: 120).utf8)) as! [String: Any]
    #expect(json["fps"] as? Int == 30)
    #expect(json["frames"] as? Int == 120)
    let list = json["events"] as! [[String: Any]]
    #expect(list.count == 6)
    #expect(list[1]["kind"] as? String == "click")
    #expect(list[1]["y"] as? Double == 312.5)
    #expect(list[5]["key"] as? String == "\"")
}

@Test func anEmptyRecordingStillWritesAList() throws {
    let json = try JSONSerialization.jsonObject(with: Data(Drive.Events(fps: 24).json(frames: 0).utf8)) as! [String: Any]
    #expect((json["events"] as? [Any])?.isEmpty == true)
}

@Test func keystrokesSplitIntoModifiersAndAKey() {
    #expect(Drive.split("cmd-shift-k") == (["cmd", "shift"], "k"))
    #expect(Drive.split("cmd--") == (["cmd"], "-"))
    #expect(Drive.split("space") == ([], "space"))
    #expect(Drive.typedKey(" ") == "space")
    #expect(Drive.script("# hi\n\nclick #a\n  wait:5 ") == ["click #a", "wait:5"])
}

@Test func inputIsWhatClicksTypesOrMoves() throws {
    #expect(try Drive.Command.parse("click #a").isInput)
    #expect(try Drive.Command.parse("type hi").isInput)
    #expect(try Drive.Command.parse("wait:300 j").isInput)
    #expect(try !Drive.Command.parse("wait:300").isInput)
    #expect(try !Drive.Command.parse("shot /tmp/a.png").isInput)
    #expect(try Drive.Command.parse("pid") == .pid)
    #expect(try Drive.Command.parse("size 1280 800") == .size(width: 1280, height: 800))
    #expect(try Drive.Command.parse("size 1280x800") == .size(width: 1280, height: 800))
    #expect(throws: Drive.Problem.self) { try Drive.Command.parse("size 12") }
}
