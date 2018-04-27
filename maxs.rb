require 'bundler/setup'
Bundler.require(:default)

require 'active_record'

set :bind, '0.0.0.0'
set :port, 8087

file = File.read('config.json')
$config = JSON.parse(file)
$config = $config.merge(YAML.load(File.read('maxs-registration.yaml')))
Phonelib.default_country = $config["defaultCountry"]
$sync_since = nil

ActiveRecord::Base.logger = Logger.new(STDERR)

ActiveRecord::Base.establish_connection(
    adapter: "sqlite3",
    database: 'sms.db'
 )

class Sms < ActiveRecord::Base
end

if !Sms.table_exists?
  ActiveRecord::Schema.define do
    create_table :sms do |table|
      table.column :time, :integer
      table.column :sender, :text
      table.column :content, :text
      table.column :room, :text
      table.column :parsed, :boolean
    end
  end
end

def matrix_send(message, room, user, timestamp = Time.now.to_i * 1000)
  if room.start_with?('#')
    room = JSON.parse(HTTParty.get("#{$config['bridge']['homeserverUrl']}/_matrix/client/r0/directory/room/#{CGI::escape(room)}?access_token=#{$config['as_token']}").body)["room_id"]
  end
  members = JSON.parse(HTTParty.get("#{$config['bridge']['homeserverUrl']}/_matrix/client/r0/rooms/#{room}/joined_members?access_token=#{$config['as_token']}").body)["joined"]

  contains_puppet = false
  members.to_a.each do |member|
    if member[0] == $config['puppet']['id']
      contains_puppet = true
      break
    end
  end

  if !contains_puppet
    HTTParty.post("#{$config['bridge']['homeserverUrl']}/_matrix/client/r0/rooms/#{room}/invite?access_token=#{$config['as_token']}", :body => {"user_id" => $config['puppet']['id']}.to_json) # have the server re-invite them
    HTTParty.post("#{$config['bridge']['homeserverUrl']}/_matrix/client/r0/rooms/#{room}/join?access_token=#{$config['as_token']}&user_id=#{$config['puppet']['id']}", :body => '{}') #rejoin them to the room
  end

  return HTTParty.post("#{$config['bridge']['homeserverUrl']}/_matrix/client/r0/rooms/#{room}/send/m.room.message?access_token=#{$config['as_token']}&ts=#{timestamp}&user_id=#{user}", :body => {"msgtype" => "m.text", "body" => "#{message}"}.to_json)
end

def maxs_send(message)
  return matrix_send(message, $config["controlRoom"], $config['puppet']['id'])
end

def parse_sms(message)
  if (message.split(': ')[0].include?('('))
    room = message.split('(')[1].split(')')[0]
  else
    room = message.split('From ')[1].split(' ')[0]
  end

  if Phonelib.parse(room).valid?
    sender = Phonelib.parse(room).international
  else
    sender = room
  end
    
  if message.start_with?('To ')
    sender = $config['puppet']['id']
  end

  room = sender.gsub(' ', '').gsub('+', '=')

  text = message.split(': ', 2)[1]
  time = Time.parse(message.split(': ', 2)[0].split(' ')[-2..-1].join(' ')).to_i * 1000
  return {time: time, room: room, content: text, sender: sender}
end

def backfill()

end

