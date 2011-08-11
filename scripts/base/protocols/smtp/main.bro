
module SMTP;

export {
	redef enum Log::ID += { SMTP };

	redef enum Notice::Type += { 
		## Indicates that the server sent a reply mentioning an SMTP block list.
		BL_Error_Message, 
		## Indicates the client's address is seen in the block list error message.
		BL_Blocked_Host, 
	};

	type Info: record {
		ts:                time            &log;
		uid:               string          &log;
		id:                conn_id         &log;
		## This is an internally generated "message id" that can be used to
		## map between SMTP messages and MIME entities in the SMTP entities
		## log.
		mid:               string          &log;
		helo:              string          &log &optional;
		mailfrom:          string          &log &optional;
		rcptto:            set[string]     &log &optional;
		date:              string          &log &optional;
		from:              string          &log &optional;
		to:                set[string]     &log &optional;
		reply_to:          string          &log &optional;
		msg_id:            string          &log &optional;
		in_reply_to:       string          &log &optional;
		subject:           string          &log &optional;
		x_originating_ip:  addr            &log &optional;
		first_received:    string          &log &optional;
		second_received:   string          &log &optional;
		## The last message the server sent to the client.
		last_reply:        string          &log &optional;
		path:              vector of addr  &log &optional;
		user_agent:        string          &log &optional;
		
		## Indicate if the "Received: from" headers should still be processed.
		process_received_from: bool        &default=T;
		## Indicates if client activity has been seen, but not yet logged
		has_client_activity:  bool            &default=F;
	};
	
	type State: record {
		helo:                     string    &optional;
		## Count the number of individual messages transmitted during this 
		## SMTP session.  Note, this is not the number of recipients, but the
		## number of message bodies transferred.
		messages_transferred:     count     &default=0;
		
		pending_messages:         set[Info] &optional;
	};
	
	## Direction to capture the full "Received from" path.
	##    REMOTE_HOSTS - only capture the path until an internal host is found.
	##    LOCAL_HOSTS - only capture the path until the external host is discovered.
	##    ALL_HOSTS - always capture the entire path.
	##    NO_HOSTS - never capture the path.
	const mail_path_capture = ALL_HOSTS &redef;
	
	# This matches content in SMTP error messages that indicate some
	# block list doesn't like the connection/mail.
	const bl_error_messages = 
	    /spamhaus\.org\//
	  | /sophos\.com\/security\//
	  | /spamcop\.net\/bl/
	  | /cbl\.abuseat\.org\// 
	  | /sorbs\.net\// 
	  | /bsn\.borderware\.com\//
	  | /mail-abuse\.com\//
	  | /b\.barracudacentral\.com\//
	  | /psbl\.surriel\.com\// 
	  | /antispam\.imp\.ch\// 
	  | /dyndns\.com\/.*spam/
	  | /rbl\.knology\.net\//
	  | /intercept\.datapacket\.net\//
	  | /uceprotect\.net\//
	  | /hostkarma\.junkemailfilter\.com\// &redef;
	
	global log_smtp: event(rec: Info);
	
	## Configure the default ports for SMTP analysis.
	const ports = { 25/tcp, 587/tcp } &redef;
}

redef record connection += { 
	smtp:       Info  &optional;
	smtp_state: State &optional;
};

# Configure DPD
redef capture_filters += { ["smtp"] = "tcp port smtp or tcp port 587" };
redef dpd_config += { [ANALYZER_SMTP] = [$ports = ports] };

event bro_init() &priority=5
	{
	Log::create_stream(SMTP, [$columns=SMTP::Info, $ev=log_smtp]);
	}
	
function find_address_in_smtp_header(header: string): string
{
	local ips = find_ip_addresses(header);
	# If there are more than one IP address found, return the second.
	if ( |ips| > 1 )
		return ips[1];
	# Otherwise, return the first.
	else if ( |ips| > 0 )
		return ips[0];
	# Otherwise, there wasn't an IP address found.
	else
		return "";
}

function new_smtp_log(c: connection): Info
	{
	local l: Info;
	l$ts=network_time();
	l$uid=c$uid;
	l$id=c$id;
	l$mid=unique_id("@");
	if ( c?$smtp_state && c$smtp_state?$helo )
		l$helo = c$smtp_state$helo;
	
	# The path will always end with the hosts involved in this connection.
	# The lower values in the vector are the end of the path.
	l$path = vector(c$id$resp_h, c$id$orig_h);
	
	return l;
	}

function set_smtp_session(c: connection)
	{
	if ( ! c?$smtp_state )
		c$smtp_state = [];
	
	if ( ! c?$smtp )
		c$smtp = new_smtp_log(c);
	}

function smtp_message(c: connection)
	{
	if ( c$smtp$has_client_activity )
		Log::write(SMTP, c$smtp);
	}
	
