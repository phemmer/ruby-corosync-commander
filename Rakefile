########################################
desc 'Run tests'
require 'rspec/core/rake_task'
RSpec::Core::RakeTask.new(:test) do |t|
	ENV['RUBY_THREAD_MACHINE_STACK_SIZE'] = '1572864'
	t.pattern = 'spec/**/*.rb'
	t.rspec_opts = '-c -f d --fail-fast'
end
