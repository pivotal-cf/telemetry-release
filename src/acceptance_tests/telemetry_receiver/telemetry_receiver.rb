#!/usr/bin/env ruby

require 'webrick'
require 'json'
require 'yajl'

server = WEBrick::HTTPServer.new :Port => 8080
server.mount_proc '/' do |req, res|
  if req.header["authorization"] == ["Bearer #{ENV["expected_api_key"]}"]
    parser = Yajl::Parser.new
    parser.on_parse_complete = Proc.new do |obj|
      WEBrick::BasicLog.new.info({"body": obj, "headers": req.header}.to_json)
    end
    parser.parse(req.body)
  else
    res.status = 401
    WEBrick::BasicLog.new.info({"status": "request did not include expected authorization header", "headers": req.header}.to_json)
  end
end
server.start
