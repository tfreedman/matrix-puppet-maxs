require 'base64'
require 'sinatra'
require 'httparty'
require 'json'
require 'yaml'
require 'phonelib'
require 'time'

set :bind, '0.0.0.0'
set :port, 8087

file = File.read('config.json')
$config = JSON.parse(file)
$config = $config.merge(YAML.load(File.read('maxs-registration.yaml')))
Phonelib.default_country = $config["defaultCountry"]
$sync_since = nil

def matrix_send(message, room, user, timestamp = Time.now.to_i * 1000)
  if room.start_with?('#')
    room = JSON.parse(HTTParty.get("#{$config['bridge']['homeserverUrl']}/_matrix/client/r0/directory/room/#{CGI::escape(room)}?access_token=#{$config['as_token']}").body)["room_id"]
  end
  return HTTParty.post("#{$config['bridge']['homeserverUrl']}/_matrix/client/r0/rooms/#{room}/send/m.room.message?access_token=#{$config['as_token']}&ts=#{timestamp}&user_id=#{user}", :body => {"msgtype" => "m.text", "body" => "#{message}"}.to_json)
end

def maxs_send(message)
  return matrix_send(message, $config["controlRoom"], $config['puppet']['id'])
end

get '/' do
  '{}'
end

get '/register' do
  config = <<~EOF
    id: #{SecureRandom.hex(32)}
    hs_token: #{SecureRandom.hex(32)}
    as_token: #{SecureRandom.hex(32)}
    namespaces:
      users:
        - exclusive: true
          regex: '@phone_.*'
        - exclusive: false
          regex: '@tyler:tylerfreedman\\.com'
      aliases:
        - exclusive: true
          regex: '#phone_.*'
      rooms: []
    url: 'http://localhost:8087'
    sender_localpart: phonebot
    rate_limited: true
  EOF
  if !File.file?('maxs-registration.yaml')
    File.open('registration.yaml', 'w') { |file| file.write(config) }
  else
    'There\'s already a registration file - delete maxs-registration.yaml to create a new one.'
  end
end

put '/transactions/:txn_id' do
  content_type 'application/json'
  puts 'TRANSACTION: '
  puts params
  events = request.body.read
  puts events
  json = JSON.parse(events)
  json["events"].each do |event|
    room_id = event["room_id"]
    room_alias = JSON.parse(HTTParty.get("#{$config['bridge']['homeserverUrl']}/_matrix/client/r0/rooms/#{room_id}/state/m.room.canonical_alias?access_token=#{$config['as_token']}").body)["alias"]
    puts room_alias
    if room_alias && room_alias.start_with?('#phone_') && room_alias.end_with?(':' + $config["bridge"]["domain"]) && event["content"]["msgtype"] == 'm.text' && event["sender"] == $config["puppet"]["id"]
      phone_number = room_alias.split(':')[0].split('#phone_')[1].gsub('=', '+')
      puts "PHONE_NUMBER: #{phone_number}"
      text = event["content"]["body"]
      maxs_send("sms send #{phone_number}  #{text}")
    elsif event["sender"] == "@phone:#{$config['bridge']['domain']}" && event["content"]["msgtype"] == 'm.text'
      body = event["content"]["body"]
      if body.include?("New SMS Received\n")
        if (body.split(': ')[0].include?('('))
          room = body.split('(')[1].split(')')[0]
        else
          room = body.split('From ')[1].split(' ')[0]
        end
        if Phonelib.parse(room).valid?
          room = Phonelib.parse(room).international.gsub(' ', '').gsub('+', '=')
        end
        text = body.split(': ', 2)[1]
        time = Time.parse(body.split(': ', 2)[0].split(' ')[-2..-1].join(' ')).to_i * 1000

        matrix_send(text, "#phone_#{room}:#{$config['bridge']['domain']}", "@phone_#{room.gsub('+', '=')}:#{$config['bridge']['domain']}", time)
      elsif body.include?('is calling')
        if body.include?(') is calling')
          room = body.split('(')[1].split(')')[0]
        else
          room = body.split(' is calling')[0]
        end
        if Phonelib.parse(room).valid?
          room = Phonelib.parse(room).international.gsub(' ', '').gsub('+', '=')
        end
        matrix_send('calling...', "#phone_#{room}:#{$config['bridge']['domain']}", "@phone_#{room.gsub('+', '=')}:#{$config['bridge']['domain']}")
      end
    else
      #what do
    end
  end
  '{}'
end

get '/rooms/:room_name' do
  content_type 'application/json'
  if params["access_token"]
    if params["access_token"] == $config["hs_token"]
      phone_number = params["room_name"].split(':')[0].split('_')[1]
      room_id = JSON.parse(HTTParty.get("#{$config['bridge']['homeserverUrl']}/_matrix/client/r0/directory/room/#{params['room_name']}?access_token=#{$config['as_token']}").body)["room_id"]
      if room_id
        #room already exists.
      else
        #create the room
        username = phone_number.gsub('+', '=') #we can't create users with a '+' in the name, so we replace them with '='
        phone_number = phone_number.gsub('=', '+') # but we have to ensure that phone number validation is done with a '+'
        if Phonelib.parse(phone_number).valid?
          phone_number = Phonelib.parse(phone_number).international
        end
        json = {'visibility' => 'private', 'room_alias_name' => params["room_name"].split(':')[0].split('#')[1].gsub(' ', ''), 'name' => phone_number, 'is_direct' => true, 'invite' => ["@phone_#{username}:#{$config['bridge']['domain']}", $config['puppet']['id']]}.to_json
        room_id = JSON.parse(HTTParty.post("#{$config['bridge']['homeserverUrl']}/_matrix/client/r0/createRoom?access_token=#{$config['as_token']}", :body => json).body)["room_id"]
        puts "ATTEMPTING TO JOIN YOU + BOT USER"
        puts HTTParty.post("#{$config['bridge']['homeserverUrl']}/_matrix/client/r0/register?access_token=#{$config['as_token']}", :body => {"username" => username, "type" => "m.login.application_service"}.to_json)
        puts HTTParty.post("#{$config['bridge']['homeserverUrl']}/_matrix/client/r0/rooms/#{room_id}/join?access_token=#{$config['as_token']}&user_id=@phone_#{username}:#{$config['bridge']['domain']}", :body => '{}')
        puts HTTParty.post("#{$config['bridge']['homeserverUrl']}/_matrix/client/r0/rooms/#{room_id}/join?access_token=#{$config['as_token']}&user_id=#{$config['puppet']['id']}", :body => '{}')
        puts HTTParty.put("#{$config['bridge']['homeserverUrl']}/_matrix/client/r0/rooms/#{room_id}/state/m.room.power_levels?access_token=#{$config['as_token']}", :body => {'users' => {$config['puppet']['id'] => 100}}.to_json)
      end
      '{}'
    else
      '{gtfo}'
    end
  else
    '{gtfo}'
  end
end

get '/users/:user_id' do
  content_type 'application/json'
  user_id = params["user_id"][1..-1].split(':')[0]  
  puts "user_id: #{user_id}"
  if params["access_token"]
    if params["access_token"] == $config["hs_token"]
      puts HTTParty.post("#{$config['bridge']['homeserverUrl']}/_matrix/client/r0/register?access_token=#{$config['as_token']}", :body => {"username" => user_id, "type" => "m.login.application_service"}.to_json)
      '{}'
    else
      '{"errcode": "M_FORBIDDEN"}'
    end
    '{gtfo}'
  end
  puts "/USERS/: #{params}"
end
