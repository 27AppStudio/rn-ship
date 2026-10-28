require "fileutils"
require "tmpdir"
require "xcodeproj"


describe Fastlane::Helper::RnShipIos do
  around do |example|
    Dir.mktmpdir("rn-ship-ios") do |dir|
      @root = dir
      @project = IosProject.create(dir)
      @workspace = File.join(dir, "ios", "App.xcworkspace")
      example.run
    end
  end

  def check(**overrides)
    described_class.check_project!(**{ project: @project, workspace: @workspace, scheme: "staging",
                                       configuration: "StagingRelease", targets: %w[App NotificationService] }.merge(overrides))
  end

  describe ".check_project!" do
    it "accepts what the project really has" do
      expect(check).to be(true)
    end

    it "catches a target typo that update_code_signing_settings would skip silently" do
      expect { check(targets: %w[App NotificationServices]) }
        .to raise_error(FastlaneCore::Interface::FastlaneError, "Target(s) NotificationServices not in App.xcodeproj (it has App, NotificationService)")
    end

    it "catches a configuration the target doesn't have" do
      expect { check(configuration: "Staging") }
        .to raise_error(FastlaneCore::Interface::FastlaneError, /Target App has no Staging configuration \(it has Debug, Release, StagingRelease\)/)
    end

    it "requires the scheme to be shared" do
      expect { check(scheme: "local") }.to raise_error(FastlaneCore::Interface::FastlaneError, /Scheme local is not shared/)
    end

    it "accepts a scheme shared in the workspace" do
      FileUtils.mkdir_p(File.join(@workspace, "xcshareddata", "xcschemes"))
      FileUtils.cp(File.join(@project, "xcshareddata", "xcschemes", "staging.xcscheme"), File.join(@workspace, "xcshareddata", "xcschemes", "ws.xcscheme"))
      expect(check(scheme: "ws")).to be(true)
    end

    it "explains a wrong project path" do
      expect { check(project: File.join(@root, "ios", "Nope.xcodeproj")) }.to raise_error(FastlaneCore::Interface::FastlaneError, /Xcode project not found/)
    end
  end

  describe ".ensure_no_stale_envfile!" do
    it "refuses to build while a stale envfile would override ENVFILE" do
      stale = File.join(@root, "envfile")
      expect(described_class.ensure_no_stale_envfile!(stale)).to be_nil
      File.write(stale, ".env.dev")
      expect { described_class.ensure_no_stale_envfile!(stale) }.to raise_error(FastlaneCore::Interface::FastlaneError, /reads it before ENVFILE/)
    end
  end

  describe ".prioritize_keychain!" do
    let(:listing) { %(    "/Users/me/Library/Keychains/login.keychain-db"\n    "/Users/me/Library/Keychains/rn_ship_ci-db"\n) }

    it "moves the CI keychain to the front and keeps the others in order" do
      calls = []
      run = lambda do |*args|
        calls << args
        listing
      end

      expect(described_class.prioritize_keychain!("rn_ship_ci", run)).to eq("/Users/me/Library/Keychains/rn_ship_ci-db")
      expect(calls.last).to eq(["list-keychains", "-d", "user", "-s", "/Users/me/Library/Keychains/rn_ship_ci-db", "/Users/me/Library/Keychains/login.keychain-db"])
    end

    it "fails when the keychain isn't in the search list" do
      expect { described_class.prioritize_keychain!("other_ci", ->(*) { listing }) }
        .to raise_error(FastlaneCore::Interface::FastlaneError, "other_ci keychain is not in the search list")
    end
  end
end

