require 'rubygems'
require 'mysql2'

(0..2).each do |index|
	abort('error') if ARGV[index].nil? || ARGV[index].to_s.empty?
end

begin
	if ARG[2].nil? || ARGV[2] == ''
	  client = Mysql2::Client.new(host: ARGV[0], username: ARGV[1])
	else
	  client = Mysql2::Client.new(host: ARGV[0], username: ARGV[1], password: ARGV[2])
	end
	client.query('show global status')
	client.close
	puts('success')
rescue StandardError
	puts 'error'
end
