require "fileutils"
require "open3"
require "tmpdir"


describe Fastlane::Helper::RnShipAndroid do
  around do |example|
    Dir.mktmpdir("rn-ship-android") do |dir|
      @dir = dir
      @gradle_home = File.join(dir, "gradle-home")
      FileUtils.mkdir_p(@gradle_home)
      example.run
    end
  end

  let(:project_dir) { File.join(@dir, "android").tap { |path| FileUtils.mkdir_p(path) } }
  let(:module_dir) { File.join(project_dir, "app").tap { |path| FileUtils.mkdir_p(path) } }
  let(:upload_props) do
    {
      "ORG_GRADLE_PROJECT_MYAPP_UPLOAD_STORE_FILE" => AndroidKeys.path("upload.jks"),
      "ORG_GRADLE_PROJECT_MYAPP_UPLOAD_STORE_PASSWORD" => "upload-pass",
      "ORG_GRADLE_PROJECT_MYAPP_UPLOAD_KEY_ALIAS" => "upload",
      "ORG_GRADLE_PROJECT_MYAPP_UPLOAD_KEY_PASSWORD" => "upload-pass"
    }
  end

  def env(extra = {})
    { "GRADLE_USER_HOME" => @gradle_home }.merge(extra)
  end

  describe ".gradle_property" do
    it "reads CI env first, then the user's gradle.properties, then the project's" do
      File.write(File.join(@gradle_home, "gradle.properties"), "# comment\nA=from-home\nB : from-home\n")
      File.write(File.join(project_dir, "gradle.properties"), "A=from-project\nB=from-project\nC=from-project\n")

      expect(described_class.gradle_property("A", project_dir: project_dir, env: env("ORG_GRADLE_PROJECT_A" => "from-env")))
        .to eq(["from-env", "ORG_GRADLE_PROJECT_A"])
      expect(described_class.gradle_property("B", project_dir: project_dir, env: env)).to eq(["from-home", File.join(@gradle_home, "gradle.properties")])
      expect(described_class.gradle_property("C", project_dir: project_dir, env: env)).to eq(["from-project", File.join(project_dir, "gradle.properties")])
      expect(described_class.gradle_property("D", project_dir: project_dir, env: env)).to be_nil
    end
  end

  describe ".upload_key!" do
    it "returns the key without passwords in the message" do
      key = described_class.upload_key!(prefix: "MYAPP_UPLOAD", project_dir: project_dir, module_dir: module_dir, env: env(upload_props))
      expect(key).to eq(store_file: AndroidKeys.path("upload.jks"), key_alias: "upload", store_password: "upload-pass")
    end

    it "resolves a relative store file against the app module, like Gradle's file()" do
      FileUtils.cp(AndroidKeys.path("upload.jks"), File.join(project_dir, "upload.jks"))
      props = upload_props.merge("ORG_GRADLE_PROJECT_MYAPP_UPLOAD_STORE_FILE" => "../upload.jks")
      key = described_class.upload_key!(prefix: "MYAPP_UPLOAD", project_dir: project_dir, module_dir: module_dir, env: env(props))
      expect(key[:store_file]).to eq(File.join(project_dir, "upload.jks"))
    end

    it "names every missing property" do
      props = upload_props.reject { |name, _| name.end_with?("PASSWORD") }
      expect { described_class.upload_key!(prefix: "MYAPP_UPLOAD", project_dir: project_dir, module_dir: module_dir, env: env(props)) }
        .to raise_error(FastlaneCore::Interface::FastlaneError, /missing Gradle properties: MYAPP_UPLOAD_STORE_PASSWORD, MYAPP_UPLOAD_KEY_PASSWORD/)
    end

    it "fails when the keystore file isn't there" do
      props = upload_props.merge("ORG_GRADLE_PROJECT_MYAPP_UPLOAD_STORE_FILE" => "missing.jks")
      expect { described_class.upload_key!(prefix: "MYAPP_UPLOAD", project_dir: project_dir, module_dir: module_dir, env: env(props)) }
        .to raise_error(FastlaneCore::Interface::FastlaneError, /Upload keystore not found at .*app\/missing.jks/)
    end
  end

  describe ".use_env_file!" do
    it "pins ENVFILE to the flavor's file, as an absolute path" do
      File.write(File.join(@dir, ".env.staging"), "API_URL=x\n")
      target = {}
      described_class.use_env_file!(".env.staging", root: @dir, flavor: "staging", env: target)
      expect(target).to eq("ENVFILE" => File.join(@dir, ".env.staging"))
    end

    it "refuses to build without it" do
      expect { described_class.use_env_file!(".env.staging", root: @dir, flavor: "staging", env: {}) }
        .to raise_error(FastlaneCore::Interface::FastlaneError, ".env.staging is missing: the staging build would ship without its config")
    end
  end

  describe ".verify_upload_signature!" do
    let(:upload_key) { { store_file: AndroidKeys.path("upload.jks"), key_alias: "upload", store_password: "upload-pass" } }
    let(:debug_keystores) { [AndroidKeys.path("debug.keystore"), File.join(@dir, "no-such.keystore")] }

    it "accepts a bundle signed with the upload key" do
      fingerprint = described_class.verify_upload_signature!(AndroidKeys.path("upload.aab"), upload_key: upload_key, debug_keystores: debug_keystores)
      expect(fingerprint).to match(/\A(\h\h:){31}\h\h\z/)
    end

    it "names the debug keystore when that's what signed it" do
      expect { described_class.verify_upload_signature!(AndroidKeys.path("debug.aab"), upload_key: upload_key, debug_keystores: debug_keystores) }
        .to raise_error(FastlaneCore::Interface::FastlaneError, /debug.aab is signed with the debug key \(.*debug.keystore\)/)
    end

    it "refuses any other key, not just the debug one" do
      expect { described_class.verify_upload_signature!(AndroidKeys.path("other.aab"), upload_key: upload_key, debug_keystores: debug_keystores) }
        .to raise_error(FastlaneCore::Interface::FastlaneError, /other.aab is signed with \S+, not the upload key/)
    end

    it "refuses an unsigned bundle" do
      expect { described_class.verify_upload_signature!(AndroidKeys.path("unsigned.aab"), upload_key: upload_key) }
        .to raise_error(FastlaneCore::Interface::FastlaneError, "unsigned.aab is not signed, refusing to ship it")
    end

    it "explains a wrong store password without printing it" do
      wrong = upload_key.merge(store_password: "not-the-password")
      expect { described_class.verify_upload_signature!(AndroidKeys.path("upload.aab"), upload_key: wrong) }
        .to raise_error(FastlaneCore::Interface::FastlaneError, /Could not read upload from .*upload.jks: wrong alias or store password\z/)
    end

    it "keeps the store password off keytool's command line" do
      calls = []
      allow(Open3).to receive(:capture2e).and_wrap_original { |original, *args| calls << args && original.call(*args) }
      described_class.key_fingerprint(**upload_key)

      env, *argv = calls.last
      expect(env).to eq("RN_SHIP_STORE_PASSWORD" => "upload-pass")
      expect(argv).to include("-storepass:env", "RN_SHIP_STORE_PASSWORD")
      expect(argv).not_to include("upload-pass")
    end
  end

  describe "gradle version" do
    def gradle(content)
      File.join(@dir, "build.gradle").tap { |path| File.write(path, content) }
    end

    let(:groovy) do
      <<~GRADLE
        android {
            defaultConfig {
                applicationId "com.example.app"
                // Set by fastlane on every upload
                versionCode 41 // from Play
                versionName "1.2.6"
            }
        }
      GRADLE
    end

    it "reads and writes Groovy literals, keeping comments and layout" do
      path = gradle(groovy)
      expect(described_class.read_gradle_version(path)).to eq(version: "1.2.6", build: 41)

      described_class.write_gradle_version(path, version: "1.2.7", build: 42)
      expect(File.read(path)).to eq(groovy.sub("versionCode 41", "versionCode 42").sub('"1.2.6"', '"1.2.7"'))
    end

    it "reads and writes Kotlin DSL literals" do
      path = gradle("defaultConfig {\n    versionCode = 3\n    versionName = \"0.4.0\"\n}\n")
      described_class.write_gradle_version(path, version: "0.5.0", build: 4)
      expect(File.read(path)).to eq("defaultConfig {\n    versionCode = 4\n    versionName = \"0.5.0\"\n}\n")
    end

    it "refuses per-flavor overrides that would keep their own value" do
      path = gradle(groovy.sub("    }\n}", "    }\n    productFlavors { staging { versionCode 7 } }\n}").sub("staging { versionCode 7 }", "staging {\n        versionCode 7\n    }"))
      expect { described_class.read_gradle_version(path) }
        .to raise_error(FastlaneCore::Interface::FastlaneError, /2 versionCode lines .* remove the per-flavor overrides/)
    end

    it "refuses a computed version" do
      path = gradle("defaultConfig {\n    versionCode getCode()\n    versionName \"1.0\"\n}\n")
      expect { described_class.read_gradle_version(path) }.to raise_error(FastlaneCore::Interface::FastlaneError, /No literal versionCode/)
    end

    it "matches Splitify's real build.gradle shape" do
      path = gradle("        // Set by fastlane on every Play upload (android/fastlane/Fastfile); Google Play is\n        // the authority, see docs/deployment.md.\n        versionCode 1\n        versionName \"1.2.6\"\n")
      expect(described_class.read_gradle_version(path)).to eq(version: "1.2.6", build: 1)
    end
  end
