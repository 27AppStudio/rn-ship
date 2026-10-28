require "fastlane/action"
require_relative "../helper/config"
require_relative "../helper/ios"

module Fastlane
  module Actions
    class RnShipXcodeVersionAction < Action
      def self.run(params)
        config = lane_context[SharedValues::RN_SHIP_CONFIG] || Helper::RnShipConfig.load(params[:config_path])
        UI.user_error!("rn-ship.yml has no ios section") unless config.ios
        flavor = config.flavor(params[:flavor])
        project = config.expand(config.ios["project"])

        current = Helper::RnShipIos.read_xcode_version(project: project, target: config.ios["target"], configuration: flavor.ios.fetch("configuration"))
        return current if params[:version].nil? && params[:build].nil?

        updated = { version: params[:version] || current[:version], build: params[:build] || current[:build] }
        files = Helper::RnShipIos.write_xcode_version(project: project, targets: config.ios_targets, **updated)
        UI.message("#{File.basename(project)}: #{current[:version]} (#{current[:build]}) → #{updated[:version]} (#{updated[:build]})")
        updated.merge(files: files)
      end

      def self.description
        "Read or write the version and build number of the app and its extensions"
      end

      def self.details
        [
          "Reads what the archive will carry: a literal in Info.plist, else MARKETING_VERSION / CURRENT_PROJECT_VERSION.",
          "Writes those build settings in every configuration of the app and every extension, plus any literal Info.plist",
          "values, so extensions can't drift from the app. No agvtool or VERSIONING_SYSTEM needed."
        ].join(" ")
      end

      def self.available_options
        [
          FastlaneCore::ConfigItem.new(key: :flavor, description: "Flavor from rn-ship.yml (its configuration is the one read)", type: String),
          FastlaneCore::ConfigItem.new(key: :version, description: "New version (CFBundleShortVersionString)", type: String, optional: true),
          FastlaneCore::ConfigItem.new(key: :build, description: "New build number (CFBundleVersion)", type: Integer, optional: true),
          FastlaneCore::ConfigItem.new(key: :config_path, env_name: "RN_SHIP_CONFIG", description: "Path to rn-ship.yml when rn_ship_config hasn't run", type: String, optional: true)
        ]
      end

      def self.return_value
        "A hash { version:, build: }; a write adds files: (what it changed, for git_commit(path:))"
      end

      def self.authors
        ["27AppStudio"]
      end

      def self.is_supported?(platform)
        platform == :ios
      end

      def self.example_code
        [
          'current = rn_ship_xcode_version(flavor: "staging")
          next_version = rn_ship_next_version(current_version: current[:version], current_build: current[:build], **rn_ship_store_state(flavor: "staging"))
          written = rn_ship_xcode_version(flavor: "staging", **next_version)
          git_commit(path: written[:files], message: "Release #{next_version[:version]}")'
        ]
      end

      def self.category
        :project
      end
    end
  end
end
