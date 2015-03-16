# corosync-commander

## Description
corosync-commander is a simplified interface into cluster communication via the Corosync library, based on the [corosync gem](http://github.com/phemmer/ruby-corosync/).

It allows you to build apps which communicate with each other in a reliable fashion. You can send messages to the apps and ensure that every app receives the message in the exact same order. This lets you synchronize data between the apps by only sending deltas.  
The key to this is that when you send a message to the cluster, you receive your own message. Thus corosync-commander becomes a communication bus between the frontend and backend of your application.

### Ruby stack size
Note that due to limitations in ruby versions prior to 2.0, the minimum ruby version supported is 2.0. For more information, see the **IMPORTANT** section of the [documentation](http://www.rubydoc.info/gems/corosync-commander/CorosyncCommander).
Even with ruby 2.0, you must set the `RUBY_THREAD_MACHINE_STACK_SIZE` environment variable higher than 1mb, recommended value is 1572864 (1.5mb)


## Examples

There is a fully working example in the `examples` directory, but here's a brief condensed version:

    require 'corosync_commander'
    cc = CorosyncCommander.new
    cc.commands.register('shell command') do |sender, shellcmd|
      %x{#{shellcmd}}
    end
    cc.join('remote commands')

    exe = cc.execute([], 'shell command', 'hostname')
      enum = exe.to_enum
      begin
        enum.each do |sender, response|
          $stdout.write "#{sender.nodeid}:#{sender.pid}: #{response.chomp}\n"
        end
      rescue CorosyncCommander::RemoteException => e
        puts "Caught remote exception: #{e}"
        retry
      end
    end
