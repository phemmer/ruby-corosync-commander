########################################
desc 'Run tests'
require 'rspec/core/rake_task'
RSpec::Core::RakeTask.new(:test) do |t|
	t.pattern = 'spec/**/*.rb'
	t.rspec_opts = '-c -f d --fail-fast'
end
