# Homebrew cask for LocalMind.
#
# To publish your own tap:
#   1. Create a repo named `homebrew-localmind` (the `homebrew-` prefix is
#      required — the tap is then `<you>/localmind`).
#   2. Copy this file to `Casks/localmind.rb` in that repo.
#   3. After each release, update `version` and the two `sha256` values
#      (the release workflow uploads a `LocalMind.dmg.sha256` next to the DMG).
#
# Users then install with:
#   brew install --cask <you>/localmind/localmind
cask "localmind" do
  version "1.0.0"

  # Replace both with the SHA-256 of the built DMG for each architecture. If
  # you ship a single universal DMG, use the same value for both.
  on_arm do
    sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  end
  on_intel do
    sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  end

  url "https://github.com/Dizzy918/LocalMind/releases/download/v#{version}/LocalMind.dmg"
  name "LocalMind"
  desc "Private, local-first AI assistant for macOS"
  homepage "https://github.com/Dizzy918/LocalMind"

  depends_on macos: ">= :sequoia"

  app "LocalMind.app"

  zap trash: [
    "~/Library/Application Support/LocalMind",
    "~/Library/Preferences/RS.LocalAIHelper.plist",
    "~/Library/Saved Application State/RS.LocalAIHelper.savedState",
  ]
end
