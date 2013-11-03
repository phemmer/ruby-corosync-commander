require File.expand_path('../lib/version.rb', __FILE__)

Gem::Specification.new 'corosync-commander', CorosyncCommander::GEM_VERSION do |s|
	s.description = 'Provides a simplified interface for issuing commands to nodes in a corosync closed process group'
	s.summary = 'Sends/receives commands from Corosync CPG nodes'
	s.authors = [ 'Patrick Hemmer' ]
	s.homepage = 'http://github.com/phemmer/ruby-corosync-commander/'
	s.files = %x{git ls-files}.split("\n")

	s.add_dependency 'corosync', '~> 0.0'
end
