require 'fsr/command_socket'

class IncomingCall < ActiveRecord::Base
  include ActionView::Helpers::DateHelper

  belongs_to :user

  after_create :signal_tropo
  after_create :set_caller_name

  def self.signal_peer(session_id)
    incoming_call = IncomingCall.find_by_session_id(session_id)
    url = TROPO_SIGNAL_URL + incoming_call.callee_session_id + "/signals?action=signal&value=leaveconference"
    HTTParty.get(url)
  end

  # signals tropo by making a session token call, passing ov_action=joinconf
  # when tropo response comes back, ov will put the user into an existing conference identified by conference_id
  def signal_tropo
    # TODO should add function that letting user to pick which phone to ring
    profile = user.profiles.first
    call_url = profile.call_url
    voice_token = profile.voice_token
    conf_id = user_id.to_s + "<--->" + caller_id
    tropo_url = (call_url || TROPO_URL) + voice_token + "&ov_action=joinconf&user_id=" + user.id.to_s \
                + "&conf_id=" + CGI::escape(conf_id) + "&caller_id=#{CGI::escape(caller_id)}" \
                + "&session_id=#{session_id}&call_id=#{call_id}"
    HTTParty.get(tropo_url)
  end

  def self.followme(params)
    user_id = params[:user_id]
    conf_id = params[:conf_id]
    caller_id = CGI::escape(params[:caller_id])
    call_id = params[:call_id]
    session_id = params[:session_id]
    user = User.find(user_id)
    forwards = user.forwarding_numbers

    if (fsp = user.fs_profiles.first )
      fs_addr = fsp.sip_address
      dest = fs_addr.match(%r{(.*)@(.*)})[1].to_s + "%" + ENV['FS_HOST_IP']
      FSR.load_all_commands
      sock = FSR::CommandSocket.new(:server => ENV['FS_HOST'], :auth => ENV['FS_PASSWORD'])

      # TODO for now only allow calls from myopenvoice.org domain
      sock.originate(:target => "sofia/internal/1000%#{ENV['FS_HOST_IP']}", :endpoint =>FSR::App::Bridge.new("sofia/internal/#{dest}")).run
    end

    next_action = "/incoming_calls/user_menu?conf_id=#{CGI::escape(conf_id)}&user_id=#{user_id}&caller_id=#{caller_id}&session_id=#{session_id}&call_id=#{call_id}"
    contact = user.contacts.select{ |c| c.number == caller_id }.first
    contact = Contact.last if contact.nil?
    name_recording = contact.name_recording ||"Unannounced caller"
    tropo = Tropo::Generator.new do
      on(:event => 'continue', :next => next_action)
      call(:to => forwards, :from => caller_id)
      ask(:name => 'main-menu-incoming',
          :attempts => 3,
          :bargein => true,
          :choices => {:value => "connect(1,connect), voicemail(2,voicemail), listenin(3,listen)"},
          :say => {:value => "Incoming call from #{name_recording} , press 1 to accept, press 2 to send to voicemail, press 3 to listen in. "})
    end

    tropo.response
  end

  # Looks up contact name by caller_id and set it for every incoming message
  def set_caller_name
    caller = user.contacts.select{ |c| c.number == caller_id }.first
    unless caller.nil?
      update_attribute(:caller_name, caller.name)
    else
      update_attribute(:caller_name, "Unknown caller")
    end
  end

  def created_at
    unless self.read_attribute(:created_at).nil?
      self.read_attribute(:created_at).strftime("%a, %b %d")
    end
  end

  def date_for_stream
    "#{time_ago_in_words(updated_at)} ago"
  end

  def hangup
    Tropo::Generator.new{ hangup }.to_json
  end
end
