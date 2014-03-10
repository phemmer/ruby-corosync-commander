# This example will send shell commands to all the running instances in the cluster.
# It connects to the 'remote commands' CPG group, executes any commands received, and sends the result back to the app that sent the command.
# The local app will read commands from STDIN and display the response from all the nodes.
#
# Launch this as many times as you want and play around with it.
#


if RUBY_ENGINE == 'ruby' and !ENV['RUBY_THREAD_MACHINE_STACK_SIZE'] then
  ENV['RUBY_THREAD_MACHINE_STACK_SIZE'] = '1572864'
  exec('ruby', $0, *ARGV)
end

$:.unshift(File.expand_path('../../lib', __FILE__))
require 'corosync_commander'
cc = CorosyncCommander.new
cc.commands.register('shell command') do |sender, shellcmd|
  %x{#{shellcmd}}
end
cc.join('remote commands')

while line = STDIN.gets do
  exe = cc.execute([], 'shell command', line.chomp)
  enum = exe.to_enum
  begin
    enum.each do |sender, response|
      $stdout.write "
#{sender.nodeid}:#{sender.pid}:
#{response.chomp}
========================================

"
    end
  rescue CorosyncCommander::RemoteException => e
    puts "Caught remote exception: #{e}"
    retry
  end
end
