require "fastlane/action"
require_relative "../helper/config"
require_relative "../helper/ios"
require_relative "../helper/store_state"

module Fastlane
  module Actions
    class RnShipIosPreflightAction < Action
      def self.run(params)
        config = lane_context[SharedValues::RN_SHIP_CONFIG] || Helper::RnShipConfig.load(params[:config_path])
        UI.user_error!("rn-ship.yml has no ios section") unless config.ios
        flavor = config.flavor(params[:flavor])
        ios = config.ios

        Helper::RnShipIos.check_project!(
          project: config.expand(ios["project"]),
          workspace: config.expand(ios["workspace"]),
          scheme: flavor.ios.fetch("scheme"),
          configuration: flavor.ios.fetch("configuration"),
          targets: config.ios_targets
        )
        UI.success("Project: scheme #{flavor.ios['scheme']}, #{flavor.ios['configuration']}, targets #{config.ios_targets.join(', ')}")

        Helper::RnShipIos.ensure_no_stale_envfile!
        env_file = config.pin_env_file!(flavor)
        UI.success("ENVFILE=#{env_file}") if env_file

        # Fail now rather than after the archive if the upload can't authenticate.
        Helper::RnShipStoreState.app_store_connect_api_key_options(ios["app_store_connect"]) unless params[:skip_api_key_check]

        { scheme: flavor.ios["scheme"], configuration: flavor.ios["configuration"], env_file: env_file }
      end

      def self.description
        "Before an iOS release build: check the project, scheme and env file, and the App Store Connect key"
      end

      def self.details
        [
          "Fails before match or the archive when a target, the configuration or the shared scheme from rn-ship.yml",
          "isn't in the Xcode project, when /tmp/envfile would override ENVFILE, when the flavor's env file is missing,",
          "or when the App Store Connect key env vars aren't set. Sets ENVFILE to the env file's absolute path."
        ].join(" ")
      end

      def self.available_options
        [
          FastlaneCore::ConfigItem.new(key: :flavor, description: "Flavor from rn-ship.yml", type: String),
          FastlaneCore::ConfigItem.new(key: :skip_api_key_check, description: "Don't require the App Store Connect key (local builds that won't upload)", type: Fastlane::Boolean, default_value: false),
          FastlaneCore::ConfigItem.new(key: :config_path, env_name: "RN_SHIP_CONFIG", description: "Path to rn-ship.yml when rn_ship_config hasn't run", type: String, optional: true)
        ]
      end

      def self.return_value
        "A hash { scheme:, configuration:, env_file: }"
      end

      def self.authors
        ["27AppStudio"]
      end

      def self.is_supported?(platform)
        platform == :ios
      end

      def self.example_code
        ['rn_ship_ios_preflight(flavor: "staging")']
      end

      def self.category
        :building
      end
    end
  end
end
