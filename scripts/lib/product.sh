# The app's shipped name, for the scripts that build, package and release it. Sourced, not run.
#
# The name is written once, as CFBundleName in Resources/Info.plist; Product.name in BetterExplorerCore must match it
# (a unit test checks). The executable is Contents/MacOS/BetterExplorer (CFBundleExecutable, Product.executable).
# Renaming the app again means changing CFBundleName and Product.name; nothing here changes.

PRODUCT_NAME="$(plutil -extract CFBundleName raw "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/Resources/Info.plist")"
# The bundle, relative to the repository root: build/Better Explorer.app. The name has a space, so always quote it.
PRODUCT_APP="build/$PRODUCT_NAME.app"
# Release file names (Better-Explorer-<version>.dmg and .zip) end up in URLs, so they have no spaces.
PRODUCT_FILES="${PRODUCT_NAME// /-}"
