class CorosyncCommander
	class Execution
	end
end
class CorosyncCommander::Execution::Message
	attr_reader :sender
	attr_reader :recipients
	attr_reader :execution_id
	attr_accessor :type
	attr_accessor :content

	def self.from_cpg_message(data, sender)
		data = JSON.parse(data)

		recipients = Corosync::CPG::MemberList.new
		data[0].each do |m|
			nodeid,pid = m.split(':').map{|i| i.to_i}
			recipients << Corosync::CPG::Member.new(nodeid,pid)
		end

		execution_id = data[1]

		type = data[2]

		content = data[3]

		self.new(:sender => sender, :recipients => recipients, :execution_id => execution_id, :type => type, :content => content)
	end

	def initialize(params = {})
		@sender = params[:sender]
		@recipients = Corosync::CPG::MemberList.new(params[:recipients])
		@execution_id = params[:execution_id]
		@type = params[:type]
		@content = params[:content]
	end

	def reply(content)
		self.class.new(:recipients => [@sender], :execution_id => @execution_id, :type => 'response', :content => content)
	end

	def to_s
		[@recipients.to_a, @execution_id, @type, @content].to_json
	end
end
