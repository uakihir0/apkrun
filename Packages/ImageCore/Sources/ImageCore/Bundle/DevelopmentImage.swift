import Foundation

/// Loads an unsigned development bundle in place (android-image.md §10.2; #012 until #065).
///
/// `python3 -m apkrun_image bundle --unsigned` writes the directory. Only a
/// Debug build loads it, and only after checking that every file the manifest
/// lists exists with its size. There is no signature and no hash check; #065
/// replaces this with `ImageStore`.
public enum DevelopmentImage {
    /// Reads and checks `directory/manifest.json`.
    public static func load(directory: URL) throws(ImageFailure) -> InstalledImage {
        #if DEBUG
            let manifestURL = directory.appendingPathComponent("manifest.json")
            let manifest: RuntimeImageManifest
            do {
                let data = try Data(contentsOf: manifestURL)
                manifest = try JSONDecoder().decode(RuntimeImageManifest.self, from: data)
            } catch let error as DecodingError {
                throw .manifestInvalid(path: "manifest.json", reason: String(describing: error))
            } catch {
                throw .missingFile(file: "manifest.json")
            }
            guard manifest.schemaVersion == 1 else {
                throw .manifestInvalid(path: "manifest.json", reason: "needs a newer APKRun")
            }
            for entry in manifest.files {
                let url = directory.appendingPathComponent(entry.path)
                guard
                    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                    let size = (attributes[.size] as? NSNumber)?.uint64Value
                else {
                    throw .missingFile(file: entry.path)
                }
                guard size == entry.size else {
                    throw .hashMismatch(file: entry.path)
                }
            }
            return InstalledImage(
                version: manifest.imageVersion,
                root: directory,
                manifest: manifest
            )
        #else
            throw .manifestInvalid(
                path: "manifest.json",
                reason: "unsigned development bundles load only in Debug builds"
            )
        #endif
    }
}
