--[[

Here is a MQTT v5.0 protocol implementation

MQTT v5.0 documentation (DOC):
	http://docs.oasis-open.org/mqtt/mqtt/v5.0/mqtt-v5.0.html

]]

-- module table
local protocol5 = {}


-- MQTT protocol version
protocol5.version = "v5.0"


-- required modules
local table = require("table")
local string = require("string")
local bit = require("mqtt.bit")
local protocol = require("mqtt.protocol")

-- cache to locals
local assert = assert
local tostring = tostring
local setmetatable = setmetatable
local error = error
local tbl_sort = table.sort
local str_sub = string.sub
local str_byte = string.byte
local str_char = string.char
local bor = bit.bor
local band = bit.band
local lshift = bit.lshift
local rshift = bit.rshift
local make_uint8 = protocol.make_uint8
local make_uint16 = protocol.make_uint16
local make_uint32 = protocol.make_uint32
local make_string = protocol.make_string
local make_var_length = protocol.make_var_length
local make_header = protocol.make_header
local check_qos = protocol.check_qos
local check_packet_id = protocol.check_packet_id
local combine = protocol.combine
local parse_var_length = protocol.parse_var_length
local packet_type = protocol.packet_type
local packet_mt = protocol.packet_mt


-- Returns true if given value is a valid Retain Handling option, DOC: 3.8.3.1 Subscription Options
local function check_retain_handling(val)
	return (val == 0) or (val == 1) or (val == 2)
end

-- Create Connect Flags data, DOC: 3.1.2.3 Connect Flags
local function make_connect_flags(args)
	local byte = 0 -- bit 0 should be zero
	-- DOC: 3.1.2.4 Clean Start
	if args.clean ~= nil then
		assert(type(args.clean) == "boolean", "expecting .clean to be a boolean")
		if args.clean then
			byte = bor(byte, lshift(1, 1))
		end
	end
	-- DOC: 3.1.2.5 Will Flag
	if args.will ~= nil then
		-- check required args are presented
		assert(type(args.will) == "table", "expecting .will to be a table")
		assert(type(args.will.payload) == "string", "expecting .will.payload to be a string")
		assert(type(args.will.topic) == "string", "expecting .will.topic to be a string")
		assert(type(args.will.qos) == "number", "expecting .will.qos to be a number")
		assert(check_qos(args.will.qos), "expecting .will.qos to be a valid QoS value")
		assert(type(args.will.retain) == "boolean", "expecting .will.retain to be a boolean")
		assert(type(args.will.properties) == "table", "expecting .will.properties to be a table")
		-- will flag should be set to 1
		byte = bor(byte, lshift(1, 2))
		-- DOC: 3.1.2.6 Will QoS
		byte = bor(byte, lshift(args.will.qos, 3))
		-- DOC: 3.1.2.7 Will Retain
		if args.will.retain then
			byte = bor(byte, lshift(1, 5))
		end
	end
	-- DOC: 3.1.2.8 User Name Flag
	if args.username ~= nil then
		assert(type(args.username) == "string", "expecting .username to be a string")
		byte = bor(byte, lshift(1, 7))
	end
	-- DOC: 3.1.2.9 Password Flag
	if args.password ~= nil then
		assert(type(args.password) == "string", "expecting .password to be a string")
		assert(args.username, "the .username is required to set .password")
		byte = bor(byte, lshift(1, 6))
	end
	return make_uint8(byte)
end

-- Make data for 1-byte property with only 0 or 1 value
local function make_uint8_0_or_1(value)
	if value ~= 0 and value ~= 1 then
		error("expecting 0 or 1 as value")
	end
	return make_uint8(value)
end

-- Make data for 2-byte property with nonzero value check
local function make_uint16_nonzero(value)
	if value == 0 then
		error("expecting nonzero value")
	end
	return make_uint16(value)
end

-- Make data for variable length property with nonzero value check
local function make_var_length_nonzero(value)
	if value == 0 then
		error("expecting nonzero value")
	end
	return str_char(make_var_length(value))
end

-- Read string using given read_func function
-- Returns false plus error message on failure
-- Returns parsed string on success
local function parse_string(read_func)
	assert(type(read_func) == "function", "expecting read_func to be a function")
	local len, err = read_func(2)
	if not len then
		return false, "failed to read string length: "..err
	end
	-- convert len string from 2-byte integer
	local byte1, byte2 = str_byte(len, 1, 2)
	len = bor(lshift(byte1, 8), byte2)
	-- and return string if parsed length
	return read_func(len)
end

-- Parse uint8 value using given read_func
local function parse_uint8(read_func)
	assert(type(read_func) == "function", "expecting read_func to be a function")
	local value, err = read_func(1)
	if not value then
		return false, "failed to read 1 byte for uint8: "..err
	end
	return str_byte(value, 1, 1)
end

-- Parse uint8 value with only 0 or 1 value
local function parse_uint8_0_or_1(read_func)
	local value, err = parse_uint8(read_func)
	if not value then
		return false, err
	end
	if value ~= 0 and value ~= 1 then
		return false, "expecting only 0 or 1 but got: "..value
	end
	return value
end

-- Parse uint16 value using given read_func
local function parse_uint16(read_func)
	assert(type(read_func) == "function", "expecting read_func to be a function")
	local value, err = read_func(2)
	if not value then
		return false, "failed to read 2 byte for uint16: "..err
	end
	local byte1, byte2 = str_byte(value, 1, 2)
	return lshift(byte1, 8) + byte2
end

-- Parse uint16 non-zero value using given read_func
local function parse_uint16_nonzero(read_func)
	local value, err = parse_uint16(read_func)
	if not value then
		return false, err
	end
	if value == 0 then
		return false, "expecting non-zero value"
	end
	return value
end

-- Parse uint32 value using given read_func
local function parse_uint32(read_func)
	assert(type(read_func) == "function", "expecting read_func to be a function")
	local value, err = read_func(4)
	if not value then
		return false, "failed to read 4 byte for uint32: "..err
	end
	local byte1, byte2, byte3, byte4 = str_byte(value, 1, 4)
	return lshift(byte1, 24) + lshift(byte2, 16) + lshift(byte3, 8) + byte4
