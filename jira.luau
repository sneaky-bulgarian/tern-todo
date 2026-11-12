--!strict
-- Jira for the Tickets tab of Todos blocks: the window half (protocol in jira-link.luau).
--
-- The API token sits in the system keychain (tern.secrets "jira.token", which host halves
-- lack); the site URL, the email, the signed-in name, the chosen project and board, and where
-- the task card posts new issues (project; per project its component and issue type) in
-- tern.kv "jira" of this machine. With an email, requests sign in as Jira Cloud expects (Basic
-- email:token); without one the token goes as a Bearer token, which is how Jira Data Center
-- personal access tokens work. Only REST v2 and Agile 1.0 are used: both serve both.

local link = require("./jira-link")

local KV_KEY = "jira"
local SECRET = "jira.token"
-- Issues being created, by the asking block's request ("<pane>:<req>"): every window of a
-- window key gets the block's link, and only the first may create the issue.
local CLAIMS_KEY = "jira.creating"
local CLAIM_S = 600
local BLOCK = "todo-proto.list"
local PANE_MOD = 17592186044416
local PAGE = 50
local MAX_PAGES = 20
local DESCRIPTION_MAX = 20000
local TIMEOUT_MS = 20000
-- Jira's limit on a summary, in characters.
local SUMMARY_MAX = 255
local ISSUE_FIELDS = "summary,status,assignee,issuetype,priority,description,environment"
-- Long text fields a ticket brings along (Definition of Done, Acceptance criteria…): at most
-- TEXT_FIELDS_MAX of the site's multi-line custom fields, each cut to DETAIL_MAX bytes.
local TEXT_FIELDS_MAX = 40
local DETAIL_MAX = 8000
-- createmeta fields the task card fills in itself (title, notes, project, type, component)
-- or that cannot be set when an issue is created.
local OWN_FIELDS = {
	summary = true,
	description = true,
	project = true,
	issuetype = true,
	components = true,
	attachment = true,
	issuelinks = true,
	worklog = true,
	parent = true,
} :: { [string]: boolean }
-- Transition targets tried first, by the transition's or its status's name.
local DONE_NAMES = { "done", "closed", "resolved", "complete", "completed" }

type Project = { key: string, name: string }
type Board = { id: number, name: string, kind: string? }
type Component = { id: string, name: string }
type IssueType = { id: string, name: string }
type TextField = { id: string, name: string }
-- Where the task card posts: the project, and per project key its component (false: none)
-- and its issue type.
type Post = { project: Project?, components: { [string]: Component | boolean }, types: { [string]: IssueType } }
-- `me` is the signed-in user's Jira id (Cloud accountId, Data Center name): the Tickets tab
-- tells your tickets by it.
type Config = { url: string?, email: string?, user: string?, me: string?, project: Project?, board: Board?, post: Post? }
type Query = { [string]: string }
type Reply = { [string]: any }
type Done = (data: any, err: string?, cx: WindowCx?, status: number) -> ()

local function str(v: any): string?
	return if type(v) == "string" and v ~= "" then v else nil
end

local function read_config(): Config
	local ok, raw = pcall(tern.kv.get, KV_KEY)
	local c: { [string]: any } = if ok and type(raw) == "table" then raw else {}
	local p, b, post = c.project, c.board, c.post
	local target: Post? = nil
	if type(post) == "table" then
		local pp = post.project
		local components: { [string]: Component | boolean } = {}
		for key, v in (if type(post.components) == "table" then post.components else {}) do
			if type(key) == "string" and v == false then
				components[key] = false
			elseif type(key) == "string" and type(v) == "table" and str(v.id) then
				components[key] = { id = v.id, name = str(v.name) or v.id }
			end
		end
		local types: { [string]: IssueType } = {}
		for key, v in (if type(post.types) == "table" then post.types else {}) do
			if type(key) == "string" and type(v) == "table" and str(v.id) then
				types[key] = { id = v.id, name = str(v.name) or v.id }
			end
		end
		target = {
			project = if type(pp) == "table" and str(pp.key) then { key = pp.key, name = str(pp.name) or pp.key } else nil,
			components = components,
			types = types,
		}
	end
	return {
		url = str(c.url),
		email = str(c.email),
		user = str(c.user),
		me = str(c.me),
		project = if type(p) == "table" and str(p.key) then { key = p.key, name = str(p.name) or p.key } else nil,
		board = if type(b) == "table" and type(b.id) == "number"
			then { id = b.id, name = str(b.name) or tostring(b.id), kind = str(b.kind) }
			else nil,
		post = target,
	}
end

local function write_config(c: Config): string?
	local ok, err = pcall(tern.kv.set, KV_KEY, c)
	return if ok then nil else tostring(err)
end

-- The keychain is read once per window run; connect and forget keep this copy current.
local token: string? = nil
local token_known = false

local function with_token(cx: WindowCx, fn: (secret: string?, err: string?, cx: WindowCx) -> ())
	if token_known then
		fn(token, nil, cx)
		return
	end
	tern.secrets.get(SECRET):next(function(value: string?, err: string?, fresh: WindowCx?)
		if err == nil then
			token = str(value)
			token_known = true
		end
		if fresh then
			fn(token, err, fresh)
		end
	end)
end

local function snapshot(c: Config): Reply
	return {
		connected = c.url ~= nil and token ~= nil,
		url = c.url,
		email = c.email,
		user = c.user,
		me = c.me,
		project = c.project,
		board = c.board,
		post = c.post,
	}
end

