Pod::Spec.new do |s|
  s.name = 'flutter_zyren_audio'
  s.version = '0.1.0'
  s.summary = 'Audio focus policy for Flutter playback hosts.'
  s.description = 'AVAudioSession focus and route notifications for native playback.'
  s.homepage = 'https://github.com/xraph'
  s.license = { :type => 'Unspecified' }
  s.author = 'Rex Raphael'
  s.source = { :path => '.' }
  s.source_files = 'Classes/**/*.swift'
  s.dependency 'Flutter'
  s.platform = :ios, '14.0'
  s.swift_version = '5.0'
  s.frameworks = 'AVFAudio'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
