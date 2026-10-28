require "fastlane_core/ui/ui"

module Fastlane
  module Helper
    # Pure version arithmetic shared by the iOS and Android lanes. No side effects, no API
    # calls: callers read the store state and pass it in.
    module RnShipVersioning
      module_function

      # Compute the next semver from a version string and a bump type
      def bump_semver(version:, type:)
        parts = version.to_s.split(".").map(&:to_i)
        parts << 0 while parts.length < 3

        case type.to_s
        when "major" then parts = [parts[0] + 1, 0, 0]
        when "minor" then parts = [parts[0], parts[1] + 1, 0]
        when "patch" then parts[2] += 1
        else UI.user_error!("Unknown bump type: #{type}. Expected major, minor, or patch.")
        end

        parts.join(".")
      end

      # Resolve the next version and build number based on local and store state.
      # Returns { version: String, build: Integer }
      #
      # `latest_*` is the newest beta build on the store (TestFlight, Play internal track) and
      # `live_version` the version the public store already has, if any.
      #
      # `monotonic_build:` is for Google Play, where a versionCode can never be reused on any
      # track: the build number keeps counting from the highest one the store has ever seen
      # (pass it as `latest_build`) instead of resetting to 1 on a new version. The version
      # name follows exactly the same rules either way.
      def resolve_next_version(current_version:, current_build:, latest_version:, latest_build:, live_version:, monotonic_build: false)
        version = current_version
        highest_build = [latest_build.to_i, current_build.to_i].max

        if latest_version.nil? || latest_version.empty?
          build = highest_build + 1
        elsif current_version != latest_version
          version = latest_version
          build = latest_build.to_i + 1
        else
          # Take whichever is ahead, matching the no-store-version branch above. Trusting
          # the checked-in build number alone recomputes a number the store already has
          # whenever a version-bump commit fails to reach the branch — the lane commits the
          # bump before a long build and pushes it afterwards, so any failure in between
          # leaves the branch behind what actually shipped, and every subsequent run is then
          # rejected as a duplicate. The store is the authority on what exists; the branch
          # is a record.
          build = highest_build + 1
        end

        build = highest_build + 1 if monotonic_build

        # Closed train: current version already live on the store
        if live_version && version == live_version
          version = bump_semver(version: version, type: "patch")
          build = 1 unless monotonic_build
        end

        { version: version, build: build }
      end
    end
  end
end