end

describe "Android actions" do
  around do |example|
    Dir.mktmpdir("rn-ship-android-actions") do |dir|
      @root = dir
      FileUtils.mkdir_p(File.join(dir, "android", "app"))
      FileUtils.mkdir_p(File.join(dir, "gradle-home"))
      File.write(File.join(dir, "android", "app", "build.gradle"), "versionCode 9\nversionName \"2.0.0\"\n")
      File.write(File.join(dir, ".env.staging"), "API_URL=x\n")
      File.write(File.join(dir, "rn-ship.yml"), <<~YAML)
        android:
          upload_key_prefix: MYAPP_UPLOAD
        flavors:
          staging:
            branch: staging
            env_file: .env.staging
            android: { flavor: staging, package_name: com.example.app.staging }
      YAML
      example.run
    end
  end

  # Never the real ENV: a developer's ~/.gradle/gradle.properties may hold a real upload key.
  before do
    stub_const("ENV", {
      "GRADLE_USER_HOME" => File.join(@root, "gradle-home"),
      "ORG_GRADLE_PROJECT_MYAPP_UPLOAD_STORE_FILE" => AndroidKeys.path("upload.jks"),
      "ORG_GRADLE_PROJECT_MYAPP_UPLOAD_STORE_PASSWORD" => "upload-pass",
      "ORG_GRADLE_PROJECT_MYAPP_UPLOAD_KEY_ALIAS" => "upload",
      "ORG_GRADLE_PROJECT_MYAPP_UPLOAD_KEY_PASSWORD" => "upload-pass",
      "PATH" => ENV.fetch("PATH"),
      "HOME" => ENV.fetch("HOME")
    })
  end

  let(:config_path) { File.join(@root, "rn-ship.yml").inspect }

  it "rn_ship_android_preflight checks the key and pins ENVFILE" do
    result = run_lane("rn_ship_android_preflight(flavor: 'staging', config_path: #{config_path})")
    expect(result).to eq(store_file: AndroidKeys.path("upload.jks"), key_alias: "upload", env_file: File.join(@root, ".env.staging"))
    expect(ENV["ENVFILE"]).to eq(File.join(@root, ".env.staging"))
  end

  it "rn_ship_verify_aab defaults to the last gradle bundle" do
    Fastlane::Actions.lane_context[Fastlane::Actions::SharedValues::GRADLE_AAB_OUTPUT_PATH] = AndroidKeys.path("upload.aab")
    expect(run_lane("rn_ship_verify_aab(config_path: #{config_path})")).to match(/\A(\h\h:){31}\h\h\z/)
  end

  it "rn_ship_verify_aab refuses a debug-signed bundle" do
    expect { run_lane("rn_ship_verify_aab(aab: #{AndroidKeys.path('debug.aab').inspect}, config_path: #{config_path})") }
      .to raise_error(FastlaneCore::Interface::FastlaneError, /not the upload key/)
  end

  it "rn_ship_gradle_version reads, then writes only what it's given" do
    expect(run_lane("rn_ship_gradle_version(config_path: #{config_path})")).to eq(version: "2.0.0", build: 9)
    expect(run_lane("rn_ship_gradle_version(build: 10, config_path: #{config_path})")).to eq(version: "2.0.0", build: 10)
    expect(File.read(File.join(@root, "android", "app", "build.gradle"))).to eq("versionCode 10\nversionName \"2.0.0\"\n")
  end
end
