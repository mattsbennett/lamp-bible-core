import Foundation
import LampModuleKit

/// The import review's decisions, asked of a library's installed modules.
extension LampTranslationImporter {
    /// Only a translation the user installed can be replaced; a bundled one,
    /// or any other kind of module, keeps its ID.
    public static func destination(abbreviation: String, installed: [LampInstalledModule]) -> LampTranslationImportDestination {
        let replaceable = installed.filter { $0.kind == .translation && !$0.isBundled }
        return destination(
            abbreviation: abbreviation,
            replaceableTranslationIDs: Set(replaceable.map(\.id)),
            otherModuleIDs: Set(installed.map(\.id)).subtracting(replaceable.map(\.id))
        )
    }

    public static func translation(
        sharingAbbreviation abbreviation: String,
        installed: [LampInstalledModule],
        except destination: LampTranslationImportDestination
    ) -> LampInstalledModule? {
        let abbreviations = Dictionary(
            installed.compactMap { module in
                module.kind == .translation ? module.abbreviation.map { (module.id, $0) } : nil
            },
            uniquingKeysWith: { first, _ in first }
        )
        let id = translationID(sharingAbbreviation: abbreviation, abbreviationsByTranslationID: abbreviations, except: destination)
        return installed.first { $0.id == id }
    }
}