def message_exists?(message)
  room_alias = CGI::escape("#phone_#{message[:room]}:#{$config['bridge']['domain']}")
  room_id = JSON.parse(HTTParty.get("#{$config['bridge']['homeserverUrl']}/_matrix/client/r0/directory/room/#{room_alias}?access_token=#{$config['as_token']}").body)["room_id"]
  search_json = {
     'search_categories' => {
        'room_events' => {
           'search_term' => message[:content],
           'sender' => "@phone_#{message[:sender].gsub(' ', '').gsub('+', '=')}:#{$config['bridge']['domain']}",
           'filter' => {
              'rooms' => [
                 room_id
              ]
           },
           'order_by' => 'recent',
           'event_context' => {
              'before_limit' => 0,
              'after_limit' => 0,
              'include_profile' => false
           }
        }
     }
  }

  search_results = JSON.parse(HTTParty.post("#{$config['bridge']['homeserverUrl']}/_matrix/client/r0/search?access_token=#{$config['as_token']}&user_id=#{$config['puppet']['id']}", :body => search_json.to_json).body)

  exists = false
  search_results["search_categories"]["room_events"]["results"].each do |r|
    if message[:time] == r["result"]["origin_server_ts"] && message[:content] == r["result"]["content"]["body"] && r["result"]["sender"] == "@phone_#{message[:sender].gsub(' ', '').gsub('+', '=')}:#{$config['bridge']['domain']}" && room_id == r["result"]["room_id"]
      exists = true
      break
    end
  end

  if !exists
    puts "NO MATCH FOUND - LISTING ALL CANDIDATES (#{search_results['search_categories']['room_events']['results'].count})"
    if search_results['search_categories']['room_events']['results'].count == 0
      puts "NO SEARCH RESULTS - DUMPING SEARCH JSON FOR INSPECTION"
      puts search_json.inspect
    end
    search_results["search_categories"]["room_events"]["results"].each do |r|
      puts r.inspect
    end
  end

  return exists
end

get '/' do

end

get '/import' do
  content_type :json

  ActiveRecord::Base.logger = nil # Disable logging for speed, since this page is likely to generate a few zillion SQL queries.
  Sms.find_each do |sms|
    sms.destroy
  end

  doc = File.open("sms.xml") { |f| Nokogiri::XML(f) }
  doc.css("smses sms").each do |sms|
    sender = sms["address"]
    if Phonelib.parse(sender).valid?
      sender = Phonelib.parse(sms["address"]).international
    end
    room = sender.gsub(' ', '').gsub('+', '=')
    if sms["type"].to_i == 2
      sender = $config['puppet']['id']
    end
    if Sms.where(time: sms["date"].to_i, content: sms["body"], sender: sender, room: room).first.nil?
      Sms.create(time: sms["date"].to_i, content: sms["body"], sender: sender, parsed: false, room: room)
    end
  end

  Sms.all.to_json
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
    if room_alias && room_alias.start_with?('#phone_') && room_alias.end_with?(':' + $config["bridge"]["domain"]) && event["content"]["msgtype"] == 'm.text' && event["sender"] == $config["puppet"]["id"] && !event["content"]["body"].end_with?("\ufeff")
      phone_number = room_alias.split(':')[0].split('#phone_')[1].gsub('=', '+')
      text = event["content"]["body"]
      maxs_send("sms send #{phone_number}  #{text}")
    elsif event["sender"] == "@phone:#{$config['bridge']['domain']}" && event["content"]["msgtype"] == 'm.text'
      body = event["content"]["body"]
      if body.include?("New SMS Received\n")
        message = parse_sms(body.split("New SMS Received\n")[1])
        if message[:sender] != $config['puppet']['id']
          matrix_send(message[:content], "#phone_#{message[:room]}:#{$config['bridge']['domain']}", "@phone_#{message[:room].gsub('+', '=')}:#{$config['bridge']['domain']}", message[:time])
        end
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
      elsif body.split("\n", 2)[0].match("Last .* SMS messages")
        # Backfill SMS messages
        body = body.split("\n", 2)[1]
        messages = body.scan(/\n(From|To)\s+(.*?)(?=(?=\n(?=From|To)|$))/)
        messages.each do |m|
          message = parse_sms("#{m[0]} #{m[1]}")
          puts "==> #{message.inspect}"
          if !message_exists?(message)
            if message[:sender] != $config['puppet']['id']
#              matrix_send(message[:content], "#phone_#{message[:room]}:#{$config['bridge']['domain']}", "@phone_#{message[:room].gsub('+', '=')}:#{$config['bridge']['domain']}", message[:time]) #Backfill it!
            end
          end
        end
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
        puts HTTParty.put("#{$config['bridge']['homeserverUrl']}/_matrix/client/r0/profile/@phone_#{username}:#{$config['bridge']['domain']}/displayname?access_token=#{$config['as_token']}&user_id=@phone_#{username}:#{$config['bridge']['domain']}", :body => {"displayname" => phone_number}.to_json)
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
