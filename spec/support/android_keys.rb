require "fileutils"
require "open3"
require "tmpdir"

# Real keystores and signed bundles, generated once: keytool is the thing under test.
module AndroidKeys
  def self.dir
    @dir ||= Dir.mktmpdir("rn-ship-keys").tap do |dir|
      genkey(dir, "upload.jks", "upload", "upload-pass")
      genkey(dir, "debug.keystore", "androiddebugkey", "android")
      genkey(dir, "other.jks", "other", "other-pass")
      FileUtils.mkdir_p(File.join(dir, "content"))
      File.write(File.join(dir, "content", "base.txt"), "bundle")
      run!(%w[zip -q ../unsigned.aab base.txt], File.join(dir, "content"))
      { "upload.aab" => ["upload.jks", "upload", "upload-pass"],
        "debug.aab" => ["debug.keystore", "androiddebugkey", "android"],
        "other.aab" => ["other.jks", "other", "other-pass"] }.each do |aab, (store, key_alias, password)|
        FileUtils.cp(File.join(dir, "unsigned.aab"), File.join(dir, aab))
        run!(["jarsigner", "-keystore", store, "-storepass", password, aab, key_alias], dir)
      end
    end
  end

  def self.genkey(dir, file, key_alias, password)
    run!(["keytool", "-genkeypair", "-keystore", file, "-storepass", password, "-keypass", password, "-alias", key_alias,
          "-keyalg", "RSA", "-keysize", "2048", "-validity", "2", "-dname", "CN=#{key_alias}", "-noprompt"], dir)
  end

  def self.run!(command, dir)
    output, status = Open3.capture2e(*command, chdir: dir)
    raise "#{command.join(' ')} failed:\n#{output}" unless status.success?
  end

  def self.path(name)
    File.join(dir, name)
  end
end
