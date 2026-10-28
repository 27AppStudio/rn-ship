require "fastlane/action"
require_relative "../helper/git_release"

module Fastlane
  module Actions
    class RnShipPushReleaseAction < Action
      def self.run(params)
        Helper::RnShipGitRelease.push_release(
          branch: params[:branch],
          tag: params[:tag],
          remote: params[:remote],
          attempts: params[:attempts]
        )
      end

      def self.description
        "Rebase the version-bump commit onto the remote branch, tag it and push both atomically"
      end

      def self.details
        [
          "Discards CI-only edits to tracked files, rebases onto the latest remote branch,",
          "tags after the rebase and pushes branch + tag with `--atomic`. A rejected push",
          "(the other platform deployed in parallel) is retried; a rebase conflict is not."
        ].join(" ")
      end

      def self.available_options
        [
          FastlaneCore::ConfigItem.new(key: :branch, description: "Branch to push the bump commit to", type: String),
          FastlaneCore::ConfigItem.new(key: :tag, description: "Annotated tag to create on the final commit", type: String),
          FastlaneCore::ConfigItem.new(key: :remote, description: "Git remote", type: String, default_value: "origin"),
          FastlaneCore::ConfigItem.new(key: :attempts, description: "Push attempts before giving up", type: Integer, default_value: 3,
                                       verify_block: proc { |value| UI.user_error!("attempts must be at least 1") if value < 1 })
        ]
      end

      def self.authors
        ["27AppStudio"]
      end

      def self.is_supported?(platform)
        [:ios, :android].include?(platform)
      end

      def self.example_code
        [
          'rn_ship_push_release(branch: "staging", tag: "ios/staging/1.2.0+7")'
        ]
      end

      def self.category
        :source_control
      end
    end
  end
end
