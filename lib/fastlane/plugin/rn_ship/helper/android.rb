require "open3"
require "fastlane_core/ui/ui"

module Fastlane
  module Helper
    # Guards around a Play upload: refuse to build without the upload key or the flavor's env
    # file, refuse to ship a bundle signed with anything but the upload key, and keep the
    # version literals in build.gradle in step with the store.
    module RnShipAndroid
      # <prefix>_STORE_FILE etc., the Gradle properties the app's signingConfigs read.
      UPLOAD_KEY_SUFFIXES = %w[STORE_FILE STORE_PASSWORD KEY_ALIAS KEY_PASSWORD].freeze

      VERSION_CODE = /^(?<lead>[ \t]*versionCode[ \t]*=?[ \t]*)(?<value>\d+)(?<tail>[ \t]*(?:\/\/.*)?)$/
      VERSION_NAME = /^(?<lead>[ \t]*versionName[ \t]*=?[ \t]*)(?<quote>["'])(?<value>[^"'\n]*)\k<quote>/

      module_function

      # A Gradle project property where the build looks for it: ORG_GRADLE_PROJECT_<name> (CI),
      # then GRADLE_USER_HOME/gradle.properties (a developer's machine), then the project's own
      # gradle.properties. Returns [value, source] or nil.
      def gradle_property(name, project_dir:, env: ENV)
        env_name = "ORG_GRADLE_PROJECT_#{name}"
        return [env[env_name], env_name] unless env[env_name].to_s.empty?

        user_home = env["GRADLE_USER_HOME"].to_s.empty? ? File.expand_path("~/.gradle") : env["GRADLE_USER_HOME"]
        [File.join(user_home, "gradle.properties"), File.join(project_dir, "gradle.properties")].each do |path|
          value = read_properties(path)[name]
          return [value, path] unless value.to_s.empty?
        end
        nil
      end

      def read_properties(path)
        return {} unless File.file?(path)

        File.readlines(path, chomp: true).each_with_object({}) do |line, properties|
          next if line.strip.empty? || line.lstrip.start_with?("#", "!")

          key, value = line.split(/\s*[=:]\s*/, 2)
          properties[key.strip] = value.to_s.strip if key
        end
      end

      # The first AAB uploaded to Play permanently enrolls its certificate as the app's upload
      # key, and React Native's template falls back to the debug key — the same public key in
      # every project — when the upload key is missing. Refuse before building.
      # Returns { store_file:, key_alias:, store_password: }; never logs the passwords.
      def upload_key!(prefix:, project_dir:, module_dir:, env: ENV)
        names = UPLOAD_KEY_SUFFIXES.map { |suffix| "#{prefix}_#{suffix}" }
        values = names.to_h { |name| [name, gradle_property(name, project_dir: project_dir, env: env)&.first] }
        missing = names.select { |name| values[name].to_s.empty? }
        unless missing.empty?
          UI.user_error!("Upload key not configured, missing Gradle properties: #{missing.join(', ')} " \
                         "(set ORG_GRADLE_PROJECT_<name> on CI, or add them to ~/.gradle/gradle.properties)")
        end

        # Gradle's file() in the app module resolves relative paths against the module.
        store_file = File.expand_path(values["#{prefix}_STORE_FILE"], module_dir)
        UI.user_error!("Upload keystore not found at #{store_file}") unless File.file?(store_file)

        { store_file: store_file, key_alias: values["#{prefix}_KEY_ALIAS"], store_password: values["#{prefix}_STORE_PASSWORD"] }
      end

      # react-native-config picks an env file by matching the Gradle task name against
      # envConfigFiles, and silently falls back to `.env` when nothing matches, which is how a
      # release can ship with the dev config. Name the file explicitly and make sure it exists.
      #
      # ENVFILE is set to the absolute path: react-native-config resolves a relative one against
      # the React Native project root (android/.. on Android), not against rn-ship.yml, so a
      # relative path would point elsewhere whenever the two differ, as in a monorepo. Both its
      # Gradle and its Xcode script accept an absolute path as is.
      def use_env_file!(env_file, root:, flavor:, env: ENV)
        path = File.expand_path(env_file, root)
        UI.user_error!("#{env_file} is missing: the #{flavor} build would ship without its config") unless File.file?(path)

        env["ENVFILE"] = path
      end

      # SHA-256 of the certificate that signed an AAB/APK/JAR, nil when it isn't signed.
      def signer_fingerprint(archive)
        UI.user_error!("#{archive} doesn't exist") unless File.file?(archive)

        fingerprint(keytool("-printcert", "-jarfile", archive))
      end

      # SHA-256 of a key in a keystore. The password reaches keytool through an environment
      # variable (-storepass:env), never on the command line where `ps` would show it.
      def key_fingerprint(store_file:, key_alias:, store_password:)
        output = keytool("-list", "-v", "-keystore", store_file, "-alias", key_alias, "-storepass:env", "RN_SHIP_STORE_PASSWORD",
                         env: { "RN_SHIP_STORE_PASSWORD" => store_password })
        fingerprint(output) || UI.user_error!("Could not read #{key_alias} from #{store_file}: wrong alias or store password")
      end

      # Positive check: the bundle must be signed with exactly the upload key. The debug
      # keystores only make the error say what went wrong.
      def verify_upload_signature!(archive, upload_key:, debug_keystores: [])
        signer = signer_fingerprint(archive) || UI.user_error!("#{File.basename(archive)} is not signed, refusing to ship it")
        expected = key_fingerprint(**upload_key)
        return signer if signer == expected

        debug = debug_keystores.select { |path| File.file?(path) }.find do |path|
          fingerprint(keytool("-list", "-v", "-keystore", path, "-storepass", "android")) == signer
        end
        if debug
          UI.user_error!("#{File.basename(archive)} is signed with the debug key (#{debug}), refusing to ship it. " \
                         "The upload key properties are probably not reaching Gradle.")
        end
        UI.user_error!("#{File.basename(archive)} is signed with #{signer}, not the upload key #{expected}")
      end

      # versionCode / versionName as plain literals in build.gradle or build.gradle.kts
      def read_gradle_version(path)
        content = File.read(path)
        code = single_match(content, VERSION_CODE, "versionCode", path)
        name = single_match(content, VERSION_NAME, "versionName", path)
        { version: name[:value], build: code[:value].to_i }
      end

      def write_gradle_version(path, version:, build:)
        content = File.read(path)
        single_match(content, VERSION_CODE, "versionCode", path)
        single_match(content, VERSION_NAME, "versionName", path)
        content = content.sub(VERSION_CODE) { "#{Regexp.last_match[:lead]}#{Integer(build)}#{Regexp.last_match[:tail]}" }
        content = content.sub(VERSION_NAME) { "#{Regexp.last_match[:lead]}#{Regexp.last_match[:quote]}#{version}#{Regexp.last_match[:quote]}" }
        File.write(path, content)
      end

      # Exactly one literal: a second one (a productFlavor override) would silently keep its
      # own value, and a computed one can't be rewritten.
      def single_match(content, pattern, label, path)
        matches = content.to_enum(:scan, pattern).map { Regexp.last_match }
        UI.user_error!("No literal #{label} found in #{path}; rn-ship manages a single literal in defaultConfig") if matches.empty?
        if matches.size > 1
          UI.user_error!("#{matches.size} #{label} lines in #{path}; rn-ship manages a single literal in defaultConfig, " \
                         "remove the per-flavor overrides")
        end
        matches.first
      end

      def fingerprint(output)
        output[/SHA256:\s*([0-9A-F:]+)/, 1]
      end

      def keytool(*args, env: {})
        output, = Open3.capture2e(env, "keytool", *args)
        output
      rescue Errno::ENOENT
        UI.user_error!("keytool not found: install a JDK (it ships with the Android toolchain)")
      end
    end
  end
end
