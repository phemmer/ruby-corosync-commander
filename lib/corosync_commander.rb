require 'corosync/cpg'

class CorosyncCommander
	require 'thread'
	require 'sync'
	require 'json'

	attr_reader :cpg

	def initialize(group_name)
		@cpg = Corosync::CPG.new
		@cpg.on_message {|*args| cpg_message(*args)}
		@cpg.on_confchg {|*args| cpg_confchg(*args)}

		# we can either share the msgid counter across all threads, or have a msgid counter on each thread and send the thread ID with each message. I prefer the former
		@next_msgid = 0
		@next_msgid_mutex = Mutex.new

		@msgid_queues = {}
		@msgid_queues.extend(Sync_m)

		@command_callbacks = {}
		@command_callbacks.extend(Sync_m)

		@cpg.join(group_name)

		@dispatch_thread = Thread.new do
			Thread.current.abort_on_exception = true
			loop do
				@cpg.dispatch
			end
		end
	end

	def stop
		@dispatch_thread.kill
		@dispatch_thread = nil
		@cpg.disconnect
		@cpg = nil
	end

	def next_msgid()
		msgid = nil
		@next_msgid_mutex.synchronize do
			msgid = @next_msgid += 1
		end
		msgid
	end

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
		message = JSON.parse(message)
		recipients = message[0].map do |m|
			nodeid,pid = m.split(':').map{|i| i.to_i}
			Corosync::CPG::Member.new(nodeid,pid)
		end
		msgid = message[1]
		type = message[2]
		args = message[3..-1]

		if sender == @cpg.member and type == 'command' then
			# we've received our own message.
			# This is used so that when someone is expecting a response, they can get the @cpg.members list at the time the message was sent and know who exactly will be receiving it.

			# this is passed 
			msgid_queue = nil
			@msgid_queues.sync_synchronize(:SH) do
				msgid_queue = @msgid_queues[msgid]
			end
			# Here is where we take the snapshot of the current members and send it back in the 'echo' message'. This corresponds to the 'pending_members' code in #send
			msgid_queue.push [sender, 'echo', *@cpg.members.to_a] if !msgid_queue.nil?
		end

		if recipients.size > 0 and !recipients.include?(@cpg.member) then
			return
		end

		case(type)
		when 'response','exception'
			msgid_queue = nil
			@msgid_queues.sync_synchronize(:SH) do
				msgid_queue = @msgid_queues[msgid]
			end
			return if msgid_queue.nil? # nobody is listening

			msgid_queue.push [sender, type, *args]
		when 'command'
			# we received a command from another node
			begin
				# see if we've got a registered callback
				command_callback = nil
				@command_callbacks.sync_synchronize(:SH) do
					command_callback = @command_callbacks[args[0]]
				end
				if command_callback.nil? then
					raise NotImplementedError, "No callback registered for command '#{args[0]}'"
				end

				reply = command_callback.call(*args[1..-1])
				if !reply.nil? then
					@cpg.send([[sender], msgid, 'response', reply].to_json)
				end
			rescue => e
				@cpg.send([[sender], msgid, 'exception', e.class, e.to_s, e.backtrace].to_json)
			end
		end
	end

	def cpg_confchg(member_list, left_list, join_list)
		# we look for any members leaving the cluster, and if so we notify all threads that are waiting for a response that they may have just lost a node
		return if left_list.size == 0
		msgid_queues = nil
		@msgid_queues.sync_synchronize(:SH) do
			msgid_queues = @msgid_queues.dup
		end
		msgid_queues.each do |msgid,queue|
			left_list.each do |member|
				queue.push [member, 'leave']
			end
		end
	end

	def register(command, &block)
		@command_callbacks.sync_synchronize(:EX) do
			@command_callbacks[command] = block
		end
	end

	def send(recipients, *args, &block)
		if recipients.nil? or (recipients.is_a?(Array) and recipients.size == 0)
			recipients = []
		elsif !recipients.is_a?(Array)
			recipients = [recipients]
		end

		msgid = next_msgid

		if block.nil? then
			@cpg.send([recipients, msgid, 'command', *args].to_json)
			return
		end

		# `block` isn't nil, so the caller expects a response from the other nodes in the cluster

		# set up a queue for the cpg_message callback to add messages to
		# this has to be set up before calling `@cpg.send` or we might have a race condition where the 'echo' comes back and we haven't set up the queue to receive it
		queue = Queue.new
		@msgid_queues.synchronize(:EX) do
			@msgid_queues[msgid] = queue
		end
		begin
			@cpg.send([recipients, msgid, 'command', *args].to_json)

			# pending members is the list of members we are expecting a response from.
			pending_members = nil
			while pending_members.nil? do
				# here we wait for the 'echo' message (our own message sent back to us)
				# This is so that we can get all the members that were present at the time of the message so that we know who will be replying to a broadcast
				message = queue.shift
				message_sender = message[0]
				message_type = message[1]
				message_args = message[2..-1]
				if message_type == 'leave' then
					next # a node left the cluster, but we still havent received the echo, so we don't care
				end
				if message_type != 'echo' then
					# We received a message, but it's not an 'echo'. This should not have happened
					raise RuntimeError, "Received unexpected response while waiting for echo"
				end

				# message_args is the snapshot of @cpg.members taken in the cpg_message method
				# If we were a broadcast (recipients == []), then we set `recipients` to all the members that were present at the time of our message.
				# If we were sent to a specific list of recipients, we set `recipients` to all the target members that were present at the time of our message.
				pending_members = recipients.size == 0 ? message_args : message_args & recipients
			end

			while pending_members.size > 0 do
				message = queue.shift

				message_sender = message[0]
				message_type = message[1]
				message_args = message[2..-1] # this is the equivalent of the `args` parameter to this method. It's what we receive

				if message_type == 'exception' then
					e_class = Kernel.const_get(message_args[0])
					e_class = StandardError if e_class.nil? or !(e_class <= Exception)
					e = e_class.new(message_args[1] + " (CorosyncCommander::RemoteException)")
					e.set_backtrace(message_args[2])
					raise e
				end

				yield message_sender, *message_args

				pending_members.delete message_sender
			end
		ensure
			# remove ourself from the expected response queue
			@msgid_queues.synchronize(:EX) do
				@msgid_queues.delete(msgid)
			end
		end
	end
end
class CorosyncCommander::RemoteException < Exception
end
