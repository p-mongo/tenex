require 'forwardable'
require "link_header"

module Github
  class Pull
    extend Forwardable

    def initialize(client, repo_full_name, info: nil)
      @client = client
      @repo_full_name = repo_full_name
      @info = info
    end

    attr_reader :client, :repo_full_name, :info

    def_delegator :@info, :[]

    def head_sha
      info['head']['sha']
    end

    def statuses
      resp = client.connection.get("/repos/#{repo_full_name}/statuses/#{head_sha}?per_page=100")
      payload = JSON.parse(resp.body)
      prev = []

      while link_header = resp.headers['link']
        link = LinkHeader.parse(link_header)
        next_link = link.find_link(%w(rel next))
        if next_link.nil?
          break
        end
        prev += payload
        resp = client.connection.get(next_link.href)
        payload = JSON.parse(resp.body)
      end
      prev += payload
      payload = prev + payload

      # sometimes the statuses are duplicated?
      payload.delete_if do |status|
        payload.any? do |other_status|
          other_status['context'] == status['context'] &&
          other_status['id'] != status['id'] &&
          other_status['updated_at'] > status['updated_at']
        end
      end
      payload.sort_by! { |a| a['context'] }

      payload.map do |info|
        Status.new(client, info: info)
      end
    end
  end
end
