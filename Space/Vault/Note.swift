import Foundation

/// One markdown file in the vault. In Space terms: a star.
struct Note: Identifiable, Hashable, Sendable {
    /// Path relative to the vault root, e.g. "Английский/Грамматика/Артикли.md".
    let id: String
    var title: String
    /// Top-level folder. Empty for notes that sit in the vault root.
    var universe: String
    /// Second-level folder. Empty for notes that sit directly in a universe folder.
    var constellation: String
    /// Targets of [[wikilinks]], already normalised to a note title.
    var links: [String]
    var tags: [String]
    var created: Date
    var modified: Date
}
