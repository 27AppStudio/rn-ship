require "pathname"
require "yaml"
require "fastlane_core/ui/ui"
require_relative "config_schema"

module Fastlane
  module Helper
    # rn-ship.yml, the eas.json of a bare project: which flavors exist and how each one maps
    # to an iOS scheme/configuration/bundle id, a Gradle flavor/package name, a branch and an
    # env file. Paths in it are relative to the file.
    class RnShipConfig
      FILE_NAME = "rn-ship.yml".freeze

      # Per match type: the prefix of the profile names match creates, and gym's export method.
      MATCH_TYPES = {
        "appstore" => { profile_prefix: "AppStore", export_method: "app-store" },
        "adhoc" => { profile_prefix: "AdHoc", export_method: "ad-hoc" },
        "development" => { profile_prefix: "Development", export_method: "development" },
        "enterprise" => { profile_prefix: "InHouse", export_method: "enterprise" }
      }.freeze

      Flavor = Struct.new(:name, :branch, :env_file, :ios, :android, :tags, keyword_init: true)

      attr_reader :path, :root, :data

      # Explicit path, else RN_SHIP_CONFIG, else the nearest rn-ship.yml above the current
      # directory: fastlane runs from ios/ or android/, the file lives at the repo root.
      def self.load(path = nil)
        path ||= ENV["RN_SHIP_CONFIG"]
        path = path ? File.expand_path(path) : find(Dir.pwd)
        UI.user_error!("#{FILE_NAME} not found in #{Dir.pwd} or any parent directory (or set RN_SHIP_CONFIG)") unless path
        UI.user_error!("#{path} doesn't exist") unless File.file?(path)

        raw = begin
          YAML.safe_load_file(path, aliases: true) || {}
        rescue Psych::SyntaxError => e
          UI.user_error!("#{path} is not valid YAML: #{e.message}")
        end
        new(raw, path: path)
      end

      def self.find(dir)
        Pathname.new(dir).expand_path.ascend do |candidate|
          file = candidate.join(FILE_NAME)
          return file.to_s if file.file?
        end
        nil
      end

      def initialize(raw, path:)
        @path = path
        @root = File.dirname(path)
        @data, errors = RnShipConfigSchema.validate(raw)
        return if errors.empty?

        UI.user_error!("#{path} is invalid:\n" + errors.map { |error| "  - #{error}" }.join("\n"))
      end

      def ios
        data["ios"]
      end

      def android
        data["android"]
      end

      def ci
        data["ci"]
      end

      def flavor_names
        data["flavors"].keys
      end

      def flavor(name)
        entry = data["flavors"][name.to_s]
        UI.user_error!("Unknown flavor #{name.inspect}, #{FILE_NAME} defines #{flavor_names.join(', ')}") unless entry

        Flavor.new(name: name.to_s, **entry.transform_keys(&:to_sym))
      end

      def flavor_for_branch(branch)
        name, = data["flavors"].find { |_, entry| entry["branch"] == branch }
        UI.user_error!("No flavor deploys from branch #{branch.inspect} (#{FILE_NAME} maps #{branch_map})") unless name

        flavor(name)
      end

      # The flavor to ship: the one named, else the one deploying from the current branch.
      def flavor_for(name = nil, env: ENV)
        name.to_s.empty? ? flavor_for_branch(current_branch(env: env)) : flavor(name)
      end

      # GitHub Actions can check out a detached HEAD, which git (and fastlane's git_branch, which
      # knows other CIs' variables but not GitHub's) reports as "HEAD".
      def current_branch(env: ENV)
        env["GITHUB_REF_NAME"].to_s.empty? ? Actions.git_branch : env["GITHUB_REF_NAME"]
      end

      # A flavor ships from its own branch: a beta pushes its bump commit there, and a release
      # tags what shipped from it. Running either from another branch would push or tag that
      # branch's commits instead.
      def ensure_release_branch!(flavor, env: ENV)
        branch = current_branch(env: env)
        UI.user_error!("#{flavor.name} ships from #{flavor.branch}, not #{branch}") unless branch == flavor.branch
      end

      # react-native-config picks an env file by matching the build against its own mapping and
      # silently falls back to `.env` when nothing matches, which is how a release can ship with
      # the dev config. Pin the flavor's file and make sure it exists. ENVFILE gets the absolute
      # path: react-native-config resolves a relative one against the React Native project root
      # (android/.. on Android), not against rn-ship.yml, so it would point elsewhere whenever the
      # two differ, as in a monorepo. Its Gradle and Xcode scripts both accept an absolute path.
      # Returns the path, nil when the flavor has no env file.
      def pin_env_file!(flavor, env: ENV)
        return nil unless flavor.env_file

        path = expand(flavor.env_file)
        UI.user_error!("#{flavor.env_file} is missing: the #{flavor.name} build would ship without its config") unless File.file?(path)
        env["ENVFILE"] = path
      end

      # Absolute path for a path written relative to rn-ship.yml
      def expand(relative)
        File.expand_path(relative, root)
      end

      def beta_tag(platform:, flavor:, version:, build:)
        render(self.flavor(flavor).tags.fetch(platform.to_s), platform: platform, flavor: flavor, version: version, build: build)
      end

      def release_tag(platform:, version:, build:, flavor: nil)
        render(data["release_tags"].fetch(platform.to_s), platform: platform, flavor: flavor, version: version, build: build)
      end

      # The app's bundle id followed by one per app extension, the order match expects.
      def ios_app_identifiers(flavor)
        bundle_id = self.flavor(flavor).ios.fetch("bundle_id")
        [bundle_id] + ios["extensions"].map { |extension| bundle_id + extension["bundle_id_suffix"] }
      end

      # The app target followed by every extension target, in ios_app_identifiers' order.
      def ios_targets
        [ios["target"]] + ios["extensions"].map { |extension| extension["target"] }
      end

      # [target, profile name] for the app and every extension, e.g.
      # ["App", "match AppStore com.example.app"].
      def ios_signing_targets(flavor)
        prefix = "match #{MATCH_TYPES.fetch(ios['match']['type'])[:profile_prefix]}"
        ios_targets.zip(ios_app_identifiers(flavor)).map { |target, identifier| [target, "#{prefix} #{identifier}"] }
      end

      def ios_export_method
        MATCH_TYPES.fetch(ios["match"]["type"])[:export_method]
      end

      private

      def render(template, platform:, flavor:, version:, build:)
        values = { "version" => version, "build" => build, "flavor" => flavor, "platform" => platform }
        template.gsub(/\{(\w+)\}/) { values.fetch(Regexp.last_match(1)).to_s }
      end

      def branch_map
        data["flavors"].map { |name, entry| "#{entry['branch']} → #{name}" }.join(", ")
      end
    end
  end
end
