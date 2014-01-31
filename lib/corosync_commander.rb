require 'corosync/cpg'
require 'corosync/quorum'
require File.expand_path('../corosync_commander/execution', __FILE__)
require File.expand_path('../corosync_commander/execution/message', __FILE__)
require File.expand_path('../corosync_commander/callback_list', __FILE__)

# This provides a simplified interface into Corosync::CPG.
# The main use case is for sending commands to a remote server, and waiting for the responses.
# 
# This library takes care of:
# * Ensuring a consistent message format.
# * Sending messages to all, or just specific nodes.
# * Invoking the appropriate callback (and passing parameters) based on the command sent.
# * Resonding with the return value of the callback.
# * Handling exceptions and sending them back to the sender.
# * Knowing exactly how many responses should be coming back.
#
# @example
#   cc = CorosyncCommander.new
#   cc.commands.register('shell command') do |shellcmd|
#     %x{#{shellcmd}}
#   end
#   cc.join('my group')
#
#   exe = cc.execute([], 'shell command', 'hostname')
#
#   enum = exe.to_enum
#   hostnames = []
#   begin
#     enum.each do |node, response|
#       hostnames << response
#     end
#   rescue CorosyncCommander::RemoteException => e
#     puts "Caught remote exception: #{e}"
#     retry
#   end
#
#   puts "Hostnames: #{hostnames.join(' ')}"
#
#
# == IMPORTANT: Will not work without tuning ruby.
# You cannot use this with MRI Ruby older than 2.0. Even with 2.0 you must tune ruby. This is because Corosync CPG (as of 1.4.3) allocates a 1mb buffer on the stack. Ruby 2.0 only allocates a 512kb stack for threads. This gem uses a thread for handling incoming messages. Thus if you try to use older ruby you will get segfaults.
#
# Ruby 2.0 allows increasing the thread stack size. You can do this with the RUBY_THREAD_MACHINE_STACK_SIZE environment variable. The advised value to set is 1.5mb.
#   RUBY_THREAD_MACHINE_STACK_SIZE=1572864 ruby yourscript.rb
class CorosyncCommander
	require 'thread'
	require 'sync'
	require 'json'

	attr_reader :cpg

	attr_reader :execution_queues

	# @!visibility private
	attr_reader :dispatch_thread

	# Creates a new instance and connects to CPG.
	# If a group name is provided, it will join that group. Otherwise it will only connect. This is so that you can establish the command callbacks and avoid NotImplementedError exceptions
	# @param group_name [String] Name of the group to join
	def initialize(group_name = nil)
		@cpg = Corosync::CPG.new
		@cpg.on_message {|*args| cpg_message(*args)}
		@cpg.on_confchg {|*args| cpg_confchg(*args)}
		@cpg.connect
		@cpg.fd.close_on_exec = true

		@quorum = Corosync::Quorum.new
		@quorum.on_notify {|*args| quorum_notify(*args)}
		@quorum.connect
		@quorum.fd.close_on_exec = true

		@cpg_members = nil

		@leader_pool = []
		@leader_pool.extend(Sync_m)

		# we can either share the msgid counter across all threads, or have a msgid counter on each thread and send the thread ID with each message. I prefer the former
		@next_execution_id = 0
		@next_execution_id_mutex = Mutex.new

		@execution_queues = {}
		@execution_queues.extend(Sync_m)

		@command_callbacks = CorosyncCommander::CallbackList.new

		if RUBY_ENGINE == 'ruby' and (Gem::Version.new(RUBY_VERSION) < Gem::Version.new('2.0.0') or ENV['RUBY_THREAD_MACHINE_STACK_SIZE'].to_i < 1572864) then
			abort "MRI Ruby must be >= 2.0 and RUBY_THREAD_MACHINE_STACK_SIZE must be > 1572864"
		end

		@dispatch_thread = Thread.new do
			Thread.current.abort_on_exception = true
			loop do
				select_ready = select([@cpg.fd, @quorum.fd], [], [])
				if select_ready[0].include?(@cpg.fd) then
					@cpg.dispatch
				end
				if select_ready[0].include?(@quorum.fd) then
					@quorum.dispatch
				end
			end
		end

		@quorum.start(true)
		if group_name then
			join(group_name)
		end
	end

	# Joins the specified group.
	# This is provided separate from initialization so that callbacks can be registered before joining the group so that you wont get NotImplementedError exceptions
	# @param group_name [String] Name of group to join
	# @return [void]
	def join(group_name)
		@cpg.join(group_name)
	end

	# Leave the active CPG group.
	# Will not stop quorum notifications. If you wish to stop quorum as well you should use {#stop} instead.
	# @return [void]
	def leave
		@cpg.leave
	end

	# Shuts down the dispatch thread and disconnects CPG
	# @return [void]
	def stop
		@dispatch_thread.kill if !@dispatch_thread.nil?
		@dispatch_thread = nil

		@cpg.close if !@cpg.nil?
		@cpg = nil
		@cpg_members = nil

		@quorum.finalize if !@quorum.nil?
		@quorum = nil
	end

	def next_execution_id()
		id = nil
		@next_execution_id_mutex.synchronize do
			id = @next_execution_id += 1
		end
		id
	end
	private :next_execution_id

	# Used as a callback on receipt of a CPG message
	# @param message [String] data structure passed to @cpg.send
	#   * message[0] == [Array<String>] Each string is "nodeid:pid" of the intended message recipients
	#   * msgid == [Integer]
	#     * In the event of a new message, this, combined with `member` will uniquely identify this message
	#     * In the event of a reply, this is the message ID sent in the original message
	#   * type == [String] command/response/exception
	#   * args == [Array]
	#     * In the event of a command, this will be the arguments passed to CorosyncCommander.send
	#     * In the event of a response, this will be the return value of the command handler
	#     * In the event of an exception, this will be the exception string and backtrace
	# @param sender [Corosync::CPG::Member] Sender of the message
	# @!visibility private
	def cpg_message(message, sender)
		message = CorosyncCommander::Execution::Message.from_cpg_message(message, sender)

		# This is the possible message classifications
		# Command echo (potentially also a command to us)
		# Response echo
		# Command to us
		# Response to us
		# Command to someone else
		# Response to someone else

		if message.type == 'command' and sender == @cpg.member then
			# It's a command echo
			execution_queue = nil
			@execution_queues.sync_synchronize(:SH) do
				execution_queue = @execution_queues[message.execution_id]
			end
			if !execution_queue.nil? then
				# someone is listening
				message_echo = message.dup
				message_echo.type = 'echo'
				message_echo.content = @cpg_members
				execution_queue << message_echo
			end
		elsif message.type != 'command' and message.recipients.include?(@cpg.member) then
			# It's a response to us
			execution_queue = nil
			@execution_queues.sync_synchronize(:SH) do
				execution_queue = @execution_queues[message.execution_id]
			end
			if !execution_queue.nil? then
				# someone is listening
				execution_queue << message
			end
		end

		if message.type == 'command' and (message.recipients.size == 0 or message.recipients.include?(@cpg.member)) then
			# It's a command to us
			begin
				# see if we've got a registered callback
				command_callback = nil

				command_name = message.content[0]
				command_callback = @command_callbacks[command_name]
				if command_callback.nil? then
					raise NotImplementedError, "No callback registered for command '#{command_name}'"
				end

				command_args = message.content[1]
				reply_value = command_callback.call(message.sender, *command_args)
				message_reply = message.reply(reply_value)
				@cpg.send(message_reply)
			rescue => e
				$stderr.puts "Exception: #{e} (#{e.class})\n#{e.backtrace.join("\n")}"
				message_reply = message.reply([e.class, e.to_s, e.backtrace])
				message_reply.type = 'exception'
				@cpg.send(message_reply)
			end
		end
	end

	# @!visibility private
	def cpg_confchg(member_list, left_list, join_list)
		@cpg_members = member_list

		if leader_position == -1 then # this will only happen on join
			@leader_pool.sync_synchronize(:EX) do
				@leader_pool.replace(member_list.to_a)
			end
		elsif left_list.size > 0 then
			@leader_pool.sync_synchronize(:EX) do
				@leader_pool.delete_if {|m| left_list.include?(m)}
			end
		end

		@confchg_callback.call(member_list, left_list, join_list) if @confchg_callback

		# we look for any members leaving the cluster, and if so we notify all threads that are waiting for a response that they may have just lost a node
		return if left_list.size == 0

		messages = left_list.map do |member|
			CorosyncCommander::Execution::Message.new(:sender => member, :type => 'leave')
		end

		@execution_queues.sync_synchronize(:SH) do
			@execution_queues.values.each do |queue|
				messages.each do |message|
					queue << message
				end
			end
		end
	end

	# Callback to execute when the CPG configuration changes
	# @yieldparam node_list [Array<Integer>] List of node IDs in group after change
	# @yieldparam left_list [Array<Integer>] List of node IDs which left the group
	# @yieldparam join_list [Array<Integer>] List of node IDs which joined the group
	def on_confchg(&block)
		@confchg_callback = block
	end

	# @!visibility private
	def quorum_notify(quorate, node_list)
		@quorumchg_callback.call(quorate, node_list) if @quorumchg_callback
	end

	# Callback to execute when the quorum state changes
	# @yieldparam quorate [Boolean] Whether cluster is quorate
	# @yieldparam member_list [Array] List of node IDs in the cluster after change
	def on_quorumchg(&block)
		@quorumchg_callback = block
	end

	# @!attribute [r] commands
	# @return [CorosyncCommander::CallbackList] List of command callbacks
	def commands
		@command_callbacks
	end

	# Execute a remote command.
	# @param recipients [Array<Corosync::CPG::Member>] List of recipients to send to, or an empty array to broadcast to all members of the group.
	# @param command [String] The name of the remote command to execute. If no such command exists on the remote node a NotImplementedError exception will be raised when enumerating the results.
	# @param args Any further arguments will be passed to the command callback on the remote host.
	# @return [CorosyncCommander::Execution]
	def execute(recipients, command, *args)
		execution = CorosyncCommander::Execution.new(self, next_execution_id, recipients, command, args)

		message = CorosyncCommander::Execution::Message.new(:recipients => recipients, :execution_id => execution.id, :type => 'command', :content => [command, args])

		@execution_queues.synchronize(:EX) do
			@execution_queues[execution.id] = execution.queue
		end
		# Technique stolen from http://www.mikeperham.com/2010/02/24/the-trouble-with-ruby-finalizers/
		#TODO We definitately need a spec test to validate the execution object gets garbage collected
		ObjectSpace.define_finalizer(execution, execution_queue_finalizer(execution.id))

		@cpg.send(message)

		execution
	end
	# This is so that we remove our queue from the execution queue list when we get garbage collected.
	def execution_queue_finalizer(execution_id)
		proc do
			@execution_queues.synchronize(:EX) do
				@execution_queues.delete(execution_id)
			end
		end
	end
	private :execution_queue_finalizer

	# Gets the member's position in the leadership queue.
	# The leadership position is simply how many nodes currently in the group were in the group before we joined.
	# @return [Integer]
	def leader_position
		@leader_pool.synchronize(:SH) do
			@leader_pool.size - 1
		end
	end

	# Indicates whether we are the group leader.
	# If we are the leader, it means that we are the oldest member of the group.
	# This is slightly different than just calling `leader_position == 0` in that if it is -1 (meaning we havent received the CPG confchg callback yet), we wait for the CPG join to complete.
	# @return [Boolean]
	def leader?
		position = nil
		loop do
			position = leader_position
			break if position != -1
			Thread.pass # let the dispatch thread run so we can get our join message
			# This isn't ideal as if the dispatch thread doesn't immediatly complete the join, we start spinning.
			# But the only other way is to use condition variables, which combined with Sync_m, would just be really messy and stupidly complex (and I don't want to go to a plain mutex and lose the ability to use shared locks).
		end
		position == 0
	end

	# List of current members
	# @return [Array<Corosync::CPG::Member>] List of members currently in the group
	def members
		@cpg_members
	end
end
