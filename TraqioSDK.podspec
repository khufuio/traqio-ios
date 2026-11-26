Pod::Spec.new do |s|
  s.name             = 'TraqioSDK'
  s.version          = '0.3.0'
  s.summary          = 'Traqio iOS SDK — mobile attribution + ROAS (SKAN + Apple Ads).'
  s.homepage         = 'https://traqio.app/docs/sdks/ios'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'khufu.io' => 'hello@khufu.io' }
  s.source           = { :git => 'https://github.com/khufuio/traqio-ios.git', :tag => s.version.to_s }
  s.ios.deployment_target = '14.0'
  s.swift_version    = '5.7'
  s.source_files     = 'Sources/TraqioSDK/**/*.swift'
  # AdServices is Apple Ads attribution (iOS 14.3+). Weak: the framework is absent on
  # 14.0-14.2, and TraqioAdServices is #if canImport-guarded + @available-gated, so a
  # hard link would refuse to launch on a device the deployment target still admits.
  s.frameworks       = 'StoreKit', 'UIKit'
  s.weak_frameworks  = 'AdServices'
end