describe "iOS actions" do
  around do |example|
    Dir.mktmpdir("rn-ship-ios-actions") do |dir|
      @root = dir
      @project = IosProject.create(dir)
      File.write(File.join(dir, ".env.staging"), "API_URL=x\n")
      File.write(File.join(dir, "rn-ship.yml"), <<~YAML)
        ios:
          project: ios/App.xcodeproj
          workspace: ios/App.xcworkspace
          target: App
          team_id: TEAM123456
          extensions:
            - { target: NotificationService, bundle_id_suffix: .NotificationService }
        flavors:
          staging:
            branch: staging
            env_file: .env.staging
            ios: { scheme: staging, configuration: StagingRelease, bundle_id: com.example.app.staging }
      YAML
      example.run
    end
  end

  let(:config_path) { File.join(@root, "rn-ship.yml").inspect }

  before do
    # Never the machine's real /tmp/envfile: other builds on this Mac read it.
    stub_const("Fastlane::Helper::RnShipIos::STALE_ENVFILE", File.join(@root, "no-envfile"))
    stub_const("ENV", { "PATH" => ENV.fetch("PATH"), "HOME" => ENV.fetch("HOME"),
                        "APP_STORE_CONNECT_API_KEY_KEY_ID" => "K", "APP_STORE_CONNECT_API_KEY_ISSUER_ID" => "I",
                        "APP_STORE_CONNECT_API_KEY_KEY" => "k" })
  end

  describe "rn_ship_ios_preflight" do
    it "checks the project and pins ENVFILE" do
      result = run_lane("rn_ship_ios_preflight(flavor: 'staging', config_path: #{config_path})")
      expect(result).to eq(scheme: "staging", configuration: "StagingRelease", env_file: File.join(@root, ".env.staging"))
      expect(ENV["ENVFILE"]).to eq(File.join(@root, ".env.staging"))
    end

    it "fails before the build when the App Store Connect key is missing" do
      ENV.delete("APP_STORE_CONNECT_API_KEY_KEY")
      expect { run_lane("rn_ship_ios_preflight(flavor: 'staging', config_path: #{config_path})") }
        .to raise_error(FastlaneCore::Interface::FastlaneError, /App Store Connect API key not configured/)
      expect(run_lane("rn_ship_ios_preflight(flavor: 'staging', skip_api_key_check: true, config_path: #{config_path})")[:scheme]).to eq("staging")
    end

    it "refuses a stale /tmp/envfile" do
      File.write(Fastlane::Helper::RnShipIos::STALE_ENVFILE, ".env.dev")
      expect { run_lane("rn_ship_ios_preflight(flavor: 'staging', config_path: #{config_path})") }
        .to raise_error(FastlaneCore::Interface::FastlaneError, /reads it before ENVFILE/)
    end

    it "refuses a missing env file" do
      File.delete(File.join(@root, ".env.staging"))
      expect { run_lane("rn_ship_ios_preflight(flavor: 'staging', config_path: #{config_path})") }
        .to raise_error(FastlaneCore::Interface::FastlaneError, ".env.staging is missing: the staging build would ship without its config")
    end
  end

  describe "rn_ship_ios_signing" do
    it "writes each target's signing for the flavor's configuration only" do
      result = run_lane("rn_ship_ios_signing(flavor: 'staging', config_path: #{config_path})")

      expect(result).to eq([
        { target: "App", profile: "match AppStore com.example.app.staging", bundle_id: "com.example.app.staging" },
        { target: "NotificationService", profile: "match AppStore com.example.app.staging.NotificationService", bundle_id: "com.example.app.staging.NotificationService" }
      ])

      app = IosProject.settings(@project, "App", "StagingRelease")
      expect(app).to include("CODE_SIGN_STYLE" => "Manual", "DEVELOPMENT_TEAM" => "TEAM123456", "CODE_SIGN_IDENTITY" => "iPhone Distribution",
                             "PROVISIONING_PROFILE_SPECIFIER" => "match AppStore com.example.app.staging",
                             "PRODUCT_BUNDLE_IDENTIFIER" => "com.example.app.staging")
      extension = IosProject.settings(@project, "NotificationService", "StagingRelease")
      expect(extension).to include("PROVISIONING_PROFILE_SPECIFIER" => "match AppStore com.example.app.staging.NotificationService",
                                   "PRODUCT_BUNDLE_IDENTIFIER" => "com.example.app.staging.NotificationService")
      expect(IosProject.settings(@project, "App", "Release")).not_to include("PROVISIONING_PROFILE_SPECIFIER")
    end
  end

  describe "rn_ship_xcode_version" do
    def plist(name)
      Xcodeproj::Plist.read_from_path(File.join(@root, "ios", name, "Info.plist"))
    end

    it "reads the literal from Info.plist and the build from the build settings" do
      expect(run_lane("rn_ship_xcode_version(flavor: 'staging', config_path: #{config_path})")).to eq(version: "1.0.0", build: 4)
    end

    it "writes the app and every extension, in every configuration" do
      expect(run_lane("rn_ship_xcode_version(flavor: 'staging', version: '1.1.0', build: 5, config_path: #{config_path})")).to eq(
        version: "1.1.0", build: 5, files: [File.join(@project, "project.pbxproj"), File.join(@root, "ios", "App", "Info.plist")]
      )

      %w[App NotificationService].product(%w[Debug Release StagingRelease]).each do |target, configuration|
        expect(IosProject.settings(@project, target, configuration)).to include("MARKETING_VERSION" => "1.1.0", "CURRENT_PROJECT_VERSION" => "5")
      end
      expect(plist("App")).to include("CFBundleShortVersionString" => "1.1.0", "CFBundleVersion" => "$(CURRENT_PROJECT_VERSION)")
      expect(plist("NotificationService")).not_to include("CFBundleShortVersionString")
      expect(run_lane("rn_ship_xcode_version(flavor: 'staging', config_path: #{config_path})")).to eq(version: "1.1.0", build: 5)
    end

    it "changes only what it's given" do
      expect(run_lane("rn_ship_xcode_version(flavor: 'staging', build: 9, config_path: #{config_path})")).to include(version: "1.0.0", build: 9)
    end
  end

  describe "rn_ship_ci_signing" do
    it "does nothing outside CI" do
      allow(FastlaneCore::Helper).to receive(:ci?).and_return(false)
      expect(run_lane("rn_ship_ci_signing(config_path: #{config_path})")).to eq(keychain: nil, archive_path: nil)
      expect(ENV["MATCH_READONLY"]).to be_nil
    end

    it "uses setup_ci on a hosted runner and forces match read-only" do
      allow(FastlaneCore::Helper).to receive(:ci?).and_return(true)
      expect(Fastlane::Actions::SetupCiAction).to receive(:run) { ENV["MATCH_KEYCHAIN_NAME"] = "fastlane_tmp_keychain" }

      expect(run_lane("rn_ship_ci_signing(config_path: #{config_path})")).to eq(keychain: "fastlane_tmp_keychain", archive_path: nil)
      expect(ENV["MATCH_READONLY"]).to eq("true")
    end

    it "creates a dedicated non-default keychain on a self-hosted Mac" do
      allow(FastlaneCore::Helper).to receive(:ci?).and_return(true)
      ENV["RN_SHIP_SELF_HOSTED"] = "1"
      ENV["RUNNER_TEMP"] = "/runner/tmp"
      allow(Fastlane::Helper::RnShipIos).to receive(:keychain_path).and_return(File.join(@root, "absent-db"))
      expect(Fastlane::Actions::SetupCiAction).not_to receive(:run)
      expect(Fastlane::Actions::CreateKeychainAction).to receive(:run) do |params|
        expect(params[:name]).to eq("rn_ship_ci")
        expect(params[:default_keychain]).to be(false)
        expect(params[:password]).to match(/\A\h{48}\z/)
      end
      expect(Fastlane::Helper::RnShipIos).to receive(:prioritize_keychain!).with("rn_ship_ci")

      expect(run_lane("rn_ship_ci_signing(config_path: #{config_path})")).to eq(keychain: "rn_ship_ci", archive_path: "/runner/tmp/rn-ship.xcarchive")
      expect(ENV).to include("MATCH_KEYCHAIN_NAME" => "rn_ship_ci", "MATCH_READONLY" => "true")
      expect(ENV["MATCH_KEYCHAIN_PASSWORD"]).to match(/\A\h{48}\z/)
    end

    it "replaces a keychain left over by a crashed run" do
      allow(FastlaneCore::Helper).to receive(:ci?).and_return(true)
      ENV["RN_SHIP_SELF_HOSTED"] = "1"
      leftover = File.join(@root, "rn_ship_ci-db")
      File.write(leftover, "")
      allow(Fastlane::Helper::RnShipIos).to receive(:keychain_path).and_return(leftover)
      allow(Fastlane::Helper::RnShipIos).to receive(:prioritize_keychain!)
      expect(Fastlane::Actions::DeleteKeychainAction).to receive(:run).ordered
      expect(Fastlane::Actions::CreateKeychainAction).to receive(:run).ordered

      run_lane("rn_ship_ci_signing(config_path: #{config_path})")
    end
  end

  describe "rn_ship_ci_signing_cleanup" do
    it "deletes the self-hosted keychain" do
      ENV["RN_SHIP_SELF_HOSTED"] = "1"
      keychain = File.join(@root, "rn_ship_ci-db")
      File.write(keychain, "")
      allow(Fastlane::Helper::RnShipIos).to receive(:keychain_path).with("rn_ship_ci").and_return(keychain)
      expect(Fastlane::Actions::DeleteKeychainAction).to receive(:run) { |params| expect(params[:name]).to eq("rn_ship_ci") }

      expect(run_lane("rn_ship_ci_signing_cleanup(config_path: #{config_path})")).to be(true)
    end

    it "leaves hosted runners alone" do
      expect(Fastlane::Actions::DeleteKeychainAction).not_to receive(:run)
      expect(run_lane("rn_ship_ci_signing_cleanup(config_path: #{config_path})")).to be(false)
    end
  end
end
