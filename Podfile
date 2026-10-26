source 'https://cdn.cocoapods.org/'
source 'https://github.com/tuya/tuya-pod-specs.git'
platform :ios, '15.0'
target 'ShuttleRef' do
 use_modular_headers!
 pod 'ThingSmartHomeKit', '7.8.0.6'
 pod 'ThingSmartCryption', :path => './ios_core_sdk'
end
post_install do |installer|
 installer.pods_project.targets.each do |target|
  target.build_configurations.each do |config|
   config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'
  end
 end
end
