Pod::Spec.new do |s|
  s.name         = "PBJVision"
  s.version      = "0.3.0"
  s.summary      = "iOS camera engine, supports touch-to-record video, slow motion video, and photo capture."
  s.homepage     = "https://github.com/piemonte/PBJVision"
  s.license      = "MIT"
  s.authors      = { "Patrick Piemonte" => "piemonte@alumni.cmu.edu" }
  s.source       = { :git => "https://github.com/smule/PBJVision.git" }
  s.frameworks   = 'Foundation', 'AVFoundation', 'CoreGraphics', 'CoreMedia', 'CoreVideo', 'MobileCoreServices', 'ImageIO', 'QuartzCore', 'OpenGLES', 'UIKit'
  s.platform     = :ios, '8.0'
  s.source_files = 'Source'
  s.resources    = 'Source/Shaders/*'
  s.requires_arc = true
  s.dependency 'client-magic/core'
  s.pod_target_xcconfig = { 'CLANG_WARN_UNGUARDED_AVAILABILITY' => 'YES' }
end
