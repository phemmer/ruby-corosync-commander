require File.expand_path('../lib/version.rb', __FILE__)

Gem::Specification.new 'corosync-commander', CorosyncCommander::GEM_VERSION do |s|
	s.description = 'Provides a simplified interface for issuing commands to nodes in a Corosync closed process group.'
	s.summary = 'Sends/receives Corosync CPG commands'
	s.homepage = 'http://github.com/phemmer/ruby-corosync-commander/'
	s.author = 'Patrick Hemmer'
	s.email = 'patrick.hemmer@gmail.com'
	s.license = 'MIT'
	s.files = %x{git ls-files}.split("\n")

	s.add_runtime_dependency 'corosync', '~> 0.0.3'
end
