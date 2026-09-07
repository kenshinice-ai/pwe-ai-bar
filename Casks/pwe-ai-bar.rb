# Homebrew cask for PWE AI Bar, published to kenshinice-ai/homebrew-tap.
#
#   brew install --cask kenshinice-ai/tap/pwe-ai-bar
#
# scripts/release.sh rewrites version and sha256 here and pushes the result to the tap, so
# this file should not be edited by hand for a release.

cask "pwe-ai-bar" do
  version "1.0.1"
  sha256 "edc5d90efed2d73d61948ff126577d754664ab31e5c50c46a10d405bb6ae9772"

  url "https://github.com/kenshinice-ai/pwe-ai-bar/releases/download/v#{version}/PWE-AI-Bar-#{version}.dmg"
  name "PWE AI Bar"
  desc "Menu-bar quota meter and sentinel for AI coding tools"
  homepage "https://github.com/kenshinice-ai/pwe-ai-bar"

  depends_on macos: :ventura
  depends_on arch: :arm64

  app "PWE AI Bar.app"

  # A menu-bar app is almost always running when its upgrade arrives. Without this, brew swaps
  # the bundle underneath the live process: the old code keeps running, the menu bar keeps
  # showing the old version, and the upgrade looks like it did nothing at all.
  uninstall quit: "com.paradiseproduction.pweaibar"

  # Deliberately not listed: the three hooks the app can add to ~/.claude/settings.json. That
  # file is the customer's own Claude Code configuration and it is merged into, not owned —
  # zapping it would take their settings with it. Settings ▸ 会话事件 removes the hooks.
  zap trash: [
    "~/.cache/pwe-ai-bar",
    "~/Library/Application Support/PWE AI Bar",
    "~/Library/Caches/PWE AI Bar",
    "~/Library/HTTPStorages/com.paradiseproduction.pweaibar",
    "~/Library/Preferences/com.paradiseproduction.pweaibar.plist",
  ]
end
