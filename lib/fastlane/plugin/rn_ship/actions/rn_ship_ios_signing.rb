require "fastlane/action"
require_relative "../helper/config"
require_relative "../helper/ios"

module Fastlane
  module Actions
    class RnShipIosSigningAction < Action
      def self.run(params)
        config = lane_context[SharedValues::RN_SHIP_CONFIG] || Helper::RnShipConfig.load(params[:config_path])
        UI.user_error!("rn-ship.yml has no ios section") unless config.ios
        flavor = config.flavor(params[:flavor])
        identity = Helper::RnShipIos::CODE_SIGN_IDENTITY.fetch(config.ios["match"]["type"])

        # The checked-in project is not trusted: every target gets its team, identity, match
        # profile and bundle id from rn-ship.yml, for the flavor's configuration only.
        config.ios_signing_targets(flavor.name).zip(config.ios_app_identifiers(flavor.name)).map do |(target, profile), bundle_id|
          other_action.update_code_signing_settings(
            path: config.expand(config.ios["project"]),
            targets: [target],
            build_configurations: [flavor.ios.fetch("configuration")],
            use_automatic_signing: false,
            team_id: config.ios["team_id"],
            code_sign_identity: identity,
            profile_name: profile,
            bundle_identifier: bundle_id
          )
          { target: target, profile: profile, bundle_id: bundle_id }
        end
      end

      def self.description
        "Set manual signing for the app and every extension from rn-ship.yml, for one flavor"
      end

      def self.details
        [
          "Writes team, code sign identity, match profile and bundle id into each target's build settings for the flavor's",
          "configuration. Run rn_ship_ios_preflight first: update_code_signing_settings silently skips unknown targets.",
          "These are CI-only edits; rn_ship_push_release discards them before pushing."
        ].join(" ")
      end

      def self.available_options
        [
          FastlaneCore::ConfigItem.new(key: :flavor, description: "Flavor from rn-ship.yml", type: String),
          FastlaneCore::ConfigItem.new(key: :config_path, env_name: "RN_SHIP_CONFIG", description: "Path to rn-ship.yml when rn_ship_config hasn't run", type: String, optional: true)
        ]
      end

      def self.return_value
        "An array of { target:, profile:, bundle_id: }"
      end

      def self.authors
        ["27AppStudio"]
      end

      def self.is_supported?(platform)
        platform == :ios
      end

      def self.example_code
        [
          'config = rn_ship_config
          match(type: "appstore", app_identifier: config.ios_app_identifiers("staging"))
          rn_ship_ios_signing(flavor: "staging")'
        ]
      end

      def self.category
        :code_signing
      end
    end
  end
end
