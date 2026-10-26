require 'xcodeproj'
root = File.expand_path('..', __dir__)
Dir.chdir(root)
project = Xcodeproj::Project.new('ShuttleRef.xcodeproj')
app = project.new_target(:application, 'ShuttleRef', :ios, '15.0')
preview = project.new_target(:application, 'ShuttleRefPreview', :ios, '15.0')
ui_tests = project.new_target(:ui_test_bundle, 'ShuttleRefUITests', :ios, '15.0')
ui_tests.add_dependency(preview)
ui_tests.source_build_phase.add_file_reference(project.main_group.new_file('UITests/JourneyTests.swift'))
ui_tests.build_configurations.each do |config|
 config.build_settings.merge!({'SWIFT_VERSION'=>'5.0','GENERATE_INFOPLIST_FILE'=>'YES','PRODUCT_BUNDLE_IDENTIFIER'=>'com.yahabib.shuttleref.uitests','TEST_TARGET_NAME'=>'ShuttleRefPreview','TARGETED_DEVICE_FAMILY'=>'1','CODE_SIGN_STYLE'=>'Automatic'})
end
group = project.main_group.new_group('Sources')
Dir.glob('{App,Core,UI}/**/*.swift').sort.each do |path|
  ref = group.new_file(path)
  app.source_build_phase.add_file_reference(ref)
  preview.source_build_phase.add_file_reference(ref) unless path.end_with?('PairingViewController.swift')
end
Dir.glob('Resources/MVP/*.png').sort.each do |path|
 ref = group.new_file(path)
 [app, preview].each { |target| target.resources_build_phase.add_file_reference(ref) }
end
app.source_build_phase.add_file_reference(group.new_file('Local/AppKey.swift'))
local = project.main_group.new_file('Local/Signing.xcconfig')
project.build_configurations.each { |config| config.base_configuration_reference = local }
[app, preview].each do |target|
 target.build_configurations.each do |config|
  config.build_settings.merge!({
   'SWIFT_VERSION'=>'5.0', 'IPHONEOS_DEPLOYMENT_TARGET'=>'15.0',
   'TARGETED_DEVICE_FAMILY'=>'1', 'SUPPORTED_PLATFORMS'=>'iphoneos iphonesimulator',
   'SUPPORTS_MACCATALYST'=>'NO', 'SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD'=>'NO',
   'PRODUCT_BUNDLE_IDENTIFIER'=>target == app ? 'com.yahabib.shuttleref' : 'com.yahabib.shuttleref.preview',
   'GENERATE_INFOPLIST_FILE'=>'YES', 'INFOPLIST_KEY_CFBundleDisplayName'=>target == app ? '羽小裁' : '羽小裁预览',
   'INFOPLIST_KEY_UIApplicationSceneManifest_Generation'=>'YES',
   'INFOPLIST_KEY_UILaunchScreen_Generation'=>'YES',
   'INFOPLIST_KEY_UISupportedInterfaceOrientations'=>'UIInterfaceOrientationPortrait',
   'INFOPLIST_KEY_NSBluetoothAlwaysUsageDescription'=>'用于发现和配网你选择的羽小裁设备。',
   'INFOPLIST_KEY_NSCameraUsageDescription'=>'用于扫描树莓派设备二维码，将设备绑定到你选择的家庭。',
   'INFOPLIST_KEY_NSLocalNetworkUsageDescription'=>'用于连接同一网络中的羽小裁设备及本地组局服务器。',
   'INFOPLIST_FILE'=>config.name == 'Debug' ? 'App/Info-Debug.plist' : 'App/Info-Release.plist',
   'CODE_SIGN_STYLE'=>'Automatic', 'SWIFT_OPTIMIZATION_LEVEL'=>config.name == 'Debug' ? '-Onone' : '-O',
   'SWIFT_ACTIVE_COMPILATION_CONDITIONS'=>'$(inherited)' + (target == preview ? ' UI_PREVIEW' : '') + (config.name == 'Debug' ? ' DEBUG' : '')
  })
 end
 scheme = Xcodeproj::XCScheme.new
 scheme.add_build_target(target); scheme.set_launch_target(target)
 scheme.add_test_target(ui_tests) if target == preview
 scheme.save_as(project.path, target.name, true)
end
project.save
puts 'Generated ShuttleRef and SDK-free ShuttleRefPreview targets.'
