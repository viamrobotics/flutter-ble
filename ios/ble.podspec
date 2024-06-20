#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint ble.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'ble'
  s.version          = '0.0.1'
  s.summary          = 'A Flutter plugin project for BLE (Bluetooth Low Energy) operations.'
  s.description      = <<-DESC
A new Flutter plugin project.
                       DESC
  s.homepage         = 'https://viam.com'
  s.license          = { :file => '../../../../../../../LICENSE' }
  s.author           = { 'First Last' => 'first.last@viam.com' }
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.10' 
end
