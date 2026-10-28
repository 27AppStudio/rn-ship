require "securerandom"
require "fastlane/action"
require_relative "../helper/config"
require_relative "../helper/ios"

module Fastlane
  module Actions
    # On GitHub-hosted runners, setup_ci creates a temporary keychain and makes it the default:
    # harmless on a throwaway VM. On a developer's Mac (a self-hosted runner, flagged by
    # ci.self_hosted_env) that would replace their login keychain as the default, so a
    # dedicated non-default keychain is created instead and deleted by rn_ship_ci_signing_cleanup.
    class RnShipCiSigningAction < Action
      def self.run(params)
        unless Helper.ci? || params[:force]
          UI.message("Not on CI, leaving the keychain alone")
          return { keychain: nil, archive_path: nil }
        end

        config = lane_context[SharedValues::RN_SHIP_CONFIG] || Helper::RnShipConfig.load(params[:config_path])
        ci = config.ci

        result = if ENV[ci["self_hosted_env"]].to_s.empty?
                   other_action.setup_ci(force: params[:force])
                   { keychain: ENV["MATCH_KEYCHAIN_NAME"], archive_path: nil }
                 else
                   self_hosted(ci["keychain"])
                 end

        # setup_ci already does this; set it on every path so no CI run can create or revoke
        # certificates, whichever branch ran.
        ENV["MATCH_READONLY"] = "true"
        result
      end

      def self.self_hosted(name)
        RnShipCiSigningCleanupAction.delete(name, other_action)
        password = SecureRandom.hex(24)
        other_action.create_keychain(
          name: name,
          password: password,
          default_keychain: false,
          unlock: true,
          timeout: 3600,
          lock_when_sleeps: false,
          add_to_search_list: true
        )
        Helper::RnShipIos.prioritize_keychain!(name)
        ENV["MATCH_KEYCHAIN_NAME"] = name
        ENV["MATCH_KEYCHAIN_PASSWORD"] = password

        # gym archives into ~/Library/Developer/Xcode/Archives by default: on a developer's Mac
        # that's ~150 MB of theirs per deploy. RUNNER_TEMP is wiped after every job.
        archive = ENV["RUNNER_TEMP"].to_s.empty? ? nil : File.join(ENV["RUNNER_TEMP"], "rn-ship.xcarchive")
        { keychain: name, archive_path: archive }
      end

      def self.description
        "Prepare signing on CI: a throwaway keychain on hosted runners, a dedicated one on self-hosted Macs"
      end

      def self.details
        [
          "GitHub-hosted: fastlane's setup_ci. Self-hosted (ci.self_hosted_env set): a non-default keychain with a random",
          "password, moved to the front of the search list, plus an archive path in RUNNER_TEMP. Always sets match to",
          "read-only. Pair with rn_ship_ci_signing_cleanup in after_all and error."
        ].join(" ")
      end

      def self.available_options
        [
          FastlaneCore::ConfigItem.new(key: :force, description: "Run outside CI too", type: Fastlane::Boolean, default_value: false),
          FastlaneCore::ConfigItem.new(key: :config_path, env_name: "RN_SHIP_CONFIG", description: "Path to rn-ship.yml when rn_ship_config hasn't run", type: String, optional: true)
        ]
      end

      def self.return_value
        "A hash { keychain:, archive_path: }; archive_path is nil except on self-hosted runners"
      end

      def self.authors
        ["27AppStudio"]
      end

      def self.is_supported?(platform)
        platform == :ios
      end

      def self.example_code
        [
          'signing = rn_ship_ci_signing
          build_app(scheme: "staging", archive_path: signing[:archive_path])'
        ]
      end

      def self.category
        :code_signing
      end
    end

    class RnShipCiSigningCleanupAction < Action
      def self.run(params)
        config = lane_context[SharedValues::RN_SHIP_CONFIG] || Helper::RnShipConfig.load(params[:config_path])
        return false if ENV[config.ci["self_hosted_env"]].to_s.empty?

        delete(config.ci["keychain"], other_action)
      end

      # `actions` is the caller's other_action: this class's own runner is only set once it has
      # run in the lane itself.
      def self.delete(name, actions)
        return false unless File.exist?(Helper::RnShipIos.keychain_path(name))

        actions.delete_keychain(name: name)
        true
      end

      def self.description
        "Delete the self-hosted signing keychain created by rn_ship_ci_signing"
      end

      def self.available_options
        [
          FastlaneCore::ConfigItem.new(key: :config_path, env_name: "RN_SHIP_CONFIG", description: "Path to rn-ship.yml when rn_ship_config hasn't run", type: String, optional: true)
        ]
      end

      def self.return_value
        "true when a keychain was deleted"
      end

      def self.authors
        ["27AppStudio"]
      end

      def self.is_supported?(platform)
        platform == :ios
      end

      def self.example_code
        [
          'after_all { rn_ship_ci_signing_cleanup }
          error { rn_ship_ci_signing_cleanup }'
        ]
      end

      def self.category
        :code_signing
      end
    end
  end
end
