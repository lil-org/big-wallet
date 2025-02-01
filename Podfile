inhibit_all_warnings!
use_frameworks!

def shared_pods
  pod 'BigInt'
  pod 'Kingfisher'
  pod 'TrustWalletCore'
end

target 'Big Wallet' do
  platform :osx, '14.0'
  shared_pods
end

target 'Big Wallet iOS' do
  platform :ios, '17.0'
  shared_pods
end

target 'Big Wallet visionOS' do
  platform :visionos, '1.0'
  pod 'Kingfisher'
  pod 'VBigInt', :git => 'https://github.com/grachyov/BigInt.git', :branch => 'master'
end

post_install do |installer|
  installer.generated_projects.each do |project|
    project.build_configurations.each do |config|
      project.targets.each do |target|
        if target.platform_name == :ios
          target.build_configurations.each do |config|
            config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '17.0'
          end
        elsif target.platform_name == :osx
          target.build_configurations.each do |config|
            config.build_settings['MACOSX_DEPLOYMENT_TARGET'] = '14.0'
          end
        elsif target.platform_name == :visionos
          target.build_configurations.each do |config|
            config.build_settings['VISIONOS_DEPLOYMENT_TARGET'] = '1.0'
          end
        end
      end
    end
  end
end