end

-- Parse Variable Byte Integer with non-zero constraint
local function parse_var_length_nonzero(read_func)
	local value, err = parse_var_length(read_func)
	if not value then
		return false, err
	end
	if value == 0 then
		return false, "expecting non-zer value"
	end
	return value
end

-- Known property names and its identifiers, DOC: 2.2.2.2 Property
local property_pairs = {
	{ 0x01, "payload_format_indicator",
		make = make_uint8_0_or_1,
		parse = parse_uint8_0_or_1, },
	{ 0x02, "message_expiry_interval",
		make = make_uint32,
		parse = parse_uint32, },
	{ 0x03, "content_type",
		make = make_string,
		parse = parse_string, },
	{ 0x08, "response_topic",
		make = make_string,
		parse = parse_string, },
	{ 0x09, "correlation_data",
		make = make_string,
		parse = parse_string, },
	{ 0x0B, "subscription_identifier",
		make = make_var_length_nonzero,
		parse = parse_var_length_nonzero,
		multiple = true, },
	{ 0x11, "session_expiry_interval",
		make = make_uint32,
		parse = parse_uint32, },
	{ 0x12, "assigned_client_identifier",
		make = make_string,
		parse = parse_string, },
	{ 0x13, "server_keep_alive",
		make = make_uint16,
		parse = parse_uint16, },
	{ 0x15, "authentication_method",
		make = make_string,
		parse = parse_string, },
	{ 0x16, "authentication_data",
		make = make_string,
		parse = parse_string, },
	{ 0x17, "request_problem_information",
		make = make_uint8_0_or_1,
		parse = parse_uint8_0_or_1, },
	{ 0x18, "will_delay_interval",
		make = make_uint32,
		parse = parse_uint32, },
	{ 0x19, "request_response_information",
		make = make_uint8_0_or_1,
		parse = parse_uint8_0_or_1, },
	{ 0x1A, "response_information",
		make = make_string,
		parse = parse_string, },
	{ 0x1C, "server_reference",
		make = make_string,
		parse = parse_string, },
	{ 0x1F, "reason_string",
		make = make_string,
		parse = parse_string, },
	{ 0x21, "receive_maximum",
		make = make_uint16,
		parse = parse_uint16, },
	{ 0x22, "topic_alias_maximum",
		make = make_uint16,
		parse = parse_uint16, },
	{ 0x23, "topic_alias",
		make = make_uint16_nonzero,
		parse = parse_uint16_nonzero, },
	{ 0x24, "maximum_qos",
		make = make_uint8_0_or_1,
		parse = parse_uint8_0_or_1, },
	{ 0x25, "retain_available",
		make = make_uint8_0_or_1,
		parse = parse_uint8_0_or_1, },
	{ 0x26, "user_property", -- NOTE: not implemented intentionally
		make = function(value_) error("not implemented") end,
		parse = function(read_func_) error("not implemented") end, },
	{ 0x27, "maximum_packet_size",
		make = make_uint32,
		parse = parse_uint32, },
	{ 0x28, "wildcard_subscription_available",
		make = make_uint8_0_or_1,
		parse = parse_uint8_0_or_1, },
	{ 0x29, "subscription_identifier_available",
		make = make_uint8_0_or_1,
		parse = parse_uint8_0_or_1, },
	{ 0x2A, "shared_subscription_available",
		make = make_uint8_0_or_1,
		parse = parse_uint8_0_or_1, },
}

-- properties table with keys in two directions: from name to identifier and back
local properties = {}
-- table with property value make functions
local property_make = {}
-- table with property value parse function
local property_parse = {}
-- table with property multiple flag
local property_multiple = {}
-- fill the properties and property_make tables
for _, prop in ipairs(property_pairs) do
	properties[prop[2]] = prop[1]				-- name ==> identifier
	properties[prop[1]] = prop[2]				-- identifier ==> name
	property_make[prop[1]] = prop.make			-- identifier ==> make function
	property_parse[prop[1]] = prop.parse		-- identifier ==> make function
	property_multiple[prop[1]] = prop.multiple	-- identifier ==> multiple flag
end

