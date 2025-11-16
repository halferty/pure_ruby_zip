
lib = File.expand_path("../lib", __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "pure_ruby_zip/version"

Gem::Specification.new do |spec|
  spec.name          = "pure_ruby_zip"
  spec.version       = PureRubyZip::VERSION
  spec.authors       = ["Edward Halferty"]
  spec.email         = ["me@edwardhalferty.com"]

  spec.summary       = "A pure-Ruby ZIP file decompressor"
  spec.description   = %q(
    A pure-Ruby ZIP file decompressor with no external dependencies.
    Supports DEFLATE compression and provides comprehensive error handling,
    security protections, and a clean API for extracting ZIP archives.
  ).strip
  spec.homepage      = "https://github.com/ehalferty/pure_ruby_zip"
  spec.license       = "MIT"

  spec.bindir        = "bin"
  spec.executables   = ["pure-ruby-zip"]
  spec.require_paths = ["lib"]
  spec.required_ruby_version = ">= 2.5.0"

  spec.files = ["lib/pure_ruby_zip.rb", "lib/pure_ruby_zip/version.rb", "README.md", "LICENSE.txt"]

  # No runtime dependencies - pure Ruby!

  # Development dependencies
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "rspec", "~> 3.12"

  spec.metadata = {
    "bug_tracker_uri" => "https://github.com/ehalferty/pure_ruby_zip/issues",
    "source_code_uri" => "https://github.com/ehalferty/pure_ruby_zip",
  }
end
