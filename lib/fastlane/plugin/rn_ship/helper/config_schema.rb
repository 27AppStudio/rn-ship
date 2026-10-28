module Fastlane
  module Helper
    # Validates rn-ship.yml against SCHEMA and fills in defaults. Collects every problem
    # instead of stopping at the first, so one run shows the whole list.
    module RnShipConfigSchema
      ENV_NAME = /\A[A-Z_][A-Z0-9_]*\z/
      TAG_PLACEHOLDERS = %w[version build flavor platform].freeze

      # Never echoed back in errors: a secret pasted here by mistake must not reach CI logs.
      env_name = ->(default) { { type: String, default: default, format: ENV_NAME, hint: "the NAME of an environment variable, never the secret itself", redact: true } }
      tag = ->(default) { { type: String, default: default, placeholders: TAG_PLACEHOLDERS } }
      # IDs are often written unquoted in YAML, which parses 121080038 as an Integer.
      id = { type: String, coerce_integer: true }

      SCHEMA = {
        "ios" => { type: Hash, optional: true, keys: {
          "project" => { type: String },
          "workspace" => { type: String },
          "target" => { type: String },
          "team_id" => id,
          "itc_team_id" => id.merge(optional: true),
          "match" => { type: Hash, default: {}, keys: {
            "git_url" => { type: String, optional: true },
            "type" => { type: String, default: "appstore", enum: %w[appstore adhoc development enterprise] }
          } },
          "extensions" => { type: Array, default: [], items: { type: Hash, keys: {
            "target" => { type: String },
            "bundle_id_suffix" => { type: String, format: /\A\./, hint: "a suffix starting with a dot, e.g. .NotificationService" }
          } } },
          "app_store_connect" => { type: Hash, default: {}, keys: {
            "key_id_env" => env_name.call("APP_STORE_CONNECT_API_KEY_KEY_ID"),
            "issuer_id_env" => env_name.call("APP_STORE_CONNECT_API_KEY_ISSUER_ID"),
            "key_content_env" => env_name.call("APP_STORE_CONNECT_API_KEY_KEY"),
            "key_path_env" => env_name.call("APP_STORE_CONNECT_API_KEY_KEY_FILEPATH")
          } }
        } },
        "android" => { type: Hash, optional: true, keys: {
          "project_dir" => { type: String, default: "android" },
          "gradle_file" => { type: String, default: "android/app/build.gradle" },
          "upload_key_prefix" => { type: String, format: ENV_NAME, hint: "a Gradle property prefix, e.g. MYAPP_UPLOAD for MYAPP_UPLOAD_STORE_FILE" },
          "play" => { type: Hash, default: {}, keys: {
            "json_key_env" => env_name.call("SUPPLY_JSON_KEY_DATA"),
            "track" => { type: String, default: "internal" },
            "release_status_env" => env_name.call("PLAY_RELEASE_STATUS")
          } }
        } },
        "flavors" => { type: Hash, min_size: 1, values: { type: Hash, keys: {
          "branch" => { type: String },
          "env_file" => { type: String, optional: true },
          "ios" => { type: Hash, optional: true, keys: {
            "scheme" => { type: String },
            "configuration" => { type: String },
            "bundle_id" => { type: String }
          } },
          "android" => { type: Hash, optional: true, keys: {
            "flavor" => { type: String },
            "package_name" => { type: String },
            "build_type" => { type: String, default: "Release" }
          } },
          "tags" => { type: Hash, default: {}, keys: {
            "ios" => tag.call("v{version}-ios-{flavor}.{build}"),
            "android" => tag.call("v{version}-android-{flavor}.{build}")
          } }
        } } },
        "release_tags" => { type: Hash, default: {}, keys: {
          "ios" => tag.call("v{version}-ios-{build}"),
          "android" => tag.call("v{version}-android-{build}")
        } },
        "ci" => { type: Hash, default: {}, keys: {
          "self_hosted_env" => env_name.call("RN_SHIP_SELF_HOSTED"),
          "keychain" => { type: String, default: "rn_ship_ci", format: /\A[\w.-]+\z/ }
        } }
      }.freeze

      module_function

      # Returns [normalized_hash, errors]
      def validate(raw)
        errors = []
        normalized = check_hash(raw, SCHEMA, "", errors)
        cross_check(normalized, errors) if errors.empty?
        [normalized, errors]
      end

      def check_hash(value, keys, path, errors)
        unless value.is_a?(Hash)
          errors << "#{label(path)} must be a mapping"
          return {}
        end

        (value.keys.map(&:to_s) - keys.keys).each do |unknown|
          suggestion = DidYouMean::SpellChecker.new(dictionary: keys.keys).correct(unknown).first
          errors << "#{join(path, unknown)} is not a known key#{suggestion ? " (did you mean #{suggestion}?)" : ''}"
        end

        keys.each_with_object({}) do |(key, rule), result|
          child = join(path, key)
          given = value.key?(key) ? value[key] : value[key.to_sym]
          if given.nil?
            if rule.key?(:default)
              result[key] = rule[:type] == Hash ? check_hash(rule[:default], rule[:keys], child, errors) : rule[:default]
            elsif !rule[:optional]
              errors << "#{child} is required"
            end
            next
          end
          result[key] = check_value(given, rule, child, errors)
        end
      end

      def check_value(value, rule, path, errors)
        value = value.to_s if rule[:coerce_integer] && value.is_a?(Integer)

        unless value.is_a?(rule[:type])
          errors << "#{path} must be #{article(rule[:type])}, got #{rule[:redact] ? value.class : value.inspect}"
          return value
        end

        case value
        when Hash
          return check_hash(value, rule[:keys], path, errors) if rule[:keys]

          errors << "#{path} needs at least #{rule[:min_size]} entry" if rule[:min_size] && value.size < rule[:min_size]
          value.to_h { |name, item| [name.to_s, check_value(item, rule[:values], join(path, name), errors)] }
        when Array
          value.each_with_index.map { |item, index| check_value(item, rule[:items], "#{path}[#{index}]", errors) }
        else
          check_string(value, rule, path, errors)
          value
        end
      end

      def check_string(value, rule, path, errors)
        errors << "#{path} must be one of #{rule[:enum].join(', ')}, got #{value.inspect}" if rule[:enum] && !rule[:enum].include?(value)
        if rule[:format] && value !~ rule[:format]
          got = rule[:redact] ? "got a value that isn't one (not shown)" : "got #{value.inspect}"
          errors << "#{path} must be #{rule[:hint] || "match #{rule[:format].inspect}"}, #{got}"
        end
        return unless rule[:placeholders]

        (value.scan(/\{(\w+)\}/).flatten - rule[:placeholders]).each do |unknown|
          errors << "#{path} uses unknown placeholder {#{unknown}} (known: #{rule[:placeholders].map { |name| "{#{name}}" }.join(' ')})"
        end
        errors << "#{path} must contain {build} so every upload gets its own tag" unless value.include?("{build}")
      end

      # Rules that span sections: a platform configured at the top needs its block in every
      # flavor, and the reverse.
      def cross_check(config, errors)
        errors << "configure at least one platform: ios or android" unless config["ios"] || config["android"]

        %w[ios android].each do |platform|
          config["flavors"].each do |name, flavor|
            if config[platform] && !flavor[platform]
              errors << "flavors.#{name}.#{platform} is required because #{platform} is configured"
            elsif !config[platform] && flavor[platform]
              errors << "flavors.#{name}.#{platform} is set but there is no top-level #{platform} section"
            end
          end
        end

        branches = config["flavors"].group_by { |_, flavor| flavor["branch"] }
        branches.each do |branch, flavors|
          errors << "flavors #{flavors.map(&:first).join(' and ')} share branch #{branch}" if flavors.size > 1
        end
      end

      def join(path, key)
        path.empty? ? key.to_s : "#{path}.#{key}"
      end

      def label(path)
        path.empty? ? "the config" : path
      end

      def article(type)
        { Hash => "a mapping", Array => "a list", String => "a string" }.fetch(type, type.to_s)
      end
    end
  end
end
