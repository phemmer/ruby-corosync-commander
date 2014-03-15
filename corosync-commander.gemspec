Gem::Specification.new 'corosync-commander', File.read('VERSION').chomp do |s|
	s.description = 'Provides a simplified interface for issuing commands to nodes in a Corosync closed process group.'
	s.summary = 'Sends/receives Corosync CPG commands'
	s.homepage = 'http://github.com/phemmer/ruby-corosync-commander/'
	s.author = 'Patrick Hemmer'
	s.email = 'patrick.hemmer@gmail.com'
	s.license = 'MIT'
	s.files = %x{git ls-files}.split("\n")

	s.add_runtime_dependency 'corosync', '~> 0.2.0'
end
