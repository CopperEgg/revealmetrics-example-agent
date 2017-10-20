require 'rubygems'
require 'redis'

(0..1).each do |index|
  abort('error') if ARGV[index].nil? || ARGV[index].to_s.empty?
end

begin
  client = Redis.new(host: ARGV[0], port: ARGV[1])
  client.info
  client.close
  puts('success')
rescue StandardError
  puts 'error'
end
