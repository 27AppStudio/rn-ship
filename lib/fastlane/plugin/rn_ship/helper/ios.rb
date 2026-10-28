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
          configurations = xcode.targets.find { |target| target.name == name }.build_configurations.map(&:name)
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

      def keychain_path(name)
        File.expand_path("~/Library/Keychains/#{name}-db")
      end

      def security(*args)
        Actions.sh("security", *args, log: false)
      end
    end
  end
end
