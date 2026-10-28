describe Fastlane::Helper::RnShipStoreState do
  Track = Struct.new(:track, :releases)
  Release = Struct.new(:name, :status, :version_codes)

  describe ".semver_from" do
    it "reads plain and Play Console default release names" do
      expect(described_class.semver_from("1.2.6")).to eq("1.2.6")
      expect(described_class.semver_from("41 (1.2.6)")).to eq("1.2.6")
      expect(described_class.semver_from("1.3")).to eq("1.3")
      expect(described_class.semver_from(nil)).to be_nil
    end
  end

  describe ".summarize_play_tracks" do
    let(:tracks) do
      [
        Track.new("internal", [Release.new("1.2.6", "completed", ["40"]), Release.new("42 (1.2.7)", "completed", ["42"])]),
        Track.new("alpha", [Release.new("1.2.7", "completed", ["45"])]),
        Track.new("production", [
          Release.new("1.2.5", "completed", ["31"]),
          Release.new("1.2.6", "inProgress", ["40"]),
          Release.new("1.2.7", "draft", ["42"])
        ])
      ]
    end

    it "reads the beta, the highest code anywhere and the live release" do
      expect(described_class.summarize_play_tracks(tracks, beta_track: "internal")).to eq(
        latest_version: "1.2.7", latest_build: 42, max_build: 45, live_version: "1.2.6"
      )
    end

    it "counts a halted rollout as live but not a draft" do
      tracks[2].releases[1].status = "halted"
      expect(described_class.summarize_play_tracks(tracks, beta_track: "internal")[:live_version]).to eq("1.2.6")

      tracks[2].releases[1].status = "draft"
      expect(described_class.summarize_play_tracks(tracks, beta_track: "internal")[:live_version]).to eq("1.2.5")
    end

    it "uses the configured beta track" do
      expect(described_class.summarize_play_tracks(tracks, beta_track: "alpha")).to include(latest_version: "1.2.7", latest_build: 45)
    end

    it "treats a new app with no tracks as empty" do
      expect(described_class.summarize_play_tracks([], beta_track: "internal")).to eq(
        latest_version: nil, latest_build: nil, max_build: 0, live_version: nil
      )
    end

    it "tolerates tracks and releases without contents" do
      sparse = [Track.new("internal", nil), Track.new("production", [Release.new(nil, "completed", nil)])]
      expect(described_class.summarize_play_tracks(sparse, beta_track: "internal")).to eq(
        latest_version: nil, latest_build: nil, max_build: 0, live_version: nil
      )
    end
  end

  describe ".play" do
    it "always aborts the edit it opened, even when listing tracks fails" do
      client = double("Supply::Client")
      require "supply"
      require "supply/client"
      allow(Supply::Client).to receive(:make_from_config).and_return(client)
      expect(client).to receive(:begin_edit).with(package_name: "com.example.app")
      expect(client).to receive(:tracks).and_raise("boom")
      expect(client).to receive(:abort_current_edit)

      expect { described_class.play(package_name: "com.example.app", json_key_data: "{}", beta_track: "internal") }.to raise_error("boom")
    end

    it "summarizes the tracks it read" do
      client = double("Supply::Client", begin_edit: nil, abort_current_edit: nil,
                                        tracks: [Track.new("internal", [Release.new("1.0.0", "completed", ["7"])])])
      require "supply"
      require "supply/client"
      allow(Supply::Client).to receive(:make_from_config).and_return(client)

      expect(described_class.play(package_name: "com.example.app", json_key_data: "{}", beta_track: "internal"))
        .to eq(latest_version: "1.0.0", latest_build: 7, max_build: 7, live_version: nil)
    end
  end

  describe ".app_store_connect_api_key_options" do
    let(:settings) do
      { "key_id_env" => "ASC_KEY_ID", "issuer_id_env" => "ASC_ISSUER", "key_content_env" => "ASC_KEY", "key_path_env" => "ASC_KEY_PATH" }
    end

    it "prefers the key content" do
      env = { "ASC_KEY_ID" => "K1", "ASC_ISSUER" => "I1", "ASC_KEY" => "-----BEGIN PRIVATE KEY-----", "ASC_KEY_PATH" => "/nope" }
      expect(described_class.app_store_connect_api_key_options(settings, env: env))
        .to eq(key_id: "K1", issuer_id: "I1", key_content: "-----BEGIN PRIVATE KEY-----")
    end

    it "falls back to a key file" do
      Tempfile.create("AuthKey.p8") do |file|
        env = { "ASC_KEY_ID" => "K1", "ASC_ISSUER" => "I1", "ASC_KEY_PATH" => file.path }
        expect(described_class.app_store_connect_api_key_options(settings, env: env))
          .to eq(key_id: "K1", issuer_id: "I1", key_filepath: File.expand_path(file.path))
      end
    end

    it "names every missing variable and never prints a value" do
      env = { "ASC_KEY_ID" => "secret-key-id", "ASC_ISSUER" => "  " }
      expect { described_class.app_store_connect_api_key_options(settings, env: env) }
        .to raise_error(FastlaneCore::Interface::FastlaneError, "App Store Connect API key not configured, set: ASC_ISSUER, ASC_KEY or ASC_KEY_PATH")
    end

    it "rejects a key path that doesn't exist without printing it" do
      env = { "ASC_KEY_ID" => "K1", "ASC_ISSUER" => "I1", "ASC_KEY_PATH" => "/private/AuthKey_SECRET.p8" }
      expect { described_class.app_store_connect_api_key_options(settings, env: env) }
        .to raise_error(FastlaneCore::Interface::FastlaneError, "ASC_KEY_PATH points to a file that doesn't exist")
    end
  end

  describe ".app_store_live_version" do
    require "spaceship"

    it "returns nil when nothing is live" do
      app = double("App", get_live_app_store_version: nil)
      allow(Spaceship::ConnectAPI::App).to receive(:find).with("com.example.app").and_return(app)
      expect(described_class.app_store_live_version(app_identifier: "com.example.app")).to be_nil
    end

    it "returns the live version string" do
      app = double("App", get_live_app_store_version: double(version_string: "1.2.6"))
      allow(Spaceship::ConnectAPI::App).to receive(:find).and_return(app)
      expect(described_class.app_store_live_version(app_identifier: "com.example.app")).to eq("1.2.6")
    end

    it "lets API failures through instead of reading them as nothing live" do
      allow(Spaceship::ConnectAPI::App).to receive(:find).and_raise(Spaceship::UnauthorizedAccessError, "expired")
      expect { described_class.app_store_live_version(app_identifier: "com.example.app") }.to raise_error(Spaceship::UnauthorizedAccessError)
    end

    it "fails on an unknown app" do
      allow(Spaceship::ConnectAPI::App).to receive(:find).and_return(nil)
      expect { described_class.app_store_live_version(app_identifier: "com.example.missing") }
        .to raise_error(FastlaneCore::Interface::FastlaneError, /Could not find com.example.missing/)
    end
  end