-- Sends the block its answer; `ok` follows `error` unless set.
local function answer(cx: WindowCx?, pane: number, op: string, q: Query, data: Reply)
	if not cx then
		return
	end
	data.op = op
	data.req = q.req
	if data.key == nil then
		data.key = q.key
	end
	if data.ok == nil then
		data.ok = data.error == nil
	end
	pcall(function()
		cx.session:event(pane, { ev = "action", act = link.ACT, json = tern.json.encode(data) })
	end)
end

-- "acme.atlassian.net/" → "https://acme.atlassian.net"; a pasted issue or board link keeps only
-- the site (and a Data Center context path such as /jira).
local function site(text: string?): string?
	local s = string.match(text or "", "^%s*(.-)%s*$") or ""
	if s == "" then
		return nil
	end
	if not string.match(s, "^%a[%w+.-]*://") then
		s = "https://" .. s
	end
	local root, path = string.match(s, "^(%a[%w+.-]*://[^/?#]+)([^?#]*)")
	if not root then
		return nil
	end
	if string.find(root, "%.atlassian%.net$") or string.find(root, "%.jira%.com$") then
		return root
	end
	local p = path or ""
	for _, marker in { "/browse/", "/secure/", "/jira/software/", "/projects/", "/issues/", "/rest/" } do
		local at = string.find(p .. "/", marker, 1, true)
		if at then
			p = string.sub(p, 1, at - 1)
			break
		end
	end
	return root .. (string.gsub(p, "/+$", ""))
end

-- Jira's own words for a failed call (errorMessages, field errors, message) after the status.
local function failure(res: FetchResult): string
	if res.status == 0 then
		return if res.timed_out then "Jira did not answer in time." else "Cannot reach Jira: " .. tostring(res.error)
	end
	local said: { string } = {}
	local ok, body = pcall(tern.json.decode, res.body)
	if ok and type(body) == "table" then
		if type(body.errorMessages) == "table" then
			for _, m in body.errorMessages do
				if type(m) == "string" and m ~= "" then
					table.insert(said, m)
				end
			end
		end
		if type(body.errors) == "table" then
			for k, m in body.errors do
				if type(m) == "string" then
					table.insert(said, tostring(k) .. ": " .. m)
				end
			end
		end
		if #said == 0 and type(body.message) == "string" then
			table.insert(said, body.message)
		end
	end
	-- A 400 is Jira explaining what it will not do; its words say it best.
	if res.status == 400 and #said > 0 then
		return table.concat(said, " ")
	end
	local head = if res.status == 401 then "Jira did not accept the email and token (401)."
		elseif res.status == 403 then "Jira refused access (403)."
		elseif res.status == 404 then "Not found in Jira (404)."
		else "Jira answered " .. res.status .. "."
	return if #said > 0 then head .. " " .. table.concat(said, " ") else head
end

-- One signed request. `done` gets the decoded JSON body ({} when empty) or an error; an error
-- returned here means nothing was sent and `done` never runs.
local function call(c: Config, secret: string, method: string, path: string, body: any, done: Done): string?
	local headers: { [string]: string } = {
		Authorization = if c.email then "Basic " .. tern.base64.encode(c.email .. ":" .. secret) else "Bearer " .. secret,
		Accept = "application/json",
	}
	local payload: string? = nil
	if body ~= nil then
		headers["Content-Type"] = "application/json"
		payload = tern.json.encode(body)
	end
	local opts = { method = method, headers = headers, body = payload, timeout_ms = TIMEOUT_MS }
	local ok, err = pcall(tern.fetch, (c.url :: string) .. path, opts, function(res: FetchResult, cx: WindowCx?)
		if res.status < 200 or res.status >= 300 then
			done(nil, failure(res), cx, res.status)
		elseif string.match(res.body, "^%s*$") then
			done({}, nil, cx, res.status)
		else
			local dok, data = pcall(tern.json.decode, res.body)
			if dok then
				done(data, nil, cx, res.status)
			else
				done(nil, "Jira sent something that is not JSON. Check the Jira URL.", cx, res.status)
			end
		end
	end)
	return if ok then nil else "Cannot call Jira: " .. tostring(err)
end

