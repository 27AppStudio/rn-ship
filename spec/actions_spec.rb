require "fileutils"
require "json"
require "open3"
require "tmpdir"
require "yaml"

describe "GitHub composite actions" do
  ROOT = File.expand_path("..", __dir__)
  SCRIPTS = File.join(ROOT, "actions", "scripts")
  ACTIONS = Dir[File.join(ROOT, "actions", "*", "action.yml")].sort

  def run_blocks(path)
    YAML.safe_load_file(path).dig("runs", "steps").select { |step| step["run"] }
  end

  it "has the four actions" do
    expect(ACTIONS.map { |path| File.basename(File.dirname(path)) }).to eq(%w[android-deploy ios-deploy notify setup])
  end

  ACTIONS.each do |path|
    name = File.basename(File.dirname(path))

    # A `${{ }}` inside `run:` is pasted into the shell source before it runs: a secret holding
    # `$`, backticks or quotes is expanded or breaks the script. Values go through `env:`.
    it "#{name}: never expands an expression inside a run: block" do
      run_blocks(path).each do |step|
        expect(step["run"]).not_to include("${{"), "#{name} / #{step['name']}"
      end
    end

    it "#{name}: passes shellcheck" do
      skip "shellcheck not installed" unless system("command -v shellcheck > /dev/null")
      run_blocks(path).each do |step|
        output, status = Open3.capture2e("shellcheck", "--shell=bash", "-", stdin_data: step["run"])
        expect(status).to be_success, "#{name} / #{step['name']}:\n#{output}"
      end
    end
  end

  describe "write-secret.sh" do
    around { |example| Dir.mktmpdir("rn-ship-secret") { |dir| @dir = dir and example.run } }

    def write(content, *args)
      Open3.capture2e({ "SECRET_CONTENT" => content }, File.join(SCRIPTS, "write-secret.sh"), *args)
    end

    it "writes the value byte for byte, whatever the shell would make of it" do
      tricky = %(API_URL=https://x.example.com?a=1&b=2\nTOKEN="$HOME `id` $(whoami) \\n 'q' %s"\nEMPTY=)
      dest = File.join(@dir, "nested", ".env.staging")
      _, status = write(tricky, dest)

      expect(status).to be_success
      expect(File.read(dest)).to eq("#{tricky}\n")
      expect(File.stat(dest).mode & 0o777).to eq(0o600)
    end

    it "tightens an existing file to 600" do
      dest = File.join(@dir, "key")
      File.write(dest, "old")
      File.chmod(0o644, dest)
      write("new", dest)
      expect(File.stat(dest).mode & 0o777).to eq(0o600)
    end

    it "decodes base64 split over lines" do
      dest = File.join(@dir, "upload.jks")
      keystore = Random.bytes(3000)
      _, status = write([keystore].pack("m"), dest, "--base64") # 60-column lines
      expect(status).to be_success
      expect(File.binread(dest)).to eq(keystore)
    end

    it "refuses an empty secret instead of writing an empty file" do
      output, status = write("", File.join(@dir, "key"))
      expect(status).not_to be_success
      expect(output).to include("::error::Nothing to write")
      expect(File.exist?(File.join(@dir, "key"))).to be(false)
    end
  end

  describe "cleanup.sh" do
    it "deletes what git doesn't track and restores what it does" do
      Dir.mktmpdir("rn-ship-cleanup") do |dir|
        git_init!(dir)
        File.write(File.join(dir, ".env"), "committed\n")
        git!(dir, "add", ".env")
        git!(dir, "commit", "-qm", "init")
        File.write(File.join(dir, ".env"), "SECRET=from-ci\n")
        File.write(File.join(dir, ".env.staging"), "SECRET=x\n")

        _, status = Open3.capture2e(File.join(SCRIPTS, "cleanup.sh"), ".env.staging", ".env", "", "missing.txt", chdir: dir)

        expect(status).to be_success
        expect(File.exist?(File.join(dir, ".env.staging"))).to be(false)
        expect(File.read(File.join(dir, ".env"))).to eq("committed\n")
      end
    end
  end

  describe "notify.sh" do
    def notify(env, *args)
      Open3.capture2e({ "GITHUB_REPOSITORY" => "me/app", "GITHUB_RUN_ID" => "42", "GITHUB_REF_NAME" => "staging", "GITHUB_ACTOR" => "me" }.merge(env),
                      File.join(SCRIPTS, "notify.sh"), *args)
    end

    it "builds a payload both Discord and Slack read, escaping the title" do
      output, status = notify({ "NOTIFY_PRINT" => "1" }, "success", %(iOS "beta" $x))
      payload = JSON.parse(output)

      expect(status).to be_success
      expect(payload["content"]).to eq(%([success] iOS "beta" $x on staging by me: https://github.com/me/app/actions/runs/42))
      expect(payload["text"]).to eq(payload["content"])
    end

    it "skips quietly without a webhook" do
      output, status = notify({ "WEBHOOK_URL" => "" }, "failure", "Android beta")
      expect(status).to be_success
      expect(output).to include("skipping")
    end

    it "never fails the job when the webhook is down" do
      output, status = notify({ "WEBHOOK_URL" => "http://127.0.0.1:9/hook" }, "failure", "Android beta")
      expect(status).to be_success
      expect(output).to include("::warning::Could not post")
    end
  end

  describe "credential-names.rb" do
    def names(*args, env: {})
      Dir.mktmpdir("rn-ship-names") do |dir|
        FileUtils.cp(File.join(ROOT, "spec", "fixtures", "splitify.yml"), File.join(dir, "rn-ship.yml"))
        output, status = Open3.capture2e({ "BUNDLE_GEMFILE" => File.join(ROOT, "Gemfile"), "GITHUB_OUTPUT" => "" }.merge(env),
                                         "bundle", "exec", "ruby", File.join(SCRIPTS, "credential-names.rb"), *args, chdir: dir)
        raise output unless status.success?

        return output.lines.grep(/=/).to_h { |line| line.chomp.split("=", 2) }.transform_values { |value| value.sub(File.realpath(dir), "<root>").sub(dir, "<root>") }
      end
    end

    it "gives the iOS names rn-ship.yml sets, never values" do
      expect(names("ios", "staging")).to eq(
        "flavor" => "staging", "env_file" => "<root>/.env.staging", "self_hosted_env" => "SPLITIFY_SELF_HOSTED",
        "key_id_env" => "APP_STORE_KEY_ID", "issuer_id_env" => "APP_STORE_ISSUER_ID", "key_content_env" => "APP_STORE_CONNECT_API_KEY_KEY",
        "ios_dir" => "<root>/ios"
      )
    end

    it "takes the flavor from the branch being deployed" do
      expect(names("android", env: { "GITHUB_REF_NAME" => "master" })).to include(
        "flavor" => "prod", "upload_key_prefix" => "SPLITIFY_UPLOAD", "json_key_env" => "PLAY_SERVICE_ACCOUNT_JSON", "release_status_env" => "PLAY_RELEASE_STATUS"
      )
    end
  end
end
