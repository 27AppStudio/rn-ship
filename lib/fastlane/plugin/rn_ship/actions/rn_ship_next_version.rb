require "fastlane/action"
require_relative "../helper/versioning"

module Fastlane
  module Actions
    module SharedValues
      RN_SHIP_NEXT_VERSION = :RN_SHIP_NEXT_VERSION
      RN_SHIP_NEXT_BUILD = :RN_SHIP_NEXT_BUILD
    end

    class RnShipNextVersionAction < Action
      def self.run(params)
        result = Helper::RnShipVersioning.resolve_next_version(
          current_version: params[:current_version],
          current_build: params[:current_build],
          latest_version: params[:latest_version],
          latest_build: params[:latest_build],
          live_version: params[:live_version],
          monotonic_build: params[:monotonic_build]
        )
        if params[:bump]
          result = Helper::RnShipVersioning.apply_bump(result, type: params[:bump], monotonic_build: params[:monotonic_build])
        end

        lane_context[SharedValues::RN_SHIP_NEXT_VERSION] = result[:version]
        lane_context[SharedValues::RN_SHIP_NEXT_BUILD] = result[:build]
        UI.message("Next version: #{result[:version]} (#{result[:build]})")
        result
      end

      def self.description
        "Resolve the next version name and build number from the checked-in values and the store state"
      end

      def self.details
        [
          "The store is the source of truth: the version aligns to the latest beta build,",
          "the build number continues from whichever of store and branch is ahead, and a version",
          "that is already live gets a patch bump. With `monotonic_build` (Google Play) the build",
          "number never resets."
        ].join(" ")
      end

      def self.available_options
        [
          FastlaneCore::ConfigItem.new(key: :current_version, description: "Version name checked into the project", type: String),
          FastlaneCore::ConfigItem.new(key: :current_build, description: "Build number checked into the project", type: Integer),
          FastlaneCore::ConfigItem.new(key: :latest_version, description: "Version of the newest beta build on the store, nil if none", type: String, optional: true),
          FastlaneCore::ConfigItem.new(key: :latest_build, description: "Build number of the newest beta build (Play: highest versionCode on any track)", type: Integer, default_value: 0),
          FastlaneCore::ConfigItem.new(key: :live_version, description: "Version currently live on the public store, nil if none", type: String, optional: true),
          FastlaneCore::ConfigItem.new(key: :monotonic_build, description: "Never reset the build number (Google Play versionCode)", type: Fastlane::Boolean, default_value: false),
          FastlaneCore::ConfigItem.new(key: :bump, description: "Also bump the resolved version: major, minor or patch", type: String, optional: true,
                                       verify_block: proc { |value| UI.user_error!("bump must be major, minor or patch, got #{value.inspect}") unless %w[major minor patch].include?(value) })
        ]
      end

      def self.output
        [
          ["RN_SHIP_NEXT_VERSION", "The resolved version name"],
          ["RN_SHIP_NEXT_BUILD", "The resolved build number"]
        ]
      end

      def self.return_value
        "A hash { version: String, build: Integer }"
      end

      def self.authors
        ["27AppStudio"]
      end

      def self.is_supported?(platform)
        [:ios, :android].include?(platform)
      end

      def self.example_code
        [
          'rn_ship_next_version(current_version: "1.2.0", current_build: 4, latest_version: "1.2.0", latest_build: 6, live_version: "1.1.3")'
        ]
      end

      def self.category
        :building
      end
    end
  end
end
