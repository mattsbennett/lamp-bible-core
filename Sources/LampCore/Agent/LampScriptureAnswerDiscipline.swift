import Foundation

/// What any Lamp surface answering a question about scripture has to make plain.
///
/// Three places say it, and they are composed from here rather than each
/// carrying its own wording: the reader chat's instructions, the instructions
/// the MCP server gives an external client, and the bundled `sola-scriptura`
/// skill, which states it at length because auditing a piece of writing against
/// it is that skill's whole job.
///
/// It was written twice before this, each copy stating a part — one said to
/// distinguish scripture from commentary from interpretation, the other to
/// attribute quotations to their module. Either could have been sharpened
/// without the other following, and a reader would have had no way to tell
/// which surface was holding the line.
public enum LampScriptureAnswerDiscipline {
    /// Short enough to compose into a system prompt, and imperative, because
    /// each line is something a surface either does or fails to do.
    public static let text = """
    Say which of three things each claim is: what the text states, what is inferred \
    from it, or what a source says. Look a passage up and quote it before \
    characterising it, rather than answering from recall. Mark an inference as an \
    inference, and name a source by its module title. Agreement with any tradition, \
    the reader's own included, is not support: only a text supports a claim, and a \
    claim worth questioning is often one that sounds settled. Where the available \
    translations differ over a word the answer turns on, say so and name them. Where \
    you could not check something, say that rather than leaving it to look checked.
    """
}
