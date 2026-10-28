require "tmpdir"

describe Fastlane::Helper::RnShipConfig do
  let(:fixture) { File.expand_path("fixtures/splitify.yml", __dir__) }
  let(:config) { described_class.load(fixture) }

  def config_from(yaml)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "rn-ship.yml")
      File.write(path, yaml)
      return described_class.load(path)
    end
  end

  def errors_for(yaml)
    config_from(yaml)
    raise "expected #{yaml.inspect} to be invalid"
  rescue FastlaneCore::Interface::FastlaneError => e
    e.message
  end

  let(:minimal) do
    <<~YAML
      android:
        upload_key_prefix: MYAPP_UPLOAD
      flavors:
        production:
          branch: main
          android: { flavor: prod, package_name: com.example.app }
    YAML
  end

  describe "Splitify's setup" do
    it "maps a flavor to its iOS and Android build settings" do
      staging = config.flavor("staging")

      expect(staging.branch).to eq("staging")
      expect(staging.env_file).to eq(".env.staging")
      expect(staging.ios).to eq("scheme" => "staging", "configuration" => "StagingRelease", "bundle_id" => "com.dtrteam.splitify.staging")
      expect(staging.android).to eq("flavor" => "staging", "package_name" => "com.dtrteam.splitify.staging", "build_type" => "Release")
    end

    it "keeps the irregular production scheme" do
      expect(config.flavor("prod").ios).to include("scheme" => "production", "configuration" => "Release")
    end

    it "finds the flavor that deploys from a branch" do
      expect(config.flavor_for_branch("master").name).to eq("prod")
    end

    it "lists match identifiers for the app and its extension" do
      expect(config.ios_app_identifiers("staging")).to eq(
        ["com.dtrteam.splitify.staging", "com.dtrteam.splitify.staging.OneSignalNotificationServiceExtension"]
      )
    end

    it "pairs every signing target with its own profile" do
      expect(config.ios_signing_targets("prod")).to eq([
        ["splitify", "match AppStore com.dtrteam.splitify"],
        ["OneSignalNotificationServiceExtension", "match AppStore com.dtrteam.splitify.OneSignalNotificationServiceExtension"]
      ])
    end

    it "renders the historical tag formats" do
      expect(config.beta_tag(platform: :ios, flavor: "staging", version: "1.1.0", build: 20)).to eq("v1.1.0-beta-staging.20")
      expect(config.beta_tag(platform: :android, flavor: "prod", version: "1.2.6", build: 41)).to eq("v1.2.6-android-beta.41")
      expect(config.release_tag(platform: :ios, version: "1.2.6", build: 1)).to eq("v1.2.6-1")
      expect(config.release_tag(platform: :android, version: "1.2.6", build: 41)).to eq("v1.2.6-android-41")
    end

    it "coerces an unquoted numeric team id to a string" do
      expect(config.ios["itc_team_id"]).to eq("121080038")
    end

    it "stores env var names for credentials, never values" do
      expect(config.ios["app_store_connect"]).to eq(
        "key_id_env" => "APP_STORE_KEY_ID",
        "issuer_id_env" => "APP_STORE_ISSUER_ID",
        "key_content_env" => "APP_STORE_CONNECT_API_KEY_KEY",
        "key_path_env" => "APP_STORE_KEY_PATH"
      )
    end

    it "resolves paths relative to the file" do
      expect(config.expand(config.ios["workspace"])).to eq(File.join(File.dirname(fixture), "ios/splitify.xcworkspace"))
    end
  end

  describe "defaults" do
    subject(:minimal_config) { config_from(minimal) }

    it "follows fastlane's own env var names and Play's internal track" do
      expect(minimal_config.android).to eq(
        "project_dir" => "android",
        "gradle_file" => "android/app/build.gradle",
        "upload_key_prefix" => "MYAPP_UPLOAD",
        "play" => { "json_key_env" => "SUPPLY_JSON_KEY_DATA", "track" => "internal", "release_status_env" => "PLAY_RELEASE_STATUS" }
      )
      expect(minimal_config.ci).to eq("self_hosted_env" => "RN_SHIP_SELF_HOSTED", "keychain" => "rn_ship_ci")
    end

    it "has tag formats that never collide across platforms" do
      expect(minimal_config.beta_tag(platform: :android, flavor: "production", version: "1.0.0", build: 3)).to eq("v1.0.0-android-production.3")
      expect(minimal_config.release_tag(platform: :android, version: "1.0.0", build: 3)).to eq("v1.0.0-android-3")
    end
  end

  describe "validation" do
    it "reports every problem with its key path" do
      message = errors_for(<<~YAML)
        ios:
          project: ios/App.xcodeproj
          target: App
          team_id: ABC
          match: { type: appStore }
        flavors:
          staging:
            branch: staging
            ios: { scheme: staging, bundle_id: com.example.app.staging }
      YAML

      expect(message).to include("ios.workspace is required")
      expect(message).to include('ios.match.type must be one of appstore, adhoc, development, enterprise, got "appStore"')
      expect(message).to include("flavors.staging.ios.configuration is required")
    end

    it "suggests the key a typo was meant to be" do
      expect(errors_for(minimal.sub("branch:", "brnach:"))).to include("flavors.production.brnach is not a known key (did you mean branch?)")
    end

    it "rejects a secret pasted where an env var name belongs" do
      message = errors_for(<<~YAML)
        android:
          upload_key_prefix: MYAPP_UPLOAD
          play:
            json_key_env: '{"type": "service_account"}'
        flavors:
          production:
            branch: main
            android: { flavor: prod, package_name: com.example.app }
      YAML
      expect(message).to include("android.play.json_key_env must be the NAME of an environment variable, never the secret itself, got a value that isn't one (not shown)")
      expect(message).not_to include("service_account")
    end

    it "requires a platform block in every flavor when the platform is configured" do
      message = errors_for(minimal.sub("upload_key_prefix: MYAPP_UPLOAD", "upload_key_prefix: MYAPP_UPLOAD\nios: { project: a, workspace: b, target: c, team_id: d }"))
      expect(message).to include("flavors.production.ios is required because ios is configured")
    end

    it "rejects a flavor block for a platform that isn't configured" do
      message = errors_for(minimal.sub("android: { flavor", "ios: { scheme: a, configuration: b, bundle_id: c }\n    android: { flavor"))
      expect(message).to include("flavors.production.ios is set but there is no top-level ios section")
    end

    it "rejects two flavors deploying from one branch" do
      yaml = minimal + "  beta:\n    branch: main\n    android: { flavor: beta, package_name: com.example.beta }\n"
      expect(errors_for(yaml)).to include("flavors production and beta share branch main")
    end

    it "checks tag placeholders" do
      message = errors_for(minimal + "release_tags:\n  android: v{version}-{sha}\n")
      expect(message).to include("release_tags.android uses unknown placeholder {sha}")
      expect(message).to include("release_tags.android must contain {build}")
    end

    it "needs at least one flavor" do
      expect(errors_for("android:\n  upload_key_prefix: X\nflavors: {}\n")).to include("flavors needs at least 1 entry")
    end

    it "doesn't echo a non-string secret either" do
      message = errors_for(minimal.sub("upload_key_prefix: MYAPP_UPLOAD", "upload_key_prefix: MYAPP_UPLOAD\n  play: { json_key_env: { private_key: hunter2 } }"))
      expect(message).to include("android.play.json_key_env must be a string, got Hash")
      expect(message).not_to include("hunter2")
    end

    it "explains a type mismatch" do
      expect(errors_for(minimal.sub("upload_key_prefix: MYAPP_UPLOAD", "upload_key_prefix: [a]"))).to include('android.upload_key_prefix must be a string, got ["a"]')
    end

    it "names unknown flavors and branches" do
      expect { config.flavor("production") }.to raise_error(FastlaneCore::Interface::FastlaneError, /Unknown flavor "production", rn-ship.yml defines staging, prod/)
      expect { config.flavor_for_branch("development") }.to raise_error(FastlaneCore::Interface::FastlaneError, /maps staging → staging, master → prod/)
    end
  end

  describe "#pin_env_file!" do
    it "pins ENVFILE to the flavor's file, as an absolute path" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "rn-ship.yml"), minimal.sub("branch: main", "branch: main\n    env_file: .env.production"))
        File.write(File.join(dir, ".env.production"), "API_URL=x\n")
        loaded = described_class.load(File.join(dir, "rn-ship.yml"))
        target = {}

        expect(loaded.pin_env_file!(loaded.flavor("production"), env: target)).to eq(File.join(File.realpath(dir), ".env.production")).or eq(File.join(dir, ".env.production"))
        expect(target["ENVFILE"]).to end_with("/.env.production")
      end
    end

    it "refuses to build without it" do
      flavor = config.flavor("staging")
      expect { config.pin_env_file!(flavor, env: {}) }
        .to raise_error(FastlaneCore::Interface::FastlaneError, ".env.staging is missing: the staging build would ship without its config")
    end

    it "does nothing for a flavor without an env file" do
      target = {}
      expect(config_from(minimal).pin_env_file!(config_from(minimal).flavor("production"), env: target)).to be_nil
      expect(target).to be_empty
    end
  end

  describe "#flavor_for / #ensure_release_branch!" do
    it "prefers the named flavor, else the branch GitHub checked out" do
      expect(config.flavor_for("prod").name).to eq("prod")
      expect(config.flavor_for(nil, env: { "GITHUB_REF_NAME" => "staging" }).name).to eq("staging")
    end

    it "falls back to git outside GitHub Actions" do
      allow(Fastlane::Actions).to receive(:git_branch).and_return("master")
      expect(config.flavor_for("", env: {}).name).to eq("prod")
    end

    it "refuses a release from another branch" do
      expect { config.ensure_release_branch!(config.flavor("prod"), env: { "GITHUB_REF_NAME" => "staging" }) }
        .to raise_error(FastlaneCore::Interface::FastlaneError, "prod is released from master, not staging")
    end
  end

  describe ".load" do
    it "finds rn-ship.yml in a parent directory" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "rn-ship.yml"), minimal)
        FileUtils.mkdir_p(File.join(dir, "ios", "fastlane"))
        found = Dir.chdir(File.join(dir, "ios", "fastlane")) { described_class.load }
        expect(File.realpath(found.path)).to eq(File.realpath(File.join(dir, "rn-ship.yml")))
      end
    end

    it "explains a missing file" do
      Dir.mktmpdir do |dir|
        expect { Dir.chdir(dir) { described_class.load } }.to raise_error(FastlaneCore::Interface::FastlaneError, /rn-ship.yml not found/)
      end
    end

    it "explains invalid YAML" do
      expect { config_from("flavors: [") }.to raise_error(FastlaneCore::Interface::FastlaneError, /is not valid YAML/)
    end
  end
end

describe Fastlane::Actions::RnShipConfigAction do
  it "loads the config into the lane context" do
    path = File.expand_path("fixtures/splitify.yml", __dir__)
    config = run_lane("rn_ship_config(path: #{path.inspect})")

    expect(config.flavor_names).to eq(%w[staging prod])
    expect(Fastlane::Actions.lane_context[Fastlane::Actions::SharedValues::RN_SHIP_CONFIG]).to be(config)
  end
end