-- Allowed properties per packet type
local allowed_properties = {
	-- DOC: 3.1.2.11 CONNECT Properties
	[packet_type.CONNECT] = {
		[0x11] = true, -- DOC: 3.1.2.11.2 Session Expiry Interval
		[0x21] = true, -- DOC: 3.1.2.11.3 Receive Maximum
		[0x27] = true, -- DOC: 3.1.2.11.4 Maximum Packet Size
		[0x22] = true, -- DOC: 3.1.2.11.5 Topic Alias Maximum
		[0x19] = true, -- DOC: 3.1.2.11.6 Request Response Information
		[0x17] = true, -- DOC: 3.1.2.11.7 Request Problem Information
		[0x26] = true, -- DOC: 3.1.2.11.8 User Property
		[0x15] = true, -- DOC: 3.1.2.11.9 Authentication Method
		[0x16] = true, -- DOC: 3.1.2.11.10 Authentication Data
	},
	[packet_type.CONNACK] = {
		[0x11] = true, -- DOC: 3.2.2.3.2 Session Expiry Interval
		[0x21] = true, -- DOC: 3.2.2.3.3 Receive Maximum
		[0x24] = true, -- DOC: 3.2.2.3.4 Maximum QoS
		[0x25] = true, -- DOC: 3.2.2.3.5 Retain Available
		[0x27] = true, -- DOC: 3.2.2.3.6 Maximum Packet Size
		[0x12] = true, -- DOC: 3.2.2.3.7 Assigned Client Identifier
		[0x22] = true, -- DOC: 3.2.2.3.8 Topic Alias Maximum
		[0x1F] = true, -- DOC: 3.2.2.3.9 Reason String
		[0x26] = true, -- DOC: 3.2.2.3.10 User Property
		[0x28] = true, -- DOC: 3.2.2.3.11 Wildcard Subscription Available
		[0x29] = true, -- DOC: 3.2.2.3.12 Subscription Identifiers Available
		[0x2A] = true, -- DOC: 3.2.2.3.13 Shared Subscription Available
		[0x13] = true, -- DOC: 3.2.2.3.14 Server Keep Alive
		[0x1A] = true, -- DOC: 3.2.2.3.15 Response Information
		[0x1C] = true, -- DOC: 3.2.2.3.16 Server Reference
		[0x15] = true, -- DOC: 3.2.2.3.17 Authentication Method
		[0x16] = true, -- DOC: 3.2.2.3.18 Authentication Data
	},
	[packet_type.PUBLISH] = {
		[0x01] = true, -- DOC: 3.3.2.3.2 Payload Format Indicator
		[0x02] = true, -- DOC: 3.3.2.3.3 Message Expiry Interval
		[0x23] = true, -- DOC: 3.3.2.3.4 Topic Alias
		[0x08] = true, -- DOC: 3.3.2.3.5 Response Topic
		[0x09] = true, -- DOC: 3.3.2.3.6 Correlation Data
		[0x26] = true, -- DOC: 3.3.2.3.7 User Property
		[0x0B] = true, -- DOC: 3.3.2.3.8 Subscription Identifier
		[0x03] = true, -- DOC: 3.3.2.3.9 Content Type
	},
	[packet_type.PUBACK] = {
		[0x1F] = true, -- DOC: 3.4.2.2.2 Reason String
		[0x26] = true, -- DOC: 3.4.2.2.3 User Property
	},
	[packet_type.PUBREC] = {
		[0x1F] = true, -- DOC: 3.5.2.2.2 Reason String
		[0x26] = true, -- DOC: 3.5.2.2.3 User Property
	},
	[packet_type.PUBREL] = {
		[0x1F] = true, -- DOC: 3.6.2.2.2 Reason String
		[0x26] = true, -- DOC: 3.6.2.2.3 User Property
	},
	[packet_type.PUBCOMP] = {
		[0x1F] = true, -- DOC: 3.7.2.2.2 Reason String
		[0x26] = true, -- DOC: 3.7.2.2.3 User Property
	},
	[packet_type.SUBSCRIBE] = {
		[0x0B] = true, -- DOC: 3.8.2.1.2 Subscription Identifier
		[0x26] = true, -- DOC: 3.8.2.1.3 User Property
	},
	[packet_type.SUBACK] = {
		[0x1F] = true, -- DOC: 3.9.2.1.2 Reason String
		[0x26] = true, -- DOC: 3.9.2.1.3 User Property
	},
	[packet_type.UNSUBSCRIBE] = {
		[0x26] = true, -- DOC: 3.10.2.1.2 User Property
	},
	[packet_type.UNSUBACK] = {
		[0x1F] = true, -- DOC: 3.11.2.1.2 Reason String
		[0x26] = true, -- DOC: 3.11.2.1.3 User Property
	},
	-- NOTE: PINGREQ (3.12), PINGRESP (3.13) has no properties
	[packet_type.DISCONNECT] = {
		[0x11] = true, -- DOC: 3.14.2.2.2 Session Expiry Interval
		[0x1F] = true, -- DOC: 3.14.2.2.3 Reason String
		[0x26] = true, -- DOC: 3.14.2.2.4 User Property
		[0x1C] = true, -- DOC: 3.14.2.2.5 Server Reference
	},
	[packet_type.AUTH] = {
		[0x15] = true, -- DOC: 3.15.2.2.2 Authentication Method
		[0x16] = true, -- DOC: 3.15.2.2.3 Authentication Data
		[0x1F] = true, -- DOC: 3.15.2.2.4 Reason String
		[0x26] = true, -- DOC: 3.15.2.2.5 User Property
	},
}

