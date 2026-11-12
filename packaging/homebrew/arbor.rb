# Homebrew cask template for Arbor.
#
# For each release (see docs/RELEASING.md):
#   1. Set `version` to the released version (VERSION, without the leading "v").
#   2. Set `sha256` to the checksum of the released disk image:
#        shasum -a 256 Arbor-<version>.dmg
#      (the release also has Arbor-<version>.dmg.sha256 attached).
#   3. Replace OWNER below with the GitHub account that hosts the repository.
#   4. Check it: brew style --fix arbor.rb && brew audit --cask --new arbor
#
# Where to publish it:
#   - Own tap (works today): put this file at Casks/arbor.rb in a repository named
#     OWNER/homebrew-arbor. Users then run: brew install --cask OWNER/arbor/arbor
#   - homebrew/cask (the main repository) only accepts apps that are signed with a Developer ID and
#     notarized, and that meet its notability rules. Submit there once releases are notarized.
cask "arbor" do
  version "0.4.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/OWNER/arbor/releases/download/v#{version}/Arbor-#{version}.dmg"
  name "Arbor"
  desc "File manager with tabs, a folder tree and an editable address bar"
  homepage "https://github.com/OWNER/arbor"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"

  app "Arbor.app"

  zap trash: [
    "~/Library/Application Support/Arbor",
    "~/Library/Preferences/io.github.arbor-files.Arbor.plist",
    "~/Library/Saved Application State/io.github.arbor-files.Arbor.savedState",
  ]
end
