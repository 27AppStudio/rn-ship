lib = File.expand_path("lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "fastlane/plugin/rn_ship/version"

Gem::Specification.new do |spec|
  spec.name          = "fastlane-plugin-rn_ship"
  spec.version       = Fastlane::RnShip::VERSION
  spec.author        = "27AppStudio"
  spec.email         = "dev@27appstudio.com"

  spec.summary       = "EAS-style CI/CD for bare React Native apps: store-driven versioning, safe CI signing and parallel-safe releases."
  spec.description   = "Release lanes for bare React Native apps without Expo: resolves version and build numbers from TestFlight and Google Play, and pushes release tags safely when iOS and Android deploy in parallel."
  spec.homepage      = "https://github.com/27AppStudio/rn-ship"
  spec.license       = "MIT"
  spec.metadata      = {
    "source_code_uri" => "https://github.com/27AppStudio/rn-ship",
    "changelog_uri" => "https://github.com/27AppStudio/rn-ship/blob/main/CHANGELOG.md",
    "rubygems_mfa_required" => "true"
  }

  spec.files         = Dir["lib/**/*"] + %w[README.md LICENSE CHANGELOG.md]
  spec.require_paths = ["lib"]
  spec.required_ruby_version = ">= 3.1"

  spec.add_development_dependency("fastlane", "~> 2.225")
  spec.add_development_dependency("rake", "~> 13.0")
  spec.add_development_dependency("rspec", "~> 3.13")
end