event smtp_request(c: connection, is_orig: bool, command: string, arg: string) &priority=5
	{
	set_smtp_session(c);
	local upper_command = to_upper(command);

	if ( upper_command != "QUIT" )
		c$smtp$has_client_activity = T;
	
	if ( upper_command == "HELO" || upper_command == "EHLO" )
		{
		c$smtp_state$helo = arg;
		c$smtp$helo = arg;
		}

	else if ( upper_command == "RCPT" && /^[tT][oO]:/ in arg )
		{
		if ( ! c$smtp?$rcptto ) 
			c$smtp$rcptto = set();
		add c$smtp$rcptto[split1(arg, /:[[:blank:]]*/)[2]];
		}

	else if ( upper_command == "MAIL" && /^[fF][rR][oO][mM]:/ in arg )
		{
		local partially_done = split1(arg, /:[[:blank:]]*/)[2];
		c$smtp$mailfrom = split1(partially_done, /[[:blank:]]?/)[1];
		}
	}
	
event smtp_reply(c: connection, is_orig: bool, code: count, cmd: string,
                 msg: string, cont_resp: bool) &priority=5
	{
	set_smtp_session(c);
	
	# This continually overwrites, but we want the last reply,
	# so this actually works fine.
	c$smtp$last_reply = fmt("%d %s", code, msg);

	if ( code != 421 && code >= 400 )
		{
		# Raise a notice when an SMTP error about a block list is discovered.
		if ( bl_error_messages in msg )
			{
			local note = BL_Error_Message;
			local message = fmt("%s received an error message mentioning an SMTP block list", c$id$orig_h);

			# Determine if the originator's IP address is in the message.
			local ips = find_ip_addresses(msg);
			local text_ip = "";
			if ( |ips| > 0 && to_addr(ips[0]) == c$id$orig_h )
				{
				note = BL_Blocked_Host;
				message = fmt("%s is on an SMTP block list", c$id$orig_h);
				}
			
			NOTICE([$note=note, $conn=c, $msg=message, $sub=msg]);
			}
		}
	}

event smtp_reply(c: connection, is_orig: bool, code: count, cmd: string,
                 msg: string, cont_resp: bool) &priority=-5
	{
	set_smtp_session(c);
	if ( cmd == "." )
		{
		# Track the number of messages seen in this session.
		++c$smtp_state$messages_transferred;
		smtp_message(c);
		c$smtp = new_smtp_log(c);
		}
	}

event mime_one_header(c: connection, h: mime_header_rec) &priority=5
	{
	if ( ! c?$smtp ) return;
	c$smtp$has_client_activity = T;

	if ( h$name == "MESSAGE-ID" )
		c$smtp$msg_id = h$value;

	else if ( h$name == "RECEIVED" )
		{
		if ( c$smtp?$first_received )
			c$smtp$second_received = c$smtp$first_received;
		c$smtp$first_received = h$value;
		}

	else if ( h$name == "IN-REPLY-TO" )
		c$smtp$in_reply_to = h$value;

	else if ( h$name == "SUBJECT" )
		c$smtp$subject = h$value;

	else if ( h$name == "FROM" )
		c$smtp$from = h$value;

	else if ( h$name == "REPLY-TO" )
		c$smtp$reply_to = h$value;

	else if ( h$name == "DATE" )
		c$smtp$date = h$value;

	else if ( h$name == "TO" )
		{
		if ( ! c$smtp?$to )
			c$smtp$to = set();
		add c$smtp$to[h$value];
		}

	else if ( h$name == "X-ORIGINATING-IP" )
		{
		local addresses = find_ip_addresses(h$name);
		if ( 1 in addresses )
			c$smtp$x_originating_ip = to_addr(addresses[1]);
		}
	
	else if ( h$name == "X-MAILER" ||
	          h$name == "USER-AGENT" ||
	          h$name == "X-USER-AGENT" )
		c$smtp$user_agent = h$value;
	}
	
# This event handler builds the "Received From" path by reading the 
# headers in the mail
event mime_one_header(c: connection, h: mime_header_rec) &priority=3
	{
	# If we've decided that we're done watching the received headers for
	# whatever reason, we're done.  Could be due to only watching until 
	# local addresses are seen in the received from headers.
	if ( ! c?$smtp || h$name != "RECEIVED" || ! c$smtp$process_received_from)
		return;

	local text_ip = find_address_in_smtp_header(h$value);
	if ( text_ip == "" )
		return;
	local ip = to_addr(text_ip);

	if ( ! addr_matches_host(ip, mail_path_capture) && 
	     ! Site::is_private_addr(ip) )
		{
		c$smtp$process_received_from = F;
		}
	if ( c$smtp$path[|c$smtp$path|-1] != ip )
		c$smtp$path[|c$smtp$path|] = ip;
	}

event connection_state_remove(c: connection) &priority=-5
	{
	if ( c?$smtp )
		smtp_message(c);
	}