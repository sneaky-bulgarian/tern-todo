--!strict
-- Jira for the Tickets tab of Todos blocks: the window half (protocol in jira-link.luau).
--
-- The API token sits in the system keychain (tern.secrets "jira.token", which host halves
-- lack); the site URL, the email, the signed-in name and the chosen project and board in
-- tern.kv "jira" of this machine. With an email, requests sign in as Jira Cloud expects
-- (Basic email:token); without one the token goes as a Bearer token, which is how Jira Data
-- Center personal access tokens work. Only REST v2 and Agile 1.0 are used: both serve both.

local link = require("./jira-link")

local KV_KEY = "jira"
local SECRET = "jira.token"
local BLOCK = "todo-proto.list"
local PANE_MOD = 17592186044416
local PAGE = 50
local MAX_PAGES = 20
local DESCRIPTION_MAX = 20000
local TIMEOUT_MS = 20000
local ISSUE_FIELDS = "summary,status,assignee,issuetype,priority,description"
-- Transition targets tried first, by the transition's or its status's name.
local DONE_NAMES = { "done", "closed", "resolved", "complete", "completed" }

type Project = { key: string, name: string }
type Board = { id: number, name: string, kind: string? }
type Config = { url: string?, email: string?, user: string?, project: Project?, board: Board? }
type Query = { [string]: string }
type Reply = { [string]: any }
type Done = (data: any, err: string?, cx: WindowCx?, status: number) -> ()

local function str(v: any): string?
	return if type(v) == "string" and v ~= "" then v else nil
end

local function read_config(): Config
	local ok, raw = pcall(tern.kv.get, KV_KEY)
	local c: { [string]: any } = if ok and type(raw) == "table" then raw else {}
	local p, b = c.project, c.board
	return {
		url = str(c.url),
		email = str(c.email),
		user = str(c.user),
		project = if type(p) == "table" and str(p.key) then { key = p.key, name = str(p.name) or p.key } else nil,
		board = if type(b) == "table" and type(b.id) == "number"
			then { id = b.id, name = str(b.name) or tostring(b.id), kind = str(b.kind) }
			else nil,
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
		project = c.project,
		board = c.board,
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

-- Every item of a paged Jira list (`field` is "values" or "issues"), at most MAX_PAGES pages.
local function all(c: Config, secret: string, path: string, field: string, done: Done): string?
	local items: { any } = {}
	local sep = if string.find(path, "?", 1, true) then "&" else "?"
	local function page(start: number, n: number): string?
		return call(c, secret, "GET", path .. sep .. "startAt=" .. start .. "&maxResults=" .. PAGE, nil, function(data, err, cx, status)
			if err then
				done(nil, err, cx, status)
				return
			end
			local got = if type(data) == "table" and type(data[field]) == "table" then data[field] else {}
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

local function ticket_of(issue: any, sprint: string): Reply?
	if type(issue) ~= "table" or not str(issue.key) then
		return nil
	end
	local f = if type(issue.fields) == "table" then issue.fields else {}
	local status = if type(f.status) == "table" then f.status else {}
	local description = str(f.description)
	return {
		key = issue.key,
		summary = str(f.summary) or issue.key,
		status = str(status.name) or "Unknown",
		category = if type(status.statusCategory) == "table" then str(status.statusCategory.key) or "new" else "new",
		kind = if type(f.issuetype) == "table" then str(f.issuetype.name) else nil,
		assignee = if type(f.assignee) == "table" then str(f.assignee.displayName) else nil,
		priority = if type(f.priority) == "table" then str(f.priority.name) else nil,
		description = if description then clip(description, DESCRIPTION_MAX) else nil,
		sprint = sprint,
	}
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
		local c: Config = { url = url, email = str(q.email), user = nil, project = nil, board = nil }
		if old.url == url then
			c.project, c.board = old.project, old.board
		end
		local failed = call(c, secret, "GET", "/rest/api/2/myself", nil, function(me, err, after)
			if err then
				answer(after, pane, "connect", q, { error = err })
				return
			end
			c.user = str(me.displayName) or str(me.emailAddress) or str(me.name) or c.email
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
		local failed = all(c, secret, "/rest/api/2/project/search?orderBy=name", "values", function(items, err, after, status)
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
		local failed = all(c, secret, path, "values", function(items, err, after)
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

-- The active sprints of the board (q.board, else the stored one) and every issue in them.
ops.sprint = function(cx, pane, q)
	connected(cx, pane, "sprint", q, function(c, secret, now)
		local board = tonumber(q.board) or (if c.board then c.board.id else nil)
		if not board then
			answer(now, pane, "sprint", q, { error = "Pick a board first." })
			return
		end
		local failed = all(c, secret, "/rest/agile/1.0/board/" .. board .. "/sprint?state=active", "values", function(found, err, after)
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
			local function load(i: number, at: WindowCx?)
				local s = sprints[i]
				if not s then
					answer(at, pane, "sprint", q, { board = board, sprints = sprints, tickets = tickets })
					return
				end
				local path = "/rest/agile/1.0/sprint/" .. s.id .. "/issue?fields=" .. ISSUE_FIELDS
				local sfailed = all(c, secret, path, "issues", function(issues, ierr, later)
					if not issues then
						answer(later, pane, "sprint", q, { error = ierr, board = board })
						return
					end
					for _, issue in issues do
						local t = ticket_of(issue, s.name)
						if t then
							table.insert(tickets, t)
						end
					end
					load(i + 1, later)
				end)
				if sfailed then
					answer(at, pane, "sprint", q, { error = sfailed, board = board })
				end
			end
			load(1, after)
		end)
		if failed then
			answer(now, pane, "sprint", q, { error = failed, board = board })
		end
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
