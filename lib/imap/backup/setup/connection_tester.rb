module Imap::Backup
  class Setup; end

  class Setup::ConnectionTester
    attr_reader :account

    def initialize(account)
      @account = account
    end

    def test
      account.client
      "Connection successful"
    rescue Net::IMAP::NoResponseError
      "No response"
    rescue StandardError => e
      "Unexpected error: #{e}"
    end
  end
end
