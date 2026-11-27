/// The app's names. `name` must equal CFBundleName in Resources/Info.plist, where the bundle and the scripts
/// (scripts/lib/product.sh) take it from, and `executable` CFBundleExecutable; a unit test checks both.
/// User-visible strings spell the name out, because translators need whole sentences (scripts/extract-strings.sh).
///
/// A few identifiers keep the app's first name, Arbor, because users' data depends on them: the bundle identifier
/// (settings, the saved-search type, Services and in-app updates), `supportFolder`, the `.arborsearch` extension and
/// the `arbor.settings` and `arbor.search` file formats. Changing any of them loses what people already have.
public enum Product {
    public static let name = "Better Explorer"
    public static let executable = "BetterExplorer"
    /// The folder in ~/Library/Application Support holding history, folder views, workspaces and job journals.
    public static let supportFolder = "Arbor"
}
