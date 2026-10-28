require "fastlane/action"
require_relative "../helper/config"
require_relative "../helper/android"

module Fastlane
  module Actions
    class RnShipVerifyAabAction < Action
      def self.run(params)
        config = lane_context[SharedValues::RN_SHIP_CONFIG] || Helper::RnShipConfig.load(params[:config_path])
        UI.user_error!("rn-ship.yml has no android section") unless config.android
        module_dir = File.dirname(config.expand(config.android["gradle_file"]))

        upload_key = Helper::RnShipAndroid.upload_key!(
          prefix: config.android["upload_key_prefix"],
          project_dir: config.expand(config.android["project_dir"]),
          module_dir: module_dir
        )
        fingerprint = Helper::RnShipAndroid.verify_upload_signature!(
          params[:aab],
          upload_key: upload_key,
          debug_keystores: [File.join(module_dir, "debug.keystore"), File.expand_path("~/.android/debug.keystore")]
        )
        UI.success("Signed with the upload key: SHA-256 #{fingerprint}")
        fingerprint
      end

      def self.description
        "After an Android release build: refuse to ship a bundle not signed with the upload key"
      end

      def self.details
        [
          "Compares the bundle's signing certificate with the upload key's own certificate (a positive match,",
          "not just 'not the debug key'), and names the debug keystore when that's what signed it."
        ].join(" ")
      end

      def self.available_options
        [
          FastlaneCore::ConfigItem.new(key: :aab, description: "Path to the AAB or APK (defaults to the last gradle build's AAB)", type: String,
                                       default_value: Actions.lane_context[SharedValues::GRADLE_AAB_OUTPUT_PATH], default_value_dynamic: true),
          FastlaneCore::ConfigItem.new(key: :config_path, env_name: "RN_SHIP_CONFIG", description: "Path to rn-ship.yml when rn_ship_config hasn't run", type: String, optional: true)
        ]
      end

      def self.return_value
        "The SHA-256 fingerprint of the signing certificate"
      end

      def self.authors
        ["27AppStudio"]
      end

      def self.is_supported?(platform)
        platform == :android
      end

      def self.example_code
        [
          'gradle(task: "bundle", flavor: "Staging", build_type: "Release", project_dir: "android")
          rn_ship_verify_aab'
        ]
      end

      def self.category
        :building
      end
    end
  end
end
