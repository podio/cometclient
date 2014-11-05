Pod::Spec.new do |s|
  s.name         = "DDCometClient"
  s.version      = "1.0.1"
  s.summary      = "Objective-C comet client using the Bayeux protocol"
  s.homepage     = "https://github.com/sebreh/cometclient"
  s.license      = 'MIT'
  s.author       = { 'Dave Dunkin' => 'me@davedunkin.com', 'Sebastian Rehnby' => 'sebastian@rehnby.com' }

  s.source       = { :git => "https://github.com/sebreh/cometclient.git", :tag => s.version.to_s }

  s.source_files = 'DDComet/**/*.{h,m}'
  s.requires_arc = false
  
  s.frameworks   = 'Security'
end
