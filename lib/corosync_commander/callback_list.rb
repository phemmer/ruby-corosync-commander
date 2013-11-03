class CorosyncCommander::CallbackList
	include Enumerable

	def initialize
		@callbacks = {}
		@callbacks.extend(Sync_m)
	end

  # Iterate through each command/callback
  # @yieldparam command [String] Name of command
  # @yieldparam callback [Proc] Proc to be executed upon receiving command
	def each(&block)
		callbacks = nil
		@callbacks.synchronize(:SH) do
			callbacks = @callbacks.dup
		end
		callbacks.each(&block)
	end

  # Assign a callback
  # @example
  #   cc.commands['my command'] = Proc.new do
  #     puts "Hello world!"
  #   end
  # @param command [String] Name of command
  # @param block [Proc] Proc to call when command is executed
  # @return [Proc]
	def []=(command, block)
		@callbacks.synchronize(:EX) do
			@callbacks[command] = block
		end
		block
	end

  # Assign a callback
  # This is another method of assigning a callback
  # @example
  #   cc.commands.register('my command') do
  #     puts "Hellow world!"
  #   end
  # @param command [String] Name of command
  # @param block [Proc] Proc to call when command is executed
  # @return [Proc]
	def register(command, &block)
		self[command] = block
	end

  # Retrieve a registered command callback
  # @param command [String] Name of command
  # @return [Proc]
	def [](command)
		@callbacks.synchronize(:SH) do
			@callbacks[command]
		end
	end

  # Delete a command callback
  # @param command [String] Name of command
  # @return [Proc] The deleted command callback
	def delete(command)
		@callbacks.synchronize(:EX) do
			@callbacks.delete(command)
		end
	end
end
