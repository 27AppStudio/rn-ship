$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "fastlane"
require "fastlane/plugin/rn_ship"

Fastlane.load_actions

# Runs a one-off lane so actions go through fastlane's real option parsing.
def run_lane(body)
  Fastlane::FastFile.new.parse("lane :test do\n#{body}\nend").runner.execute(:test)
end
