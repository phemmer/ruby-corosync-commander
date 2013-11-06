require 'corosync/cpg'
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
#     enum.each do |response, node|
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

	# Creates a new instance and connects to CPG.
	# If a group name is provided, it will join that group. Otherwise it will only connect. This is so that you can establish the command callbacks and avoid NotImplementedError exceptions
	# @param group_name [String] Name of the group to join
	def initialize(group_name = nil)
		@cpg = Corosync::CPG.new
		@cpg.on_message {|*args| cpg_message(*args)}
		@cpg.on_confchg {|*args| cpg_confchg(*args)}
		@cpg.connect
		@cpg.fd.close_on_exec = true

		@cpg_members = nil

		# we can either share the msgid counter across all threads, or have a msgid counter on each thread and send the thread ID with each message. I prefer the former
		@next_execution_id = 0
		@next_execution_id_mutex = Mutex.new

		@execution_queues = {}
		@execution_queues.extend(Sync_m)

		@command_callbacks = CorosyncCommander::CallbackList.new

		@dispatch_thread = Thread.new do
			Thread.current.abort_on_exception = true
			loop do
				@cpg.dispatch
			end
		end

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

	# Shuts down the dispatch thread and disconnects CPG
	# @return [void]
	def stop
		@dispatch_thread.kill
		@dispatch_thread = nil
		@cpg.disconnect
		@cpg = nil
		@cpg_members = nil
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

		if sender == @cpg.member || message.recipients.include?(@cpg.member)
			execution_queue = nil
			@execution_queues.sync_synchronize(:SH) do
				execution_queue = @execution_queues[message.execution_id]
			end
			if !execution_queue.nil? then
				# someone is listening
				if sender == @cpg.member and message.type == 'command' then
					# the Execution object needs a list of the members at the time it's message was received
					message_echo = message.dup
					message_echo.type = 'echo'
					message_echo.content = @cpg_members
					execution_queue << message_echo
				else
					execution_queue << message
				end
			end
		end

		if message.recipients.size > 0 and !message.recipients.include?(@cpg.member) then
			return
		end

		if message.type == 'command' then
			# we received a command from another node
			begin
				# see if we've got a registered callback
				command_callback = nil

				command_name = message.content[0]
				command_callback = @command_callbacks[command_name]
				if command_callback.nil? then
					raise NotImplementedError, "No callback registered for command '#{command_name}'"
				end

				command_args = message.content[1]
				reply_value = command_callback.call(*command_args)
				message_reply = message.reply(reply_value)
				@cpg.send(message_reply)
			rescue => e
				message_reply = message.reply([e.class, e.to_s, e.backtrace])
				message_reply.type = 'exception'
				@cpg.send(message_reply)
			end
		end
	end

	# @!visibility private
	def cpg_confchg(member_list, left_list, join_list)
		@cpg_members = member_list

		# we look for any members leaving the cluster, and if so we notify all threads that are waiting for a response that they may have just lost a node
		return if left_list.size == 0

		messages = left_list.map do |member|
			CorosyncCommander::Execution::Message.new(:sender => member, :type => 'leave')
		end

		@execution_queues.sync_synchronize(:SH) do
			@execution_queues.each do |queue|
				messages.each do |message|
					queue << message
				end
			end
		end
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
end
