Pod::Spec.new do |s|
  s.name = 'zyren_xr'
  s.version = '0.1.0'
  s.summary = 'Native ARKit sessions for Zyren.'
  s.description = 'ARKit tracking, local anchors, planes and ambient light.'
  s.homepage = 'https://github.com/xraph'
  s.license = { :type => 'Unspecified' }
  s.author = 'Rex Raphael'
  s.source = { :path => '.' }
  s.source_files = 'Classes/**/*.swift'
  s.dependency 'Flutter'
  s.platform = :ios, '14.0'
  s.swift_version = '5.0'
  s.frameworks = 'ARKit', 'AVFoundation'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
