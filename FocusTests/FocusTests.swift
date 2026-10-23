//
//  FocusTests.swift
//  FocusTests
//
//  Created by Beyang Liu on 7/19/25.
//

import Testing
@testable import Focus

struct FocusTests {

    @Test func commandInvocationSplitsNameFromArguments() {
        let registry = CommandRegistry()
        registry.register(SpotlightCommand(name: "timer", arguments: .required("<time> [message]"), summary: "", action: { _ in }))
        registry.register(SpotlightCommand(name: "new tab", aliases: ["tab"], arguments: .optional("[url]"), summary: "", action: { _ in }))
        registry.register(SpotlightCommand(name: "new chrome window", summary: "", action: { _ in }))

        let timer = registry.invocation(for: "  Timer 5m Stretch Break ")
        #expect(timer?.command.name == "timer")
        #expect(timer?.arguments == "5m Stretch Break")

        let tab = registry.invocation(for: "tab Example.com/Path")
        #expect(tab?.command.name == "new tab")
        #expect(tab?.arguments == "Example.com/Path")

        #expect(registry.invocation(for: "timer")?.arguments == "")
        #expect(registry.invocation(for: "timers 5m") == nil)
        #expect(registry.invocation(for: "new chrome window") == nil)
    }

}
