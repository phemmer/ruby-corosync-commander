require 'spec_helper'

describe CorosyncCommander do
	before(:all) do
		@cc = CorosyncCommander.new("CorosyncCommander RSPEC #{Random.rand(2 ** 32)}")
	end

	it 'can call cpg_dispatch' do
		# this is just so that if the thread test fails, we verify that it's not `dispatch` that's the issue
		@cc.cpg.dispatch(0)
	end

	it 'can call cpg_dispatch on a thread' do
		t = Thread.new do
			@cc.cpg.dispatch(0)
		end
		joined = t.join(1)
		expect(joined).to be_a(Thread)
	end

	it 'can handle commands' do
		Timeout.timeout(1) do
			sum = 0
			@cc.register('summation') do |number|
				sum += number
			end
			num1 = Random.rand(2 ** 32)
			@cc.send([], 'summation', num1) {}
			num2 = Random.rand(2 ** 32)
			@cc.send([], 'summation', num2) {}

			expect(sum).to eq(num1 + num2)
		end
	end

	it 'works with multiple processes' do
		Timeout.timeout(1) do
			sum = 0
			@cc.register('summation2') do |number|
				sum += number
			end
			num1 = Random.rand(2 ** 32)
			forkpid = fork do
				cc = CorosyncCommander.new(@cc.cpg.group)
				cc.send([], 'summation2', num1)
			end
			num2 = Random.rand(2 ** 32)
			@cc.send([], 'summation2', num2) {}
			Process.wait(forkpid)

			expect(sum).to eq(num1 + num2)
		end
	end

	it 'captures remote exceptions' do
		Timeout.timeout(5) do
			@cc.register('make exception') do
				0/0
			end
			expect { @cc.send(@cc.cpg.member, 'make exception') {} }.to raise_error(ZeroDivisionError)
		end
	end
end