-- Every item of a paged Jira list, at most MAX_PAGES pages. The items sit in the first of
-- `fields` the answer has: "values" (Agile, Data Center), "issues", or Jira Cloud's names for
-- createmeta pages ("issueTypes", "fields").
local function all(c: Config, secret: string, path: string, fields: { string }, done: Done): string?
	local items: { any } = {}
	local sep = if string.find(path, "?", 1, true) then "&" else "?"
	local function page(start: number, n: number): string?
		return call(c, secret, "GET", path .. sep .. "startAt=" .. start .. "&maxResults=" .. PAGE, nil, function(data, err, cx, status)
			if err then
				done(nil, err, cx, status)
				return
			end
			local got: { any } = {}
			for _, field in fields do
				if type(data) == "table" and type(data[field]) == "table" then
					got = data[field]
					break
				end
			end
			for _, it in got do
				table.insert(items, it)
			end
			local total = if type(data) == "table" then tonumber(data.total) else nil
			local is_last = if type(data) == "table" then data.isLast else nil
			local last = #got == 0 or is_last == true or (total ~= nil and start + #got >= total)
				or (is_last == nil and total == nil and #got < PAGE)
			if last or n >= MAX_PAGES then
				done(items, nil, cx, status)
				return
			end
			local failed = page(start + #got, n + 1)
			if failed then
				done(nil, failed, cx, 0)
			end
		end)
	end
	return page(0, 1)
end

-- Runs `fn` with the configuration and token, or answers that Jira is not connected.
local function connected(cx: WindowCx, pane: number, op: string, q: Query, fn: (c: Config, secret: string, cx: WindowCx) -> ())
	with_token(cx, function(secret, err, fresh)
		local c = read_config()
		if err then
			answer(fresh, pane, op, q, { error = "Cannot read the Jira token from the keychain: " .. err, status = snapshot(c) })
		elseif not secret or not c.url then
			answer(fresh, pane, op, q, { error = "Jira is not connected.", status = snapshot(c) })
		else
			fn(c, secret, fresh)
		end
	end)
end

-- The text of the block's masked token field, read from its surface (node id `field`). The
-- token never travels in a link; this is the one place it crosses from the block.
local function typed_token(cx: WindowCx, pane: number, field: string?): string?
	if not field or field == "" then
		return nil
	end
	local ok, tree = pcall(function()
		return cx.session:surface(pane, { as = "table", root = field })
	end)
	if not ok then
		return nil
	end
	local function find(node: any): string?
		if type(node) ~= "table" then
			return nil
		end
		local p = node.p
		if type(p) == "table" and p.role == "todo-proto.jira-token" then
			return str(string.match(tostring(p.text or ""), "^%s*(.-)%s*$"))
		end
		for _, region in { "main", "dock", "layer" } do
			local found = find(node[region])
			if found then
				return found
			end
		end
		if type(node.c) == "table" then
			for _, child in node.c do
				local found = find(child)
				if found then
					return found
				end
			end
		end
		return nil
	end
	return find(tree)
end

local function clip(s: string, max: number): string
	if #s <= max then
		return s
	end
	local cut = max
	-- Back off to the start of a UTF-8 character.
	while cut > 0 and bit32.band(string.byte(s, cut + 1) or 0, 0xC0) == 0x80 do
		cut -= 1
	end
	return string.sub(s, 1, cut) .. "…"
end

-- An issue of the sprint for the block. `details` are its long text fields (`texts`, in the
-- site's order) that hold something, as { name, text }.
local function ticket_of(issue: any, sprint: string, texts: { TextField }): Reply?
	if type(issue) ~= "table" or not str(issue.key) then
		return nil
	end
	local f = if type(issue.fields) == "table" then issue.fields else {}
	local status = if type(f.status) == "table" then f.status else {}
	local description = str(f.description)
	local details: { Reply } = {}
	for _, field in texts do
		local text = str(f[field.id])
		text = if text then str(string.match(text, "^%s*(.-)%s*$")) else nil
		if text then
			table.insert(details, { name = field.name, text = clip(text, DETAIL_MAX) })
		end
	end
	return {
		key = issue.key,
		summary = str(f.summary) or issue.key,
		status = str(status.name) or "Unknown",
		category = if type(status.statusCategory) == "table" then str(status.statusCategory.key) or "new" else "new",
		kind = if type(f.issuetype) == "table" then str(f.issuetype.name) else nil,
		assignee = if type(f.assignee) == "table" then str(f.assignee.displayName) else nil,
		assignee_id = if type(f.assignee) == "table" then str(f.assignee.accountId) or str(f.assignee.name) else nil,
		priority = if type(f.priority) == "table" then str(f.priority.name) else nil,
		description = if description then clip(description, DESCRIPTION_MAX) else nil,
		details = details,
		sprint = sprint,
	}
end

-- The site's long text fields, read once per window run and site: the system Environment and
-- the multi-line custom fields (Definition of Done, Acceptance criteria…), at most
-- TEXT_FIELDS_MAX. Without the field list (no permission, old Jira) tickets come without them.
local text_fields: { url: string, list: { TextField } }? = nil

local function with_text_fields(c: Config, secret: string, at: WindowCx?, fn: (list: { TextField }, at: WindowCx?) -> ())
	local known = text_fields
	if known and known.url == c.url then
		fn(known.list, at)
		return
	end
	local failed = call(c, secret, "GET", "/rest/api/2/field", nil, function(data, err, after)
		local list: { TextField } = { { id = "environment", name = "Environment" } }
		if err or type(data) ~= "table" then
			fn(list, after)
			return
		end
		for _, f in data do
			local schema = if type(f) == "table" and type(f.schema) == "table" then f.schema else nil
			if schema and f.custom == true and schema.type == "string" and type(schema.custom) == "string"
				and string.find(schema.custom, "textarea", 1, true) and str(f.id) and #list <= TEXT_FIELDS_MAX then
				table.insert(list, { id = f.id, name = str(f.name) or f.id })
			end
		end
		text_fields = { url = c.url :: string, list = list }
		fn(list, after)
	end)
	if failed then
		fn({}, at)
	end
end

local function project_list(items: { any }): { Project }
	local out: { Project } = {}
	for _, p in items do
		if type(p) == "table" and str(p.key) then
			table.insert(out, { key = p.key, name = str(p.name) or p.key })
		end
	end
	table.sort(out, function(a: Project, b: Project): boolean
		return string.lower(a.name) < string.lower(b.name)
	end)
	return out
end

-- The transition to a done status: one named like DONE_NAMES first, else the first of them.
local function pick_transition(list: { any }): any
	local done: { any } = {}
	for _, t in list do
		if type(t) == "table" and str(t.id) and type(t.to) == "table" and type(t.to.statusCategory) == "table"
			and t.to.statusCategory.key == "done" then
			table.insert(done, t)
		end
	end
	for _, wanted in DONE_NAMES do
		for _, t in done do
			if string.lower(str(t.to.name) or "") == wanted or string.lower(str(t.name) or "") == wanted then
				return t
			end
		end
	end
	return done[1]
end

-- A resolution the transition's screen requires (Done or Fixed when offered), else nil.
local function resolution_of(t: any): string?
	local fields = if type(t.fields) == "table" then t.fields else nil
	local r = if fields and type(fields.resolution) == "table" then fields.resolution else nil
	if not r or r.required ~= true or type(r.allowedValues) ~= "table" then
		return nil
	end
	local first: string? = nil
	for _, v in r.allowedValues do
		local name = if type(v) == "table" then str(v.name) else nil
		if name then
			local low = string.lower(name)
			if low == "done" or low == "fixed" then
				return name
			end
			first = first or name
		end
	end
	return first
end

-- A task title as an issue summary: trimmed, at most SUMMARY_MAX characters; nil when empty.
local function summary_of(text: string?): string?
	local s = str(string.match(text or "", "^%s*(.-)%s*$"))
	local n = if s then utf8.len(s) else nil
	if s and n and n > SUMMARY_MAX then
		s = string.sub(s, 1, (utf8.offset(s, SUMMARY_MAX) :: number) - 1) .. "…"
	end
	return s
end

-- The type a task's issue gets: Task when the project has it, else its first standard type
-- (no sub-task, and nothing above the standard level, such as an epic).
local function issue_type(list: any): IssueType?
	if type(list) ~= "table" then
		return nil
	end
	local first: IssueType? = nil
	for _, t in list do
		local id = if type(t) == "table" and (type(t.id) == "string" or type(t.id) == "number") then tostring(t.id) else nil
		if id and t.subtask ~= true then
			local name = str(t.name) or id
			if string.lower(name) == "task" then
				return { id = id, name = name }
			end
			local level = tonumber(t.hierarchyLevel)
			if not first and (level == nil or level == 0) then
				first = { id = id, name = name }
			end
		end
	end
	return first
end

-- The issue types a task can become: every one but sub-tasks, in Jira's order.
local function type_list(list: any): { IssueType }
	local out: { IssueType } = {}
	for _, t in (if type(list) == "table" then list else {}) :: { any } do
		local id = if type(t) == "table" and (type(t.id) == "string" or type(t.id) == "number") then tostring(t.id) else nil
		if id and t.subtask ~= true then
			table.insert(out, { id = id, name = str(t.name) or id })
		end
	end
	return out
end

-- The type asked for (`wanted`, an id) when the project still offers it, else issue_type's.
local function pick_type(list: any, wanted: string?): IssueType?
	if wanted then
		for _, t in type_list(list) do
			if t.id == wanted then
				return t
			end
		end
	end
	return issue_type(list)
end

-- One createmeta field as the task card shows it: { id, name, required, default (Jira fills
-- it when left empty), kind } and per kind:
--   choice   `choices` ({ id, name }), `multi` for a list, `default_name` when Jira says it;
--   text     `multiline` for a multi-line field; number, date, datetime, user, labels;
--   other    a required field the card cannot fill (Jira must be told elsewhere).
-- Nil for the fields the card owns (OWN_FIELDS) and optional ones it cannot fill.
local function field_spec(f: any, key: string?): Reply?
	if type(f) ~= "table" then
		return nil
	end
	local id = str(f.fieldId) or str(f.key) or key
	if not id or OWN_FIELDS[id] then
		return nil
	end
	local schema = if type(f.schema) == "table" then f.schema else {}
	local kind = str(schema.type) or ""
	local custom = str(schema.custom) or ""
	local spec: Reply = {
		id = id,
		name = str(f.name) or id,
		required = f.required == true,
		default = f.hasDefaultValue == true,
	}
	if type(f.allowedValues) == "table" then
		local choices: { Reply } = {}
		for _, v in f.allowedValues do
			local vid = if type(v) == "table" and (type(v.id) == "string" or type(v.id) == "number") then tostring(v.id) else nil
			local name = if vid then str(v.name) or str(v.value) else nil
			if vid and name and v.disabled ~= true and v.archived ~= true then
				table.insert(choices, { id = vid, name = name })
			end
		end
		spec.kind, spec.multi, spec.choices = "choice", kind == "array", choices
		local dv = f.defaultValue
		local first = if type(dv) == "table" and dv[1] ~= nil then dv[1] else dv
		if type(first) == "table" then
			spec.default_name = str(first.name) or str(first.value)
		end
	elseif kind == "string" then
		spec.kind = "text"
		spec.multiline = string.find(custom, "textarea", 1, true) ~= nil or id == "environment"
	elseif kind == "number" or kind == "date" or kind == "datetime" or kind == "user" then
		spec.kind = kind
	elseif kind == "array" and schema.items == "string" then
		spec.kind = "labels"
	elseif spec.required and not spec.default then
		spec.kind = "other"
	else
		return nil
	end
	return spec
end

-- Whether this window is the first to take the block's create request (see CLAIMS_KEY).
local function claim(q: Query): boolean
	if not q.req or not q.pane then
		return true
	end
	local id = q.pane .. ":" .. q.req
	local ok, raw = pcall(tern.kv.get, CLAIMS_KEY)
	local claims: { [string]: any } = if ok and type(raw) == "table" then raw else {}
	if claims[id] ~= nil then
		return false
	end
	local now = os.time()
	local kept: { [string]: number } = { [id] = now }
	for k, at in claims do
		if type(k) == "string" and type(at) == "number" and now - at < CLAIM_S then
			kept[k] = at
		end
	end
	pcall(tern.kv.set, CLAIMS_KEY, kept)
	return true
end

-- Stores where the task card posts: the project, its component (`component` "none" for
-- none; nil keeps the one stored for that project) and its issue type (nil keeps it).
-- Returns an error.
local function set_target(c: Config, key: string, name: string?, component: string?, component_name: string?, kind: IssueType?): string?
	local post: Post = c.post or { project = nil, components = {}, types = {} }
	post.project = { key = key, name = name or key }
	if component == "none" then
		post.components[key] = false
	elseif component then
		post.components[key] = { id = component, name = component_name or component }
	end
	if kind then
		post.types[key] = kind
	end
	c.post = post
	return write_config(c)
end

local ops: { [string]: (cx: WindowCx, pane: number, q: Query) -> () } = {}

ops.status = function(cx, pane, q)
	with_token(cx, function(_secret, err, fresh)
		answer(fresh, pane, "status", q, {
			status = snapshot(read_config()),
			error = if err then "Cannot read the Jira token from the keychain: " .. err else nil,
		})
	end)
end

-- Checks the URL, email and token against /myself, then stores them. An empty token field
-- keeps the stored token, so the URL or email can change without pasting it again.
ops.connect = function(cx, pane, q)
	local url = site(q.url)
	if not url then
		answer(cx, pane, "connect", q, { error = "Enter your Jira URL, like https://your-company.atlassian.net." })
		return
	end
	local typed = typed_token(cx, pane, q.field)
	with_token(cx, function(stored, _err, fresh)
		local secret = typed or stored
		if not secret then
			answer(fresh, pane, "connect", q, { error = "Paste an API token." })
			return
		end
		local old = read_config()
		local c: Config = { url = url, email = str(q.email), user = nil, me = nil, project = nil, board = nil, post = nil }
		if old.url == url then
			c.project, c.board, c.post = old.project, old.board, old.post
		end
		local failed = call(c, secret, "GET", "/rest/api/2/myself", nil, function(me, err, after)
			if err then
				answer(after, pane, "connect", q, { error = err })
				return
			end
			c.user = str(me.displayName) or str(me.emailAddress) or str(me.name) or c.email
			c.me = str(me.accountId) or str(me.name)
			local function finish(final: WindowCx?)
				local werr = write_config(c)
				if werr then
					answer(final, pane, "connect", q, { error = "Cannot save the Jira settings: " .. werr })
					return
				end
				answer(final, pane, "connect", q, { status = snapshot(c) })
			end
			if typed then
				tern.secrets.set(SECRET, typed):next(function(_, serr, final)
					if serr then
						answer(final, pane, "connect", q, { error = "Cannot store the token in the keychain: " .. serr })
						return
					end
					token, token_known = typed, true
					finish(final)
				end)
			else
				finish(after)
			end
		end)
		if failed then
			answer(fresh, pane, "connect", q, { error = failed })
		end
	end)
end

-- Removes the token from the keychain; the URL, email, project and board stay for next time.
ops.forget = function(cx, pane, q)
	tern.secrets.set(SECRET, nil):next(function(_, err, fresh)
		if err then
			answer(fresh, pane, "forget", q, { error = "Cannot remove the token from the keychain: " .. err })
			return
		end
		token, token_known = nil, true
		local c = read_config()
		c.user = nil
		write_config(c)
		answer(fresh, pane, "forget", q, { status = snapshot(c) })
	end)
end

ops.projects = function(cx, pane, q)
	connected(cx, pane, "projects", q, function(c, secret, now)
		-- Older Jira Data Center lacks project/search; /project lists every project at once.
		local function fallback(after: WindowCx?)
			local failed = call(c, secret, "GET", "/rest/api/2/project", nil, function(data, err, last)
				if err then
					answer(last, pane, "projects", q, { error = err })
				else
					answer(last, pane, "projects", q, { projects = project_list(if type(data) == "table" then data else {}) })
				end
			end)
			if failed then
				answer(after, pane, "projects", q, { error = failed })
			end
		end
		local failed = all(c, secret, "/rest/api/2/project/search?orderBy=name", { "values" }, function(items, err, after, status)
			if items then
				answer(after, pane, "projects", q, { projects = project_list(items) })
			elseif status == 404 then
				fallback(after)
			else
				answer(after, pane, "projects", q, { error = err })
			end
		end)
		if failed then
			answer(now, pane, "projects", q, { error = failed })
		end
	end)
end

ops.boards = function(cx, pane, q)
	local project = str(q.project)
	if not project then
		answer(cx, pane, "boards", q, { error = "Pick a project first." })
		return
	end
	connected(cx, pane, "boards", q, function(c, secret, now)
		local path = "/rest/agile/1.0/board?projectKeyOrId=" .. link.encode(project)
		local failed = all(c, secret, path, { "values" }, function(items, err, after)
			if not items then
				answer(after, pane, "boards", q, { error = err, project = project })
				return
			end
			local boards: { Board } = {}
			for _, b in items do
				if type(b) == "table" and type(b.id) == "number" then
					table.insert(boards, { id = b.id, name = str(b.name) or tostring(b.id), kind = str(b.type) })
				end
			end
			answer(after, pane, "boards", q, { project = project, boards = boards })
		end)
		if failed then
			answer(now, pane, "boards", q, { error = failed, project = project })
		end
	end)
end

-- Stores the chosen project and/or board; a new project drops the board of the old one.
ops.select = function(cx, pane, q)
	local c = read_config()
	local project = str(q.project)
	if project then
		if not c.project or c.project.key ~= project then
			c.board = nil
		end
		c.project = { key = project, name = str(q.project_name) or project }
	end
	local id = tonumber(q.board)
	if id then
		c.board = { id = id, name = str(q.board_name) or tostring(id), kind = str(q.board_kind) }
	end
	local err = write_config(c)
	with_token(cx, function(_secret, _err, fresh)
		answer(fresh, pane, "select", q, {
			status = snapshot(c),
			error = if err then "Cannot save the Jira settings: " .. err else nil,
		})
	end)
end

-- Runs `fn` once `c.me` is known: a connection made before it was stored asks /myself once
-- and keeps the answer. Without it, `fn` still runs (the block then goes by display name).
local function with_identity(c: Config, secret: string, at: WindowCx?, fn: (at: WindowCx?) -> ())
	if c.me then
		fn(at)
		return
	end
	local failed = call(c, secret, "GET", "/rest/api/2/myself", nil, function(me, err, after)
		c.me = if not err and type(me) == "table" then str(me.accountId) or str(me.name) else nil
		local stored = read_config()
		if c.me and stored.url == c.url then
			stored.me = c.me
			write_config(stored)
		end
		fn(after)
	end)
	if failed then
		fn(at)
	end
end

-- The active sprints of the board (q.board, else the stored one) and every issue in them,
-- with the site's long text fields (with_text_fields) and who you are (`me`).
ops.sprint = function(cx, pane, q)
	connected(cx, pane, "sprint", q, function(c, secret, now)
		local board = tonumber(q.board) or (if c.board then c.board.id else nil)
		if not board then
			answer(now, pane, "sprint", q, { error = "Pick a board first." })
			return
		end
		local function fetch(texts: { TextField }, at: WindowCx?)
			local wanted = ISSUE_FIELDS
			for _, f in texts do
				if f.id ~= "environment" then
					wanted ..= "," .. f.id
				end
			end
			local failed = all(c, secret, "/rest/agile/1.0/board/" .. board .. "/sprint?state=active", { "values" }, function(found, err, after)
				if not found then
					answer(after, pane, "sprint", q, { error = err, board = board })
					return
				end
				local sprints: { Reply } = {}
				for _, s in found do
					if type(s) == "table" and type(s.id) == "number" then
						table.insert(sprints, { id = s.id, name = str(s.name) or ("Sprint " .. s.id), ends = str(s.endDate) })
					end
				end
				local tickets: { Reply } = {}
				local function load(i: number, later: WindowCx?)
					local s = sprints[i]
					if not s then
						answer(later, pane, "sprint", q, { board = board, sprints = sprints, tickets = tickets, me = c.me })
						return
					end
					local path = "/rest/agile/1.0/sprint/" .. s.id .. "/issue?fields=" .. wanted
					local sfailed = all(c, secret, path, { "issues" }, function(issues, ierr, last)
						if not issues then
							answer(last, pane, "sprint", q, { error = ierr, board = board })
							return
						end
						for _, issue in issues do
							local t = ticket_of(issue, s.name, texts)
							if t then
								table.insert(tickets, t)
							end
						end
						load(i + 1, last)
					end)
					if sfailed then
						answer(later, pane, "sprint", q, { error = sfailed, board = board })
					end
				end
				load(1, after)
			end)
			if failed then
				answer(at, pane, "sprint", q, { error = failed, board = board })
			end
		end
		with_identity(c, secret, now, function(known)
			with_text_fields(c, secret, known, fetch)
		end)
	end)
end

-- Moves the issue to a done status, unless it is in one already.
ops.done = function(cx, pane, q)
	local key = str(q.key)
	if not key then
		answer(cx, pane, "done", q, { error = "No issue key." })
		return
	end
	local path = "/rest/api/2/issue/" .. link.encode(key)
	connected(cx, pane, "done", q, function(c, secret, now)
		local function fail(at: WindowCx?, err: string?)
			answer(at, pane, "done", q, { error = err or "Unknown error" })
		end
		local failed = call(c, secret, "GET", path .. "?fields=status", nil, function(issue, err, after)
			if err then
				fail(after, err)
				return
			end
			local fields = if type(issue) == "table" and type(issue.fields) == "table" then issue.fields else {}
			local st = if type(fields.status) == "table" then fields.status else {}
			if type(st.statusCategory) == "table" and st.statusCategory.key == "done" then
				answer(after, pane, "done", q, { jira_status = str(st.name), already = true })
				return
			end
			local tfailed = call(c, secret, "GET", path .. "/transitions?expand=transitions.fields", nil, function(data, terr, later)
				if terr then
					fail(later, terr)
					return
				end
				local list = if type(data) == "table" and type(data.transitions) == "table" then data.transitions else {}
				local t = pick_transition(list)
				if not t then
					local names: { string } = {}
					for _, x in list do
						if type(x) == "table" and str(x.name) then
							table.insert(names, x.name)
						end
					end
					fail(later, "No transition of " .. key .. " leads to a done status"
						.. (if #names > 0 then " (it offers: " .. table.concat(names, ", ") .. ")." else "."))
					return
				end
				local body: { [string]: any } = { transition = { id = t.id } }
				local resolution = resolution_of(t)
				if resolution then
					body.fields = { resolution = { name = resolution } }
				end
				local pfailed = call(c, secret, "POST", path .. "/transitions", body, function(_, perr, last)
					if perr then
						fail(last, perr)
					else
						answer(last, pane, "done", q, { jira_status = str(t.to.name) or "Done" })
					end
				end)
				if pfailed then
					fail(later, pfailed)
				end
			end)
			if tfailed then
				fail(after, tfailed)
			end
		end)
		if failed then
			fail(now, failed)
		end
	end)
end

-- The components of a project, for the task card's Component row, sorted by name.
ops.components = function(cx, pane, q)
	local project = str(q.project)
	if not project then
		answer(cx, pane, "components", q, { error = "Pick a project first." })
		return
	end
	connected(cx, pane, "components", q, function(c, secret, now)
		local path = "/rest/api/2/project/" .. link.encode(project) .. "/components"
		local failed = call(c, secret, "GET", path, nil, function(data, err, after)
			if err then
				answer(after, pane, "components", q, { error = err, project = project })
				return
			end
			local list: { Component } = {}
			for _, it in (if type(data) == "table" then data else {}) :: { any } do
				local id = if type(it) == "table" and (type(it.id) == "string" or type(it.id) == "number") then tostring(it.id) else nil
				local name = if id then str(it.name) else nil
				if id and name then
					table.insert(list, { id = id, name = name })
				end
			end
			table.sort(list, function(a: Component, b: Component): boolean
				return string.lower(a.name) < string.lower(b.name)
			end)
			answer(after, pane, "components", q, { project = project, components = list })
		end)
		if failed then
			answer(now, pane, "components", q, { error = failed, project = project })
		end
	end)
end

-- Stores where the task card posts: q.project (q.project_name), q.component, a component id
-- ("none" for none; absent keeps the project's stored one), and q.type (q.type_name), an
-- issue type id (absent keeps the stored one).
ops.target = function(cx, pane, q)
	local c = read_config()
	local project = str(q.project)
	local kind: IssueType? = if str(q.type) then { id = q.type, name = str(q.type_name) or q.type } else nil
	local err = if project then set_target(c, project, str(q.project_name), str(q.component), str(q.component_name), kind) else nil
	with_token(cx, function(_secret, _err, fresh)
		answer(fresh, pane, "target", q, {
			status = snapshot(c),
			error = if err then "Cannot save the Jira settings: " .. err else nil,
		})
	end)
end

-- What the task card can fill in for a new issue of q.project: its issue types and, for
-- q.type (an id; else issue_type's pick, and `default` says so), the fields of that type's
-- create screen as field_spec describes them, in Jira's order, and whether its description
-- (the task's notes) is required. Jira Data Center before 8.4 only has the old createmeta,
-- which lists every type's fields at once.
ops.meta = function(cx, pane, q)
	local project = str(q.project)
	if not project then
		answer(cx, pane, "meta", q, { error = "Pick a project first." })
		return
	end
	local function fail(at: WindowCx?, err: string?)
		answer(at, pane, "meta", q, { project = project, error = err or "Unknown error" })
	end
	-- `raw` holds the createmeta fields, with their ids as keys or not (newer createmeta).
	local function reply(at: WindowCx?, list: any, kind: IssueType, raw: { [any]: any }, sorted: boolean)
		local fields: { Reply } = {}
		local notes_required = false
		for key, f in raw do
			local id = if type(f) == "table" then str(f.fieldId) or str(f.key) or (if type(key) == "string" then key else nil) else nil
			if id == "description" and f.required == true then
				notes_required = true
			end
			local spec = field_spec(f, if type(key) == "string" then key else nil)
			if spec then
				table.insert(fields, spec)
			end
		end
		if sorted then
			-- The old createmeta keys fields by id, so its order is lost: required first.
			table.sort(fields, function(a: Reply, b: Reply): boolean
				if a.required ~= b.required then
					return a.required == true
				end
				return string.lower(a.name) < string.lower(b.name)
			end)
		end
		answer(at, pane, "meta", q, {
			project = project,
			types = type_list(list),
			type = kind,
			default = str(q.type) ~= kind.id,
			fields = fields,
			notes_required = notes_required,
		})
	end
	connected(cx, pane, "meta", q, function(c, secret, now)
		local base = "/rest/api/2/issue/createmeta/" .. link.encode(project) .. "/issuetypes"
		local function legacy(at: WindowCx?)
			local path = "/rest/api/2/issue/createmeta?projectKeys=" .. link.encode(project) .. "&expand=projects.issuetypes.fields"
			local failed = call(c, secret, "GET", path, nil, function(data, err, later)
				if err then
					fail(later, err)
					return
				end
				local p = if type(data) == "table" and type(data.projects) == "table" then data.projects[1] else nil
				local list = if type(p) == "table" and type(p.issuetypes) == "table" then p.issuetypes else {}
				local kind = pick_type(list, str(q.type))
				if not kind then
					fail(later, "Jira offers no issue type to create in " .. project .. ".")
					return
				end
				local raw: { [any]: any } = {}
				for _, t in list do
					if type(t) == "table" and tostring(t.id) == kind.id and type(t.fields) == "table" then
						raw = t.fields
					end
				end
				reply(later, list, kind, raw, true)
			end)
			if failed then
				fail(at, failed)
			end
		end
		local failed = all(c, secret, base, { "values", "issueTypes", "results" }, function(list, err, after, status)
			if not list then
				if status == 404 then
					legacy(after)
				else
					fail(after, err)
				end
				return
			end
			local kind = pick_type(list, str(q.type))
			if not kind then
				fail(after, "Jira offers no issue type to create in " .. project .. ".")
				return
			end
			local path = base .. "/" .. link.encode(kind.id)
			local ffailed = all(c, secret, path, { "fields", "values", "results" }, function(items, ferr, later)
				if not items then
					fail(later, ferr)
					return
				end
				reply(later, list, kind, items, false)
			end)
			if ffailed then
				fail(after, ffailed)
			end
		end)
		if failed then
			fail(now, failed)
		end
	end)
end

-- Creates an issue from the task q.task: q.summary, q.description, the issue type q.type
-- (q.type_name; without one the project's issue_type), the component q.component (empty:
-- none) and q.fields, a JSON object of further field values already in Jira's shape. The
-- user fields listed in q.users (comma-separated ids) are set to the signed-in user. Then
-- stores that project, component and type as the task card's target.
ops.create = function(cx, pane, q)
	local project = str(q.project)
	local summary = summary_of(q.summary)
	if not project or not summary then
		answer(cx, pane, "create", q, { task = q.task, error = if project then "The task has no title." else "Pick a Jira project first." })
		return
	end
	if not claim(q) then
		return
	end
	local component = str(q.component)
	local extra: { [string]: any } = {}
	if str(q.fields) then
		local ok, decoded = pcall(tern.json.decode, q.fields)
		if ok and type(decoded) == "table" then
			extra = decoded
		end
	end
	local users: { string } = {}
	for id in string.gmatch(q.users or "", "[^,]+") do
		table.insert(users, id)
	end
	local function fail(at: WindowCx?, err: string?)
		answer(at, pane, "create", q, { task = q.task, error = err or "Unknown error" })
	end
	connected(cx, pane, "create", q, function(c, secret, now)
		local function post(at: WindowCx?, kind: IssueType, me: Reply?)
			local fields: { [string]: any } = {}
			for id, value in extra do
				if type(id) == "string" and not OWN_FIELDS[id] then
					fields[id] = value
				end
			end
			for _, id in users do
				fields[id] = me
			end
			fields.project = { key = project }
			fields.summary = summary
			fields.issuetype = { id = kind.id }
			if str(q.description) then
				fields.description = q.description
			end
			if component then
				fields.components = { { id = component } }
			end
			local pfailed = call(c, secret, "POST", "/rest/api/2/issue", { fields = fields }, function(made, perr, later)
				if perr then
					fail(later, perr)
					return
				end
				local key = if type(made) == "table" then str(made.key) else nil
				if not key then
					fail(later, "Jira did not say which issue it created.")
					return
				end
				local stored = read_config()
				local werr = set_target(stored, project, str(q.project_name), component or "none", str(q.component_name), kind)
				answer(later, pane, "create", q, {
					task = q.task,
					key = key,
					url = (c.url :: string) .. "/browse/" .. key,
					kind = kind.name,
					project_name = str(q.project_name) or project,
					component_name = if component then str(q.component_name) or component else nil,
					status = snapshot(stored),
					warning = if werr then "Cannot save the Jira settings: " .. werr else nil,
				})
			end)
			if pfailed then
				fail(at, pfailed)
			end
		end
		-- User fields set to "me": Jira Cloud names users by accountId, Data Center by name.
		local function as_me(at: WindowCx?, kind: IssueType)
			if #users == 0 then
				post(at, kind, nil)
				return
			end
			local failed = call(c, secret, "GET", "/rest/api/2/myself", nil, function(me, err, later)
				if err then
					fail(later, err)
					return
				end
				local who: Reply? = if type(me) ~= "table" then nil
					elseif str(me.accountId) then { accountId = me.accountId }
					elseif str(me.name) then { name = me.name }
					else nil
				if not who then
					fail(later, "Jira did not say who you are, so the fields set to you cannot be filled.")
					return
				end
				post(later, kind, who)
			end)
			if failed then
				fail(at, failed)
			end
		end
		if str(q.type) then
			as_me(now, { id = q.type, name = str(q.type_name) or q.type })
			return
		end
		local path = "/rest/api/2/project/" .. link.encode(project) .. "?expand=issueTypes"
		local failed = call(c, secret, "GET", path, nil, function(info, err, after)
			if err then
				fail(after, err)
				return
			end
			local kind = issue_type(if type(info) == "table" then info.issueTypes else nil)
			if not kind then
				fail(after, "Jira offers no issue type to create in " .. project .. ".")
				return
			end
			as_me(after, kind)
		end)
		if failed then
			fail(now, failed)
		end
	end)
end

-- The Todos block that asked. A block's effects reach its window even from a hidden tab, but
-- the link's pane is then the window's focused one, so the block also sends its own id (the
-- id on its host; window ids add host * PANE_MOD, as in window.luau).
local function asker(cx: WindowCx, req: LinkRequest, q: Query): number
	local want = tonumber(q.pane)
	if not want then
		return req.pane
	end
	local ok, panes = pcall(function()
		return cx.session:panes()
	end)
	local found: number? = nil
	if ok and type(panes) == "table" then
		for _, p in panes do
			if type(p) == "table" and p.block == BLOCK and type(p.pane) == "number" and p.pane % PANE_MOD == want % PANE_MOD then
				if p.pane == req.pane then
					return p.pane
				end
				found = found or p.pane
			end
		end
	end
	return found or req.pane
end

tern.route.link(function(req: LinkRequest, cx: WindowCx): RouteDecision?
	local op, q = link.parse(req.url)
	if not op then
		return nil
	end
	local run = ops[op]
	if run then
		local pane = asker(cx, req, q)
		local ok, err = pcall(run, cx, pane, q)
		if not ok then
			answer(cx, pane, op, q, { error = tostring(err) })
		end
	end
	return { handled = true }
end)

return {}
