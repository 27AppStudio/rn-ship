require "fastlane/action"
require "fastlane_core/ui/ui"

module Fastlane
  module Helper
    module RnShipGitRelease
      module_function

      # Push the version-bump commit and its tag once the build is on the store.
      #
      # The build + upload take 15+ minutes, during which other commits commonly land on the
      # branch (developer pushes, [skip ci] metadata edits, the other platform's bump commit —
      # iOS and Android deploy in parallel). Rebase onto the latest origin/<branch> so the push
      # fast-forwards instead of being rejected with "! [rejected] <branch> -> <branch> (fetch
      # first)", and tag AFTER the rebase so the tag points at the final commit. A push that
      # is still rejected (the other platform pushed in between) is retried; a rebase conflict
      # is not.
      def push_release(branch:, tag:, remote: "origin", attempts: 3)
        # The build leaves CI-only edits in tracked files — on iOS, signing and team settings
        # are rewritten in project.pbxproj *after* the bump commit — and git refuses to rebase
        # a dirty tree ("cannot rebase: You have unstaged changes"). These edits must never
        # land on the branch, so they are discarded rather than stashed. `:/` is the repo-root
        # pathspec: fastlane runs from ios/ or android/, and the build can touch tracked files
        # outside it. Untracked build artefacts don't block a rebase, so no `git clean`.
        git("checkout", "--", ":/")

        attempts.times do |attempt|
          git("fetch", remote, branch)
          begin
            git("rebase", "#{remote}/#{branch}")
          rescue StandardError
            git("rebase", "--abort")
            raise
          end

          git("tag", "--force", "--annotate", tag, "--message", tag)
          begin
            git("push", "--atomic", remote, "HEAD:refs/heads/#{branch}", "refs/tags/#{tag}")
            return
          rescue StandardError
            raise if attempt == attempts - 1

            UI.important("Push to #{branch} rejected (attempt #{attempt + 1}/#{attempts}), retrying")
          end
        end
      end

      def git(*args)
        Actions.sh("git", *args)
      end
    end
  end
end