-- Create properties field for various control packets, DOC: 2.2.2 Properties
local function make_properties(ptype, args)
	local allowed = assert(allowed_properties[ptype], "invalid packet type to detect allowed properties")
	local props = ""
	local uprop_id = properties.user_property
	-- writing known properties
	if args.properties ~= nil then
		assert(type(args.properties) == "table", "expecting .properties to be a table")
		-- validate all properties and append them to order list
		local order = {}
		for name, value in pairs(args.properties) do
			assert(type(name) == "string", "expecting property name to be a string: "..tostring(name))
			-- detect property identifier and check it's allowed for that packet type
			local prop_id = assert(properties[name], "unknown property: "..tostring(name))
			assert(prop_id ~= uprop_id, "user properties should be passed in .user_properties table")
			assert(allowed[prop_id], "property "..name.." is not allowed for packet type "..ptype)
			order[#order + 1] = { prop_id, name, value }
		end
		-- sort props in the identifier ascending order
		tbl_sort(order, function(a, b) return a[1] < b[1] end)
		for _, item in ipairs(order) do
			local prop_id, name,  value = unpack(item)
			-- make property data
			local ok, val = pcall(property_make[prop_id], value)
			if not ok then
				error("invalid property value: "..name.." = "..tostring(value)..": "..tostring(val))
			end
			local prop = combine(
				str_char(make_var_length(prop_id)),
				val
			)
			-- and append it to props
			if type(props) == "string" then
				props = combine(prop)
			else
				props:append(prop)
			end
		end
	end
	-- writing userproperties
	if args.user_properties ~= nil then
		assert(type(args.user_properties) == "table", "expecting .user_properties to be a table")
		assert(allowed[uprop_id], "user_property is not allowed for packet type "..ptype)
		for name, value in pairs(args.user_properties) do
			if type(name) == "number" and type(value) == "table" then
				-- this is a {"name", "value"} array item, not name = "value" pair
				name = value[1]
				value = value[2]
			end
			assert(type(name) == "string", "expecting user property name to be a string: "..tostring(name))
			assert(type(value) == "string", "expecting user property value to be a string: "..tostring(value))
			-- make user property data
			local prop = combine(
				str_char(make_var_length(uprop_id)),
				make_string(name),
				make_string(value)
			)
			-- and append it to props
			if type(props) == "string" then
				props = combine(prop)
			else
				props:append(prop)
			end
		end
	end
	-- and combine properties with its length field
	return combine(
		str_char(make_var_length(props:len())),		-- DOC: 2.2.2.1 Property Length
		props										-- DOC: 2.2.2.2 Property
	)
end

-- Create CONNECT packet, DOC: 3.1 CONNECT – Connection Request
local function make_packet_connect(args)
	-- check args
	assert(type(args.id) == "string", "expecting .id to be a string with MQTT client id")
	-- DOC: 3.1.2.10 Keep Alive
	local keep_alive_ival = 0
	if args.keep_alive then
		assert(type(args.keep_alive) == "number")
		keep_alive_ival = args.keep_alive
	end
	-- DOC: 3.1.2.11 CONNECT Properties
	local props = make_properties(packet_type.CONNECT, args)
	-- DOC: 3.1.2 CONNECT Variable Header
	local variable_header = combine(
		make_string("MQTT"), 				-- DOC: 3.1.2.1 Protocol Name
		make_uint8(5), 						-- DOC: 3.1.2.2 Protocol Version (5 is for MQTT v5.0)
		make_connect_flags(args), 			-- DOC: 3.1.2.3 Connect Flags
		make_uint16(keep_alive_ival), 		-- DOC: 3.1.2.10 Keep Alive
		props								-- DOC: 3.1.2.11 CONNECT Properties
	)
	-- DOC: 3.1.3 CONNECT Payload
	-- DOC: 3.1.3.1 Client Identifier (ClientID)
	local payload = combine(
		make_string(args.id)
	)
	if args.will then
		-- DOC: 3.1.3.2 Will Properties
		payload:append(make_properties(packet_type.PUBLISH, args.will))
		-- DOC: 3.1.3.3 Will Topic
		payload:append(make_string(args.will.topic))
		-- DOC: 3.1.3.4 Will Payload
		payload:append(make_string(args.will.payload))
	end
	if args.username then
		-- DOC: 3.1.3.5 User Name
		payload:append(make_string(args.username))
		if args.password then
			-- DOC: 3.1.3.6 Password
			payload:append(make_string(args.password))
		end
	end
	-- DOC: 3.1.1 Fixed header
	local header = make_header(packet_type.CONNECT, 0, variable_header:len() + payload:len())
	return combine(header, variable_header, payload)
end

-- Create PUBLISH packet, DOC: 3.3 PUBLISH – Publish message
local function make_packet_publish(args)
	-- check args
	assert(type(args.topic) == "string", "expecting .topic to be a string")
	if args.payload ~= nil then
		assert(type(args.payload) == "string", "expecting .payload to be a string")
	end
	assert(type(args.qos) == "number", "expecting .qos to be a number")
	assert(check_qos(args.qos), "expecting .qos to be a valid QoS value")
	assert(type(args.retain) == "boolean", "expecting .retain to be a boolean")
	assert(type(args.dup) == "boolean", "expecting .dup to be a boolean")

	-- DOC: 3.3.1 PUBLISH Fixed Header
	local flags = 0
	-- 3.3.1.3 RETAIN
	if args.retain then
		flags = bor(flags, 0x1)
	end
	-- DOC: 3.3.1.2 QoS
	flags = bor(flags, lshift(args.qos, 1))
	-- DOC: 3.3.1.1 DUP
	if args.dup then
		flags = bor(flags, lshift(1, 3))
	end
	-- DOC: 3.3.2 PUBLISH Variable Header
	local variable_header = combine(
		make_string(args.topic)
	)
	-- DOC: 3.3.2.2 Packet Identifier
	if args.qos > 0 then
		assert(type(args.packet_id) == "number", "expecting .packet_id to be a number")
		assert(check_packet_id(args.packet_id), "expecting .packet_id to be a valid Packet Identifier")
		variable_header:append(make_uint16(args.packet_id))
	end
	-- DOC: 3.3.2.3 PUBLISH Properties
	variable_header:append(make_properties(packet_type.PUBLISH, args))
	-- DOC: 3.3.3 PUBLISH Payload
	local payload
	if args.payload then
		payload = args.payload
	else
		payload = ""
	end
	-- DOC: 3.3.1 Fixed header
	local header = make_header(packet_type.PUBLISH, flags, variable_header:len() + payload:len())
	return combine(header, variable_header, payload)
end

-- Create PUBACK packet, DOC: 3.4 PUBACK – Publish acknowledgement
local function make_packet_puback(args)
	-- check args
	assert(type(args.packet_id) == "number", "expecting .packet_id to be a number")
	assert(check_packet_id(args.packet_id), "expecting .packet_id to be a valid Packet Identifier")
	assert(type(args.reason_code) == "number", "expecting .reason_code to be a number")
	-- DOC: 3.4.2 PUBACK Variable Header
	local variable_header = combine(make_uint16(args.packet_id))
	local props = make_properties(packet_type.PUBACK, args)		-- DOC: 3.4.2.2 PUBACK Properties
	-- DOC: The Reason Code and Property Length can be omitted if the Reason Code is 0x00 (Success) and there are no Properties. In this case the PUBACK has a Remaining Length of 2.
	if props:len() > 1 or args.reason_code ~= 0 then
		variable_header:append(make_uint8(args.reason_code))	-- DOC: 3.4.2.1 PUBACK Reason Code
		variable_header:append(props)							-- DOC: 3.4.2.2 PUBACK Properties
	end
	-- DOC: 3.4.1 PUBACK Fixed Header
	local header = make_header(packet_type.PUBACK, 0, variable_header:len())
	return combine(header, variable_header)
end

-- Create PUBREC packet, DOC: 3.5 PUBREC – Publish received (QoS 2 delivery part 1)
local function make_packet_pubrec(args)
	-- check args
	assert(type(args.packet_id) == "number", "expecting .packet_id to be a number")
	assert(check_packet_id(args.packet_id), "expecting .packet_id to be a valid Packet Identifier")
	assert(type(args.reason_code) == "number", "expecting .reason_code to be a number")
	-- DOC: 3.5.2 PUBREC Variable Header
	local variable_header = combine(make_uint16(args.packet_id))
	local props = make_properties(packet_type.PUBREC, args)		-- DOC: 3.5.2.2 PUBREC Properties
	-- DOC: The Reason Code and Property Length can be omitted if the Reason Code is 0x00 (Success) and there are no Properties. In this case the PUBREC has a Remaining Length of 2.
	if props:len() > 1 or args.reason_code ~= 0 then
		variable_header:append(make_uint8(args.reason_code))	-- DOC: 3.5.2.1 PUBREC Reason Code
		variable_header:append(props)							-- DOC: 3.5.2.2 PUBREC Properties
	end
	-- DOC: 3.5.1 PUBREC Fixed Header
	local header = make_header(packet_type.PUBREC, 0, variable_header:len())
	return combine(header, variable_header)
end

-- Create PUBREL packet, DOC: 3.6 PUBREL – Publish release (QoS 2 delivery part 2)
local function make_packet_pubrel(args)
	-- check args
	assert(type(args.packet_id) == "number", "expecting .packet_id to be a number")
	assert(check_packet_id(args.packet_id), "expecting .packet_id to be a valid Packet Identifier")
	assert(type(args.reason_code) == "number", "expecting .reason_code to be a number")
	-- DOC: 3.6.2 PUBREL Variable Header
	local variable_header = combine(make_uint16(args.packet_id))
	local props = make_properties(packet_type.PUBREL, args)		-- DOC: 3.6.2.2 PUBREL Properties
	-- DOC: The Reason Code and Property Length can be omitted if the Reason Code is 0x00 (Success) and there are no Properties. In this case the PUBREL has a Remaining Length of 2.
	if props:len() > 1 or args.reason_code ~= 0 then
		variable_header:append(make_uint8(args.reason_code))	-- DOC: 3.6.2.1 PUBREL Reason Code
		variable_header:append(props)							-- DOC: 3.6.2.2 PUBREL Properties
	end
	-- DOC: 3.6.1 PUBREL Fixed Header
	local header = make_header(packet_type.PUBREL, 2, variable_header:len()) -- flags: fixed 0010 bits, DOC: Figure 3‑14 – PUBREL packet Fixed Header
	return combine(header, variable_header)
end

-- Create PUBCOMP packet, DOC: 3.7 PUBCOMP – Publish complete (QoS 2 delivery part 3)
local function make_packet_pubcomp(args)
	-- check args
	assert(type(args.packet_id) == "number", "expecting .packet_id to be a number")
	assert(check_packet_id(args.packet_id), "expecting .packet_id to be a valid Packet Identifier")
	assert(type(args.reason_code) == "number", "expecting .reason_code to be a number")
	-- DOC: 3.7.2 PUBCOMP Variable Header
	local variable_header = combine(make_uint16(args.packet_id))
	local props = make_properties(packet_type.PUBCOMP, args)	-- DOC: 3.7.2.2 PUBCOMP Properties
	-- DOC: The Reason Code and Property Length can be omitted if the Reason Code is 0x00 (Success) and there are no Properties. In this case the PUBCOMP has a Remaining Length of 2.
	if props:len() > 1 or args.reason_code ~= 0 then
		variable_header:append(make_uint8(args.reason_code))	-- DOC: 3.7.2.1 PUBCOMP Reason Code
		variable_header:append(props)							-- DOC: 3.7.2.2 PUBCOMP Properties
	end
	-- DOC: 3.7.1 PUBCOMP Fixed Header
	local header = make_header(packet_type.PUBCOMP, 0, variable_header:len())
	return combine(header, variable_header)
end

-- Create SUBSCRIBE packet, DOC: 3.8 SUBSCRIBE - Subscribe request
local function make_packet_subscribe(args)
	-- check args
	assert(type(args.packet_id) == "number", "expecting .packet_id to be a number")
	assert(check_packet_id(args.packet_id), "expecting .packet_id to be a valid Packet Identifier")
	assert(type(args.subscriptions) == "table", "expecting .subscriptions to be a table")
	assert(#args.subscriptions > 0, "expecting .subscriptions to be a non-empty array")
	-- DOC: 3.8.2 SUBSCRIBE Variable Header
	local variable_header = combine(
		make_uint16(args.packet_id),
		make_properties(packet_type.SUBSCRIBE, args)	-- DOC: 3.8.2.1 SUBSCRIBE Properties
	)
	-- DOC: 3.8.3 SUBSCRIBE Payload
	local payload = combine()
	for i, subscription in ipairs(args.subscriptions) do
		assert(type(subscription) == "table", "expecting .subscriptions["..i.."] to be a table")
		assert(type(subscription.topic) == "string", "expecting .subscriptions["..i.."].topic to be a string")
		if subscription.qos ~= nil then -- TODO: maybe remove that check and make .qos mandatory?
			assert(type(subscription.qos) == "number", "expecting .subscriptions["..i.."].qos to be a number")
			assert(check_qos(subscription.qos), "expecting .subscriptions["..i.."].qos to be a valid QoS value")
		end
		assert(type(subscription.no_local) == "boolean", "expecting .subscriptions["..i.."].no_local to be a boolean")
		assert(type(subscription.retain_as_published) == "boolean", "expecting .subscriptions["..i.."].retain_as_published to be a boolean")
		assert(type(subscription.retain_handling) == "number", "expecting .subscriptions["..i.."].retain_handling to be a number")
		assert(check_retain_handling(subscription.retain_handling), "expecting .subscriptions["..i.."].retain_handling to be a valid Retain Handling option")
		-- DOC: 3.8.3.1 Subscription Options
		local so = subscription.qos or 0
		if subscription.no_local then
			so = bor(so, 4) -- set Bit 2
		end
		if subscription.retain_as_published then
			so = bor(so, 8) -- set Bit 3
		end
		so = bor(so, lshift(subscription.retain_handling, 4)) -- set Bit 4 and 5
		payload:append(make_string(subscription.topic))
		payload:append(make_uint8(so))
	end
	-- DOC: 3.8.1 SUBSCRIBE Fixed Header
	local header = make_header(packet_type.SUBSCRIBE, 2, variable_header:len() + payload:len()) -- flags: fixed 0010 bits, DOC: Figure 3‑18 SUBSCRIBE packet Fixed Header
	return combine(header, variable_header, payload)
end

-- Create UNSUBSCRIBE packet, DOC: 3.10 UNSUBSCRIBE – Unsubscribe request
local function make_packet_unsubscribe(args)
	-- check args
	assert(type(args.packet_id) == "number", "expecting .packet_id to be a number")
	assert(check_packet_id(args.packet_id), "expecting .packet_id to be a valid Packet Identifier")
	assert(type(args.subscriptions) == "table", "expecting .subscriptions to be a table")
	assert(#args.subscriptions > 0, "expecting .subscriptions to be a non-empty array")
	-- DOC: 3.10.2 UNSUBSCRIBE Variable Header
	local variable_header = combine(
		make_uint16(args.packet_id),
		make_properties(packet_type.UNSUBSCRIBE, args)	-- DOC: 3.10.2.1 UNSUBSCRIBE Properties
	)
	-- DOC: 3.10.3 UNSUBSCRIBE Payload
	local payload = combine()
	for i, subscription in ipairs(args.subscriptions) do
		assert(type(subscription) == "string", "expecting .subscriptions["..i.."] to be a string")
		payload:append(make_string(subscription))
	end
	-- DOC: 3.10.1 UNSUBSCRIBE Fixed Header
	local header = make_header(packet_type.UNSUBSCRIBE, 2, variable_header:len() + payload:len()) -- flags: fixed 0010 bits, DOC: Figure 3.28 – UNSUBSCRIBE packet Fixed Header
	return combine(header, variable_header, payload)
end

-- Create DISCONNECT packet, DOC: 3.14 DISCONNECT – Disconnect notification
local function make_packet_disconnect(args)
	-- check args
	assert(type(args.reason_code) == "number", "expecting .reason_code to be a number")
	-- DOC: 3.14.2 DISCONNECT Variable Header
	local variable_header = combine()
	local props = make_properties(packet_type.DISCONNECT, args)	-- DOC: 3.14.2.2 DISCONNECT Properties
	-- DOC: The Reason Code and Property Length can be omitted if the Reason Code is 0x00 (Normal disconnecton) and there are no Properties. In this case the DISCONNECT has a Remaining Length of 0.
	if props:len() > 1 or args.reason_code ~= 0 then
		variable_header:append(make_uint8(args.reason_code))	-- DOC: 3.14.2.1 Disconnect Reason Code
		variable_header:append(props)							-- DOC: 3.14.2.2 DISCONNECT Properties
	end
	-- DOC: 3.14.1 DISCONNECT Fixed Header
	local header = make_header(packet_type.DISCONNECT, 2, variable_header:len()) -- flags: fixed 0010 bits, DOC: Figure 3.28 – UNSUBSCRIBE packet Fixed Header
	return combine(header, variable_header)
end

-- Create AUTH packet, DOC: 3.15 AUTH – Authentication exchange
local function make_packet_auth(args)
	-- check args
	assert(type(args.reason_code) == "number", "expecting .reason_code to be a number")
	-- DOC: 3.15.2 AUTH Variable Header
	local variable_header = combine()
	-- DOC: The Reason Code and Property Length can be omitted if the Reason Code is 0x00 (Success) and there are no Properties. In this case the AUTH has a Remaining Length of 0.
	local props = make_properties(packet_type.AUTH, args)		-- DOC: 3.15.2.2 AUTH Properties
	if props:len() > 1 or args.reason_code ~= 0 then
		variable_header:append(make_uint8(args.reason_code))	-- DOC: 3.15.2.1 Authenticate Reason Code
		variable_header:append(props)							-- DOC: 3.15.2.2 AUTH Properties
	end
	-- DOC: 3.15.1 AUTH Fixed Header
	local header = make_header(packet_type.AUTH, 0, variable_header:len())
	return combine(header, variable_header)
end

-- Create packet of given {type: number} in args
function protocol5.make_packet(args)
	assert(type(args) == "table", "expecting args to be a table")
	assert(type(args.type) == "number", "expecting .type number in args")
	local ptype = args.type
	if ptype == packet_type.CONNECT then
		return make_packet_connect(args)
	elseif ptype == packet_type.PUBLISH then
		return make_packet_publish(args)
	elseif ptype == packet_type.PUBACK then
		return make_packet_puback(args)
	elseif ptype == packet_type.PUBREC then
		return make_packet_pubrec(args)
	elseif ptype == packet_type.PUBREL then
		return make_packet_pubrel(args)
	elseif ptype == packet_type.PUBCOMP then
		return make_packet_pubcomp(args)
	elseif ptype == packet_type.SUBSCRIBE then
		return make_packet_subscribe(args)
	elseif ptype == packet_type.UNSUBSCRIBE then
		return make_packet_unsubscribe(args)
	elseif ptype == packet_type.PINGREQ then
		-- DOC: 3.12 PINGREQ – PING request
		return combine("\192\000") -- 192 == 0xC0, type == 12, flags == 0
	elseif ptype == packet_type.DISCONNECT then
		return make_packet_disconnect(args)
	elseif ptype == packet_type.AUTH then
		return make_packet_auth(args)
	else
		error("unexpected packet type to make: "..ptype)
	end
end

-- Parse properties using given read_data function for specified packet type
-- Result will be stored in packet.properties and packet.user_properties
-- Returns false plus string with error message on failure
-- Returns true on success
local function parse_properties(ptype, read_data, input, packet)
	assert(type(read_data) == "function", "expecting read_data to be a function")
	-- DOC: 2.2.2 Properties
	-- parse Property Length
	-- create read_func for parse_var_length and other parse functions, reading from data string instead of network connector
	local len = parse_var_length(read_data)
	-- check data contains enough bytes for reading properties
	if input.available < len then
		return true, "not enough data to parse properties of length "..len
	end
	-- ensure properties and user_properties are presented in packet
	if not packet.properties then
		packet.properties = {}
	end
	if not packet.user_properties then
		packet.user_properties = {}
	end
	-- parse allowed properties
	local uprop_id = properties.user_property
	local allowed = assert(allowed_properties[ptype], "no allowed properties for specified packet type: "..tostring(ptype))
	local props_end = input[1] + len
	while input[1] < props_end do
		-- property id, DOC: 2.2.2.2 Property
		local prop_id, err = parse_var_length(read_data)
		if not prop_id then
			return false, "failed to parse property length: "..err
		end
		if not allowed[prop_id] then
			return false, "property "..prop_id.." is not allowed for packet type "..ptype
		end
		if prop_id == uprop_id then
			-- parse name=value string pair
			local name, value
			name, err = parse_string(read_data)
			if not name then
				return false, "failed to parse user property name: "..err
			end
			value, err = parse_string(read_data)
			if not value then
				return false, "failed to parse user property value: "..err
			end
			packet.user_properties[name] = value
		else
			-- parse property value according its identifier
			local value
			value, err = property_parse[prop_id](read_data)
			if err then
				return false, "failed ro parse property "..prop_id.." value: "..err
			end
			if property_multiple[prop_id] then
				local curr = packet.properties[properties[prop_id]] or {}
				curr[#curr + 1] = value
				packet.properties[properties[prop_id]] = curr
			else
				packet.properties[properties[prop_id]] = value
			end
		end
	end
	return true
end

-- Parse packet using given read_func
-- Returns packet on success or false and error message on failure
function protocol5.parse_packet(read_func)
	assert(type(read_func) == "function", "expecting read_func to be a function")
	-- parse fixed header
	local byte1, byte2, err, len, data, rc, ok, packet, topic, packet_id, reason_code
	byte1, err = read_func(1)
	if not byte1 then
		return false, "failed to read first byte: "..err
	end
	byte1 = str_byte(byte1, 1, 1)
	local ptype = rshift(byte1, 4)
	local flags = band(byte1, 0xF)
	len, err = parse_var_length(read_func)
	if not len then
		return false, "failed to parse remaining length: "..err
	end
	local input = {1, available = 0} -- input data offset and available size
	if len > 0 then
		data, err = read_func(len)
	else
		data = ""
	end
	if not data then
		return false, "failed to read packet data: "..err
	end
	input.available = data:len()
	-- read data function
	local function read_data(size)
		if size > input.available then
			return false, "not enough data to read size: "..size
		end
		local off = input[1]
		local res = str_sub(data, off, off + size - 1)
		input[1] = off + size
		input.available = input.available - size
		return res
	end
	-- parse readed data according type in fixed header
	if ptype == packet_type.CONNACK then
		-- DOC: 3.2 CONNACK – Connect acknowledgement
		if input.available < 3 then
			return false, "expecting data of length 3 bytes or more"
		end
		-- DOC: 3.2.2.1.1 Session Present
		-- DOC: 3.2.2.2 Connect Reason Code
		byte1, byte2 = parse_uint8(read_data), parse_uint8(read_data)
		local sp = (band(byte1, 0x1) ~= 0)
		packet = setmetatable({type=ptype, sp=sp, rc=byte2}, packet_mt)
		-- DOC: 3.2.2.3 CONNACK Properties
		ok, err = parse_properties(ptype, read_data, input, packet)
		if not ok then
			return false, "failed to parse packet properties: "..err
		end
	elseif ptype == packet_type.PUBLISH then
		-- DOC: 3.3 PUBLISH – Publish message
		-- DOC: 3.3.1.1 DUP
		local dup = (band(flags, 0x8) ~= 0)
		-- DOC: 3.3.1.2 QoS
		local qos = band(rshift(flags, 1), 0x3)
		-- DOC: 3.3.1.3 RETAIN
		local retain = (band(flags, 0x1) ~= 0)
		-- DOC: 3.3.2.1 Topic Name
		topic, err = parse_string(read_data)
		if not topic then
			return false, "failed to parse topic: "..err
		end
		-- DOC: 3.3.2.2 Packet Identifier
		if qos > 0 then
			packet_id, err = parse_uint16(read_data)
			if not packet_id then
				return false, "failed to parse packet_id: "..err
			end
		end
		-- DOC: 3.3.2.3 PUBLISH Properties
		packet = setmetatable({type=ptype, dup=dup, qos=qos, retain=retain, packet_id=packet_id, topic=topic}, packet_mt)
		ok, err = parse_properties(ptype, read_data, input, packet)
		if not ok then
			return false, "failed to parse packet properties: "..err
		end
		if input.available > 0 then
			-- DOC: 3.3.3 PUBLISH Payload
			packet.payload = read_data(input.available)
		end
	elseif ptype == packet_type.PUBACK then
		-- DOC: 3.4 PUBACK – Publish acknowledgement
		packet_id, err = parse_uint16(read_data)
		if not packet_id then
			return false, "failed to parse packet_id: "..err
		end
		packet = setmetatable({type=ptype, packet_id=packet_id, reason_code=0, properties={}, user_properties={}}, packet_mt)
		if input.available > 0 then
			-- DOC: 3.4.2.1 PUBACK Reason Code
			reason_code, err = parse_uint8(read_data)
			if not reason_code then
				return false, "failed to parse reason_code: "..err
			end
			packet.reason_code = reason_code
			-- DOC: 3.4.2.2 PUBACK Properties
			ok, err = parse_properties(ptype, read_data, input, packet)
			if not ok then
				return false, "failed to parse packet properties: "..err
			end
		end
	elseif ptype == packet_type.PUBREC then
		-- DOC: 3.5 PUBREC – Publish received (QoS 2 delivery part 1)
		packet_id, err = parse_uint16(read_data)
		if not packet_id then
			return false, "failed to parse packet_id: "..err
		end
		packet = setmetatable({type=ptype, packet_id=packet_id, reason_code=0, properties={}, user_properties={}}, packet_mt)
		if input.available > 0 then
			-- DOC: 3.5.2.1 PUBREC Reason Code
			reason_code, err = parse_uint8(read_data)
			if not reason_code then
				return false, "failed to parse reason_code: "..err
			end
			packet.reason_code = reason_code
			-- DOC: 3.5.2.2 PUBREC Properties
			ok, err = parse_properties(ptype, read_data, input, packet)
			if not ok then
				return false, "failed to parse packet properties: "..err
			end
		end
	elseif ptype == packet_type.PUBREL then
		-- DOC: 3.6 PUBREL – Publish release (QoS 2 delivery part 2)
		packet_id, err = parse_uint16(read_data)
		if not packet_id then
			return false, "failed to parse packet_id: "..err
		end
		packet = setmetatable({type=ptype, packet_id=packet_id, reason_code=0, properties={}, user_properties={}}, packet_mt)
		if input.available > 0 then
			-- DOC: 3.6.2.1 PUBREL Reason Code
			reason_code, err = parse_uint8(read_data)
			if not reason_code then
				return false, "failed to parse reason_code: "..err
			end
			packet.reason_code = reason_code
			-- DOC: 3.6.2.2 PUBREL Properties
			ok, err = parse_properties(ptype, read_data, input, packet)
			if not ok then
				return false, "failed to parse packet properties: "..err
			end
		end
	elseif ptype == packet_type.PUBCOMP then
		-- DOC: 3.7 PUBCOMP – Publish complete (QoS 2 delivery part 3)
		packet_id, err = parse_uint16(read_data)
		if not packet_id then
			return false, "failed to parse packet_id: "..err
		end
		packet = setmetatable({type=ptype, packet_id=packet_id, reason_code=0, properties={}, user_properties={}}, packet_mt)
		if input.available > 0 then
			-- DOC: 3.7.2.1 PUBCOMP Reason Code
			reason_code, err = parse_uint8(read_data)
			if not reason_code then
				return false, "failed to parse reason_code: "..err
			end
			packet.reason_code = reason_code
			-- DOC: 3.7.2.2 PUBCOMP Properties
			ok, err = parse_properties(ptype, read_data, input, packet)
			if not ok then
				return false, "failed to parse packet properties: "..err
			end
		end
	elseif ptype == packet_type.SUBACK then
		-- DOC: 3.9 SUBACK – Subscribe acknowledgement
		-- DOC: 3.9.2 SUBACK Variable Header
		packet_id, err = parse_uint16(read_data)
		if not packet_id then
			return false, "failed to parse packet_id: "..err
		end
		-- DOC: 3.9.2.1 SUBACK Properties
		packet = setmetatable({type=ptype, packet_id=packet_id}, packet_mt)
		ok, err = parse_properties(ptype, read_data, input, packet)
		if not ok then
			return false, "failed to parse packet properties: "..err
		end
		-- DOC: 3.9.3 SUBACK Payload
		local reason_codes = {}
		while input.available > 0 do
			rc, err = parse_uint8(read_data)
			if not rc then
				return false, "failed to parse reason code: "..err
			end
			reason_codes[#reason_codes + 1] = rc
		end
		if not next(reason_codes) then
			return false, "expecting at least one reason code in SUBACK"
		end
		packet.reason_codes = reason_codes -- TODO: reason codes table somewhere should be placed
	elseif ptype == packet_type.UNSUBACK then
		-- DOC: 3.11 UNSUBACK – Unsubscribe acknowledgement
		-- DOC: 3.11.2 UNSUBACK Variable Header
		packet_id, err = parse_uint16(read_data)
		if not packet_id then
			return false, "failed to parse packet_id: "..err
		end
		-- 3.11.2.1 UNSUBACK Properties
		packet = setmetatable({type=ptype, packet_id=packet_id}, packet_mt)
		ok, err = parse_properties(ptype, read_data, input, packet)
		if not ok then
			return false, "failed to parse packet properties: "..err
		end
		-- 3.11.3 UNSUBACK Payload
		local reason_codes = {}
		while input.available > 0 do
			rc, err = parse_uint8(read_data)
			if not rc then
				return false, "failed to parse reason code: "..err
			end
			reason_codes[#reason_codes + 1] = rc
		end
		if not next(reason_codes) then
			return false, "expecting at least one reason code in UNSUBACK"
		end
		packet.reason_codes = reason_codes
	elseif ptype == packet_type.PINGRESP then
		-- DOC: 3.13 PINGRESP – PING response
		packet = setmetatable({type=ptype, properties={}, user_properties={}}, packet_mt)
	elseif ptype == packet_type.DISCONNECT then
		-- DOC: 3.14 DISCONNECT – Disconnect notification
		packet = setmetatable({type=ptype, reason_code=0, properties={}, user_properties={}}, packet_mt)
		if input.available > 0 then
			-- DOC: 3.14.2.1 Disconnect Reason Code
			reason_code, err = parse_uint8(read_data) -- TODO: reason codes table
			if not reason_code then
				return false, "failed to parse reason_code: "..err
			end
			-- DOC: 3.14.2.2 DISCONNECT Properties
			ok, err = parse_properties(ptype, read_data, input, packet)
			if not ok then
				return false, "failed to parse packet properties: "..err
			end
		end
	elseif ptype == packet_type.AUTH then
		-- DOC: 3.15 AUTH – Authentication exchange
		-- DOC: 3.15.2.1 Authenticate Reason Code
		reason_code, err = parse_uint8(read_data) -- TODO: table
		if not reason_code then
			return false, "failed to parse Authenticate Reason Code: "..err
		end
		-- DOC: 3.15.2.2 AUTH Properties
		packet = setmetatable({type=ptype, reason_code=reason_code}, packet_mt)
		ok, err = parse_properties(ptype, read_data, input, packet)
		if not ok then
			return false, "failed to parse packet properties: "..err
		end
	else
		return false, "unexpected packet type received: "..tostring(ptype)
	end
	if input.available > 0 then
		return false, "extra data in remaining length left after packet parsing"
	end
	return packet
end

-- export module table
return protocol5

-- vim: ts=4 sts=4 sw=4 noet ft=lua
