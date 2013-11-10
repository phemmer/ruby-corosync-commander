########################################
desc 'Run tests'
require 'rspec/core/rake_task'
RSpec::Core::RakeTask.new(:test) do |t|
	ENV['RUBY_THREAD_MACHINE_STACK_SIZE'] = '1572864'
	t.pattern = 'spec/**/*.rb'
	t.rspec_opts = '-c -f d --fail-fast'
end


########################################
@gemspec_file = Dir.glob('*.gemspec').first
def spec
	require 'rubygems' unless defined? Gem::Specification
	@spec ||= eval(File.read(@gemspec_file))
end

desc 'Bump version'
task 'version' do
	file = 'lib/version.rb'
	const = 'CorosyncCommander::GEM_VERSION'

	current_version = %x{ruby -e "require './#{file}'; puts #{const}"}.chomp
	current_version_commit = %x{git rev-parse --verify #{current_version} 2>/dev/null}.chomp
	current_head_commit = %x{git rev-parse HEAD}.chomp
	if current_version_commit != '' and current_version_commit != current_head_commit then
		# there have been commits since the current version

		next_version = current_version.split('.')
		next_version[-1] = next_version.last.to_i + 1
		next_version = next_version.join('.')
		print "Next version? (#{next_version}): "
		response = STDIN.gets.chomp
		if response != '' then
			raise StandardError, "Not a valid version" unless response.match(/^[0-9\.]$/)
			next_version = response
		end

		const_name = const.sub(/^.+:/, '')
		new_file_content = ''
		File.open(file, 'r') do |file|
			file.each_line do |line|
				new_file_content += line.sub(/(#{const_name}\s*=\s*['"])#{current_version}(['"])/, "\\1#{next_version}\\2")
			end
		end
		File.open(file, 'w') do |file|
			file.write new_file_content
		end
		message = %x{git log #{current_version_commit}..HEAD --pretty=format:'* %s%n  %an (%ai) - @%h%n'}.gsub(/'/, "'\\\\''")

		sh "git commit -m 'Version: #{next_version}\n\n#{message}' #{file}"

		@spec = nil
	end
end

desc 'Build gem file'
task 'build' do
	sh "gem build #{@gemspec_file}"
end

desc 'Publish gem file'
task 'publish' do
	gem_file = "#{spec.name}-#{spec.version}.gem"
	sh "git tag #{spec.version}"
	sh "git push"
	sh "gem push #{gem_file}"
end

desc 'Release a new version'
task 'release' do
	raise StandardError, "Not on master branch" if %x{git rev-parse --abbrev-ref HEAD}.chomp != "master"
	raise StandardError, "Uncommitted files" if %x{git status --porcelain}.chomp.size != 0

	[:test, :version, :build, :publish].each do |task|
		puts "# #{task}\n"
		Rake::Task[task].execute
		puts "\n"
	end
end
