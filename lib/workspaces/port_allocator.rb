# frozen_string_literal: true

require 'socket'

module Workspaces
  # Finds a free local TCP port for a new PR backend, avoiding ports this tool already
  # considers taken (per the state file) as well as ports something else on the box is using.
  module PortAllocator
    class NoFreePortError < StandardError; end

    def self.allocate(range, taken_ports)
      range.each do |port|
        next if taken_ports.include?(port)
        return port if free?(port)
      end
      raise NoFreePortError, "No free ports available in #{range}"
    end

    def self.free?(port)
      return false if listening?(port)

      server = TCPServer.new('127.0.0.1', port)
      server.close
      true
    rescue Errno::EADDRINUSE
      false
    end

    def self.listening?(port)
      Socket.tcp('127.0.0.1', port, connect_timeout: 0.2) { true }
    rescue Errno::ECONNREFUSED, Errno::ETIMEDOUT
      false
    end
  end
end
