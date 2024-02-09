inhibit_all_warnings!
use_frameworks!

def shared_pods
  pod 'BigInt'
  pod 'Kingfisher'
  pod 'TrustWalletCore'
end

target 'Wallet macOS' do
  platform :osx, '12.0'
  shared_pods
end

target 'Wallet iOS' do
  platform :ios, '15.0'
  shared_pods
end

post_install do |installer|
  installer.generated_projects.each do |project|
    project.build_configurations.each do |config|
      project.targets.each do |target|
        if target.platform_name == :ios
          target.build_configurations.each do |config|
            config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'
          end
        elsif target.platform_name == :osx
          target.build_configurations.each do |config|
            config.build_settings['MACOSX_DEPLOYMENT_TARGET'] = '12.0'
          end
        end
      end
    end
  end
end
