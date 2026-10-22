# frozen_string_literal: true

# ==============================================================================
# bin/lib/bounded.rb - Run a command for at most so many seconds, whatever it ignores
# ==============================================================================
# Usage: ruby bin/lib/bounded.rb <seconds> <grace> <command> [args...]
#
# What GNU `timeout --kill-after=<grace> <seconds>` does, for a machine without it
# (bin/check_ai_engines.sh, bin/agent_exec.sh): the command runs in a process group
# of its own; when its time is up, or when this process gets TERM or INT, the
# whole group gets TERM, then KILL <grace> seconds later, so a CLI that ignores
# TERM cannot hold its caller forever. Once the command was stopped, KILL also
# reaches whatever it left behind in its group.
# Exit: the command's own status; 124 when its time ran out; 128 + the signal
# when this process was told to stop.

seconds, grace, *command = ARGV
abort 'usage: ruby bin/lib/bounded.rb <seconds> <grace> <command> [args...]' if command.empty?

pid = Process.spawn(*command, pgroup: true)
stop = nil # why the command is being stopped: :timeout, or the signal this process got
%w[TERM INT].each { |sig| Signal.trap(sig) { stop ||= sig } }

signal_group = lambda do |sig|
  Process.kill(sig, -pid)
rescue Errno::ESRCH, Errno::EPERM
  nil
end

deadline = Time.now + seconds.to_i
status = nil
loop do
  _, status = Process.wait2(pid, Process::WNOHANG)
  break if status

  stop ||= :timeout if Time.now >= deadline
  break if stop

  sleep 0.1
end

if stop
  signal_group.call('TERM')
  kill_at = Time.now + grace.to_i
  loop do
    _, status = Process.wait2(pid, Process::WNOHANG)
    break if status || Time.now >= kill_at

    sleep 0.1
  end
  signal_group.call('KILL') # the command if TERM did not stop it, and anything it left in its group
  begin
    Process.wait(pid) unless status
  rescue Errno::ECHILD
    nil
  end
  exit(stop == :timeout ? 124 : 128 + Signal.list.fetch(stop))
end

exit(status.exitstatus || (128 + status.termsig.to_i))
