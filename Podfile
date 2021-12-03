platform :osx, '11.4'
inhibit_all_warnings!
use_frameworks!

def shared_pods
  pod 'Web3Swift.io', :git => 'https://github.com/zeriontech/Web3Swift.git', :branch => 'develop'
  pod 'BlockiesSwift'
  pod 'Kingfisher'
  pod 'WalletConnect', git: 'https://github.com/grachyov/wallet-connect-swift', branch: 'master'
  pod 'TrustWalletCore'
end

target 'Tokenary' do
  shared_pods
end

target 'Tokenary iOS' do
  shared_pods
end
