require "fileutils"
require "xcodeproj"

# A real Xcode project: an app and a notification extension, Debug / Release / StagingRelease,
# a shared "staging" scheme and a user-only "local" scheme.
module IosProject
  def self.create(root)
    path = File.join(root, "ios", "App.xcodeproj")
    FileUtils.mkdir_p(File.join(root, "ios", "App.xcworkspace"))
    project = Xcodeproj::Project.new(path)
    app = project.new_target(:application, "App", :ios, "15.0")
    extension = project.new_target(:app_extension, "NotificationService", :ios, "15.0")
    project.add_build_configuration("StagingRelease", :release)
    [app, extension].each { |target| target.add_build_configuration("StagingRelease", :release) }
    project.root_object.attributes["TargetAttributes"] = [app, extension].to_h { |target| [target.uuid, { "CreatedOnToolsVersion" => "16.0" }] }
    # Like Splitify: the app's Info.plist has a literal version and references the build number;
    # the extension's has neither, so both come from the build settings.
    { app => "App/Info.plist", extension => "NotificationService/Info.plist" }.each do |target, plist|
      target.build_configurations.each do |configuration|
        configuration.build_settings.merge!("INFOPLIST_FILE" => (target == app ? "$(SRCROOT)/#{plist}" : plist),
                                            "MARKETING_VERSION" => "1.0.0", "CURRENT_PROJECT_VERSION" => "4")
      end
    end
    project.save
    FileUtils.mkdir_p(File.join(root, "ios", "App"))
    FileUtils.mkdir_p(File.join(root, "ios", "NotificationService"))
    Xcodeproj::Plist.write_to_path({ "CFBundleName" => "App", "CFBundleShortVersionString" => "1.0.0", "CFBundleVersion" => "$(CURRENT_PROJECT_VERSION)" },
                                   File.join(root, "ios", "App", "Info.plist"))
    Xcodeproj::Plist.write_to_path({ "NSExtension" => { "NSExtensionPointIdentifier" => "com.apple.usernotifications.service" } },
                                   File.join(root, "ios", "NotificationService", "Info.plist"))

    scheme = Xcodeproj::XCScheme.new
    scheme.add_build_target(app)
    scheme.save_as(path, "staging", true)
    scheme.save_as(path, "local", false)
    path
  end

  def self.settings(path, target, configuration)
    Xcodeproj::Project.open(path).targets.find { |t| t.name == target }.build_configurations.find { |c| c.name == configuration }.build_settings
  end
end
