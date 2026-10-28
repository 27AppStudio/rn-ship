# Writes what a deploy job needs from rn-ship.yml as step outputs: the flavor, its env file and
# the NAMES of the env vars the lanes read credentials from. Never a value. Reading the file
# through the plugin keeps one source of truth for every default.
#
# Usage: bundle exec ruby credential-names.rb <ios|android> [flavor]
require "fastlane"
require "fastlane/plugin/rn_ship"

platform, flavor_name = ARGV
abort("usage: credential-names.rb <ios|android> [flavor]") unless %w[ios android].include?(platform)

config = Fastlane::Helper::RnShipConfig.load
flavor = config.flavor_for(flavor_name)

outputs = {
  "flavor" => flavor.name,
  "env_file" => flavor.env_file ? config.expand(flavor.env_file) : "",
  "self_hosted_env" => config.ci["self_hosted_env"]
}
if platform == "ios"
  abort("rn-ship.yml has no ios section") unless config.ios
  keys = config.ios["app_store_connect"]
  outputs.merge!(
    "key_id_env" => keys["key_id_env"],
    "issuer_id_env" => keys["issuer_id_env"],
    "key_content_env" => keys["key_content_env"],
    "ios_dir" => File.dirname(config.expand(config.ios["project"]))
  )
else
  abort("rn-ship.yml has no android section") unless config.android
  outputs.merge!(
    "upload_key_prefix" => config.android["upload_key_prefix"],
    "json_key_env" => config.android["play"]["json_key_env"],
    "release_status_env" => config.android["play"]["release_status_env"]
  )
end

lines = outputs.map do |key, value|
  abort("#{key} contains a line break") if value.to_s.include?("\n")
  "#{key}=#{value}"
end
if ENV["GITHUB_OUTPUT"].to_s.empty?
  puts lines
else
  File.open(ENV["GITHUB_OUTPUT"], "a") { |file| file.puts(lines) }
end
