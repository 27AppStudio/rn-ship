require "fastlane/action"
require_relative "../helper/config"

module Fastlane
  module Actions
    module SharedValues
      RN_SHIP_CONFIG = :RN_SHIP_CONFIG
    end

    class RnShipConfigAction < Action
      def self.run(params)
        config = Helper::RnShipConfig.load(params[:path])
        lane_context[SharedValues::RN_SHIP_CONFIG] = config
        UI.message("Loaded #{config.path} (flavors: #{config.flavor_names.join(', ')})")
        config
      end

      def self.description
        "Load and validate rn-ship.yml, the flavor map of a bare React Native project"
      end

      def self.details
        "Finds the nearest rn-ship.yml above the current directory (or RN_SHIP_CONFIG), validates it and reports every problem at once with its key path."
      end

      def self.available_options
        [
          FastlaneCore::ConfigItem.new(key: :path, env_name: "RN_SHIP_CONFIG", description: "Path to rn-ship.yml", type: String, optional: true)
        ]
      end

      def self.output
        [["RN_SHIP_CONFIG", "The loaded Fastlane::Helper::RnShipConfig"]]
      end

      def self.return_value
        "A Fastlane::Helper::RnShipConfig"
      end

      def self.authors
        ["27AppStudio"]
      end

      def self.is_supported?(platform)
        [:ios, :android].include?(platform)
      end

      def self.example_code
        [
          'config = rn_ship_config
          flavor = config.flavor("staging")
          match(type: "appstore", app_identifier: config.ios_app_identifiers("staging"), readonly: is_ci)'
        ]
      end

      def self.category
        :misc
      end
    end
  end
end
