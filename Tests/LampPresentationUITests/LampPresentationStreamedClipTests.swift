import Foundation
import Testing
@testable import LampPresentationUI

/// The embedded player's page is let through Lamp's own navigation rule, and
/// nothing else in the main frame is. WebKit names the page's address with a
/// trailing slash, and a rule comparing whole addresses turned the page
/// itself away, so nothing ever played.
struct LampPresentationStreamedClipTests {
    private typealias Rule = LampPresentationEmbeddedPlayer.Coordinator

    @Test func thePlayersPageIsLetThroughAndNothingElseInTheMainFrame() {
        #expect(Rule.allows(URL(string: "https://lampbible.com/"), inMainFrame: true))
        #expect(Rule.allows(URL(string: "https://lampbible.com"), inMainFrame: true))
        #expect(Rule.allows(URL(string: "about:blank"), inMainFrame: true))
        // The player's own frame goes where it needs to.
        #expect(Rule.allows(URL(string: "https://www.youtube-nocookie.com/embed/jNQXAC9IVRw"), inMainFrame: false))
        // But the page is never taken elsewhere.
        #expect(!Rule.allows(URL(string: "https://www.youtube.com/watch?v=jNQXAC9IVRw"), inMainFrame: true))
        #expect(!Rule.allows(URL(string: "http://lampbible.com/"), inMainFrame: true))
        #expect(!Rule.allows(URL(string: "https://lampbible.com/elsewhere"), inMainFrame: true))
        #expect(!Rule.allows(nil, inMainFrame: true))
    }
}
