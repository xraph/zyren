Pod::Spec.new do |s|
  s.name = 'flutter_gpu3d'
  s.version = '0.1.0'
  s.summary = 'Native GPU texture presentation for Flutter.'
  s.description = s.summary
  s.homepage = 'https://github.com/xraph'
  s.license = { :type => 'Unspecified' }
  s.author = 'Rex Raphael'
  s.source = { :path => '.' }
  s.source_files = 'Classes/**/*.{h,mm}'
  s.public_header_files = 'Classes/Gpu3dPlugin.h'
  s.ios.dependency 'Flutter'
  s.osx.dependency 'FlutterMacOS'
  s.ios.deployment_target = '13.0'
  s.osx.deployment_target = '10.15'
  s.ios.frameworks = 'CoreVideo', 'Metal', 'QuartzCore', 'Flutter'
  s.osx.frameworks = 'CoreVideo', 'Metal', 'QuartzCore', 'FlutterMacOS'
  s.requires_arc = true
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17' }
end
