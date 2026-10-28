require "fileutils"
require "open3"

# Runs git in a directory and fails the example with git's output when it fails.
module GitHelpers
  IDENTITY = { "user.name" => "CI", "user.email" => "ci@example.com", "commit.gpgsign" => "false", "tag.gpgsign" => "false" }.freeze

  def git!(dir, *args)
    output, status = Open3.capture2e("git", *args, chdir: dir)
    raise "git #{args.join(' ')} failed in #{dir}:\n#{output}" unless status.success?

    output.strip
  end

  # A repo at `dir` whose commits and tags work without the developer's global git config.
  def git_init!(dir, *args)
    FileUtils.mkdir_p(dir)
    git!(dir, "init", "-q", *args)
    IDENTITY.each { |key, value| git!(dir, "config", key, value) }
  end
end

RSpec.configure { |config| config.include(GitHelpers) }
