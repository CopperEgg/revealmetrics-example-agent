require 'rubygems'
require 'mysql2'

begin
  options = { username: ARGV[0].to_s }
  options[:password] = ARGV[1].to_s unless ARGV[1].to_s.empty?
  if ARGV[3].nil? || ARGV[3].to_s.empty?
    options[:socket] = ARGV[2].to_s
  else
    options[:host] = ARGV[2].to_s
    options[:port] = ARGV[3].to_s
  end

  client = Mysql2::Client.new(options)
  client.query('show global status')
  client.close
  puts('success')
rescue StandardError
  puts 'error'
end
