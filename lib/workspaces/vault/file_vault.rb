# frozen_string_literal: true

require 'openssl'
require 'json'
require 'securerandom'
require_relative '../config'

module Workspaces
  module Vault
    # An encrypted file per workspace under $WORKSPACES_HOME/vault, readable only with the master key
    # in WORKSPACES_MASTER_KEY (32 random bytes, base64 encoded: `openssl rand -base64 32`).
    #
    # Each workspace gets its own AES-256-GCM key, derived from the master key with HKDF, and its id is
    # bound into the ciphertext, so a file copied to another workspace's name does not decrypt. Names
    # are encrypted along with values. The master key lives only in the environment of the process
    # that runs `serve`; ChildEnv keeps it out of everything that process starts.
    class FileVault < Provider
      KEY_ENV = 'WORKSPACES_MASTER_KEY'
      FORMAT_VERSION = 1
      HKDF_SALT = 'workspaces-vault-v1'
      GENERATE_HINT = 'openssl rand -base64 32'

      def initialize(home: Config.home, env: ENV)
        super()
        @home = home
        @env = env
      end

      def name
        'file'
      end

      def problem
        text = @env.fetch(KEY_ENV, '').to_s.strip
        if text.empty?
          return "Secrets are turned off. Set #{KEY_ENV} where `workspaces serve` runs " \
                 "(generate one with: #{GENERATE_HINT})."
        end
        return nil if master_key

        "#{KEY_ENV} must be 32 random bytes, base64 encoded (generate one with: #{GENERATE_HINT})."
      end

      def read(scope)
        path = file_for(scope)
        return {} unless path.exist?

        require_usable!
        decrypt(scope, path.binread)
      end

      def write(scope, entries)
        path = file_for(scope)
        return purge(scope) if entries.empty?

        require_usable!
        ensure_directory!
        store(path, encrypt(scope, entries))
      end

      def purge(scope)
        path = file_for(scope)
        File.unlink(path) if path.exist? || path.symlink?
      end

      private

      def require_usable!
        reason = problem
        raise Unavailable, reason if reason
      end

      def master_key
        decoded = decode64(@env.fetch(KEY_ENV, '').to_s.strip)
        decoded.bytesize == 32 ? decoded : nil
      rescue ArgumentError
        nil
      end

      # Strict base64 without the base64 gem, which is no longer a default gem from Ruby 3.4.
      def encode64(bytes)
        [bytes].pack('m0')
      end

      def decode64(text)
        text.unpack1('m0')
      end

      def key_for(scope)
        OpenSSL::KDF.hkdf(master_key, salt: HKDF_SALT, info: "workspace:#{scope}", length: 32, hash: 'SHA256')
      end

      def encrypt(scope, entries)
        cipher = OpenSSL::Cipher.new('aes-256-gcm').encrypt
        cipher.key = key_for(scope)
        iv = cipher.random_iv
        cipher.auth_data = scope
        ciphertext = cipher.update(JSON.generate(entries)) + cipher.final
        JSON.generate('v' => FORMAT_VERSION, 'iv' => encode64(iv),
                      'tag' => encode64(cipher.auth_tag), 'data' => encode64(ciphertext))
      end

      def decrypt(scope, document)
        parsed = JSON.parse(document)
        raise Unavailable, 'The stored secrets use an unknown format' unless parsed['v'] == FORMAT_VERSION

        cipher = OpenSSL::Cipher.new('aes-256-gcm').decrypt
        cipher.key = key_for(scope)
        cipher.iv = decode64(parsed.fetch('iv'))
        cipher.auth_tag = decode64(parsed.fetch('tag'))
        cipher.auth_data = scope
        entries = JSON.parse(cipher.update(decode64(parsed.fetch('data'))) + cipher.final)
        raise Unavailable, 'The stored secrets are damaged' unless entries.is_a?(Hash)

        entries
      rescue OpenSSL::Cipher::CipherError, JSON::ParserError, KeyError, ArgumentError, TypeError
        raise Unavailable, "The stored secrets could not be decrypted: wrong #{KEY_ENV}, or the file is damaged"
      end

      def directory
        @home.join('vault')
      end

      def file_for(scope)
        Config.validate_id!(scope.to_s)
        reject_symlink!(directory)
        path = directory.join("#{scope}.enc")
        reject_symlink!(path)
        path
      end

      def ensure_directory!
        directory.mkpath unless directory.exist?
        raise Unavailable, 'The secret vault path is not a directory' unless directory.directory?

        File.chmod(0o700, directory)
      end

      def store(path, document)
        temp = directory.join(".#{path.basename}.#{Process.pid}.#{SecureRandom.hex(6)}.tmp")
        begin
          File.open(temp, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
            file.write(document)
            file.flush
            file.fsync
          end
          File.rename(temp, path)
          File.chmod(0o600, path)
        ensure
          File.unlink(temp) if temp.exist?
        end
      end

      def reject_symlink!(path)
        raise Unavailable, 'The secret vault does not allow symlinks' if path.symlink?
      end
    end

    register('file', FileVault)
  end
end
