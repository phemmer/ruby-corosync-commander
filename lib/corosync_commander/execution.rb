class CorosyncCommander
end
class CorosyncCommander::Execution
	attr_reader :queue
	attr_reader :id
	attr_reader :recipients
	attr_reader :command
	attr_reader :args
	attr_reader :pending_members

	def initialize(cc, id, recipients, command, args)
		@cc = cc
		@id = id
		@recipients = Corosync::CPG::MemberList.new(recipients)
		@command = command
		@args = args

		@queue = Queue.new

		@pending_members = nil

		@responses = []
	end

	# Gets the next response, blocking if none has been returned yet.
	# This will also raise an exception if the remote process raised an exception. This can be tested by calling `exception.is_a?(CorosyncCommander::RemoteException)`
	# @return [CorosyncCommander::Execution::Message] The response from the remote host. Returns `nil` when there are no more responses.
	def response
		response = get_response

		return nil if response.nil?

		if response.type == 'exception'
			e_class = Kernel.const_get(response.content[0])
			e_class = StandardError if e_class.nil? or !(e_class <= Exception) # The remote node might have types we don't have. So if we don't have them use StandardError
			e = e_class.new(response.content[1] + " (CorosyncCommander::RemoteException@#{response.sender})")
			e.set_backtrace(response.content[2])
			e.extend(CorosyncCommander::RemoteException)
			e.sender = response.sender
			raise e
		end

		response
	end
	alias_method :next, :response

	# Provides an enumerator that can be looped through.
	# Will raise an exception if the remote node generated an exception. Can be verified by calling `is_a?(CorosyncCommander::RemoteException)`.
	# Restarting the enumerator will not restart from the first response, it will continue on to the next.
	# @yieldparam response [Object] The response generated by the remote command.
	# @yieldparam sender [Corosync::CPG::Member] The node which generated the response.
	# @return [Enumerator]
	def to_enum(ignore_exception = false)
		Enumerator.new do |block|
			begin
				while response = self.response do
					block.yield response.content, response.sender
				end
			rescue CorosyncCommander::RemoteException => e
				raise e unless ignore_exception
				retry
			end
		end
	end

	# Wait for all responses to come in, but discard them.
	# Useful to block waiting for the remote commands to finish when you dont care about the result.
	# @param ignore_exception [Boolean] Whether to ignore remote exceptions, or raise them. If `true`, remote exceptions will not raise an exception here.
	# @return [Boolean] Returns `true` if no exceptions were raised, `false` otherwise.
	def wait(ignore_exception = false)
		success = true
		begin
			while response do end
		rescue CorosyncCommander::RemoteException => e
			success = false
			retry if ignore_exception
			raise e
		end
		success
	end

	# This is just so that we can remove the queue from execution_queues and avoid running unnecessary code on receipt of message/confchg
	def discard
		@cc.execution_queues.sync_synchronize(:EX) do
			@cc.execution_queues.delete(@id)
		end
		@queue.clear
		@queue = []
	end

	# Gets the next response message from the queue.
	# This is used internally and is probably not what you want. See {#response}
	# @return [CorosyncCommander::Execution::Message]
	def get_response
		return if !@queue.is_a?(Queue) # we've called `clear`

		while @pending_members.nil?
			message = @queue.shift

			next if message.type == 'leave' # we havent received the echo, so we dont care yet

			raise RuntimeError, "Received unexpected response while waiting for echo" if message.type != 'echo'

			@pending_members = @recipients.size == 0 ? message.content.dup : message.content & @recipients
		end

		return if @pending_members.size == 0

		message = @queue.shift

		@pending_members.delete message.sender
		if @pending_members.size == 0 then
			self.discard
		end

		return if message.type == 'leave' # we already did @pending_members.delete above

		message
	end
end

module CorosyncCommander::RemoteException
	# empty module that we use to extend remote exceptions with
end
