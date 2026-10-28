require "fastlane/action"
require_relative "../helper/config"
require_relative "../helper/android"

module Fastlane
  module Actions
    class RnShipAndroidPreflightAction < Action
      def self.run(params)
        config = lane_context[SharedValues::RN_SHIP_CONFIG] || Helper::RnShipConfig.load(params[:config_path])
        UI.user_error!("rn-ship.yml has no android section") unless config.android
        flavor = config.flavor(params[:flavor])

        upload_key = Helper::RnShipAndroid.upload_key!(
          prefix: config.android["upload_key_prefix"],
          project_dir: config.expand(config.android["project_dir"]),
          module_dir: File.dirname(config.expand(config.android["gradle_file"]))
        )
        UI.success("Upload key: #{upload_key[:key_alias]} in #{upload_key[:store_file]}")

        env_file = config.pin_env_file!(flavor)
        UI.success("ENVFILE=#{env_file}") if env_file

        { store_file: upload_key[:store_file], key_alias: upload_key[:key_alias], env_file: env_file }
      end

      def self.description
        "Before an Android release build: require the upload key and pin the flavor's env file"
      end

      def self.details
        [
          "Fails before Gradle runs when any <upload_key_prefix>_STORE_FILE / _STORE_PASSWORD / _KEY_ALIAS / _KEY_PASSWORD",
          "property is missing or the keystore file doesn't exist, so a release can never fall back to the debug key.",
          "Sets ENVFILE to the absolute path of the flavor's env_file so react-native-config can't fall back to `.env`."
        ].join(" ")
      end

      def self.available_options
        [
          FastlaneCore::ConfigItem.new(key: :flavor, description: "Flavor from rn-ship.yml", type: String),
          FastlaneCore::ConfigItem.new(key: :config_path, env_name: "RN_SHIP_CONFIG", description: "Path to rn-ship.yml when rn_ship_config hasn't run", type: String, optional: true)
        ]
      end

      def self.return_value
        "A hash { store_file:, key_alias:, env_file: } (no passwords)"
      end

      def self.authors
        ["27AppStudio"]
      end

      def self.is_supported?(platform)
        platform == :android
      end

      def self.example_code
        ['rn_ship_android_preflight(flavor: "staging")']
      end

      def self.category
        :building
      end
    end
  end
end
