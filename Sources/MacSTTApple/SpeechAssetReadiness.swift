import Foundation
import MacSTTCore
import Speech

enum SpeechAssetReadiness {
    static func installIfNeeded(
        modules: [any SpeechModule],
        locale: Locale,
        stage: String,
        validate: @escaping @Sendable () async throws -> Void
    ) async throws {
        try await validate()
        if await AssetInventory.status(forModules: modules) != .installed {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
                try await validate()
                try await request.downloadAndInstall()
            }
            try await validate()
            guard await AssetInventory.status(forModules: modules) == .installed else {
                throw MacSTTFailure(
                    code: "SPEECH_ASSET_INSTALLATION_INCOMPLETE",
                    domain: .asset,
                    stage: stage,
                    recoverability: .retryableOnce,
                    messageKey: "speech_asset_installation_incomplete",
                    redactedDetail: locale.identifier(.bcp47)
                )
            }
        }
        try await validate()
    }

    static func reserveInstalledModelIfPossible(locale: Locale, diagnostics: Diagnostics) async {
        let reservedLocales = await AssetInventory.reservedLocales
        let identifier = locale.identifier(.bcp47)
        guard !reservedLocales.contains(where: {
            $0.identifier(.bcp47).caseInsensitiveCompare(identifier) == .orderedSame
        }) else { return }

        do {
            try await AssetInventory.reserve(locale: locale)
        } catch {
            diagnostics.failure(
                code: "SPEECH_MODEL_RESERVATION_FAILED",
                stage: "model-retention",
                detail: String(reflecting: type(of: error))
            )
        }
    }
}
