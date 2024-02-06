require_relative "upflix_api"

run(
  Rack::Builder.new do
    map '/' do
      run UpflixApi.for
    end
  end
)
