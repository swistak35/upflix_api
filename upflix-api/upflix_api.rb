require 'json'
require 'faraday'
require "rack"
require "nokogiri"

module Upflix
  BASE_URL = "https://upflix.pl"

  class Client
    def initialize
      @http_client = Faraday.new(url: BASE_URL)
    end

    def get(upflix_path)
      fetched_at = Time.now.utc.iso8601
      response = http_client.get(upflix_path)
      xml = Nokogiri.parse(response.body)

      filmweb_link = get_link(xml.css("a.fw")&.first&.attribute("href")&.to_s)
      imdb_link = get_link(xml.css("a.im")&.first&.attribute("href")&.to_s)

      {
        fetched_at:,
        polish_title: polish_title(xml),
        english_title: english_title(xml),
        year: year(xml),
        genres: genres(xml),
        filmweb_url: filmweb_link,
        imdb_url: imdb_link,
        **vods(xml),
      }
    end

    def polish_title(xml)
      xml.css("h1")&.first&.content
    end

    def english_title(xml)
      xml.css("h2")&.first&.content
    end

    def year(xml)
      xml.css(".yr")&.first&.content
    end

    def genres(xml)
      xml.css(".ge a").map(&:content)
    end

    def vods(xml)
      sources = xml.css("#sc a")
      subscriptions =
        sources
          .select {|el| el.content == "ABONAMENT" }
          .map {|el| el.attribute("href").value.match(/\#vod-(\w+)/)[1] }
      rents =
        sources
          .select {|el| el.content == "WYPOŻYCZENIE" }
          .map {|el| el.attribute("href").value.match(/\#vod-(\w+)/)[1] }
      {
        subscriptions: subscriptions,
        rents: rents
      }
    end

    def get_link(maybe_url)
      return nil if maybe_url.nil?

      response = http_client.get(maybe_url)

      response.headers["location"]
    end

    attr_reader :http_client
  end
end

class Cache
end

class UpflixApi
  def self.for(_host = nil, _root_path = nil)
    Rack::Builder.new do
      run UpflixApi.new
    end
  end

  def call(env)
    @upflix_client = Upflix::Client.new
    request = Rack::Request.new(env)
    result = Upflix::Client.new.get(request.path)
    json_response(result)
  end

  def json_response(body)
    [200, { "content-type" => "application/json" }, [JSON.dump(body.to_h)]]
  end
end
