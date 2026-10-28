require "fileutils"
require "open3"
require "tmpdir"

# The reference Fastfile, run end to end against a real git repo, Xcode project and Gradle file.
# Only what talks to a store or a compiler is stubbed.
describe "templates/fastlane/Fastfile" do
  TEMPLATE = File.expand_path("../templates/fastlane/Fastfile", __dir__)

  around do |example|
    Dir.mktmpdir("rn-ship-template") do |dir|
      @origin = File.join(dir, "origin.git")
      @app = File.join(dir, "app")
      git!(dir, "init", "-q", "--bare", "-b", "staging", @origin)
      FileUtils.mkdir_p(@app)
      git_init!(@app, "-b", "staging")

      IosProject.create(@app)
      FileUtils.mkdir_p(File.join(@app, "android", "app"))
      File.write(File.join(@app, "android", "app", "build.gradle"), "android {\n    defaultConfig {\n        versionCode 9\n        versionName \"1.0.0\"\n    }\n}\n")
      File.write(File.join(@app, ".env.staging"), "API_URL=https://staging.example.com\n")
      FileUtils.mkdir_p(File.join(@app, "fastlane"))
      FileUtils.cp(TEMPLATE, File.join(@app, "fastlane", "Fastfile"))
      File.write(File.join(@app, "rn-ship.yml"), <<~YAML)
        ios:
          project: ios/App.xcodeproj
          workspace: ios/App.xcworkspace
          target: App
          team_id: TEAM123456
          extensions:
            - { target: NotificationService, bundle_id_suffix: .NotificationService }
        android:
          upload_key_prefix: MYAPP_UPLOAD
        flavors:
          staging:
            branch: staging
            env_file: .env.staging
            ios: { scheme: staging, configuration: StagingRelease, bundle_id: com.example.app.staging }
            android: { flavor: staging, package_name: com.example.app.staging }
          production:
            branch: main
            ios: { scheme: staging, configuration: Release, bundle_id: com.example.app }
            android: { flavor: production, package_name: com.example.app }
      YAML
      git!(@app, "add", "-A")
      git!(@app, "commit", "-q", "-m", "init")
      git!(@app, "remote", "add", "origin", @origin)
      git!(@app, "push", "-q", "origin", "staging")
      example.run
    end
  end

  before do
    stub_const("Fastlane::Helper::RnShipIos::STALE_ENVFILE", File.join(@app, "no-envfile"))
    gradle_home = File.join(@app, "..", "gradle-home")
    FileUtils.mkdir_p(gradle_home)
    stub_const("ENV", {
      "PATH" => ENV.fetch("PATH"), "HOME" => ENV.fetch("HOME"), "GRADLE_USER_HOME" => gradle_home,
      "APP_STORE_CONNECT_API_KEY_KEY_ID" => "K", "APP_STORE_CONNECT_API_KEY_ISSUER_ID" => "I", "APP_STORE_CONNECT_API_KEY_KEY" => "k",
      "SUPPLY_JSON_KEY_DATA" => "{\"type\":\"service_account\"}",
      "ORG_GRADLE_PROJECT_MYAPP_UPLOAD_STORE_FILE" => AndroidKeys.path("upload.jks"),
      "ORG_GRADLE_PROJECT_MYAPP_UPLOAD_STORE_PASSWORD" => "upload-pass",
      "ORG_GRADLE_PROJECT_MYAPP_UPLOAD_KEY_ALIAS" => "upload",
      "ORG_GRADLE_PROJECT_MYAPP_UPLOAD_KEY_PASSWORD" => "upload-pass"
    })
    @calls = Hash.new { |hash, key| hash[key] = [] }
    { MatchAction: nil, BuildAppAction: "/tmp/App.ipa", UploadToTestflightAction: nil, DeliverAction: nil, UploadToPlayStoreAction: nil }.each do |action, result|
      allow(Fastlane::Actions.const_get(action)).to receive(:run) do |params|
        @calls[action] << params.values(ask: false)
        result
      end
    end
    allow(Fastlane::Actions::GradleAction).to receive(:run) do |params|
      @calls[:GradleAction] << params.values(ask: false)
      Fastlane::Actions.lane_context[Fastlane::Actions::SharedValues::GRADLE_AAB_OUTPUT_PATH] = AndroidKeys.path(@aab || "upload.aab")
    end
  end

  def store(**state)
    allow(Fastlane::Actions::RnShipStoreStateAction).to receive(:run) do
      Fastlane::Actions.lane_context[Fastlane::Actions::SharedValues::APP_STORE_CONNECT_API_KEY] = { key_id: "K" }
      Fastlane::Actions.lane_context[Fastlane::Actions::SharedValues::RN_SHIP_STORE_STATE] = state
      state.slice(:latest_version, :latest_build, :live_version, :monotonic_build)
    end
  end

  def lane(platform, name, **options)
    Dir.chdir(@app) { Fastlane::FastFile.new("fastlane/Fastfile").runner.execute(name, platform, options) }
  end

  def origin(*args)
    git!(@origin, *args)
  end

  describe "ios beta" do
    before { store(latest_version: "1.1.0", latest_build: 5, live_version: "1.0.0", monotonic_build: false) }

    it "versions from the store, commits only the version files, builds, uploads and pushes the tag" do
      lane(:ios, :beta)

      expect(origin("log", "-1", "--format=%s", "staging")).to eq("chore(release): iOS 1.1.0 (6) [skip ci]")
      expect(origin("show", "--name-only", "--format=", "staging").split("\n")).to contain_exactly("ios/App.xcodeproj/project.pbxproj", "ios/App/Info.plist")
      expect(origin("rev-parse", "v1.1.0-ios-staging.6^{commit}")).to eq(origin("rev-parse", "staging"))

      match = @calls[:MatchAction].first
      expect(match).to include(type: "appstore", app_identifier: ["com.example.app.staging", "com.example.app.staging.NotificationService"], team_id: "TEAM123456")
      expect(@calls[:BuildAppAction].first).to include(scheme: "staging", configuration: "StagingRelease", export_method: "app-store")
      expect(@calls[:UploadToTestflightAction].first).to include(app_identifier: "com.example.app.staging", skip_submission: true)
    end

    it "leaves the CI-only signing edits out of the pushed commit" do
      lane(:ios, :beta)

      pbxproj = origin("show", "staging:ios/App.xcodeproj/project.pbxproj")
      expect(pbxproj).to include("MARKETING_VERSION = 1.1.0")
      expect(pbxproj).not_to include("match AppStore")
      expect(git!(@app, "status", "--porcelain")).to eq("")
    end

    it "starts a new version with bump:" do
      lane(:ios, :beta, bump: "minor")
      expect(origin("log", "-1", "--format=%s", "staging")).to eq("chore(release): iOS 1.2.0 (1) [skip ci]")
    end

    it "refuses to ship a flavor from another branch, which would push this branch's commits to it" do
      expect { lane(:ios, :beta, flavor: "production") }.to raise_error(FastlaneCore::Interface::FastlaneError, "production ships from main, not staging")
      expect(git!(@app, "log", "-1", "--format=%s")).to eq("init")
    end

    it "fails before committing anything when the preflight fails" do
      File.delete(File.join(@app, ".env.staging"))
      expect { lane(:ios, :beta) }.to raise_error(FastlaneCore::Interface::FastlaneError, /.env.staging is missing/)
      expect(git!(@app, "log", "-1", "--format=%s")).to eq("init")
      expect(@calls[:MatchAction]).to be_empty
    end
  end

  describe "android beta" do
    before { store(latest_version: "1.0.0", latest_build: 12, beta_build: 11, max_build: 12, live_version: "1.0.0", monotonic_build: true) }

    it "counts past every track, verifies the AAB and uploads to the beta track" do
      lane(:android, :beta)

      expect(origin("log", "-1", "--format=%s", "staging")).to eq("chore(release): Android 1.0.1 (13) [skip ci]")
      expect(origin("show", "--name-only", "--format=", "staging").split("\n")).to eq(["android/app/build.gradle"])
      expect(origin("show", "staging:android/app/build.gradle")).to include("versionCode 13", 'versionName "1.0.1"')
      expect(origin("tag", "--list")).to eq("v1.0.1-android-staging.13")

      expect(@calls[:GradleAction].first).to include(task: "bundle", flavor: "Staging", build_type: "Release")
      expect(@calls[:UploadToPlayStoreAction].first).to include(package_name: "com.example.app.staging", track: "internal", aab: AndroidKeys.path("upload.aab"), version_name: "1.0.1",
                                                                json_key_data: "{\"type\":\"service_account\"}", release_status: "completed")
    end

    it "never uploads a debug-signed bundle" do
      @aab = "debug.aab"
      expect { lane(:android, :beta) }.to raise_error(FastlaneCore::Interface::FastlaneError, /not the upload key/)
      expect(@calls[:UploadToPlayStoreAction]).to be_empty
      expect(origin("tag", "--list")).to eq("")
    end
  end

  describe "release" do
    it "submits the latest TestFlight build and tags it" do
      store(latest_version: "1.1.0", latest_build: 5, live_version: "1.0.0", monotonic_build: false)
      lane(:ios, :release)

      expect(@calls[:DeliverAction].first).to include(app_identifier: "com.example.app.staging", app_version: "1.1.0", build_number: "5",
                                                      submit_for_review: true, skip_metadata: true)
      expect(origin("tag", "--list")).to eq("v1.1.0-ios-5")
    end

    it "promotes the latest beta-track build on Play and tags it" do
      store(latest_version: "1.0.0", latest_build: 12, beta_build: 11, max_build: 12, live_version: nil, monotonic_build: true)
      lane(:android, :release)

      expect(@calls[:UploadToPlayStoreAction].first).to include(track: "internal", track_promote_to: "production", track_promote_release_status: "completed",
                                                                version_code: 11, skip_upload_aab: true)
      expect(origin("tag", "--list")).to eq("v1.0.0-android-11")
    end

    it "refuses to release a flavor from another branch" do
      store(latest_version: "1.1.0", latest_build: 5, live_version: nil, monotonic_build: false)
      expect { lane(:ios, :release, flavor: "production") }.to raise_error(FastlaneCore::Interface::FastlaneError, "production ships from main, not staging")
      expect(@calls[:DeliverAction]).to be_empty
    end
  end
end
