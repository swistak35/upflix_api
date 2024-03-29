require 'json'
require 'faraday'
require "rack"
require "nokogiri"
require "pstore"

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
  VALIDITY_PERIOD = 7 * 24 * 60 * 60 # 7 days

  def initialize
    @pstore = PStore.new("cache.pstore")
  end

  def has?(key)
    @pstore.transaction do
      value = @pstore[key]
      if value && valid?(value)
        value
      else
        nil
      end
    end
  end

  def get(key)
    @pstore.transaction do
      value = @pstore[key]
      if valid?(value)
        value
      else
        nil
      end
    end
  end

  def store(key, value)
    @pstore.transaction do
      @pstore[key] = value
    end
  end

  def valid?(value)
    Time.parse(value.fetch(:fetched_at)) > (Time.now.utc - VALIDITY_PERIOD)
  end
end

class RateLimiter
  RATE_LIMITING_PERIOD = 10 * 60 # 10 minutes

  def initialize
    @recently_failed = Time.new(2024)
  end

  def failed!
    @recently_failed = Time.now
  end

  def active?
    @recently_failed > (Time.now - RATE_LIMITING_PERIOD)
  end
end

class UpflixApi
  def self.for(_host = nil, _root_path = nil)
    Rack::Builder.new do
      run UpflixApi.new
    end
  end

  def initialize
    @cache = Cache.new
    @rate_limiter = RateLimiter.new
  end

  def call(env)
    @upflix_client = Upflix::Client.new
    request = Rack::Request.new(env)

    puts "Processing #{request.path}"

    if request.path == "/favicon.ico"
      return [404, {}, []]
    end

    if !request.params["force"] && @rate_limiter.active?
      puts "Rate limiting, because recently rate limited"
      return rate_limiting_response
    end

    if !request.params["force"] && @cache.has?(request.path)
      puts "#{request.path} in cache"
      result = @cache.get(request.path)
    else
      puts "#{request.path} not in cache"
      result = Upflix::Client.new.get(request.path)

      if result.fetch(:english_title) == "Miss Christmas"
        @rate_limiter.failed!
        puts "Rate limiting response"
        return rate_limiting_response
      end

      @cache.store(request.path, result)
    end
    puts result.inspect
    json_response(result)
  end

  def json_response(body)
    [200, { "content-type" => "application/json" }, [JSON.dump(body.to_h)]]
  end

  def rate_limiting_response
    [429, { "content-type" => "application/json" }, []]
  end
end
