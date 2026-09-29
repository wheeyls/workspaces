require 'net/http'

loop do
  body = Net::HTTP.get(URI("http://127.0.0.1:#{ENV.fetch('WORKSPACE_PORT')}/"))
  break if body == ENV.fetch('WORKSPACE_RUN_ID')
rescue SystemCallError, IOError
  sleep 0.02
end
puts 'fixture ready'
