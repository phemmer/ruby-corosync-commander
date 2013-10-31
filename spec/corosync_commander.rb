require 'spec_helper'
require 'timeout'

describe CorosyncCommander do
	def fork_execute(wait, cc_recip, command, *args)
		recip = cc_recip.cpg.member
		pid = fork do
			cc = CorosyncCommander.new(cc_recip.cpg.group)
			exe = cc.execute([recip], command, *args)
			exe.wait
			exit!(0)
		end
		if wait then
			status = Process.wait2(pid)
			status.exitstatus
		else
			pid
		end
	end

	before(:all) do
		@cc = CorosyncCommander.new("CorosyncCommander RSPEC #{Random.rand(2 ** 32)}")
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

	it 'registers a callback' do
		@cc.register('summation') do |arg1,arg2|
			arg1 + arg2
		end
	end

	it 'calls the callback' do
		exe = @cc.execute([], 'summation', 123, 456)
		results = exe.to_enum.collect do |response,node|
			response
		end
		
		expect(results.size).to eq(1)
		expect(results.first).to eq(123 + 456)
	end

	it 'removes queues on garbage collection' do
		GC.start
		GC.disable
		@cc.register('nothing') do end
		queue_size_before = @cc.execution_queues.size
		p = Proc.new do
			@cc.execute([], 'nothing')
			false
		end
		p.call
		queue_size_during = @cc.execution_queues.size
		GC.enable
		GC.start
		queue_size_after = @cc.execution_queues.size

		expect(queue_size_during).to eq(queue_size_before + 1)
		expect(queue_size_after).to eq(queue_size_before)
	end

	it 'works with multiple processes' do
		Timeout.timeout(1) do
			sum = 0
			num1 = Random.rand(2 ** 32)
			num2 = Random.rand(2 ** 32)

			@cc.register('summation2') do |number|
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
			@cc.register('make exception') do
				0/0
			end
			exe = @cc.execute(@cc.cpg.member, 'make exception')
			expect{exe.wait}.to raise_error(ZeroDivisionError)
		end
	end

	it 'resumes after exception' do
		Timeout.timeout(5) do
			@cc.register('resumes after exception') do
				'OK'
			end

			forkpid1 = fork do
				cc = CorosyncCommander.new(@cc.cpg.group)
				cc.register('resumes after exception') do
					0/0
				end
				sleep 5
			end

			forkpid2 = fork do
				cc = CorosyncCommander.new(@cc.cpg.group)
				cc.register('resumes after exception') do
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
end
