import Foundation

/// Per-project signing options consumed by PersonalCertificateSigner.sign.
struct PersonalProjectOptions: Sendable {
    var displayName: String? = nil
    var bundleID: String? = nil
    var version: String? = nil
    var outputFilename: String = "Mirsa-Signed"
    var fileSharing = false
    var removeURLSchemes = false
    var removeEmbeddedProfile = false
    var removeWatchApp = false
    var minimumOS: String? = nil
    var libraries: [URL] = []
    var additionalProfiles: [Data] = []
    var removeExtensions = false
    var removeAppClips = false
}

func personalText(_ en: String, _ ar: String) -> String { L.isArabic ? ar : en }

/// Editable values persisted per library app. Library files are referenced by id,
/// never by absolute path.
struct PersonalProjectDraft: Codable, Equatable {
    var name = ""
    var bundleID = ""
    var version = ""
    var outputFilename = ""
    var fileSharing = false
    var removeURLSchemes = false
    var removeEmbeddedProfile = false
    var removeWatchApp = false
    var minimumOS = ""
    var tweakIDs: [UUID] = []
}