end

describe Fastlane::Actions::RnShipStoreStateAction do
  let(:fixture) { File.expand_path("fixtures/splitify.yml", __dir__) }

  context "on iOS" do
    let(:api_key) { { key_id: "K1", issuer_id: "I1", key: "k" } }

    before do
      Fastlane::Actions.lane_context[Fastlane::Actions::SharedValues::APP_STORE_CONNECT_API_KEY] = api_key
      allow(Fastlane::Actions::LatestTestflightBuildNumberAction).to receive(:run) do |params|
        @testflight_params = params
        Fastlane::Actions.lane_context[Fastlane::Actions::SharedValues::LATEST_TESTFLIGHT_VERSION] = "1.3.0"
        13
      end
      allow(Fastlane::Helper::RnShipStoreState).to receive(:app_store_live_version)
        .with(app_identifier: "com.dtrteam.splitify.staging", api_key: api_key).and_return("1.2.6")
    end

    it "reads TestFlight and the live version for the flavor's bundle id" do
      result = run_lane("rn_ship_store_state(flavor: 'staging', platform: 'ios', config_path: #{fixture.inspect})")

      expect(result).to eq(latest_version: "1.3.0", latest_build: 13, live_version: "1.2.6", monotonic_build: false)
      expect(@testflight_params[:app_identifier]).to eq("com.dtrteam.splitify.staging")
      expect(@testflight_params[:initial_build_number]).to eq(0)
      expect(@testflight_params[:api_key]).to eq(api_key)
    end

    it "composes with rn_ship_next_version" do
      result = run_lane(<<~RUBY)
        store = rn_ship_store_state(flavor: 'staging', platform: 'ios', config_path: #{fixture.inspect})
        rn_ship_next_version(current_version: '1.3.0', current_build: 12, **store)
      RUBY
      expect(result).to eq(version: "1.3.0", build: 14)
    end

    it "takes the platform from the lane" do
      result = Fastlane::FastFile.new.parse(<<~RUBY).runner.execute(:test, :ios)
        platform :ios do
          lane :test do
            rn_ship_store_state(flavor: 'staging', config_path: #{fixture.inspect})
          end
        end
      RUBY
      expect(result[:latest_build]).to eq(13)
    end
  end

  context "on iOS without an API key yet" do
    it "creates one from the env var names in rn-ship.yml" do
      stub_const("ENV", ENV.to_h.merge("APP_STORE_KEY_ID" => "K1", "APP_STORE_ISSUER_ID" => "I1", "APP_STORE_CONNECT_API_KEY_KEY" => "k"))
      expect(Fastlane::Actions::AppStoreConnectApiKeyAction).to receive(:run) do |params|
        expect(params[:key_id]).to eq("K1")
        expect(params[:issuer_id]).to eq("I1")
        expect(params[:key_content]).to eq("k")
        { key_id: "K1" }
      end
      allow(Fastlane::Actions::LatestTestflightBuildNumberAction).to receive(:run).and_return(0)
      allow(Fastlane::Helper::RnShipStoreState).to receive(:app_store_live_version).and_return(nil)

      result = run_lane("rn_ship_store_state(flavor: 'prod', platform: 'ios', config_path: #{fixture.inspect})")
      expect(result).to eq(latest_version: nil, latest_build: 0, live_version: nil, monotonic_build: false)
    end
  end

  context "on Android" do
    it "counts from the highest versionCode on any track" do
      stub_const("ENV", ENV.to_h.merge("PLAY_SERVICE_ACCOUNT_JSON" => "{\"type\":\"service_account\"}"))
      expect(Fastlane::Helper::RnShipStoreState).to receive(:play)
        .with(package_name: "com.dtrteam.splitify", json_key_data: "{\"type\":\"service_account\"}", beta_track: "internal")
        .and_return(latest_version: "1.2.7", latest_build: 42, max_build: 45, live_version: "1.2.6")

      result = run_lane("rn_ship_store_state(flavor: 'prod', platform: 'android', config_path: #{fixture.inspect})")

      expect(result).to eq(latest_version: "1.2.7", latest_build: 45, live_version: "1.2.6", monotonic_build: true)
      expect(Fastlane::Actions.lane_context[Fastlane::Actions::SharedValues::RN_SHIP_STORE_STATE]).to include(beta_build: 42, max_build: 45)
    end

    it "explains a missing service account key" do
      stub_const("ENV", ENV.to_h.reject { |name, _| name == "PLAY_SERVICE_ACCOUNT_JSON" })
      expect { run_lane("rn_ship_store_state(flavor: 'prod', platform: 'android', config_path: #{fixture.inspect})") }
        .to raise_error(FastlaneCore::Interface::FastlaneError, /set PLAY_SERVICE_ACCOUNT_JSON to the key's JSON content/)
    end
  end

  it "rejects an unknown platform" do
    expect { run_lane("rn_ship_store_state(flavor: 'prod', platform: 'web', config_path: #{fixture.inspect})") }
      .to raise_error(FastlaneCore::Interface::FastlaneError, /platform must be ios or android/)
  end
end
