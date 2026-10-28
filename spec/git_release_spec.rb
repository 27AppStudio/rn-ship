require "fileutils"
require "open3"
require "tmpdir"

describe Fastlane::Helper::RnShipGitRelease do
  around do |example|
    Dir.mktmpdir("rn-ship-git") do |dir|
      @dir = dir
      example.run
    end
  end

  def git!(cwd, *args)
    out, status = Open3.capture2e("git", *args, chdir: cwd)
    raise "git #{args.join(' ')} failed in #{cwd}:\n#{out}" unless status.success?

    out.strip
  end

  def commit!(cwd, file, content, message)
    File.write(File.join(cwd, file), content)
    git!(cwd, "add", file)
    git!(cwd, "commit", "-q", "-m", message)
  end

  def clone!(name)
    path = File.join(@dir, name)
    git!(@dir, "clone", "-q", "--branch", "staging", origin, path)
    git!(path, "config", "user.name", "CI")
    git!(path, "config", "user.email", "ci@example.com")
    git!(path, "config", "commit.gpgsign", "false")
    git!(path, "config", "tag.gpgsign", "false")
    path
  end

  # Bare origin with a `staging` branch, and the runner's clone of it.
  let(:origin) do
    path = File.join(@dir, "origin.git")
    git!(@dir, "init", "-q", "--bare", "-b", "staging", path)
    seed = File.join(@dir, "seed")
    git!(@dir, "init", "-q", "-b", "staging", seed)
    git!(seed, "config", "user.name", "Seed")
    git!(seed, "config", "user.email", "seed@example.com")
    git!(seed, "config", "commit.gpgsign", "false")
    commit!(seed, "version.txt", "1.0.0+1\n", "init")
    commit!(seed, "README.md", "app\n", "readme")
    git!(seed, "push", "-q", path, "staging")
    path
  end
  let(:runner) { clone!("runner") }

  def push_release(**args)
    Dir.chdir(runner) { described_class.push_release(branch: "staging", **args) }
  end

  def origin_rev(ref)
    git!(origin, "rev-parse", "#{ref}^{commit}")
  end

  # Rejects the first `count` pushes, like a concurrent push from the other platform would.
  def reject_pushes(count)
    hook = File.join(origin, "hooks", "pre-receive")
    counter = File.join(@dir, "rejections")
    File.write(counter, count.to_s)
    File.write(hook, <<~SH)
      #!/bin/sh
      left=$(cat "#{counter}")
      if [ "$left" -gt 0 ]; then
        echo $((left - 1)) > "#{counter}"
        echo "simulated rejection" >&2
        exit 1
      fi
    SH
    FileUtils.chmod("+x", hook)
  end

  it "pushes the bump commit and an annotated tag on it" do
    commit!(runner, "version.txt", "1.0.0+2\n", "Bump to 1.0.0 (2)")

    push_release(tag: "ios/staging/1.0.0+2")

    expect(origin_rev("staging")).to eq(git!(runner, "rev-parse", "HEAD"))
    expect(origin_rev("ios/staging/1.0.0+2")).to eq(origin_rev("staging"))
    expect(git!(origin, "cat-file", "-t", "ios/staging/1.0.0+2")).to eq("tag")
  end

  it "rebases onto commits that landed during the build and tags the rebased commit" do
    commit!(runner, "version.txt", "1.0.0+2\n", "Bump to 1.0.0 (2)")
    other = clone!("other")
    commit!(other, "README.md", "app, edited during the build\n", "[skip ci] metadata")
    git!(other, "push", "-q", "origin", "staging")

    push_release(tag: "ios/staging/1.0.0+2")

    expect(git!(origin, "log", "--format=%s", "staging")).to eq("Bump to 1.0.0 (2)\n[skip ci] metadata\nreadme\ninit")
    expect(origin_rev("ios/staging/1.0.0+2")).to eq(origin_rev("staging"))
  end

  it "discards CI-only edits to tracked files instead of pushing them" do
    commit!(runner, "version.txt", "1.0.0+2\n", "Bump to 1.0.0 (2)")
    File.write(File.join(runner, "README.md"), "signing settings rewritten by CI\n")

    push_release(tag: "ios/staging/1.0.0+2")

    expect(git!(origin, "show", "staging:README.md")).to eq("app")
  end

  it "retries a rejected push" do
    commit!(runner, "version.txt", "1.0.0+2\n", "Bump to 1.0.0 (2)")
    reject_pushes(2)

    push_release(tag: "ios/staging/1.0.0+2", attempts: 3)

    expect(origin_rev("staging")).to eq(git!(runner, "rev-parse", "HEAD"))
  end

  it "gives up after the last attempt" do
    commit!(runner, "version.txt", "1.0.0+2\n", "Bump to 1.0.0 (2)")
    reject_pushes(2)

    expect { push_release(tag: "ios/staging/1.0.0+2", attempts: 2) }.to raise_error(StandardError)
    expect(git!(origin, "log", "-1", "--format=%s", "staging")).to eq("readme")
  end

  it "aborts the rebase on a conflict and does not retry" do
    commit!(runner, "version.txt", "1.0.0+2\n", "Bump to 1.0.0 (2)")
    other = clone!("other")
    commit!(other, "version.txt", "1.0.0+9\n", "Conflicting bump")
    git!(other, "push", "-q", "origin", "staging")

    expect { push_release(tag: "ios/staging/1.0.0+2") }.to raise_error(StandardError)
    expect(Dir.exist?(File.join(runner, ".git", "rebase-merge"))).to be(false)
    expect(Dir.exist?(File.join(runner, ".git", "rebase-apply"))).to be(false)
    expect(git!(origin, "tag", "--list")).to eq("")
  end
end

describe Fastlane::Actions::RnShipPushReleaseAction do
  it "rejects fewer than one attempt" do
    expect { run_lane('rn_ship_push_release(branch: "staging", tag: "t", attempts: 0)') }
      .to raise_error(FastlaneCore::Interface::FastlaneError, /attempts must be at least 1/)
  end
end
