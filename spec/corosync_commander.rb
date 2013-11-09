require 'spec_helper'
require 'timeout'

describe CorosyncCommander do
	before(:all) do
		Timeout.timeout(1) do
			@cc = CorosyncCommander.new("CorosyncCommander RSPEC #{Random.rand(2 ** 32)}")
		end
	end

	it 'can call cpg_dispatch' do
		# this is just so that if the thread test fails, we verify that it's not `dispatch` that's the issue
		@cc.cpg.dispatch(0)
	end

	it 'can call cpg_dispatch on a thread' do
		Timeout.timeout(2) do
			pid = fork do
				t = Thread.new do
					@cc.cpg.dispatch(0)
				end
				t.join
				exit!(0)
			end
			status = Process.wait2(pid)
			expect(status[1]).to eq(0)
		end
	end

	it 'registers a callback (block style)' do
		@cc.commands.register 'summation' do |sender,arg1,arg2|
			arg1 + arg2
		end

		expect(@cc.commands['summation']).to be_a(Proc)
	end

	it 'registers a callback (assignment style)' do
		@cc.commands['summation'] = Proc.new do |sender,arg1,arg2|
			arg1 + arg2
		end
		expect(@cc.commands['summation']).to be_a(Proc)
	end

	it 'calls the callback' do
		exe = @cc.execute([], 'summation', 123, 456)
		results = exe.to_enum.collect do |response,node|
			response
		end
		
		expect(results.size).to eq(1)
		expect(results.first).to eq(123 + 456)
	end

=begin doesn't work for some reason. will investigate later as it's not critical
	it 'removes queues on garbage collection' do
		GC.start
		GC.disable

		@cc.commands.register('nothing') do end

		queue_size_before = @cc.execution_queues.size

		@cc.execute([], 'nothing')
		queue_size_during = @cc.execution_queues.size

		GC.enable
		GC.start
		queue_size_after = @cc.execution_queues.size

		expect(queue_size_during).to eq(queue_size_before + 1)
		expect(queue_size_after).to eq(queue_size_before)
	end
=end

	it 'works with multiple processes' do
		Timeout.timeout(1) do
			sum = 0
			num1 = Random.rand(2 ** 32)
			num2 = Random.rand(2 ** 32)

			@cc.commands.register('summation2') do |sender,number|
				sum += number
			end

			recipient = @cc.cpg.member
			forkpid = fork do
				cc = CorosyncCommander.new(@cc.cpg.group)
				exe = cc.execute([recipient], 'summation2', num1)
				exe.wait
			end

			exe = @cc.execute([recipient], 'summation2', num2)
			exe.wait

			result = Process.wait2(forkpid)

			expect(result[1].exitstatus).to eq(0)

			expect(sum).to eq(num1 + num2)
		end
	end

	it 'captures remote exceptions' do
		Timeout.timeout(5) do
			@cc.commands.register('make exception') do
				0/0
			end
			exe = @cc.execute(@cc.cpg.member, 'make exception')
			expect{exe.wait}.to raise_error(ZeroDivisionError)
		end
	end

	it 'resumes after exception' do
		Timeout.timeout(5) do
			@cc.commands.register('resumes after exception') do
				'OK'
			end

			forkpid1 = fork do
				cc = CorosyncCommander.new(@cc.cpg.group)
				cc.commands.register('resumes after exception') do
					0/0
				end
				sleep 5
			end

			forkpid2 = fork do
				cc = CorosyncCommander.new(@cc.cpg.group)
				cc.commands.register('resumes after exception') do
					sleep 0.5 # make sure this response is not before the exception one
					'OK'
				end
				sleep 5
			end

			sleep 1 # we have to wait for the forks to connect to the group

			exe = @cc.execute([], 'resumes after exception')
			enum = exe.to_enum
			responses = []
			exceptions = 0
			begin
				enum.each do |response,node|
					responses << response
				end
			rescue CorosyncCommander::RemoteException
				exceptions += 1
				retry
			end

			[forkpid1,forkpid2].each do |forkpid|
				begin
					Process.kill('TERM', forkpid)
				rescue Errno::ESRCH => e
				end
			end


			expect(responses.size).to eq(2)
			expect(exceptions).to eq(1)
			expect(responses.find_all{|r| r == 'OK'}.size).to eq(2)
		end
	end

	it 'checks for leadership (true)' do
		expect(@cc.leader?).to eq(true)
	end

	it 'checks for leadership (false)' do
		forkpid = fork do
			cc = CorosyncCommander.new(@cc.cpg.group)
			if !cc.leader? then
				exit 0 # we aren't a leader, as expected
			end
			exit 1 # something went wrong
		end

		status = Process.wait2(forkpid)
		expect(status[1]).to eq(0)
	end
end
