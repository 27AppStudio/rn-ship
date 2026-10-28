require "fastlane/action"
require_relative "../helper/config"
require_relative "../helper/android"

module Fastlane
  module Actions
    module SharedValues
      RN_SHIP_VERSION_FILES = :RN_SHIP_VERSION_FILES
    end

    class RnShipGradleVersionAction < Action
      def self.run(params)
        path = params[:gradle_file] || begin
          config = lane_context[SharedValues::RN_SHIP_CONFIG] || Helper::RnShipConfig.load(params[:config_path])
          UI.user_error!("rn-ship.yml has no android section") unless config.android
          config.expand(config.android["gradle_file"])
        end

        current = Helper::RnShipAndroid.read_gradle_version(path)
        return current if params[:version].nil? && params[:build].nil?

        updated = { version: params[:version] || current[:version], build: params[:build] || current[:build] }
        lane_context[SharedValues::RN_SHIP_VERSION_FILES] = Helper::RnShipAndroid.write_gradle_version(path, **updated)
        UI.message("#{File.basename(path)}: #{current[:version]} (#{current[:build]}) → #{updated[:version]} (#{updated[:build]})")
        updated
      end

      def self.description
        "Read or write versionName / versionCode in build.gradle(.kts)"
      end

      def self.details
        "Without version/build it only reads. Expects exactly one literal of each, in defaultConfig: a per-flavor override would silently keep its own value, so it is refused."
      end

      def self.available_options
        [
          FastlaneCore::ConfigItem.new(key: :version, description: "New versionName", type: String, optional: true),
          FastlaneCore::ConfigItem.new(key: :build, description: "New versionCode", type: Integer, optional: true),
          FastlaneCore::ConfigItem.new(key: :gradle_file, description: "build.gradle path (defaults to android.gradle_file in rn-ship.yml)", type: String, optional: true),
          FastlaneCore::ConfigItem.new(key: :config_path, env_name: "RN_SHIP_CONFIG", description: "Path to rn-ship.yml when rn_ship_config hasn't run", type: String, optional: true)
        ]
      end

      def self.output
        [["RN_SHIP_VERSION_FILES", "The files a write changed, for git_commit(path:)"]]
      end

      def self.return_value
        "A hash { version:, build: } after any change"
      end

      def self.authors
        ["27AppStudio"]
      end

      def self.is_supported?(platform)
        platform == :android
      end

      def self.example_code
        [
          'current = rn_ship_gradle_version
          next_version = rn_ship_next_version(current_version: current[:version], current_build: current[:build], **rn_ship_store_state(flavor: "staging"))
          rn_ship_gradle_version(version: next_version[:version], build: next_version[:build])'
        ]
      end

      def self.category
        :project
      end
    end
  end
end
