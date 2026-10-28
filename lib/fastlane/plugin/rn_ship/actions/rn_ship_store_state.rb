require "fastlane/action"
require_relative "../helper/config"
require_relative "../helper/store_state"

module Fastlane
  module Actions
    module SharedValues
      RN_SHIP_STORE_STATE = :RN_SHIP_STORE_STATE
    end

    class RnShipStoreStateAction < Action
      def self.run(params)
        config = lane_context[SharedValues::RN_SHIP_CONFIG] || Helper::RnShipConfig.load(params[:config_path])
        flavor = config.flavor(params[:flavor])

        state = params[:platform] == "ios" ? app_store(config, flavor) : play(config, flavor)
        lane_context[SharedValues::RN_SHIP_STORE_STATE] = state

        beta_build = state.key?(:beta_build) ? state[:beta_build] : state[:latest_build]
        summary = "Store: beta #{state[:latest_version] || 'none'} (#{beta_build || 'none'}), live #{state[:live_version] || 'none'}"
        summary += ", highest versionCode #{state[:max_build]}" if state.key?(:max_build)
        UI.message(summary)
        state.slice(:latest_version, :latest_build, :live_version, :monotonic_build)
      end

      def self.app_store(config, flavor)
        api_key = lane_context[SharedValues::APP_STORE_CONNECT_API_KEY] ||
                  other_action.app_store_connect_api_key(**Helper::RnShipStoreState.app_store_connect_api_key_options(config.ios["app_store_connect"]))
        app_identifier = flavor.ios.fetch("bundle_id")

        # initial_build_number 0: an app with nothing on TestFlight has no build yet, rather
        # than fastlane's default pretend build 1.
        build = other_action.latest_testflight_build_number(app_identifier: app_identifier, api_key: api_key, initial_build_number: 0)
        {
          latest_version: lane_context[SharedValues::LATEST_TESTFLIGHT_VERSION],
          latest_build: build.to_i,
          live_version: Helper::RnShipStoreState.app_store_live_version(app_identifier: app_identifier, api_key: api_key),
          monotonic_build: false
        }
      end

      def self.play(config, flavor)
        play = config.android["play"]
        json_key_data = ENV[play["json_key_env"]].to_s
        UI.user_error!("Google Play service account key not configured, set #{play['json_key_env']} to the key's JSON content") if json_key_data.strip.empty?

        state = Helper::RnShipStoreState.play(
          package_name: flavor.android.fetch("package_name"),
          json_key_data: json_key_data,
          beta_track: play["track"]
        )
        # Play's next versionCode goes above every track, not just the beta one.
        state.merge(latest_build: state[:max_build], beta_build: state[:latest_build], monotonic_build: true)
      end

      def self.description
        "Read what TestFlight / the App Store or Google Play already has for a flavor"
      end

      def self.details
        [
          "Returns the inputs of rn_ship_next_version, so the two compose:",
          "`rn_ship_next_version(current_version: v, current_build: b, **rn_ship_store_state(flavor: \"staging\"))`.",
          "On Google Play latest_build is the highest versionCode on any track and monotonic_build is true.",
          "Read-only: Play needs an edit to list tracks, which is aborted, never committed."
        ].join(" ")
      end

      def self.available_options
        [
          FastlaneCore::ConfigItem.new(key: :flavor, description: "Flavor from rn-ship.yml", type: String),
          FastlaneCore::ConfigItem.new(key: :platform, description: "ios or android (defaults to the lane's platform)", type: String,
                                       default_value: Actions.lane_context[SharedValues::PLATFORM_NAME]&.to_s, default_value_dynamic: true,
                                       verify_block: proc { |value| UI.user_error!("platform must be ios or android, got #{value.inspect}") unless %w[ios android].include?(value.to_s) }),
          FastlaneCore::ConfigItem.new(key: :config_path, env_name: "RN_SHIP_CONFIG", description: "Path to rn-ship.yml when rn_ship_config hasn't run", type: String, optional: true)
        ]
      end

      def self.output
        [["RN_SHIP_STORE_STATE", "Everything read, including Play's beta_build and max_build"]]
      end

      def self.return_value
        "A hash { latest_version:, latest_build:, live_version:, monotonic_build: } ready to splat into rn_ship_next_version"
      end

      def self.authors
        ["27AppStudio"]
      end

      def self.is_supported?(platform)
        [:ios, :android].include?(platform)
      end

      def self.example_code
        [
          'store = rn_ship_store_state(flavor: "staging")
          next_version = rn_ship_next_version(current_version: "1.2.0", current_build: 4, **store)'
        ]
      end

      def self.category
        :app_store_connect
      end
    end
  end
end
