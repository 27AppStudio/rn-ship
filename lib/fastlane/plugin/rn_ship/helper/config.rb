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

      MATCH_PROFILE_PREFIX = {
        "appstore" => "AppStore",
        "adhoc" => "AdHoc",
        "development" => "Development",
        "enterprise" => "InHouse"
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

      # [target, profile name] for the app and every extension, e.g.
      # ["App", "match AppStore com.example.app"].
      def ios_signing_targets(flavor)
        prefix = "match #{MATCH_PROFILE_PREFIX.fetch(ios['match']['type'])}"
        targets = [ios["target"]] + ios["extensions"].map { |extension| extension["target"] }
        targets.zip(ios_app_identifiers(flavor)).map { |target, identifier| [target, "#{prefix} #{identifier}"] }
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
