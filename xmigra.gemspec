# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'xmigra/version'

Gem::Specification.new do |spec|
  spec.name          = "xmigra"
  spec.version       = XMigra::VERSION
  spec.authors       = ["Next IT Corporation", "Richard Weeks"]
  spec.email         = ["rtweeks21@gmail.com"]
  spec.summary       = %q{Toolkit for managing database schema evolution with version control.}
  spec.description   = <<-END
    XMigra is a suite of tools for managing database schema evolution with
    version controlled files.  All database manipulations are written in
    SQL (specific to the target database).  Works with Git or Subversion.
    Currently supports Microsoft SQL Server.
  END
  spec.homepage      = "https://github.com/rtweeks/xmigra"
  spec.license       = "CC-BY-SA 4.0 Itnl."

  spec.files         = `git ls-files -z`.split("\x0")
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.test_files    = ["test/runner.rb"]
  spec.require_paths = ["lib"]

  spec.add_development_dependency "bundler", "~> 1.5"
  spec.add_development_dependency "rake"
end
