require "fastlane/plugin/rn_ship/version"

module Fastlane
  module RnShip
    # Loaded by fastlane's plugin manager; returns every action and helper file.
    def self.all_classes
      Dir[File.expand_path("**/{actions,helper}/*.rb", File.dirname(__FILE__))]
    end
  end
end

Fastlane::RnShip.all_classes.each do |current|
  require current
end
