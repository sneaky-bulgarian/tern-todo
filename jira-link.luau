--!strict
-- The protocol between a Todos block (host.luau) and the window's Jira half (jira.luau).
--
-- Host halves have no keychain, so the window owns the Jira connection. A block asks with
-- cx:open(build(op, query)), a "todo-jira:<op>?<query>" link that only this plugin's window
-- claims; the window answers with cx.session:event(pane, { ev = "action", act = ACT, json = … }).
-- Every query carries the block's request number `req`, echoed in the answer so the block can
-- drop stale answers and the duplicates of a second window. Links never carry a secret.

local SCHEME = "todo-jira:"
local ACT = "todo.jira"

local function encode(s: string): string
	return (string.gsub(s, "[^%w%-%._~]", function(c: string): string
		return string.format("%%%02X", string.byte(c))
	end))
end

local function decode(s: string): string
	return (string.gsub(s, "%%(%x%x)", function(h: string): string
		return string.char(tonumber(h, 16) :: number)
	end))
end

local function build(op: string, query: { [string]: string | number }): string
	local keys: { string } = {}
	for k in query do
		table.insert(keys, k)
	end
	table.sort(keys)
	local parts: { string } = {}
	for _, k in keys do
		table.insert(parts, encode(k) .. "=" .. encode(tostring(query[k])))
	end
	return SCHEME .. op .. (if #parts > 0 then "?" .. table.concat(parts, "&") else "")
end

-- The op and query of one of our links; nil for any other URL.
local function parse(url: string): (string?, { [string]: string })
	local query: { [string]: string } = {}
	if string.sub(url, 1, #SCHEME) ~= SCHEME then
		return nil, query
	end
	local op, rest = string.match(string.sub(url, #SCHEME + 1), "^([%w%-]+)%??(.*)$")
	if not op then
		return nil, query
	end
	for pair in string.gmatch(rest or "", "[^&]+") do
		local k, v = string.match(pair, "^([^=]*)=?(.*)$")
		if k and k ~= "" then
			query[decode(k)] = decode(v or "")
		end
	end
	return op, query
end

return { SCHEME = SCHEME, ACT = ACT, build = build, parse = parse, encode = encode }
