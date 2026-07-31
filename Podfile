# Uncomment the next line to define a global platform for your project
platform :macos, '10.15'

target 'MidiMapper' do
  # Comment the next line if you don't want to use dynamic frameworks
#  use_frameworks!

  # Pods for MidiMapper
  pod 'MIKMIDI'
end

target 'MidiMapperTests' do
  inherit! :search_paths
end

# MIKMIDI's podspec still declares macOS 10.8. Keep all generated Pods targets
# aligned with the app's supported macOS version to avoid deployment-target warnings.
post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['MACOSX_DEPLOYMENT_TARGET'] = '11.0'
    end
  end
end
