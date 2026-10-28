require "fastlane/action"
require "fastlane_core/ui/ui"

module Fastlane
  module Helper
    # Checks and settings for an iOS release build on CI.
    module RnShipIos
      # Generic identities: Xcode matches them against both the legacy "iPhone Distribution"
      # certificates and the current "Apple Distribution" ones that match creates.
      CODE_SIGN_IDENTITY = {
        "appstore" => "iPhone Distribution",
        "adhoc" => "iPhone Distribution",
        "enterprise" => "iPhone Distribution",
        "development" => "iPhone Developer"
      }.freeze

      # react-native-config's Xcode script reads this file BEFORE $ENVFILE. A leftover one on a
      # self-hosted Mac silently swaps the config of every build.
      STALE_ENVFILE = "/tmp/envfile".freeze

      module_function

      # Everything the build will rely on, checked against the real project before match, the
      # version bump or a 15-minute archive. update_code_signing_settings skips a target name
      # it can't find without failing, so a typo here would otherwise sign the wrong way.
      def check_project!(project:, workspace:, scheme:, configuration:, targets:)
        require "xcodeproj"
        UI.user_error!("Xcode project not found at #{project}") unless File.directory?(project)
        UI.user_error!("Workspace not found at #{workspace}") unless File.directory?(workspace)

        xcode = Xcodeproj::Project.open(project)
        names = xcode.targets.map(&:name)
        missing = targets - names
        UI.user_error!("Target(s) #{missing.join(', ')} not in #{File.basename(project)} (it has #{names.join(', ')})") unless missing.empty?

        targets.each do |name|
          configurations = find_target!(xcode, name).build_configurations.map(&:name)
          next if configurations.include?(configuration)

          UI.user_error!("Target #{name} has no #{configuration} configuration (it has #{configurations.sort.join(', ')})")
        end

        unless shared_scheme?(scheme, project: project, workspace: workspace)
          UI.user_error!("Scheme #{scheme} is not shared, so CI can't see it: in Xcode, Product > Scheme > Manage Schemes, tick Shared, and commit the .xcscheme")
        end
        true
      end

      # CI only sees schemes committed under xcshareddata; a user scheme lives in xcuserdata.
      def shared_scheme?(scheme, project:, workspace:)
        [project, workspace].any? { |container| File.file?(File.join(container, "xcshareddata", "xcschemes", "#{scheme}.xcscheme")) }
      end

      def ensure_no_stale_envfile!(path = STALE_ENVFILE)
        return unless File.exist?(path)

        UI.user_error!("#{path} exists: react-native-config reads it before ENVFILE, so this build would use whatever env file it names. " \
                       "Delete it (it is left behind by some local workflows).")
      end

      # Keychains in the user search list, in order.
      def keychain_search_list(run = method(:security))
        run.call("list-keychains", "-d", "user").lines.map { |line| line.strip.delete('"') }.reject(&:empty?)
      end

      # create_keychain appends to the search list, but codesign signs with the first keychain
      # that holds the identity. A developer's login keychain may hold the same distribution
      # identity behind an access prompt a background runner cannot answer, which fails the
      # build with errSecInternalComponent. Move ours to the front; deleting it at the end
      # leaves the others in their original order.
      def prioritize_keychain!(name, run = method(:security))
        keychains = keychain_search_list(run)
        ours = keychains.find { |path| File.basename(path).start_with?("#{name}-db", "#{name}.keychain") }
        UI.user_error!("#{name} keychain is not in the search list") unless ours

        run.call("list-keychains", "-d", "user", "-s", ours, *(keychains - [ours]))
        ours
      end

      # The version the archive will carry: a literal in the target's Info.plist wins, otherwise
      # the build setting it references (or that a generated Info.plist uses).
      def read_xcode_version(project:, target:, configuration:)
        require "xcodeproj"
        settings = build_configuration(Xcodeproj::Project.open(project), target, configuration).build_settings
        path = info_plist(project, settings)
        plist = path ? Xcodeproj::Plist.read_from_path(path) : {}
        {
          version: plist_literal(plist, "CFBundleShortVersionString") || settings["MARKETING_VERSION"],
          build: (plist_literal(plist, "CFBundleVersion") || settings["CURRENT_PROJECT_VERSION"]).to_i
        }.tap do |result|
          UI.user_error!("No version for #{target} (#{configuration}): set MARKETING_VERSION in its build settings") unless result[:version]
        end
      end

      # Writes MARKETING_VERSION / CURRENT_PROJECT_VERSION in every configuration of the app and
      # its extensions (the App Store rejects an extension whose version differs from the app's),
      # and any literal value in their Info.plist files. Plists that reference the build settings
      # are left alone. Returns the files written: exactly what to commit, never whatever else
      # CI touched (Podfile.lock...).
      def write_xcode_version(project:, targets:, version:, build:)
        require "xcodeproj"
        xcode = Xcodeproj::Project.open(project)
        plists = []
        targets.each do |name|
          find_target!(xcode, name).build_configurations.each do |configuration|
            configuration.build_settings["MARKETING_VERSION"] = version.to_s
            configuration.build_settings["CURRENT_PROJECT_VERSION"] = build.to_s
            plists << info_plist(project, configuration.build_settings)
          end
        end
        xcode.save

        written = plists.compact.uniq.select do |path|
          plist = Xcodeproj::Plist.read_from_path(path)
          literals = { "CFBundleShortVersionString" => version.to_s, "CFBundleVersion" => build.to_s }.select { |key, _| plist_literal(plist, key) }
          next false if literals.empty?

          Xcodeproj::Plist.write_to_path(plist.merge(literals), path)
          true
        end
        [File.join(project, "project.pbxproj"), *written]
      end

      def find_target!(xcode, name)
        xcode.targets.find { |target| target.name == name } || UI.user_error!("Target #{name} not in #{File.basename(xcode.path)}")
      end

      def build_configuration(xcode, target_name, configuration)
        find_target!(xcode, target_name).build_configurations.find { |candidate| candidate.name == configuration } ||
          UI.user_error!("Target #{target_name} has no #{configuration} configuration")
      end

      # INFOPLIST_FILE is relative to the folder holding the .xcodeproj ($(SRCROOT)).
      def info_plist(project, settings)
        file = settings["INFOPLIST_FILE"].to_s.sub(%r{\A\$[({]SRCROOT[)}]/}, "")
        return nil if file.empty?

        path = File.expand_path(file, File.dirname(project))
        File.file?(path) ? path : nil
      end

      # A plist value written out, not a $(BUILD_SETTING) reference.
      def plist_literal(plist, key)
        value = plist[key]
        value.is_a?(String) && !value.include?("$") ? value : nil
      end

      def keychain_path(name)
        File.expand_path("~/Library/Keychains/#{name}-db")
      end

      def security(*args)
        Actions.sh("security", *args, log: false)
      end
    end
  end
end
