##! Script for detecting strange activity within DNS.
##!
##! Notices raised:
##!
##!   * :bro:enum:`DNS::ExternalName`
##!
##!     A remote host resolves to a local host, but the name is not considered
##!     to be within a local zone.  :bro:id:`local_zones` variable **must**
##!     be set appropriately for this detection.

@load frameworks/notice

module DNS;

export {
	redef enum Notice::Type += { 
		## Raised when a non-local name is found to be pointing at a local host.
		## This only works appropriately when all of your authoritative DNS
		## servers are located in your :bro:id:`Site::local_nets`.
		ExternalName, 
		};
}

event dns_A_reply(c: connection, msg: dns_msg, ans: dns_answer, a: addr) &priority=-3
	{
	if ( |Site::local_zones| == 0 )
		return;
	
	# Check for responses from remote hosts that point at local hosts
	# but the name is not considered to be within a "local" zone.
	if ( Site::is_local_addr(a) &&            # referring to a local host
	     !Site::is_local_addr(c$id$resp_h) && # response from an external nameserver
	     !Site::is_local_name(ans$query) )    # name isn't in a local zone.
		{
		NOTICE([$note=ExternalName,
		        $msg=fmt("%s is pointing to a local host - %s.", ans$query, a),
		        $conn=c]);
		}
	}