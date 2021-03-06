require 'rubygems'
require 'bundler/setup'

require 'sinatra'
require 'json'
require 'yaml'
require 'stomp'
require 'syslog'



settings = YAML.load_file("/etc/gitlab-stomp/gitlab-stomp.yaml")

Syslog.open('gitlab-stomp', Syslog::LOG_CONS, Syslog::LOG_DAEMON)

trigger_topic = settings['trigger-topic']
report_topic = settings['report-topic']
stompconnector = settings['stompconnector']


post '/' do
  push = JSON.parse(env['rack.input'].read)

  type = 'push'
  type = push['object_kind'] if push['object_kind']

  case type
  when 'push'
    reponame = push['repository']['name']
    oldrev = push['before']
    newrev = push['after']
    refname = push['ref']
    user = push['user_name']
    repo_homepage = push['repository']['homepage']

    subject = "[#{reponame}] #{refname} #{newrev}"
    body = "repo: #{reponame}\noldrev: #{oldrev}\nnewrev: #{newrev}\nrefname: #{refname}\n"

    push['commits'].each do |flob|
      body2 = " commit #{flob['id']}\nAuthor: #{flob['author']['email']}\nDate: #{flob['timestamp']}\n\t#{flob['message']}\n\n"
      body.concat(body2)
    end

    client = Stomp::Client.new(stompconnector)
    if client
      client.publish("/topic/#{trigger_topic}",body, {:subject => subject})

      # Create a more human friendly version of the published events that include a url to the latest change
      # Example: John Smith pushed 4 commit(s) to myrepo - http://gitlab.example.org/myrepo/commits/da1560886d4f094c3e6c9ef40349f7d38b5d27d7
      eventdetail = "#{user} pushed #{push['commits'].length} commit(s) to #{reponame} - #{repo_homepage}/commits/#{newrev} (webhook)"
      client.publish("/topic/#{report_topic}",eventdetail, {:subject => "Talking to eventbot"})
      
      Syslog.info("Pushed change: %s",subject)
      client.close
    end

  when 'merge_request'
    source = push['object_attributes']['source_branch']
    target = push['object_attributes']['target_branch']
    state = push['object_attributes']['state']
    user = push['user']['name']
    sourcerepo = push['object_attributes']['source']['namespace']
    targetrepo = push['object_attributes']['target']['namespace']

    # Amazingly, its really hard to work out what the Merge Request url is
    eventdetail = "Merge request (#{push['object_attributes']['title']}) #{state} by #{user}: #{sourcerepo}:#{source} -> #{targetrepo}:#{target}"

    client = Stomp::Client.new(stompconnector)
    if client
      client.publish("/topic/#{report_topic}",eventdetail, {:subject => "Talking to eventbot"})
      client.close
    end
  end
end
