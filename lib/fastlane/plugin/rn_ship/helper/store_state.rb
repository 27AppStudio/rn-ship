require "fastlane_core/ui/ui"

module Fastlane
  module Helper
    # What the stores already have, the input of RnShipVersioning.resolve_next_version.
    # Reads only: nothing here creates, uploads or changes anything on a store.
    module RnShipStoreState
      # Production releases that count as live: rolled out, rolling out, or halted mid-rollout.
      PLAY_LIVE_STATUSES = %w[completed inProgress halted].freeze

      module_function

      # "1.2.6", or the Play Console's default release name "41 (1.2.6)" -> "1.2.6"
      def semver_from(release_name)
        release_name.to_s[/\d+\.\d+(?:\.\d+)?/]
      end

      # Google Play's equivalent of the TestFlight / App Store lookups, from the tracks of one
      # edit. Returns
      #   latest_version / latest_build  the newest release on the beta track
      #   max_build                      the highest versionCode on ANY track: Play never accepts
      #                                  a code twice, so the next build always goes above it
      #   live_version                   the newest production release. Counts from the moment
      #                                  it is promoted, even while still in review.
      # A track that doesn't exist yet on a new app just counts as empty.
      def summarize_play_tracks(tracks, beta_track:)
        releases_on = ->(name) { tracks.select { |track| track.track == name }.flat_map { |track| track.releases || [] } }
        highest = ->(release) { (release&.version_codes || []).map(&:to_i).max }

        latest = releases_on.call(beta_track).max_by { |release| highest.call(release) || 0 }
        live = releases_on.call("production")
               .select { |release| PLAY_LIVE_STATUSES.include?(release.status) }
               .max_by { |release| highest.call(release) || 0 }
        all_codes = tracks.flat_map { |track| (track.releases || []).flat_map { |release| release.version_codes || [] } }

        {
          latest_version: semver_from(latest&.name),
          latest_build: highest.call(latest),
          max_build: all_codes.map(&:to_i).max || 0,
          live_version: semver_from(live&.name)
        }
      end

      # One edit, opened and aborted: Play has no read-only API for tracks.
      def play(package_name:, json_key_data:, beta_track:)
        require "supply"
        require "supply/options"
        require "supply/client"

        Supply.config = FastlaneCore::Configuration.create(
          Supply::Options.available_options,
          { package_name: package_name, json_key_data: json_key_data }
        )
        client = Supply::Client.make_from_config
        client.begin_edit(package_name: package_name)
        begin
          tracks = client.tracks
        ensure
          client.abort_current_edit
        end
        summarize_play_tracks(tracks, beta_track: beta_track)
      end

      # Options for fastlane's app_store_connect_api_key, from the env var NAMES in rn-ship.yml.
      # Key content wins over a key path, matching fastlane. Errors name the variables, never
      # their values.
      def app_store_connect_api_key_options(settings, env: ENV)
        value = ->(name) { env[settings[name]].to_s.strip.empty? ? nil : env[settings[name]] }

        missing = %w[key_id_env issuer_id_env].reject { |name| value.call(name) }.map { |name| settings[name] }
        content = value.call("key_content_env")
        path = value.call("key_path_env")
        missing << "#{settings['key_content_env']} or #{settings['key_path_env']}" unless content || path
        UI.user_error!("App Store Connect API key not configured, set: #{missing.join(', ')}") unless missing.empty?

        options = { key_id: value.call("key_id_env"), issuer_id: value.call("issuer_id_env") }
        return options.merge(key_content: content) if content

        expanded = File.expand_path(path)
        UI.user_error!("#{settings['key_path_env']} points to a file that doesn't exist") unless File.exist?(expanded)
        options.merge(key_filepath: expanded)
      end

      # The version live on the App Store, nil when there is none yet (first release, a
      # staging app). Asks Spaceship directly instead of `latest_testflight_build_number(live:
      # true)`, which raises for "nothing live" exactly like it does for an expired key: a
      # caller that rescues one rescues both, and a version that is actually live then never
      # gets its patch bump.
      def app_store_live_version(app_identifier:, api_key: nil)
        require "spaceship"

        Spaceship::ConnectAPI.token = Spaceship::ConnectAPI::Token.from(hash: api_key) if api_key
        app = Spaceship::ConnectAPI::App.find(app_identifier)
        UI.user_error!("Could not find #{app_identifier} on App Store Connect") unless app

        app.get_live_app_store_version(platform: Spaceship::ConnectAPI::Platform::IOS)&.version_string
      end
    end
  end
end
