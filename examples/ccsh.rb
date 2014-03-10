#!/usr/bin/env ruby
# This is a more heavyweight example of the remote_commands example.
# It utilizes additional features such as quorum. It follows the same principles though, and you can launch it as many times as you want to play with it.

if RUBY_ENGINE == 'ruby' and ENV['RUBY_THREAD_MACHINE_STACK_SIZE'].to_i < 1572864 then
	ENV['RUBY_THREAD_MACHINE_STACK_SIZE'] = '1572864'
	exec('ruby', $0, *ARGV)
end

require 'rubygems'
require 'bundler/setup'

$:.unshift(File.expand_path('../../lib', File.realpath(__FILE__)))

require 'corosync_commander'
require 'timeout'
require 'readline'

class CCSH
	def initialize
		@cc = CorosyncCommander.new
		@cc.commands.register 'sh', &self.method(:cc_sh)
		@cc.on_confchg &self.method(:cc_confchg)
		@cc.on_quorumchg &self.method(:cc_quorumchg)

		@cc.join('ccsh')
	end

	def cc_sh(sender, command)
		output = nil
		status = nil
		begin
			Timeout::timeout(10) do
				output = %x{#{command}}
				status = $?.exitstatus
			end
		rescue Timeout::Error => e
			output = 'Command timed out'
			status = 255
		end

		[status, output]
	end

	def cc_confchg(members, left, joined)
		$stderr.puts "Group membership changed"
		$stderr.puts "Members: #{members.map{|m| m.to_s}.join(' ')}" if members.size > 0
		$stderr.puts "Lost: #{left.map{|m| m.to_s}.join(' ')}" if left.size > 0
		$stderr.puts "Joined: #{joined.map{|m| m.to_s}.join(' ')}" if joined.size > 0
		$stderr.puts ""
	end

	def cc_quorumchg(quorate, members)
		msg = quorate ? "gained" : "lost"
		$stderr.puts "Quorum #{msg}"
		$stderr.puts ""
	end

	def run
		while line = Readline.readline('> ', true) do
			line.chomp!

			if line.match(/^!\s*(.*)/) then
				# internal command
				command = $1
				if command == 'leaders' then
					leader_pool = @cc.instance_variable_get(:@leader_pool)
					$stdout.write(leader_pool.map{|m| m.to_s}.join("\n") + "\n")
				elsif command == 'whoami' then
					$stdout.write(@cc.cpg.member.to_s + "\n")
				elsif command == 'exit' then
					exit
				end
			else
				# remote command
				exe = @cc.execute([], 'sh', line)
				exe.to_enum.each do |sender, result|
					status, output = result
					output.split("\n").each do |line|
						$stdout.write("#{sender}: #{line}\n")
					end
				end
			end

			$stdout.write("\n")
		end
	end
end

ccsh = CCSH.new
ccsh.run
