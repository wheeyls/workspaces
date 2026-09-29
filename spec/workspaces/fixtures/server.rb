require 'socket'

server = TCPServer.new('127.0.0.1', ENV.fetch('WORKSPACE_PORT').to_i)
File.write('server.pid', Process.pid)
loop do
  socket = server.accept
  socket.gets
  body = ENV.fetch('WORKSPACE_RUN_ID')
  socket.write "HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}"
  socket.close
end
