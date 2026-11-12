--!strict
-- The file is re-read every 5 seconds, except while a text field or popover has focus.
--
-- Keys (no field focused): j/k or up/down move, space or x toggles done, Enter
-- focuses the linked pane, resumes the linked omp chat in a new tab, or starts
-- the task in omp; Tab or a opens a new task card and the add field, e edits the notes, F2 or n renames the task,
-- p picks the project, r reloads the file, z archives or restores, Delete or Backspace
-- deletes (press twice), Z shows or hides the archived section. Alt+Up / Alt+Down (or
-- cmd+shift+Up / Down) move the selected task one place within its group. Double-clicking a
-- row selects it, opens its card and does what Enter does. The grip at the right of a row
-- picks the task up; the next click on a row drops it there (Esc or the grip again cancels).
-- Keys (field focused): typing edits the field, Enter adds the task (add row), saves the
-- title or inserts a newline (notes), Tab commits; Esc discards title/notes drafts.
--
-- Settings: the bottom-right gear, the `,` key (no field focused) and the palette command
-- "Todo: settings" open a centred sheet of switches (see SETTINGS), kept in tern.kv "settings"
-- and shared by every block and window. Up/Down, Space/Enter toggle, Esc or `,` closes.
--
-- Times: the block stamps the tasks it changes with ISO UTC `created` (new tasks), `updated` (any
-- change of that task; a reorder is none) and `completed` (while done). Each row shows the age
-- of `completed` (done), the later of `updated` and the linked omp session file's mtime, or
-- `updated`/`created`, as now/Nm/Nh/Nd/Nw/Nmo/Ny; tasks without a valid stamp show nothing.
--
-- Fields are natively edited: the block opts into `features = {"edit", "undo"}`, so Tern
-- keeps the selection (shift-arrows, drag, double/triple click, cmd+a) and sends edits as
-- `edit` events and cmd+z as `undo`. The block's `Field` model applies those, plus the
-- keys Tern leaves to the program (typing, deletes, word moves, ctrl+a, redo).
--
-- Jira tickets tab: the window half holds the connection (jira.luau; the token is in the
-- keychain) and this block asks it over "todo-jira:" links (jira-link.luau). The tab lists the
-- active sprint of the chosen board, grouped by assignee (you first) or status, or not at all,
-- and optionally only your tickets (Jira.view, kept in tern.kv "jira_view"). Keys: j/k move,
-- Enter starts the ticket (adds it as a task linked by `jira.key` and launches it like Enter
-- on a task), a adds it without starting, o opens it in Jira, m only mine, s grouping, r
-- reloads, p picks the project, b the board, c edits the connection. A linked task that turns
-- done moves its issue to a done status in Jira (see `rewrite`).
--
-- Task card → Jira: while Jira is connected, an unlinked open task's card is also the draft of
-- its Jira issue: project, issue type, component, and the fields Jira's create screen has for
-- that type (required ones, long texts such as Definition of Done, priority, labels…; the rest
-- behind "more fields"). Post to Jira (Add and post to Jira on a new task) creates the issue:
-- title as summary, notes as description. Nothing stored preselects the Tickets tab's project
-- (else Jira's first), Jira's default type and the project's first component; a pick or a post
-- stores them (jira.target). Field values stay on the task (`jira_fields`) until it is posted.

local ui = tern.ui
local session = require("./session")
local json = require("./json")
require("./session-import")
local auto_import = require("./auto-import")
local session_files = require("./session-files")
-- The Tickets tab's functions and constants live in this one table, and the task card's in
-- `card`: the chunk is at Luau's limit of 200 locals.
local jira = {}
jira.link = require("./jira-link")
local card = {}

local POLL_MS = 5 * 1000
-- fswatch reports a file change within about WATCH_LATENCY_S; POLL_MS stays as the fallback when it is missing or misses an event.
local FSWATCH = "/opt/homebrew/bin/fswatch"
local WATCH_LATENCY_S = "0.1"
local WATCH_RUN_MS = 15 * 1000
local TERN = require("./executable").tern_bin()
local ROLE = "todo-proto."
local PRIORITIES = { "none", "low", "medium", "high", "urgent" }
local PRIORITY_LABEL: { [string]: string } = {
	none = "No priority",
	low = "Low",
	medium = "Medium",
	high = "High",
	urgent = "Urgent",
}
local PRIORITY_TONE: { [string]: string } = {
	urgent = "error",
	high = "warning",
	medium = "accent",
	low = "neutral",
	none = "muted",
}
-- Tone of the priority pill: No priority and Medium stay uncoloured.
local PILL_TONE: { [string]: string } = { low = "muted", high = "warning", urgent = "error" }
-- Thinking levels as omp lists them for a model with reasoning: off, auto, then the
-- model's own efforts (cycleThinkingLevel in omp's model-controls.ts). Used for the
-- default model, whose efforts are not known.
local DEFAULT_EFFORTS = { "minimal", "low", "medium", "high", "xhigh", "max" }
local LEVEL_LABEL: { [string]: string } = {
	off = "Off",
	minimal = "Minimal",
	low = "Low",
	medium = "Medium",
	high = "High",
	xhigh = "Extra high",
	max = "Max",
	auto = "Auto",
}
local STATUS_LABEL: { [string]: string } = {
	starting = "Starting",
	running = "Working",
	needs = "Needs you",
	review = "Ready for you",
	stopped = "Stopped",
}
-- Window-side omp states (cx.agents:list) and debug words mapped to status kinds.
local KIND_OF_STATE: { [string]: string } = {
	working = "running",
	waiting_input = "needs",
	idle = "review",
	exited = "stopped",
	running = "running",
	needs = "needs",
	review = "review",
	stopped = "stopped",
	starting = "starting",
	todo = "todo",
}
local STARTING_S = 8
-- Rows PageUp/PageDown move in a popover.
local PAGE_ROWS = 8
-- Longest task title, in UTF-16 units.
local TITLE_MAX = 500
-- Popovers that have a search field; the others are plain lists.
local SEARCH: { [string]: string } = {
	project = "Search projects",
	model = "Search models",
	chat = "Search chats",
	jira_project = "Search projects",
	jira_board = "Search boards",
	jira_target = "Search projects",
	jira_component = "Search components",
	jira_type = "Search issue types",
	jira_field = "Search values",
}

-- Settings (tern.kv "settings", shared by every Todos block and window; absent keys use
-- their default). Each one gates something real below.
local SETTINGS_KEY = "settings"
local SETTINGS: { { id: string, label: string, hint: string, default: boolean } } = {
	{ id = "time", label = "Show time on rows", hint = "How long ago a task was last touched, at the right of the row.", default = true },
	{ id = "row_actions", label = "Show row action icons", hint = "Done, move to backlog, archive and delete buttons on hovered rows.", default = true },
	{ id = "close_on_done", label = "Close pane on done, archive or backlog", hint = "Closes the linked pane unless the agent is busy.", default = true },
	{ id = "reopen_on_undone", label = "Reopen chat when a task is not done", hint = "Not done resumes the task's omp chat in a new tab.", default = true },
	{ id = "focus_on_start", label = "Open pane when a task starts", hint = "Switch to the new tab right away. Off opens it in the background.", default = true },
	{ id = "new_chat_worktree", label = "Create new chats in a worktree", hint = "Start new chats in a separate Git worktree. Existing chats keep their directory.", default = true },
	{ id = "dblclick", label = "Double-click opens pane", hint = "Double-click does what Enter does: focus, resume or start.", default = true },
	{ id = "archived", label = "Show archived section", hint = "The Archived list below the tasks.", default = true },
	{ id = "badges", label = "Show badges on rows", hint = "Priority, pane and omp chips under the title.", default = true },
	{ id = "status_line", label = "Show agent status on rows", hint = "Working, Needs you, Ready for you or Stopped under the title.", default = true },
	{ id = "hints", label = "Show key hints", hint = "The line of keyboard shortcuts at the bottom of the block.", default = true },
	{ id = "done_group", label = "Done tasks as a separate group", hint = "Collapse completed tasks into their own Done section.", default = false },
	{ id = "omp_titles", label = "Task titles from omp", hint = "Default for linked tasks, which take the title omp gives their session. Each task has its own switch; renaming a task turns it off.", default = false },
}
-- Jira: a sprint is refetched when the Tickets tab opens after STALE_S; a request the window
-- leaves unanswered for WAIT_MS is given up. TONE colours a ticket's status badge by its Jira
-- status category.
jira.STALE_S = 60
jira.WAIT_MS = 120 * 1000
jira.TONE = { new = "muted", indeterminate = "accent", done = "success" } :: { [string]: string }
jira.TOKEN_PAGE = "https://id.atlassian.com/manage-profile/security/api-tokens"
-- How the tab groups tickets (Jira.view.group), in the order its popover lists them; the
-- choice and "only mine" persist in tern.kv VIEW_KEY, shared by every block.
jira.GROUPS = { "assignee", "status", "none" }
jira.GROUP_LABEL = { assignee = "Assignee", status = "Status", none = "No grouping" } :: { [string]: string }
jira.VIEW_KEY = "jira_view"
-- Status groups follow Jira's status categories: to do, in progress, done.
jira.CATEGORY_RANK = { new = 1, indeterminate = 2, done = 3 } :: { [string]: number }


type Links = { tern_pane: number?, cwd: string?, omp_session: string? }
type Agent = { model: string?, thinking: string? }
-- The Jira issue a task was made from (Tickets tab); `url` is its browse link.
type JiraLink = { key: string, url: string? }
type Todo = {
	id: string,
	title: string,
	notes: string,
	priority: string,
	due: string?,
	done: boolean,
	archived: boolean,
	backlog: boolean,
	links: Links,
	agent: Agent,
	-- Whether omp names the task; nil follows the omp_titles setting.
	auto_title: boolean?,
	-- ISO UTC stamps the block maintains (absent on tasks it has not touched yet).
	created: string?,
	updated: string?,
	completed: string?,
	jira: JiraLink?,
	-- What Post to Jira fills in, by Jira field id: text as typed, a choice as { id, name } (a
	-- list of them for a multi-choice field), "me" for a user field.
	jira_fields: { [string]: any }?,
}

type Model = { selector: string, id: string, provider: string, reasoning: boolean, efforts: { string }, context: string }
type Chat = { id: string, title: string, cwd: string, mtime: number }

-- An issue of the active sprint, as jira.luau sends it; `category` is Jira's status category
-- key (new, indeterminate, done).
type Ticket = {
	key: string,
	summary: string,
	status: string,
	category: string,
	kind: string?,
	assignee: string?,
	-- The assignee's Jira id (Cloud accountId, Data Center name).
	assignee_id: string?,
	priority: string?,
	description: string?,
	-- Its long text fields that hold something (Definition of Done…), as { name, text }.
	details: { { name: string, text: string } },
	sprint: string?,
}
-- A run of the Jira tickets tab's rows under one header: `id` is "me", "a:<assignee id>",
-- "none" (unassigned), "s:<status>", or "all" (no grouping, no header).
type TicketGroup = { id: string, label: string, tickets: { Ticket }, rank: number, order: number }
type JiraProject = { key: string, name: string }
type JiraBoard = { id: number, name: string, kind: string? }
type JiraComponent = { id: string, name: string }
type JiraType = { id: string, name: string }
type JiraChoice = { id: string, name: string }
-- A field the task card fills in for a new issue, as jira.luau's field_spec describes it.
type JiraField = {
	id: string,
	name: string,
	required: boolean,
	-- Jira fills it in when the card leaves it empty.
	default: boolean,
	default_name: string?,
	kind: string,
	multi: boolean,
	multiline: boolean,
	choices: { JiraChoice },
}
type Sprint = { id: number, name: string, ends: string? }
-- What the Tickets tab knows. `conn` is "unknown" until the window first answers, then
-- "connected" or "disconnected". `busy` and `last` are keyed by request slot: the op,
-- "done:<key>" per issue or "create:<task id>" per task; `last` holds the newest request
-- number, so older answers and the copies a second window sends are dropped.
type Jira = {
	conn: string,
	url: string?,
	email: string?,
	user: string?,
	-- Your Jira id (jira.luau's Config.me); nil for a connection that never said it.
	me: string?,
	project: JiraProject?,
	board: JiraBoard?,
	projects: { JiraProject }?,
	boards: { JiraBoard }?,
	boards_for: string?,
	sprints: { Sprint }?,
	tickets: { Ticket }?,
	loaded_at: number?,
	busy: { [string]: boolean },
	last: { [string]: number },
	req: number,
	error: string?,
	form_error: string?,
	list_error: string?,
	cursor: string?,
	-- The connection form is open while connected.
	editing: boolean,
	-- A project was just picked: open the board picker once its boards arrive (several).
	want_board: boolean,
	-- Where the task card posts new issues, as the window stores it: the project, and per
	-- project key its component (false: none) and issue type. Unset ones fall back to a default
	-- (see jira.target, jira.kind). `comps` holds each project's components once loaded,
	-- `comps_error` why not.
	post: { project: JiraProject?, components: { [string]: JiraComponent | boolean }, types: { [string]: JiraType } },
	comps: { [string]: { JiraComponent } },
	comps_error: { [string]: string },
	-- Per project: its issue types, Jira's default one, why they could not be loaded, and
	-- whether its description is required; per "<project>:<type id>" the create screen's fields.
	types: { [string]: { JiraType } },
	def_type: { [string]: JiraType },
	meta_error: { [string]: string },
	notes_required: { [string]: boolean },
	fields: { [string]: { JiraField } },
	-- The card shows every field, not only the main ones (jira.main_field).
	more: boolean,
	-- Fields Post to Jira found empty or invalid, for task `missing_task`.
	missing: { [string]: boolean },
	missing_task: string?,
	-- The field the choice popover (jira_field) or the text field (focus "jx") is for.
	pick_field: string?,
	jx_field: string?,
	-- The tickets tab's grouping and "only mine" (persisted), and the groups folded shut here.
	view: { mine: boolean, group: string },
	folded: { [string]: boolean },
}

-- Popover state. `kind` is project, model or chat; `text` is the search
-- field; `sel` is the highlighted item (0 = none); `dir`/`names` cache the last directory
-- listing of the project picker's path mode.
type Pick = {
	kind: string,
	task: string,
	q: Field,
	sel: number,
	dir: string?,
	names: { string },
	missing: boolean,
	want: string?,
	hint: string?,
}

type State = {
	cx: BlockCx,
	path: string?,
	todos: { Todo },
	cursor: string?,
	error: string?,
	timer: TimerHandle?,
	-- "add" (the add row), "title" or "notes" (the detail fields), "picker" (a popover), "jx"
	-- (a Jira field of the task card, jira.jx_field), a connection form field, or nil (list keys).
	focus: string?,
	detail_open: boolean,
	fresh: Todo?,
	add: Field,
	-- Drafts of the focused detail fields, valid while focus == "title" / "notes".
	notes: Field,
	title: Field,
	pick: Pick?,
	-- Models from `omp models --json`, loaded once per block run.
	models: { Model }?,
	models_state: string,
	models_error: string?,
	-- Recent omp chats, newest first; reloaded whenever the chat popover opens.
	chats: { Chat }?,
	chats_loading: boolean,
	chats_token: number,
	-- When the chat list was last rescanned for a linked chat it lacked, per session id.
	chats_tried: { [string]: number },
	agent_states: { [string]: string },
	states_at: number,
	previous_live: { [number]: boolean }?,
	-- Test hook: tern.kv "todo-proto.debug_states" ({ [pane id string] = state word })
	-- replaces live detection for those panes. Words: starting, running/working, needs/waiting_input,
	-- review/idle, stopped/exited, todo.
	debug_states: { [string]: string },
	states_sig: string,
	closed_panes: { [string]: boolean }?,
	st_timer: TimerHandle?,
	-- Key of the window showing this block, from window.luau's state events (nil until the first).
	window: string?,
	-- Counter of window.luau's "todo-proto.nudge" already handled (see `reload_if_nudged`).
	nudge_seen: number,
	-- When a pane was last seen working / launched by this block (os.time()).
	since: { [number]: number },
	launched: { [number]: number },
	-- Archived section expanded; id of the task whose Delete awaits its second press (view
	-- state only, never saved to the file).
	arch_open: boolean,
	-- Whether the optional Done section is expanded, kept only in this block.
	done_open: boolean,
	tab: string,
	confirm: string?,
	confirm_timer: TimerHandle?,
	-- The task picked up by its grip, waiting to be dropped on a row (view state only).
	lift: string?,
	-- The last press on a glyph or grip (key, tern.now()): a double click delivers it twice.
	tap: { key: string, at: number }?,
	-- Tasks whose `tern new tab` is still running, so a repeated double click starts one tab.
	launching: { [string]: boolean },
	-- Multi-selection (view state only, never saved): the ticked ids, the row a shift range
	-- starts at, whether Delete awaits its second press for the whole selection, and the
	-- tasks whose done toggle (pane close) is in flight.
	sel: { [string]: boolean },
	anchor: string?,
	confirm_bulk: boolean,
	closing: { [string]: boolean },
	-- Settings (see SETTINGS), the sheet that edits them, the last settings-sheet click, the
	-- palette request counter already handled, and the omp session files' last activity
	-- (mtime, seconds) with their paths and the last lookup try per session id.
	cfg: { [string]: boolean },
	settings_open: boolean,
	settings_sel: number,
	settings_tap: { id: string, at: number }?,
	sess_mtime: { [string]: number },
	sess_path: { [string]: string },
	sess_tried: { [string]: number },
	sess_busy: boolean,
	-- True while an fswatch process waits for the next file change.
	fsw: boolean,
	-- The shared minute-aligned timer that refreshes the time labels.
	tick: TimerHandle?,
	-- The Tickets tab and the drafts of its connection form (URL, email, token). The token
	-- draft is never saved: the window reads it off the masked field, then the block clears it.
	jira: Jira,
	jurl: Field,
	jemail: Field,
	jtoken: Field,
	-- Draft of the Jira field being typed in (focus "jx").
	jx: Field,
}

-- A pane ID survives Restart; the state object identifies this block run.
local running: { [number]: State } = {}

-- Defined with the picker functions, which they need.
local open_settings: (State) -> ()
local open_picker: (State, string) -> ()

local CONFIRM_MS = 4000

local function clear_confirm(state: State)
	state.confirm = nil
	state.confirm_bulk = false
	if state.confirm_timer then
		state.confirm_timer:cancel()
		state.confirm_timer = nil
	end
end

local function retire(state: State)
	if running[state.cx.pane] == state then
		running[state.cx.pane] = nil
	end
	if state.tick then
		state.tick:cancel()
		state.tick = nil
	end
	if state.timer then
		state.timer:cancel()
		state.timer = nil
	end
	if state.st_timer then
		state.st_timer:cancel()
		state.st_timer = nil
	end
	clear_confirm(state)
	state.todos = {}
end

-- Check this run first, not just its pane: Restart reuses the pane ID.
local function alive(state: State): boolean
	if running[state.cx.pane] ~= state then
		return false
	end
	for _, p in tern.pane.list() do
		if p.pane == state.cx.pane then
			return true
		end
	end
	retire(state)
	return false
end

-- Options for a `tern` command about this block's window. Without --window, $TERN_PANE (with
-- its socket) or $TERN_WINDOW_KEY, the CLI acts on the first window, and the daemon starts the
-- block's processes with none of them: a block in a second window opened its tabs in the first.
local function in_window(state: State, timeout_ms: number): ProcessOptions
	return { timeout_ms = timeout_ms, env = if state.window then { TERN_WINDOW_KEY = state.window } else nil }
end

local function live_panes(): { [number]: boolean }
	local set: { [number]: boolean } = {}
	for _, p in tern.pane.list() do
		set[p.pane] = true
	end
	return set
end

-- Open todos first, then done ones, file order inside each group; archived ones last, and
-- only while the Archived section is expanded. The Backlog tab lists only backlog tasks, the
-- Tasks tab everything else; an archived task is never in the backlog. `with_done` is false
-- while done tasks sit in a collapsed Done group.
local function in_backlog(t: Todo): boolean
	return t.backlog and not t.archived
end

local function ordered(todos: { Todo }, tab: string, with_archived: boolean, with_done: boolean): { Todo }
	local want = tab == "backlog"
	local out: { Todo } = {}
	for _, t in todos do
		if not t.done and not t.archived and in_backlog(t) == want then
			table.insert(out, t)
		end
	end
	if with_done then
		for _, t in todos do
			if t.done and not t.archived and in_backlog(t) == want then
				table.insert(out, t)
			end
		end
	end
	if with_archived and not want then
		for _, t in todos do
			if t.archived then
				table.insert(out, t)
			end
		end
	end
	return out
end

local function listed(state: State): { Todo }
	return ordered(state.todos, state.tab, state.arch_open and state.cfg.archived, not state.cfg.done_group or state.done_open)
end

local function str_or_nil(v: any): string?
	if type(v) == "string" and v ~= "" then
		return v
	end
	return nil
end

local function parse(text: string): ({ Todo }?, string?)
	local ok, data = pcall(tern.json.decode, text)
	if not ok or type(data) ~= "table" or type(data.todos) ~= "table" then
		return nil, "The file is not a {\"todos\": [...]} document."
	end
	local todos: { Todo } = {}
	for _, item in data.todos do
		if type(item) == "table" and type(item.id) == "string" then
			local links = if type(item.links) == "table" then item.links else {}
			local agent = if type(item.agent) == "table" then item.agent else {}
			table.insert(todos, {
				id = item.id,
				title = tostring(item.title or ""),
				notes = tostring(item.notes or ""),
				priority = if PRIORITY_TONE[tostring(item.priority)] then tostring(item.priority) else "none",
				due = if type(item.due) == "string" then item.due else nil,
				done = item.done == true,
				archived = item.archived == true,
				backlog = item.backlog == true and item.done ~= true,
				links = {
					tern_pane = tonumber(links.tern_pane),
					cwd = str_or_nil(links.cwd),
					omp_session = str_or_nil(links.omp_session),
				},
				agent = { model = str_or_nil(agent.model), thinking = str_or_nil(agent.thinking) },
				auto_title = if type(item.auto_title) == "boolean" then item.auto_title else nil,
				created = str_or_nil(item.created),
				updated = str_or_nil(item.updated),
				completed = str_or_nil(item.completed),
				jira = if type(item.jira) == "table" and str_or_nil(item.jira.key)
					then { key = item.jira.key, url = str_or_nil(item.jira.url) }
					else nil,
				jira_fields = if type(item.jira_fields) == "table" then item.jira_fields else nil,
			})
		end
	end
	return todos, nil
end

local function ensure_cursor(state: State)
	if state.fresh then
		return
	end
	local shown = listed(state)
	for _, t in shown do
		if t.id == state.cursor then
			return
		end
	end
	state.cursor = if shown[1] then shown[1].id else nil
end

-- Drops selected ids that are no longer listed (gone from the file, or in a collapsed section).
local function prune_sel(state: State)
	if next(state.sel) == nil and state.anchor == nil then
		return
	end
	local visible: { [string]: boolean } = {}
	for _, t in listed(state) do
		visible[t.id] = true
	end
	local changed = false
	for id in state.sel do
		if not visible[id] then
			state.sel[id] = nil
			changed = true
		end
	end
	if state.anchor and not visible[state.anchor] then
		state.anchor = nil
	end
	if changed then
		clear_confirm(state)
	end
end

local function load(state: State)
	local path = state.path
	if not path then
		return
	end
	local ok, text = pcall(tern.fs.read, path)
	if not ok then
		state.error = "Cannot read " .. path .. ": " .. tostring(text)
		return
	end
	local todos, err = parse(text)
	if not todos then
		state.error = err
		return
	end
	state.error = nil
	state.todos = todos
	ensure_cursor(state)
	prune_sel(state)
end

-- Time ------------------------------------------------------------------

local function days_from_civil(y: number, m: number, d: number): number
	if m <= 2 then
		y -= 1
	end
	local era = y // 400
	local yoe = y - era * 400
	local mp = (m + 9) % 12
	local doy = (153 * mp + 2) // 5 + d - 1
	local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
	return era * 146097 + doe - 719468
end

-- Seconds since the epoch of an ISO-8601 stamp ("2026-10-12T09:30:00Z", fraction and
-- +hh:mm offsets allowed; no zone means UTC), nil when it is not one.
local function parse_iso(text: string?): number?
	if not text then
		return nil
	end
	local y, mo, d, h, mi, s, rest = string.match(text, "^(%d%d%d%d)%-(%d%d)%-(%d%d)[Tt ](%d%d):(%d%d):(%d%d)(.*)$")
	if not y then
		return nil
	end
	local Y, M, D = tonumber(y) or 0, tonumber(mo) or 0, tonumber(d) or 0
	local H, I, S = tonumber(h) or 0, tonumber(mi) or 0, tonumber(s) or 0
	if M < 1 or M > 12 or D < 1 or D > 31 or H > 23 or I > 59 or S > 60 then
		return nil
	end
	local zone = (string.gsub(rest :: string, "^%.%d+", ""))
	local offset = 0
	if zone ~= "" and zone ~= "Z" and zone ~= "z" then
		local sign, oh, om = string.match(zone, "^([%+%-])(%d%d):?(%d%d)$")
		if not sign then
			return nil
		end
		offset = ((tonumber(oh) or 0) * 3600 + (tonumber(om) or 0) * 60) * (if sign == "+" then 1 else -1)
	end
	return days_from_civil(Y, M, D) * 86400 + H * 3600 + I * 60 + S - offset
end

local function format_age(now: number, ts: number): string
	local secs = now - ts
	if secs < 60 then
		return "now"
	end
	local mins = secs // 60
	if mins < 60 then
		return mins .. "m"
	end
	local hours = mins // 60
	if hours < 24 then
		return hours .. "h"
	end
	local days = hours // 24
	if days < 7 then
		return days .. "d"
	elseif days < 30 then
		return (days // 7) .. "w"
	elseif days < 365 then
		return (days // 30) .. "mo"
	end
	return (days // 365) .. "y"
end

-- The moment a row's label counts from, and what it means: a done task shows `completed`; a
-- task with an omp chat the later of `updated` and the chat file's last activity; any other
-- `updated`, else `created`. Nothing when the task carries no valid stamp (old tasks stay
-- unlabelled until the block first touches them).
local function stamp_of(state: State, t: Todo): (number?, string)
	if t.done then
		local c = parse_iso(t.completed)
		if c then
			return c, "completed"
		end
	end
	local base, kind = parse_iso(t.updated), "updated"
	if not base then
		base, kind = parse_iso(t.created), "created"
	end
	local sid = t.links.omp_session
	if sid and not t.done then
		local m = state.sess_mtime[sid]
		if m and (not base or m > base) then
			return m, "activity"
		end
	end
	return base, kind
end

local STAMP_PREFIX: { [string]: string } = {
	completed = "Completed",
	updated = "Updated",
	created = "Created",
	activity = "Last activity",
}

-- Label, absolute local date and a sentence for the card; nil without a stamp.
local function stamp_label(state: State, t: Todo): (string?, string?, string?)
	local ts, kind = stamp_of(state, t)
	if not ts then
		return nil, nil, nil
	end
	local label = format_age(os.time(), ts)
	local abs = os.date("%a %d %b %Y, %H:%M", ts)
	local ago = if label == "now" then "just now" else label .. " ago"
	return label, abs, STAMP_PREFIX[kind] .. " " .. ago .. " · " .. abs
end

-- Settings --------------------------------------------------------------

-- One-time cutover from master's former modal store. Canonical values take precedence.
local settings_migrated = false
local function migrate_settings()
	if settings_migrated then
		return
	end
	local ok, old = pcall(tern.kv.get, "todo-proto.settings")
	local cok, current = pcall(tern.kv.get, SETTINGS_KEY)
	if not ok or not cok then
		return
	end
	if type(old) == "table" then
		local merged = if type(current) == "table" then table.clone(current) else {}
		for key, value in old do
			if merged[key] == nil then
				merged[key] = value
			end
		end
		if not pcall(tern.kv.set, SETTINGS_KEY, merged) then
			return
		end
		if not pcall(tern.kv.set, "todo-proto.settings", nil) then
			return
		end
	end
	settings_migrated = true
end

local function read_settings(): { [string]: boolean }
	migrate_settings()
	local out: { [string]: boolean } = {}
	local ok, raw = pcall(tern.kv.get, SETTINGS_KEY)
	local src: { [string]: any } = if ok and type(raw) == "table" then raw else {}
	for key, value in src do
		if type(value) == "boolean" then
			out[key] = value
		end
	end
	for _, s in SETTINGS do
		local v = src[s.id]
		out[s.id] = if type(v) == "boolean" then v else s.default
	end
	return out
end

-- What a settings change implies for the view state.
local function apply_settings(state: State)
	if not state.cfg.done_group then
		state.done_open = false
	end
	if not state.cfg.archived then
		state.arch_open = false
	end
	ensure_cursor(state)
	prune_sel(state)
end

-- Re-reads the kv (another window or block may have changed it); true when a value differs.
local function refresh_cfg(state: State): boolean
	local fresh = read_settings()
	local changed = false
	for id, v in fresh do
		if state.cfg[id] ~= v then
			changed = true
		end
	end
	if changed then
		state.cfg = fresh
		apply_settings(state)
	end
	return changed
end

local function toggle_setting(state: State, id: string)
	refresh_cfg(state)
	local nextcfg = table.clone(state.cfg)
	nextcfg[id] = not nextcfg[id]
	local ok, err = pcall(tern.kv.set, SETTINGS_KEY, nextcfg)
	if not ok then
		state.cx:toast("error", "Cannot save settings", tostring(err))
		return
	end
	state.cfg = nextcfg
	apply_settings(state)
end


-- One timer for the whole list, first fired on the next minute boundary, then every minute.
local function start_tick(state: State)
	if state.tick or not state.path then
		return
	end
	state.tick = tern.timer((60 - os.time() % 60) * 1000 + 200, function()
		state.tick = nil
		if not running[state.cx.pane] or running[state.cx.pane] ~= state then
			return
		end
		if state.cfg.time then
			state.cx:render()
		end
		start_tick(state)
	end)
end

local function iso_now(): string
	return os.date("!%Y-%m-%dT%H:%M:%SZ", os.time())
end

local function deep_copy(v: any): any
	if type(v) ~= "table" or v == tern.json.null then
		return v
	end
	local out: { [any]: any } = {}
	for k, x in v do
		out[k] = deep_copy(x)
	end
	return out
end

local function deep_equal(a: any, b: any): boolean
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	for k, x in a do
		if not deep_equal(x, b[k]) then
			return false
		end
	end
	for k in b do
		if a[k] == nil then
			return false
		end
	end
	return true
end

-- The request slot of an op (see Jira.busy): one per issue for done, per task for create.
function jira.slot(op: string, key: string?, task: string?): string
	return if op == "done" and key then "done:" .. key elseif op == "create" and task then "create:" .. task else op
end

-- Asks the window's Jira half (jira.luau) for `op`; the answer arrives as a "todo.jira" event
-- (jira.answer). A request left unanswered for WAIT_MS is given up.
function jira.ask(state: State, op: string, query: { [string]: string }?)
	local j = state.jira
	local slot = jira.slot(op, query and query.key, query and query.task)
	j.req += 1
	local req = j.req
	-- `pane` lets the window answer this block even while its tab is hidden (the link's own
	-- pane is then the window's focused one).
	local q: { [string]: string | number } = { req = req, pane = state.cx.pane }
	for k, v in query or {} do
		q[k] = v
	end
	j.last[slot] = req
	j.busy[slot] = true
	local ok, err = pcall(function()
		state.cx:open(jira.link.build(op, q))
	end)
	if not ok then
		j.busy[slot] = nil
		j.last[slot] = nil
		state.cx:toast("error", "Cannot reach Jira", tostring(err))
		return
	end
	tern.timer(jira.WAIT_MS, function()
		if j.last[slot] ~= req or not alive(state) then
			return
		end
		j.last[slot] = nil
		j.busy[slot] = nil
		local message = "No answer from Jira. Is a Tern window showing this block?"
		if slot == "connect" then
			j.form_error = message
		elseif op == "done" then
			state.cx:toast("error", "Could not close " .. tostring(query and query.key) .. " in Jira", message)
		elseif op == "create" then
			state.cx:toast("error", "Could not post the task to Jira", message)
		elseif op == "components" then
			j.comps_error[tostring(query and query.project)] = message
		elseif op == "meta" then
			j.meta_error[tostring(query and query.project)] = message
		else
			j.error = message
		end
		state.cx:render()
	end)
end

-- Re-reads the file, lets `change` edit its `todos` array, and writes it back.
-- Reading first keeps edits made elsewhere; known keys that are absent are filled in
-- as explicit nulls (`due` is kept as it is, null when unset;
-- `agent` is optional and only filled in where a task has one).
-- Returns whether the file was written.
local function rewrite(state: State, change: ({ any }) -> boolean?): boolean
	local path = state.path
	if not path then
		return false
	end
	local ok, text = pcall(tern.fs.read, path)
	if not ok then
		state.cx:toast("error", "Cannot read todo file", tostring(text))
		return false
	end
	local dok, data = pcall(json.decode, text)
	if not dok or type(data) ~= "table" or type(data.todos) ~= "table" then
		state.cx:toast("error", "Todo file is not valid JSON")
		return false
	end
	local list = tern.json.array(data.todos)
	-- Per-task snapshot: after `change`, only a task whose content differs is stamped.
	local snap: { [string]: any } = {}
	for _, item in list do
		if type(item) == "table" and type(item.id) == "string" then
			snap[item.id] = deep_copy(item)
		end
	end
	if change(list) == false then
		load(state)
		return false
	end
	-- `updated` moves on every task the change touched (a reorder touches none); a task that
	-- turned done gets `completed`, one that turned open loses it; new tasks get `created`.
	-- Tasks the change left alone, and keys the block does not know, are not rewritten.
	local now = iso_now()
	-- Jira issues of tasks that turn done here; jira.luau closes them once the file is written.
	local finished: { string } = {}
	for _, item in list do
		if type(item) == "table" and type(item.id) == "string" then
			local before = snap[item.id]
			if before == nil then
				if item.created == nil then
					item.created = now
				end
				if item.updated == nil then
					item.updated = now
				end
			elseif not deep_equal(before, item) then
				item.updated = now
				if item.done == true and before.done ~= true then
					item.completed = now
					local issue = item.jira
					if type(issue) == "table" and type(issue.key) == "string" and issue.key ~= "" then
						table.insert(finished, issue.key)
					end
				elseif item.done ~= true and before.done == true then
					item.completed = nil
				end
			end
		end
	end
	for _, item in list do
		if type(item) == "table" then
			if item.due == nil then
				item.due = tern.json.null
			end
			local links = if type(item.links) == "table" then item.links else {}
			for _, k in { "tern_pane", "cwd", "omp_session" } do
				if links[k] == nil then
					links[k] = tern.json.null
				end
			end
			item.links = links
			if type(item.agent) == "table" then
				for _, k in { "model", "thinking" } do
					if item.agent[k] == nil then
						item.agent[k] = tern.json.null
					end
				end
			end
		end
	end
	data.todos = list
	local wok, werr = pcall(tern.fs.write, path, tern.json.encode(data, true) .. "\n")
	if not wok then
		state.cx:toast("error", "Cannot write todo file", tostring(werr))
		return false
	end
	load(state)
	for _, key in finished do
		jira.ask(state, "done", { key = key })
	end
	return true
end

local function patch(state: State, id: string, change: (any) -> ())
	if state.fresh and state.fresh.id == id then
		change(state.fresh)
		for _, key in { "cwd", "omp_session", "tern_pane" } do
			if state.fresh.links[key] == tern.json.null then
				state.fresh.links[key] = nil
			end
		end
		for _, key in { "model", "thinking" } do
			if state.fresh.agent[key] == tern.json.null then
				state.fresh.agent[key] = nil
			end
		end
		return
	end
	rewrite(state, function(list)
		for _, item in list do
			if type(item) == "table" and item.id == id then
				change(item)
			end
		end
	end)
end

local LAST_PROJECT_KEY = "todo-proto.last_project"

local function last_project(): string?
	local ok, v = pcall(tern.kv.get, LAST_PROJECT_KEY)
	return if ok then str_or_nil(v) else nil
end

-- Adds the task (the draft's priority, agent, links and notes) as the first one and selects
-- it. Returns its id, or nil when the file could not be written.
local function add_task(state: State, title: string): string?
	local new_id = ""
	local draft = state.fresh
	local cwd = if draft then draft.links.cwd else last_project()
	local written = rewrite(state, function(list)
		local taken: { [string]: boolean } = {}
		for _, item in list do
			if type(item) == "table" and type(item.id) == "string" then
				taken[item.id] = true
			end
		end
		local n = #list + 1
		while taken["t" .. n] do
			n += 1
		end
		new_id = "t" .. n
		table.insert(list, 1, {
			id = new_id,
			title = title,
			notes = if draft then draft.notes else "",
			priority = if draft then draft.priority else "none",
			agent = if draft then draft.agent else nil,
			due = tern.json.null,
			done = false,
			backlog = if state.tab == "backlog" then true else nil,
			links = if draft then table.clone(draft.links) else (if cwd then { cwd = cwd } else {}),
			jira_fields = if draft then draft.jira_fields else nil,
		})
	end)
	if not written then
		return nil
	end
	state.fresh = nil
	state.cursor = new_id
	state.sel = {}
	state.anchor = nil
	state.detail_open = true
	return new_id
end

local function index_of(state: State): number
	for i, t in listed(state) do
		if t.id == state.cursor then
			return i
		end
	end
	return 0
end

local function selected(state: State): Todo?
	return state.fresh or listed(state)[index_of(state)]
end

local function todo_by_id(state: State, id: string): Todo?
	for _, t in state.todos do
		if t.id == id then
			return t
		end
	end
	return nil
end

local function clear_sel(state: State)
	state.sel = {}
	clear_confirm(state)
end

-- The ids of a multi-selection (two or more rows), in list order; empty otherwise.
local function multi_ids(state: State): { string }
	local out: { string } = {}
	if next(state.sel) == nil then
		return out
	end
	for _, t in listed(state) do
		if state.sel[t.id] then
			table.insert(out, t.id)
		end
	end
	if #out < 2 then
		return {}
	end
	return out
end

-- Selects the visible rows from the anchor (else the cursor) to `to`, ends included.
local function select_range(state: State, to: string)
	local shown = listed(state)
	if not state.anchor then
		state.anchor = state.cursor
	end
	local a, b = 0, 0
	for i, t in shown do
		if t.id == state.anchor then
			a = i
		end
		if t.id == to then
			b = i
		end
	end
	if b == 0 then
		return
	end
	if a == 0 then
		a = b
	end
	if a > b then
		a, b = b, a
	end
	local sel: { [string]: boolean } = {}
	for i = a, b do
		sel[shown[i].id] = true
	end
	state.sel = sel
	clear_confirm(state)
end

-- Cmd/ctrl-click and `v`: ticks or unticks one row. The first tick also ticks the cursor row.
local function toggle_mark(state: State, id: string)
	if next(state.sel) == nil and state.cursor and state.cursor ~= id then
		state.sel[state.cursor] = true
	end
	if state.sel[id] then
		state.sel[id] = nil
	else
		state.sel[id] = true
	end
	state.anchor = id
	state.cursor = id
	state.detail_open = true
	state.lift = nil
	clear_confirm(state)
end

-- Shift+Up / Shift+Down: moves the cursor and selects from the anchor to it.
local function extend(state: State, delta: number)
	local shown = listed(state)
	local t = shown[math.clamp(index_of(state) + delta, 1, math.max(1, #shown))]
	if not t then
		return
	end
	state.lift = nil
	if not state.anchor then
		state.anchor = state.cursor
	end
	state.cursor = t.id
	state.detail_open = true
	select_range(state, t.id)
end

local function select_all(state: State)
	local sel: { [string]: boolean } = {}
	for _, t in listed(state) do
		sel[t.id] = true
	end
	state.lift = nil
	state.sel = sel
	state.anchor = state.cursor
	clear_confirm(state)
end

-- The row to put the cursor on once the rows in `gone` leave: the next one not in it, else the
-- previous one.
local function survivor(state: State, gone: { [string]: boolean }): string?
	local shown = listed(state)
	local last = 0
	for i, t in shown do
		if gone[t.id] then
			last = i
		end
	end
	for i = last + 1, #shown do
		if not gone[shown[i].id] then
			return shown[i].id
		end
	end
	for i = last - 1, 1, -1 do
		if not gone[shown[i].id] then
			return shown[i].id
		end
	end
	return nil
end

local function move(state: State, to: number)
	local shown = listed(state)
	local t = shown[math.clamp(to, 1, math.max(1, #shown))]
	if t then
		if state.cursor ~= t.id then
			clear_confirm(state)
		end
		state.cursor = t.id
		state.anchor = t.id
		state.detail_open = true
	end
end

-- The task to select once `id` leaves the list or its group: the next one, else the
-- previous one, preferring its own group (open/done vs archived).
local function neighbour(state: State, id: string): string?
	local shown = listed(state)
	local at = 0
	for i, t in shown do
		if t.id == id then
			at = i
		end
	end
	local own = if shown[at] then shown[at].archived else false
	for i = at + 1, #shown do
		if shown[i].archived == own then
			return shown[i].id
		end
	end
	for i = at - 1, 1, -1 do
		if shown[i].archived == own then
			return shown[i].id
		end
	end
	local other = shown[at + 1] or shown[at - 1]
	return if other then other.id else nil
end

local close_task_panes: (State, { [string]: boolean }, ({ [string]: number }) -> boolean) -> ()

-- Archives the selected tasks, or restores them when all of them are archived (one write).
local function bulk_archive(state: State, ids: { string })
	local set: { [string]: boolean } = {}
	local all_archived = true
	for _, id in ids do
		set[id] = true
		local t = todo_by_id(state, id)
		if t and not t.archived then
			all_archived = false
		end
	end
	local target = not all_archived
	local after = survivor(state, set)
	clear_confirm(state)
	local function commit(closed: { [string]: number }): boolean
		local written = rewrite(state, function(list)
			for _, item in list do
				if type(item) == "table" and set[item.id] then
					item.archived = if target then true else nil
					if target then
						item.backlog = nil
					end
					local pane = closed[item.id]
					if pane and type(item.links) == "table" and tonumber(item.links.tern_pane) == pane then
						item.links.tern_pane = nil
					end
				end
			end
		end)
		if written then
			state.sel = {}
			state.anchor = nil
			state.cursor = after or state.cursor
			ensure_cursor(state)
			state.cx:toast("info", (if target then "Archived " else "Restored ") .. #ids .. " tasks")
		end
		return written
	end
	if target then
		close_task_panes(state, set, commit)
	else
		commit({})
	end
end

local function archive_toggle(state: State, t: Todo)
	local ids = multi_ids(state)
	bulk_archive(state, if #ids >= 2 then ids else { t.id })
end

-- First press arms the confirmation on the task's own button, the second removes the record.
local function delete_one(state: State, t: Todo)
	if state.confirm ~= t.id then
		clear_confirm(state)
		state.confirm = t.id
		state.confirm_timer = tern.timer(CONFIRM_MS, function()
			state.confirm_timer = nil
			if alive(state) and state.confirm == t.id then
				state.confirm = nil
				state.cx:render()
			end
		end)
		return
	end
	local after = neighbour(state, t.id)
	clear_confirm(state)
	local removed_session: string? = nil
	local written = rewrite(state, function(list)
		for i, item in list do
			if type(item) == "table" and item.id == t.id then
				if type(item.links) == "table" and type(item.links.omp_session) == "string" then
					removed_session = item.links.omp_session
				end
				table.remove(list, i)
				break
			end
		end
	end)
	if written then
		if removed_session then
			auto_import.suppress(removed_session)
		end
		state.cursor = after
	end
end

-- First press arms the confirmation, the second removes the record (never a pane or session).
local function delete_press(state: State)
	local ids = multi_ids(state)
	if #ids >= 2 then
		if not state.confirm_bulk then
			clear_confirm(state)
			state.confirm_bulk = true
			state.confirm_timer = tern.timer(CONFIRM_MS, function()
				state.confirm_timer = nil
				if alive(state) and state.confirm_bulk then
					state.confirm_bulk = false
					state.cx:render()
				end
			end)
			return
		end
		local set: { [string]: boolean } = {}
		for _, id in ids do
			set[id] = true
		end
		local after = survivor(state, set)
		clear_confirm(state)
		local removed_sessions: { string } = {}
		local written = rewrite(state, function(list)
			for i = #list, 1, -1 do
				local item = list[i]
				if type(item) == "table" and set[item.id] then
					if type(item.links) == "table" and type(item.links.omp_session) == "string" then
						table.insert(removed_sessions, item.links.omp_session)
					end
					table.remove(list, i)
				end
			end
		end)
		if written then
			for _, session_id in removed_sessions do
				auto_import.suppress(session_id)
			end
			state.sel = {}
			state.anchor = nil
			state.cursor = after or state.cursor
			ensure_cursor(state)
			state.cx:toast("info", "Deleted " .. #ids .. " tasks")
		end
		return
	end
	local t = selected(state)
	if not t then
		return
	end
	delete_one(state, t)
end

local function toggle_archived(state: State)
	if not state.cfg.archived then
		return
	end
	state.arch_open = not state.arch_open
	clear_confirm(state)
	ensure_cursor(state)
	prune_sel(state)
end

local function toggle_done_open(state: State)
	state.done_open = not state.done_open
	clear_confirm(state)
	ensure_cursor(state)
	prune_sel(state)
end


local function switch_tab(state: State, tab: string)
	if state.tab == tab then
		return
	end
	state.tab = tab
	state.lift = nil
	clear_sel(state)
	state.anchor = nil
	-- The connection form exists only on the Tickets tab.
	if state.focus == "jurl" or state.focus == "jemail" or state.focus == "jtoken" then
		state.focus = nil
	end
	ensure_cursor(state)
	if tab == "tickets" then
		jira.enter(state)
	end
end

-- Moves tasks between the Tasks list and the Backlog; archived tasks stay where they are.
local function backlog_ids(state: State, ids: { string })
	local set: { [string]: boolean } = {}
	local all_backlog = true
	for _, id in ids do
		local t = todo_by_id(state, id)
		if t and not t.archived then
			set[id] = true
			if not t.backlog then
				all_backlog = false
			end
		end
	end
	if next(set) == nil then
		return
	end
	local target = not all_backlog
	local after = survivor(state, set)
	clear_confirm(state)
	local function commit(closed: { [string]: number }): boolean
		local written = rewrite(state, function(list)
			for _, item in list do
				if type(item) == "table" and set[item.id] then
					item.backlog = if target then true else nil
					if target then
						item.done = false
					end
					local pane = closed[item.id]
					if pane and type(item.links) == "table" and tonumber(item.links.tern_pane) == pane then
						item.links.tern_pane = nil
					end
				end
			end
		end)
		if written then
			state.sel = {}
			state.anchor = nil
			state.cursor = after or state.cursor
			ensure_cursor(state)
			state.cx:toast("info", if target then "Moved to backlog" else "Back to tasks")
		end
		return written
	end
	if target then
		close_task_panes(state, set, commit)
	else
		commit({})
	end
end

local function backlog_toggle(state: State, t: Todo)
	local ids = multi_ids(state)
	if #ids >= 2 then
		backlog_ids(state, ids)
	else
		backlog_ids(state, { t.id })
	end
end

local function bulk_all_backlog(state: State, ids: { string }): boolean
	for _, id in ids do
		local t = todo_by_id(state, id)
		if t and not t.archived and not t.backlog then
			return false
		end
	end
	return true
end

-- Reorder -------------------------------------------------------------------

-- The group a task is listed in: 1 open, 2 done, 3 archived (the order of `ordered`).
local function group_of(item: any): number
	if type(item) ~= "table" then
		return 0
	end
	if item.archived == true then
		return 3
	elseif item.done == true then
		return 2
	end
	return 1
end

-- Moves the item `id` of `list` (the file's todos array) onto `target`: within one group it
-- takes the target's place (before it when moving up, after it when moving down). A target
-- of another group puts it at the near edge of its own group instead (after the last item
-- when the target's group is listed later, before the first when earlier). Only the array
-- order changes. Returns whether the order changed.
local function place(list: { any }, id: string, target: string): boolean
	local from, to = 0, 0
	for i, item in list do
		if type(item) == "table" then
			if item.id == id then
				from = i
			elseif item.id == target then
				to = i
			end
		end
	end
	if from == 0 or to == 0 then
		return false
	end
	local g, tg = group_of(list[from]), group_of(list[to])
	local item = table.remove(list, from)
	local at = from
	if g == tg then
		at = to
	else
		local first, last = 0, 0
		for i, other in list do
			if group_of(other) == g then
				if first == 0 then
					first = i
				end
				last = i
			end
		end
		if first > 0 then
			at = if tg > g then last + 1 else first
		end
	end
	table.insert(list, at, item)
	return at ~= from
end

-- Writes the new order through the safe path (re-read, apply by id, write), so another
-- writer's changes survive. A move that would change nothing writes nothing.
local function reorder(state: State, id: string, target: string): boolean
	local probe = table.clone(state.todos) :: { any }
	if not place(probe, id, target) then
		return false
	end
	return rewrite(state, function(list)
		place(list, id, target)
	end)
end

-- The neighbour `delta` places away in the same group, if there is one (a group's edge stops).
local function neighbour_in_group(state: State, t: Todo, delta: number): Todo?
	local other = listed(state)[index_of(state) + delta]
	if other and group_of(other) == group_of(t) then
		return other
	end
	return nil
end

local function can_move(state: State, t: Todo, delta: number): boolean
	return neighbour_in_group(state, t, delta) ~= nil
end

-- Moves the selected task one place up (-1) or down (1) within its group.
local function step(state: State, delta: number)
	local t = selected(state)
	local other = if t then neighbour_in_group(state, t, delta) else nil
	if t and other then
		reorder(state, t.id, other.id)
	end
end

local TAP_MS = 450

-- True when this press repeats the previous one on the same target within TAP_MS.
local function repeated(state: State, key: string): boolean
	local now = tern.now()
	local last = state.tap
	state.tap = { key = key, at = now }
	return last ~= nil and last.key == key and now - last.at < TAP_MS
end

-- Paths -------------------------------------------------------------------

local function home_dir(): string
	local h = tern.getenv("HOME")
	return if h and h ~= "" then h else "/"
end

local function normalize(path: string): string
	local parts: { string } = {}
	for seg in string.gmatch(path, "[^/]+") do
		if seg == ".." then
			table.remove(parts)
		elseif seg ~= "." then
			table.insert(parts, seg)
		end
	end
	return "/" .. table.concat(parts, "/")
end

local function expand(text: string, base: string): string
	if text == "~" or string.sub(text, 1, 2) == "~/" then
		text = home_dir() .. string.sub(text, 2)
	end
	if string.sub(text, 1, 1) ~= "/" then
		text = base .. "/" .. text
	end
	return normalize(text)
end

local function basename(p: string): string
	return string.match(p, "([^/]+)/*$") or p
end

local project_names: { [string]: string } = {}
local project_asked: { [string]: boolean } = {}

-- The name of the project in `cwd`: the repository name plus " (wt)" inside a linked
-- worktree. Git answers once per path; the directory name shows until then.
local function project_label(state: State, cwd: string): string
	local known = project_names[cwd]
	if known then
		return known
	end
	if not project_asked[cwd] then
		project_asked[cwd] = true
		pcall(tern.process.run, {
			"/usr/bin/git", "-C", cwd, "rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir",
		}, { timeout_ms = 5000 }, function(result: ProcessResult, _)
			local git_dir, common = string.match(result.stdout, "^([^\n]+)\n([^\n]+)")
			if result.status ~= 0 or not git_dir or not common then
				project_names[cwd] = basename(cwd)
			elseif git_dir == common then
				project_names[cwd] = basename(cwd)
			else
				project_names[cwd] = basename((string.gsub(common, "/%.git/*$", ""))) .. " (wt)"
			end
			if alive(state) then
				state.cx:render()
			end
		end)
	end
	return basename(cwd)
end

local function abbreviate(p: string): string
	local home = home_dir()
	if p == home then
		return "~"
	elseif home ~= "/" and string.sub(p, 1, #home + 1) == home .. "/" then
		return "~" .. string.sub(p, #home + 1)
	end
	return p
end

local function is_path_text(text: string): boolean
	local c = string.sub(text, 1, 1)
	return c == "/" or c == "~" or string.find(text, "/", 1, true) ~= nil or text == "." or text == ".."
end

-- omp ---------------------------------------------------------------------

-- The daemon has no shell PATH, so look omp up the way a login shell would.
local function omp_bin(): string
	local env = tern.getenv("OMP_BIN")
	if env and env ~= "" then
		return env
	end
	local home = home_dir()
	for _, c in { home .. "/.local/bin/omp", home .. "/.bun/bin/omp", "/opt/homebrew/bin/omp", "/usr/local/bin/omp" } do
		if tern.fs.exists(c) then
			return c
		end
	end
	return "omp"
end

local function sessions_root(): string
	return home_dir() .. "/.omp/agent/sessions"
end

-- omp's session bucket directory for a cwd (see omp docs, session.md "On-disk layout").
local function bucket_of(cwd: string): string
	local home = home_dir()
	if cwd == home then
		return "-"
	elseif home ~= "/" and string.sub(cwd, 1, #home + 1) == home .. "/" then
		return "-" .. (string.gsub(string.sub(cwd, #home + 2), "/", "-"))
	end
	return "--" .. (string.gsub(string.sub(cwd, 2), "/", "-")) .. "--"
end

type SessionFile = { mtime: number, path: string, dir: string, id: string }

-- Parses `stat -f '%m %N'` lines of session files, newest first.
local function parse_stat(stdout: string): { SessionFile }
	local files: { SessionFile } = {}
	for line in string.gmatch(stdout, "[^\n]+") do
		local mtime, path = string.match(line, "^(%d+) (.+)$")
		if mtime and path then
			local dir = string.match(path, "([^/]+)/[^/]+$")
			local id = string.match(path, "_([^/_]+)%.jsonl$")
			if dir and id then
				table.insert(files, { mtime = tonumber(mtime) or 0, path = path, dir = dir, id = id })
			end
		end
	end
	table.sort(files, function(a, b)
		return a.mtime > b.mtime
	end)
	return files
end

local function untitled(timestamp: string): string
	local stamp = string.gsub(string.sub(timestamp, 1, 16), "T", " ")
	return "Untitled · " .. stamp
end

-- Lists recent sessions without a shell: one `find`+`stat` for every file's mtime, then one
-- `head -n 2` over the newest of them (title slot and header lines only, never whole files).
-- Files of the `cwd` bucket are preferred so a project's own chats are not pushed out.
-- Chats linked to a task are always read, so their pills never fall back to the bare id.
local function scan_chats(state: State, cwd: string?)
	state.chats_token += 1
	local token = state.chats_token
	state.chats_loading = true
	local function finish(chats: { Chat }?)
		if alive(state) and state.chats_token == token then
			state.chats_loading = false
			if chats then
				state.chats = chats
			end
			state.cx:render()
		end
	end
	local ok = pcall(
		tern.process.run,
		session_files.find_argv(sessions_root()),
		{ timeout_ms = 8000 },
		function(found: ProcessResult, _)
			if not alive(state) or state.chats_token ~= token then
				return
			end
			local files = parse_stat(found.stdout)
			local bucket = if cwd then bucket_of(cwd) else nil
			local chosen: { SessionFile } = {}
			local mtimes: { [string]: number } = {}
			local near, far = 0, 0
			local linked: { [string]: boolean } = {}
			for _, t in state.todos do
				if t.links.omp_session then
					linked[t.links.omp_session] = true
				end
			end
			for _, f in files do
				if linked[f.id] then
					table.insert(chosen, f)
				elseif bucket and f.dir == bucket and near < 25 then
					near += 1
					table.insert(chosen, f)
				elseif far < 40 then
					far += 1
					table.insert(chosen, f)
				end
				mtimes[f.id] = f.mtime
			end
			if #chosen == 0 then
				finish({})
				return
			end
			local argv = { "/usr/bin/head", "-n", "2" }
			for _, f in chosen do
				table.insert(argv, f.path)
			end
			local hok = pcall(tern.process.run, argv, { timeout_ms = 8000 }, function(heads: ProcessResult, _)
				local chats: { Chat } = {}
				local slot_title = ""
				for line in string.gmatch(heads.stdout, "[^\n]+") do
					local dok, entry = pcall(tern.json.decode, line)
					if dok and type(entry) == "table" then
						if entry.type == "title" then
							slot_title = tostring(entry.title or "")
						elseif entry.type == "session" and type(entry.id) == "string" then
							local title = slot_title
							if title == "" then
								title = tostring(entry.title or "")
							end
							if title == "" then
								title = untitled(tostring(entry.timestamp or ""))
							end
							table.insert(chats, {
								id = entry.id,
								title = title,
								cwd = tostring(entry.cwd or ""),
								mtime = mtimes[entry.id] or 0,
							})
							slot_title = ""
						end
					end
				end
				table.sort(chats, function(a, b)
					return a.mtime > b.mtime
				end)
				finish(chats)
			end)
			if not hok then
				finish(nil)
			end
		end
	)
	if not ok then
		state.chats_loading = false
	end
end

-- Loads the model list once per block run (`omp models --json`, about a second).
local function load_models(state: State)
	if state.models or state.models_state == "loading" then
		return
	end
	state.models_state = "loading"
	local function fail(reason: string)
		state.models_state = "error"
		state.models_error = reason
		state.cx:render()
	end
	local ok, err = pcall(tern.process.run, { omp_bin(), "models", "--json" }, { timeout_ms = 20000 }, function(result: ProcessResult, _)
		if not alive(state) then
			return
		end
		if result.status ~= 0 then
			local first = string.match(result.stderr, "[^\n]+") or ("exit " .. result.status)
			fail("omp models failed: " .. first)
			return
		end
		local dok, data = pcall(tern.json.decode, result.stdout)
		if not dok or type(data) ~= "table" or type(data.models) ~= "table" then
			fail("omp models gave no JSON")
			return
		end
		local models: { Model } = {}
		for _, m in data.models do
			if type(m) == "table" and type(m.selector) == "string" then
				local efforts: { string } = {}
				if type(m.thinking) == "table" then
					for _, e in m.thinking do
						table.insert(efforts, tostring(e))
					end
				end
				local ctx = tonumber(m.contextWindow)
				table.insert(models, {
					selector = m.selector,
					id = tostring(m.id or m.selector),
					provider = tostring(m.provider or ""),
					reasoning = m.reasoning == true,
					efforts = efforts,
					context = if not ctx then "" elseif ctx >= 1000000 then string.format("%dM", math.floor(ctx / 1000000 + 0.5)) else string.format("%dK", ctx // 1000),
				})
			end
		end
		state.models = models
		state.models_state = "ready"
		state.cx:render()
	end)
	if not ok then
		fail("Cannot run omp: " .. tostring(err))
	end
end

-- omp reports its exact session file on the pane. Retry briefly while it starts;
-- never infer ownership from another session's cwd or modification time.
local function discover_session(state: State, task_id: string, pane: number, deadline: number)
	if tern.now() >= deadline then
		return
	end
	tern.timer(1500, function()
		if not alive(state) then
			return
		end
		local function retry()
			discover_session(state, task_id, pane, deadline)
		end
		local ok = pcall(tern.process.run, { TERN, "inspect", "--json" }, in_window(state, 3000), function(found: ProcessResult, _)
			if not alive(state) then
				return
			end
			local dok, doc = pcall(tern.json.decode, found.stdout)
			local file: string? = nil
			if found.status == 0 and dok and type(doc) == "table" and type(doc.panes) == "table" then
				for _, p in doc.panes do
					if type(p) == "table" and p.pane == pane and type(p.omp_session_file) == "string" then
						file = p.omp_session_file
					end
				end
			end
			local file_id = if file then string.match(file, "_([%w%-]+)%.jsonl$") else nil
			if not file_id then
				retry()
				return
			end
			local hok = pcall(tern.process.run, { "/usr/bin/head", "-n", "2", "--", file :: string }, { timeout_ms = 3000 }, function(head: ProcessResult, _)
				if not alive(state) then
					return
				end
				local _, id = session.read_head(head.stdout)
				if head.status ~= 0 or id ~= file_id then
					retry()
					return
				end
				rewrite(state, function(list)
					for _, item in list do
						if type(item) == "table" and item.id == task_id then
							local links = if type(item.links) == "table" then item.links else {}
							if links.tern_pane ~= pane or (type(links.omp_session) == "string" and links.omp_session ~= "") then
								return false
							end
							links.omp_session = id
							item.links = links
							return true
						end
					end
					return false
				end)
				state.cx:render()
			end)
			if not hok then
				retry()
			end
		end)
		if not ok then
			retry()
		end
	end)
end

local function pane_from(stdout: string): number?
	local ok, data = pcall(tern.json.decode, stdout)
	if ok and type(data) == "table" then
		for _, k in { "pane", "block", "id" } do
			local n = tonumber(data[k])
			if n then
				return n
			end
		end
	end
	return tonumber(string.match(stdout, "%d+"))
end

-- Opens a new Tern tab in the task's project running `argv` (one argv element each, no
-- shell) and links the new pane to the task.
local function launch(state: State, t: Todo, argv: { string }, find_session: boolean)
	if state.launching[t.id] then
		return
	end
	local cwd = t.links.cwd or state.cx.cwd or home_dir()
	local id = t.id
	state.launching[id] = true
	local function open_tab(directory: string)
		local cmd = { TERN, "new", "tab", "--json", "--cwd", directory, "--" }
		for _, a in argv do
			table.insert(cmd, a)
		end
		local ok, err = pcall(tern.process.run, cmd, in_window(state, 10000), function(result: ProcessResult, _)
			state.launching[id] = nil
			if result.status ~= 0 then
				local first = string.match(result.stderr, "[^\n]+") or ("exit " .. result.status)
				state.cx:toast("error", "tern new tab failed", first)
				return
			end
			local pane = pane_from(result.stdout)
			if not pane then
				state.cx:toast("error", "tern new tab gave no pane id", result.stdout)
				return
			end
			if not alive(state) then
				return
			end
			if state.cfg.focus_on_start then
				-- `tern new tab` leaves the new tab in the background: show it.
				pcall(tern.process.run, { TERN, "focus", tostring(pane) }, in_window(state, 5000), function(shown: ProcessResult, _)
					if shown.status ~= 0 then
						state.cx:toast("error", "tern focus failed", shown.stderr)
					end
				end)
			end
			patch(state, id, function(item)
				local links = if type(item.links) == "table" then item.links else {}
				links.tern_pane = pane
				if find_session then
					links.cwd = directory
				end
				item.links = links
			end)
			state.launched[pane] = os.time()
			state.cx:render()
			if find_session then
				discover_session(state, id, pane, tern.now() + 20000)
			end
		end)
		if not ok then
			state.launching[id] = nil
			state.cx:toast("error", "Cannot run tern", tostring(err))
		end
	end
	if not find_session or not state.cfg.new_chat_worktree then
		open_tab(cwd)
		return
	end
	local function failed(message: string)
		state.launching[id] = nil
		state.cx:toast("error", "Cannot create worktree", message)
		state.cx:render()
	end
	local ok, err = pcall(tern.process.run, {
		"/usr/bin/git", "-C", cwd, "for-each-ref", "--format=%(refname)",
		"refs/remotes/origin/HEAD", "refs/remotes/origin/main", "refs/heads/main",
		"refs/remotes/origin/master", "refs/heads/master",
	}, { timeout_ms = 5000 }, function(refs: ProcessResult, _)
		if not alive(state) then
			state.launching[id] = nil
			return
		end
		local base: string? = nil
		for _, ref in { "refs/remotes/origin/HEAD", "refs/remotes/origin/main", "refs/heads/main", "refs/remotes/origin/master", "refs/heads/master" } do
			if string.find("\n" .. refs.stdout, "\n" .. ref .. "\n", 1, true) then
				base = ref
				break
			end
		end
		if refs.status ~= 0 or not base then
			failed(if refs.status ~= 0 then refs.stderr else "The project has no main or master branch")
			return
		end
		local name = "todo-" .. tostring(math.random(100000, 999999))
		local directory = home_dir() .. "/.omp/wt/" .. name
		local added, reason = pcall(tern.process.run, {
			"/usr/bin/git", "-C", cwd, "worktree", "add", "-b", name, directory, base :: string,
		}, { timeout_ms = 120000 }, function(result: ProcessResult, _)
			if result.status ~= 0 then
				failed(result.stderr)
			elseif alive(state) then
				open_tab(directory)
			else
				state.launching[id] = nil
			end
		end)
		if not added then
			failed(tostring(reason))
		end
	end)
	if not ok then
		failed(tostring(err))
	end
end

local function live_pane_of(t: Todo): number?
	local pane = t.links.tern_pane
	if pane and live_panes()[pane] then
		return pane
	end
	return nil
end

-- What the primary button does for a task right now.
local function primary_label(t: Todo): string
	if live_pane_of(t) then
		return "Open pane"
	elseif t.links.omp_session then
		return "Open chat"
	end
	return "Start"
end

-- Done wins. A task without a live pane is a plain todo; stopped only describes
-- a live pane whose omp exited back to the shell.
local function status_of(state: State, t: Todo, live: { [number]: boolean }): string
	if t.done then
		return "done"
	end
	local pane = t.links.tern_pane
	if not pane then
		return "todo"
	end
	local key = tostring(pane)
	local dbg = state.debug_states[key]
	local word = dbg or state.agent_states[key]
	local kind = if word then KIND_OF_STATE[word] else nil
	local launched = state.launched[pane]
	local fresh = launched ~= nil and os.time() - (launched :: number) < STARTING_S
	if launched and not fresh then
		state.launched[pane] = nil
	end
	if not dbg then
		if not live[pane] then
			kind = if fresh then "starting" else "todo"
		elseif kind == nil and fresh then
			kind = "starting"
		end
	end
	kind = kind or "todo"
	if kind ~= "running" then
		state.since[pane] = nil
	elseif not state.since[pane] then
		state.since[pane] = os.time()
	end
	return kind
end

-- The quiet line under a row's title for a task with an agent.
local function agent_line(state: State, t: Todo, kind: string): string?
	if kind == "running" then
		local pane = t.links.tern_pane
		local started = if pane then state.since[pane] else nil
		local secs = if started then os.time() - started else 0
		if secs >= 3600 then
			return string.format("Working · %dh %dm", secs // 3600, (secs % 3600) // 60)
		elseif secs >= 60 then
			return string.format("Working · %dm", secs // 60)
		end
		return "Working"
	elseif kind == "needs" then
		return "Needs you"
	elseif kind == "review" then
		return "Ready for you"
	elseif kind == "starting" then
		return "Starting…"
	elseif kind == "stopped" then
		return "Stopped"
	end
	return nil
end

local function update_states(state: State): boolean
	local states = if tern.now() - state.states_at <= 15000 then state.agent_states else {}
	local debug: { [string]: string } = {}
	local dok, draw = pcall(tern.kv.get, "todo-proto.debug_states")
	if dok and type(draw) == "table" then
		for k, v in draw do
			if type(v) == "string" then
				debug[tostring(k)] = v
			end
		end
	end
	local live = live_panes()
	local ok_managed, raw_managed = pcall(tern.kv.get, "managed_closes")
	local managed = if ok_managed and type(raw_managed) == "table" then raw_managed else {}
	local closed = state.closed_panes or {}
	if state.previous_live then
		for pane in state.previous_live do
			if not live[pane] and not managed[tostring(pane)] then
				closed[tostring(pane)] = true
			end
		end
	end
	state.previous_live = live
	state.closed_panes = closed
	local completed = false
	if state.focus == nil and next(state.closing) == nil and next(state.launching) == nil and next(closed) ~= nil then
		local matched: boolean? = nil
		completed = rewrite(state, function(list)
			matched = false
			local changed = false
			for _, item in list do
				if type(item) == "table" and type(item.links) == "table" then
					local pane = tonumber(item.links.tern_pane)
					if pane and closed[tostring(pane)] then
						matched = true
						item.done = true
						item.backlog = nil
						item.links.tern_pane = nil
						changed = true
					end
				end
			end
			return changed
		end)
		if completed or matched == false then
			state.closed_panes = {}
		end
	end
	local panes: { number } = {}
	for pane in live do
		table.insert(panes, pane)
	end
	table.sort(panes)
	local sig = tern.json.encode({ states, debug, panes })
	if sig == state.states_sig then
		return completed
	end
	state.states_sig = sig
	state.agent_states = states
	state.debug_states = debug
	return true
end

local function nudge_n(state: State): number?
	local ok, v = pcall(tern.kv.get, "todo-proto.nudge")
	if ok and type(v) == "table" and v.path == state.path and type(v.n) == "number" then
		return v.n
	end
	return nil
end

local function reload_if_nudged(state: State): boolean
	local n = nudge_n(state)
	if n == nil or n == state.nudge_seen or state.focus ~= nil then
		return false
	end
	state.nudge_seen = n
	load(state)
	return true
end

local function heartbeat()
	local ids: { [string]: number } = {}
	local ambiguous: { [string]: boolean } = {}
	for _, pane in tern.pane.list() do
		local key = tostring(pane.pane % 17592186044416)
		if ids[key] ~= nil then
			ambiguous[key] = true
		end
		ids[key] = pane.pane
	end
	for key in ambiguous do
		ids[key] = nil
	end
	pcall(tern.kv.set, "todo-proto.pane_ids", ids)
	pcall(tern.kv.set, "watch", os.time())
end

-- Cycles the thinking level the way omp does: off, auto, then the model's efforts, then
-- back to Default (no flag).
local function cycle_level(state: State, t: Todo)
	local efforts = DEFAULT_EFFORTS
	local reasoning = true
	if t.agent.model then
		if state.models then
			for _, m in state.models do
				if m.selector == t.agent.model then
					reasoning = m.reasoning
					efforts = m.efforts
				end
			end
		else
			load_models(state)
		end
	end
	if not reasoning then
		state.cx:toast("info", "This model has no thinking levels")
		return
	end
	local levels: { string } = { "off", "auto" }
	for _, e in efforts do
		table.insert(levels, e)
	end
	local at = if t.agent.thinking then table.find(levels, t.agent.thinking) else 0
	local nextlevel = levels[(at or 0) + 1]
	if t.agent.thinking and not at then
		nextlevel = levels[1]
	end
	patch(state, t.id, function(item)
		local agent = if type(item.agent) == "table" then item.agent else {}
		agent.thinking = if nextlevel then nextlevel else tern.json.null
		item.agent = agent
	end)
end

-- Cycles the priority none -> low -> medium -> high -> urgent -> none.
local function cycle_priority(state: State, t: Todo)
	local at = table.find(PRIORITIES, t.priority) or 1
	local next_priority = PRIORITIES[at % #PRIORITIES + 1]
	patch(state, t.id, function(item)
		item.priority = next_priority
	end)
end

local function toggle_auto_title(state: State, t: Todo)
	local on = if t.auto_title == nil then state.cfg.omp_titles == true else t.auto_title
	patch(state, t.id, function(item)
		item.auto_title = not on
	end)
end

local function activate(state: State, t: Todo)
	local pane = live_pane_of(t)
	if pane then
		local ok, err = pcall(function()
			tern.process.run({ TERN, "focus", tostring(pane) }, in_window(state, 5000), function(result: ProcessResult, _)
				if result.status ~= 0 then
					state.cx:toast("error", "tern focus failed", result.stderr)
				end
			end)
		end)
		if not ok then
			state.cx:toast("error", "Cannot run tern", tostring(err))
		end
	elseif t.links.omp_session then
		launch(state, t, { omp_bin(), "--resume", t.links.omp_session }, false)
	else
		local argv = { omp_bin() }
		if t.agent.model then
			table.insert(argv, "--model")
			table.insert(argv, t.agent.model)
		end
		if t.agent.thinking then
			table.insert(argv, "--thinking")
			table.insert(argv, t.agent.thinking)
		end
		local prompt = t.title
		if t.notes ~= "" then
			prompt ..= "\n\n" .. t.notes
		end
		-- omp reads a leading "-" as a flag and "@" as a file attachment.
		local first = string.sub(prompt, 1, 1)
		if first == "-" or first == "@" then
			prompt = "Task: " .. prompt
		end
		table.insert(argv, prompt)
		launch(state, t, argv, true)
	end
end

-- Done and the pane -----------------------------------------------------

local SHELLS: { [string]: boolean } = {
	fish = true, bash = true, zsh = true, sh = true, dash = true, ksh = true,
	tcsh = true, csh = true, nu = true, xonsh = true, elvish = true,
}

local function exe_name(v: any): string
	local s = tostring(v or "")
	local base = string.match(s, "([^/]+)$") or s
	return (string.gsub(base, "^%-", ""))
end

local function proc_argv(proc: any): { any }
	return if type(proc) == "table" and type(proc.argv) == "table" then proc.argv else {}
end

local function is_shell(proc: any): boolean
	return type(proc) == "table" and SHELLS[exe_name(proc_argv(proc)[1] or proc.name)] == true
end

local function is_omp(proc: any): boolean
	if type(proc) ~= "table" then
		return false
	end
	local argv = proc_argv(proc)
	return exe_name(argv[1]) == "omp" or exe_name(proc.name) == "omp" or exe_name(argv[2]) == "omp"
end

local function keep_reason(stdout: string, pane: { working: boolean?, omp_session_file: string? }?): string?
	local ok, data = pcall(tern.json.decode, stdout)
	if not ok or type(data) ~= "table" or type(pane) ~= "table" then
		return "cannot inspect it"
	end
	local job = if type(data.foreground) == "table" then data.foreground else data.child
	if is_shell(job) then
		return nil
	elseif is_omp(job) then
		if pane.working == true then
			return "agent is working or needs you"
		elseif pane.working == false and type(pane.omp_session_file) == "string" then
			return nil
		end
		return "agent state unknown"
	end
	return "running a command"
end

local function busy(state: State, id: string): boolean
	return state.closing[id] == true or state.launching[id] == true
end

local function plural(n: number, noun: string): string
	return n .. " " .. noun .. (if n == 1 then "" else "s")
end

close_task_panes = function(state: State, set: { [string]: boolean }, commit: ({ [string]: number }) -> boolean)
	local want: { string } = {}
	for id in set do
		if todo_by_id(state, id) and not busy(state, id) then
			table.insert(want, id)
		else
			set[id] = nil
		end
	end
	if #want == 0 then
		return
	end
	local bulk = #want > 1
	refresh_cfg(state)
	-- One entry per live pane; tasks sharing a pane follow its verdict.
	local live = live_panes()
	local groups: { { pane: number, ids: { string } } } = {}
	for _, id in want do
		local t = todo_by_id(state, id) :: Todo
		local pane = t.links.tern_pane
		if pane and live[pane] then
			local found = false
			for _, g in groups do
				if g.pane == pane then
					table.insert(g.ids, id)
					found = true
				end
			end
			if not found then
				table.insert(groups, { pane = pane, ids = { id } })
			end
		end
	end
	-- Setting off: the task only changes status; its pane and link stay.
	if not state.cfg.close_on_done then
		groups = {}
	end
	if #groups == 0 then
		commit({})
		return
	end

	for _, id in want do
		state.closing[id] = true
	end
	local closed: { [string]: number } = {}
	local closed_panes, left_panes = 0, 0
	local why: { string } = {}
	local function finish()
		for _, id in want do
			state.closing[id] = nil
		end
		for _, g in groups do
			local key = tostring(g.pane)
			if closed[g.ids[1]] then
				state.agent_states[key] = nil
				state.since[g.pane] = nil
				state.launched[g.pane] = nil
			end
		end
		local written = commit(closed)
		if written and #why > 0 and not bulk then
			state.cx:toast("info", "Pane left open (" .. why[1] .. ")")
		elseif written and bulk then
			local parts: { string } = {}
			if closed_panes > 0 then
				table.insert(parts, "Closed " .. plural(closed_panes, "pane"))
			end
			if left_panes > 0 then
				table.insert(parts, (if closed_panes > 0 then "left " else "Left ") .. left_panes .. " open")
			end
			state.cx:toast("info", table.concat(parts, ", "), if #why > 0 then table.concat(why, "; ") else nil)
		end
		if alive(state) then
			state.cx:render()
		end
	end

	local function leave(reason: string)
		left_panes += 1
		if not table.find(why, reason) then
			table.insert(why, reason)
		end
	end

	local function close_phase(candidates: { { pane: number, ids: { string } } })
		local pending = #candidates
		if pending == 0 then
			finish()
			return
		end
		for _, g in candidates do
			local function settle()
				pending -= 1
				if pending == 0 then
					finish()
				end
			end
			local key = tostring(g.pane)
			local function mark_managed(value: boolean?): boolean
				local raw = tern.kv.get("managed_closes")
				local managed = if type(raw) == "table" then raw else {}
				if value and managed[key] then
					return false
				end
				managed[key] = value
				tern.kv.set("managed_closes", managed)
				return true
			end
			local recorded, claimed = pcall(mark_managed, true)
			if not recorded or not claimed then
				leave(if recorded then "pane closure already in flight" else "cannot record pane closure")
				settle()
				continue
			end
			local ok = pcall(tern.process.run, { TERN, "close", tostring(g.pane) }, in_window(state, 5000), function(result: ProcessResult, _)
				if result.status == 0 then
					closed_panes += 1
					for _, id in g.ids do
						closed[id] = g.pane
					end
				else
					pcall(mark_managed, nil)
					leave("close failed")
					state.cx:toast("error", "tern close failed", string.match(result.stderr, "[^\n]+") or ("exit " .. result.status))
				end
				settle()
			end)
			if not ok then
				pcall(mark_managed, nil)
				leave("cannot run tern")
				settle()
			end
		end
	end

	local candidates: { { pane: number, ids: { string } } } = {}
	local probing = #groups
	local function probed()
		probing -= 1
		if probing == 0 then
			close_phase(candidates)
		end
	end
	for _, g in groups do
		local reason: string? = nil
		if g.pane == state.cx.pane then
			reason = "this is the todo pane"
		else
			for _, other in state.todos do
				if other.links.tern_pane == g.pane and not set[other.id] and not other.done then
					reason = "shared with another task"
				end
			end
		end
		if reason then
			leave(reason)
			probed()
		else
			local ok = pcall(tern.process.run, { TERN, "process", "--json", tostring(g.pane) }, in_window(state, 5000), function(result: ProcessResult, _)
				if result.status ~= 0 then
					leave("cannot inspect it")
					probed()
					return
				end
				local inspected = pcall(tern.process.run, { TERN, "inspect", "--json" }, in_window(state, 5000), function(snapshot: ProcessResult, _)
					local decoded, catalog = pcall(tern.json.decode, snapshot.stdout)
					local pane = nil
					if snapshot.status == 0 and decoded and type(catalog) == "table" and type(catalog.panes) == "table" then
						for _, item in catalog.panes do
							if type(item) == "table" and item.pane == g.pane then
								pane = item
								break
							end
						end
					end
					local why_not = keep_reason(result.stdout, pane)
					if why_not then
						leave(why_not)
					else
						table.insert(candidates, g)
					end
					probed()
				end)
				if not inspected then
					leave("cannot run tern")
					probed()
				end
			end)
			if not ok then
				leave("cannot run tern")
				probed()
			end
		end
	end
end

local function set_done(state: State, ids: { string }, to: boolean)
	local want: { string } = {}
	local set: { [string]: boolean } = {}
	for _, id in ids do
		local t = todo_by_id(state, id)
		if t and t.done ~= to and not busy(state, id) and not set[id] then
			table.insert(want, id)
			set[id] = true
		end
	end
	if #want == 0 then
		return
	end
	local bulk = #ids > 1
	refresh_cfg(state)

	if not to then
		local written = rewrite(state, function(list)
			for _, item in list do
				if type(item) == "table" and set[item.id] then
					item.done = false
				end
			end
		end)
		if written then
			local opened = 0
			for _, id in want do
				local t = todo_by_id(state, id)
				if t and state.cfg.reopen_on_undone and t.links.omp_session and not live_pane_of(t) then
					opened += 1
					launch(state, t, { omp_bin(), "--resume", t.links.omp_session }, false)
				end
			end
			if bulk then
				state.cx:toast("info", "Marked " .. #want .. " not done" .. (if opened > 0 then ", reopening " .. plural(opened, "chat") else ""))
			end
		end
		return
	end

	local function write_done(closed: { [string]: number }): boolean
		return rewrite(state, function(list)
			for _, item in list do
				if type(item) == "table" and type(item.id) == "string" and set[item.id] then
					item.done = true
					item.backlog = nil
					local pane = closed[item.id]
					if pane and type(item.links) == "table" and tonumber(item.links.tern_pane) == pane then
						item.links.tern_pane = nil
					end
				end
			end
		end)
	end
	close_task_panes(state, set, function(closed)
		local written = write_done(closed)
		if written and bulk and next(closed) == nil then
			state.cx:toast("info", "Marked " .. #want .. " done")
		end
		return written
	end)

end

local function toggle_done(state: State, id: string)
	local t = todo_by_id(state, id)
	if t then
		set_done(state, { id }, not t.done)
	end
end

-- Mark done for the whole selection, or not done when every selected task is done.
local function bulk_done(state: State, ids: { string })
	local all_done = true
	for _, id in ids do
		local t = todo_by_id(state, id)
		if t and not t.done then
			all_done = false
		end
	end
	set_done(state, ids, not all_done)
end

local function bulk_action(state: State, which: string?)
	if which == "clear" then
		clear_sel(state)
		return
	end
	local ids = multi_ids(state)
	if #ids < 2 then
		return
	end
	if which == "archive" then
		bulk_archive(state, ids)
	elseif which == "backlog" then
		backlog_ids(state, ids)
	elseif which == "done" then
		bulk_done(state, ids)
	elseif which == "delete" then
		delete_press(state)
	end
end

-- Last activity of the omp chats linked to tasks: the mtime of each session jsonl, from one
-- `stat` over the known paths and (at most every 20 seconds per id) one `find` for new ids.
-- Runs on the file poll, not per frame; renders when a time changed.
local function absorb_stat(state: State, stdout: string): boolean
	local changed = false
	for _, f in parse_stat(stdout) do
		state.sess_path[f.id] = f.path
		if state.sess_mtime[f.id] ~= f.mtime then
			state.sess_mtime[f.id] = f.mtime
			changed = true
		end
	end
	return changed
end

local function poll_sessions(state: State)
	if state.sess_busy or not state.cfg.time then
		return
	end
	local now = os.time()
	local seen: { [string]: boolean } = {}
	local paths: { string } = {}
	local unknown: { string } = {}
	for _, t in state.todos do
		local id = t.links.omp_session
		if id and not seen[id] and string.match(id, "^[%w%-]+$") then
			seen[id] = true
			local path = state.sess_path[id]
			if path then
				table.insert(paths, path)
			elseif now - (state.sess_tried[id] or 0) >= 20 then
				state.sess_tried[id] = now
				table.insert(unknown, id)
			end
		end
	end
	local jobs = 0
	local changed = false
	local function done(stdout: string?)
		if stdout and absorb_stat(state, stdout) then
			changed = true
		end
		jobs -= 1
		if jobs == 0 then
			state.sess_busy = false
			if changed and alive(state) then
				state.cx:render()
			end
		end
	end
	local function run(argv: { string })
		jobs += 1
		state.sess_busy = true
		local ok = pcall(tern.process.run, argv, { timeout_ms = 8000 }, function(result: ProcessResult, _)
			done(result.stdout)
		end)
		if not ok then
			done(nil)
		end
	end
	if #paths > 0 then
		run(session_files.stat_argv(paths))
	end
	if #unknown > 0 then
		run(session_files.find_argv(sessions_root(), unknown))
	end
end

local function refresh(state: State)
	if not alive(state) then
		return
	end
	load(state)
end

-- tern.process.run hands back stdout only after the process ends, so one fswatch run waits for
-- one batch of changes (or WATCH_RUN_MS, to pick up session files found since). The watcher is
-- armed before the reload, so a change during the reload starts the next run instead of getting lost.
local function sync(state: State)
	poll_sessions(state)
	-- A field being edited owns its text: the file is left alone then.
	if state.focus == nil then
		refresh(state)
		state.cx:render()
	end
end

local function watch_files(state: State)
	if state.fsw or not alive(state) or not state.path then
		return
	end
	local argv = { FSWATCH, "-1", "--latency", WATCH_LATENCY_S, state.path :: string }
	if state.cfg.time then
		for _, path in state.sess_path do
			table.insert(argv, path)
		end
	end
	state.fsw = true
	local ok = pcall(tern.process.run, argv, { timeout_ms = WATCH_RUN_MS }, function(result: ProcessResult, _)
		state.fsw = false
		if not alive(state) then
			return
		end
		if result.timed_out then
			watch_files(state)
		elseif result.status == 0 and result.stdout ~= "" then
			watch_files(state)
			sync(state)
		end
	end)
	if not ok then
		state.fsw = false
	end
end

local function poll(state: State)
	if not alive(state) or state.timer then
		return
	end
	heartbeat()
	state.timer = tern.timer(POLL_MS, function()
		if not alive(state) then
			return
		end
		state.timer = nil
		heartbeat()
		sync(state)
		poll(state)
	end)
end

local STATE_MS = 200

-- Samples window.luau's omp states every STATE_MS; renders only when they changed.
local function poll_states(state: State)
	if not alive(state) or state.st_timer then
		return
	end
	state.st_timer = tern.timer(STATE_MS, function()
		if not alive(state) then
			return
		end
		state.st_timer = nil
		local changed = update_states(state)
		if refresh_cfg(state) then
			changed = true
		end
		if reload_if_nudged(state) then
			changed = true
		end
		if changed or next(state.launched) ~= nil then
			state.cx:render()
		end
		poll_states(state)
	end)
end

-- Text fields -----------------------------------------------------------

local function chars_of(s: string): { string }
	local out: { string } = {}
	for _, cp in utf8.codes(s) do
		table.insert(out, utf8.char(cp))
	end
	return out
end

local function length_of(s: string): number
	return utf8.len(s) or #s
end

-- Tern counts offsets in UTF-16 code units: the units before the first `cur` characters.
local function utf16_offset(s: string, cur: number): number
	local n, i = 0, 0
	for _, cp in utf8.codes(s) do
		if i >= cur then
			break
		end
		n += if cp > 0xFFFF then 2 else 1
		i += 1
	end
	return n
end

-- The number of characters that fit in the first `off` UTF-16 units (an offset inside a
-- surrogate pair rounds down, as Tern does).
local function char_index(s: string, off: number): number
	local units, n = 0, 0
	for _, cp in utf8.codes(s) do
		local w = if cp > 0xFFFF then 2 else 1
		if units + w > off then
			break
		end
		units += w
		n += 1
	end
	return n
end

local function trim(s: string): string
	return string.match(s, "^%s*(.-)%s*$") or ""
end

local function line_start(chars: { string }, cur: number): number
	local i = cur
	while i > 0 and chars[i] ~= "\n" do
		i -= 1
	end
	return i
end

local function line_end(chars: { string }, from: number): number
	local i = from
	while i < #chars and chars[i + 1] ~= "\n" do
		i += 1
	end
	return i
end

-- Letters, digits and everything non-ASCII (Cyrillic, emoji) belong to words.
local function is_word(c: string): boolean
	return #c > 1 or string.find(c, "^[%w_]$") ~= nil
end

local function word_left(chars: { string }, cur: number): number
	local i = cur
	while i > 0 and not is_word(chars[i]) do
		i -= 1
	end
	while i > 0 and is_word(chars[i]) do
		i -= 1
	end
	return i
end

local function word_right(chars: { string }, cur: number): number
	local n, i = #chars, cur
	while i < n and not is_word(chars[i + 1]) do
		i += 1
	end
	while i < n and is_word(chars[i + 1]) do
		i += 1
	end
	return i
end

-- A field's text, caret and selection anchor (both counted in characters), with its own
-- undo history: Tern's undo event carries no state, so each field keeps its steps. `max` is a
-- limit in UTF-16 units.
type Snap = { text: string, cur: number }
type Field = {
	text: string,
	cur: number,
	anchor: number?,
	id: string?,
	rev: number,
	undo: { Snap },
	redo: { Snap },
	-- The last change was typing, so the next typed character joins its undo step.
	typing: boolean,
	multiline: boolean,
	max: number?,
	task: string?,
	base: string,
	saved: string,
	conflict: boolean,
}

local HISTORY = 200

local function reset_field(f: Field, text: string)
	f.text, f.cur, f.anchor = text, length_of(text), nil
	f.undo, f.redo, f.typing = {}, {}, false
	f.base, f.saved, f.conflict, f.task = text, text, false, nil
	f.rev += 1
end

local function new_field(text: string, multiline: boolean, max: number?): Field
	local f: Field = { text = "", cur = 0, anchor = nil, rev = 0, base = "", saved = "", conflict = false, undo = {}, redo = {}, typing = false, multiline = multiline, max = max }
	reset_field(f, text)
	return f
end

-- Single-line fields take pasted line breaks as spaces.
local function tidy(f: Field, s: string): string
	if f.multiline then
		return (string.gsub(s, "\r\n?", "\n"))
	end
	return (string.gsub(s, "[\r\n]+", " "))
end

-- Ordered selection bounds; equal when nothing is selected.
local function bounds(f: Field): (number, number)
	local a = f.anchor
	if a == nil or a == f.cur then
		return f.cur, f.cur
	end
	return math.min(a, f.cur), math.max(a, f.cur)
end

-- Replaces characters [from, to) by `ins`, the caret after them. One undo step; typing
-- joins the open one. Returns whether the text changed.
local function replace(f: Field, from: number, to: number, ins: { string }, typing: boolean): boolean
	local chars = chars_of(f.text)
	local head = table.concat(chars, "", 1, from)
	local tail = table.concat(chars, "", to + 1)
	local max = f.max
	if max then
		while #ins > 0 and utf16_offset(head .. table.concat(ins) .. tail, math.huge) > max do
			table.remove(ins)
		end
	end
	local text = head .. table.concat(ins) .. tail
	if text == f.text then
		return false
	end
	if not (typing and f.typing) then
		table.insert(f.undo, { text = f.text, cur = f.cur })
		if #f.undo > HISTORY then
			table.remove(f.undo, 1)
		end
	end
	f.redo = {}
	f.typing = typing
	f.text, f.cur, f.anchor = text, from + #ins, nil
	return true
end

-- Steps back (redo = false) or forward through the field's history.
local function undo_step(f: Field, redo: boolean): boolean
	local from = if redo then f.redo else f.undo
	local snap = table.remove(from)
	if not snap then
		return false
	end
	table.insert(if redo then f.undo else f.redo, { text = f.text, cur = f.cur })
	f.text, f.cur, f.anchor, f.typing = snap.text, snap.cur, nil, false
	return true
end

-- Applies Tern's `edit` event: replace UTF-16 [from, to) by `text`, caret at `cursor`.
-- Returns "text", "caret", or nil when the event is stale (its `len` is not our text's).
local function apply_edit(f: Field, ev: UiEvent): string?
	if tonumber(ev.len) ~= utf16_offset(f.text, math.huge) then
		return nil
	end
	local from = char_index(f.text, tonumber(ev.from) or 0)
	local to = char_index(f.text, tonumber(ev.to) or 0)
	local ins = chars_of(tidy(f, if type(ev.text) == "string" then ev.text else ""))
	local changed = replace(f, from, to, ins, false)
	f.cur = char_index(f.text, tonumber(ev.cursor) or 0)
	f.anchor, f.typing = nil, false
	return if changed then "text" else "caret"
end

-- Applies a key to a field. Returns "text" (changed), "caret" (moved or selected), "submit"
-- (Enter in a single-line field), "blur" (Esc or Tab), or nil (the key is not for the field).
-- Tern turns keys that act on its own selection into `edit` events, so this sees the rest:
-- typing and deletes without a selection, word and line moves, ctrl+a, redo, and every
-- key on a selection the block drew itself.
local function edit_key(f: Field, key: Key, cx: BlockCx): string?
	local chars = chars_of(f.text)
	local n = #chars
	f.cur = math.clamp(f.cur, 0, n)
	local lo, hi = bounds(f)
	local name = key.name
	local mod = key.ctrl or key.meta
	local function remove(from: number, to: number): string
		return if replace(f, from, to, {}, false) then "text" else "caret"
	end
	local function go(to: number): string
		to = math.clamp(to, 0, n)
		if key.shift then
			f.anchor = f.anchor or f.cur
		else
			f.anchor = nil
		end
		f.cur, f.typing = to, false
		return "caret"
	end
	if name == "escape" or name == "tab" then
		return "blur"
	elseif name == "enter" then
		if not f.multiline then
			return "submit"
		end
		return if replace(f, lo, hi, { "\n" }, false) then "text" else "caret"
	elseif mod and not key.alt and name == "a" and not key.shift then
		-- A fresh node key drops Tern's retained native range before block select-all.
		f.anchor, f.cur, f.typing = 0, n, false
		f.rev += 1
		if f.id then
			f.id = string.gsub(f.id, "_%d+$", "_" .. f.rev)
			cx:frame({ { "focus", f.id } })
		end
		return "caret"
	elseif mod and not key.alt and name == "z" then
		return if undo_step(f, key.shift) then "text" else nil
	elseif key.ctrl and name == "y" then
		return if undo_step(f, true) then "text" else nil
	elseif mod and (name == "c" or name == "x") and lo ~= hi then
		cx:copy(table.concat(chars, "", lo + 1, hi))
		return if name == "x" then remove(lo, hi) else "caret"
	elseif name == "backspace" or (key.ctrl and (name == "u" or name == "w")) then
		if lo ~= hi then
			return remove(lo, hi)
		end
		-- cmd+backspace reaches the program as ctrl+u; ctrl+w and option+backspace delete a word.
		local to = f.cur - 1
		if key.meta or name == "u" then
			to = line_start(chars, f.cur)
			if to == f.cur then
				to = f.cur - 1
			end
		elseif key.alt or name == "w" then
			to = word_left(chars, f.cur)
		end
		return remove(math.max(0, to), f.cur)
	elseif name == "delete" or (key.ctrl and name == "k") then
		if lo ~= hi then
			return remove(lo, hi)
		end
		local to = f.cur + 1
		if key.meta or name == "k" then
			to = line_end(chars, f.cur)
			if to == f.cur then
				to = f.cur + 1
			end
		elseif key.alt then
			to = word_right(chars, f.cur)
		end
		return remove(f.cur, math.min(n, to))
	elseif name == "left" or (key.alt and name == "b") then
		if not key.shift and lo ~= hi and not key.alt and not mod then
			return go(lo)
		end
		if key.alt then
			return go(word_left(chars, f.cur))
		elseif mod then
			return go(if f.multiline then line_start(chars, f.cur) else 0)
		end
		return go(f.cur - 1)
	elseif name == "right" or (key.alt and name == "f") then
		if not key.shift and lo ~= hi and not key.alt and not mod then
			return go(hi)
		end
		if key.alt then
			return go(word_right(chars, f.cur))
		elseif mod then
			return go(if f.multiline then line_end(chars, f.cur) else n)
		end
		return go(f.cur + 1)
	elseif name == "home" then
		return go(if f.multiline and not mod then line_start(chars, f.cur) else 0)
	elseif name == "end" then
		return go(if f.multiline and not mod then line_end(chars, f.cur) else n)
	elseif key.ctrl and not key.alt and not key.meta and name == "e" then
		return go(if f.multiline then line_end(chars, f.cur) else n)
	elseif name == "up" then
		return go(0)
	elseif name == "down" then
		return go(n)
	end
	local typed = key.text
	if name == "space" and not typed then
		typed = " "
	end
	if name == "paste" or (typed and typed ~= "" and not (key.ctrl or key.alt or key.meta)) then
		local ins = chars_of(tidy(f, typed or ""))
		return if replace(f, lo, hi, ins, name ~= "paste") then "text" else "caret"
	end
	return nil
end

-- The last value we wrote is the base version for the next live save. `base` stays
-- the edit-start value for Esc. Re-read inside rewrite, never from the sampled view.
local function save_field(state: State, f: Field, name: string, mode: string)
	local id = f.task
	if not id then
		return
	end
	local draft = if name == "title" then trim(f.text) else f.text
	local cancel = mode == "cancel" or (name == "title" and mode == "commit" and draft == "")
	-- A new task's notes stay on the draft until add_task writes it (its title is the add row).
	local fresh = state.fresh
	if fresh and fresh.id == id then
		if name == "notes" then
			if cancel then
				reset_field(f, f.base)
				f.task = id
			end
			fresh.notes = f.text
		end
		return
	end
	rewrite(state, function(list)
		for _, item in list do
			if type(item) ~= "table" or item.id ~= id then
				continue
			end
			local disk = tostring(item[name] or "")
			if cancel then
				local value = if not f.conflict and disk == f.saved then f.base else disk
				reset_field(f, value)
				if value == disk then
					return false
				end
				item[name] = value
				return true
			end
			if disk ~= f.base and disk ~= f.saved and disk ~= draft and not f.conflict then
				f.conflict = true
				state.cx:toast("warning", "Task changed on disk")
			end
			if mode == "live" and (f.conflict or (name == "title" and draft == "")) then
				return false
			end
			if disk == draft then
				f.saved = draft
				return false
			end
			item[name], f.saved = draft, draft
			if name == "title" then
				item.auto_title = false
			end
			return true
		end
		return false
	end)
end

local function drop_fresh(state: State)
	state.fresh = nil
	ensure_cursor(state)
end

-- The connection form's field `name` (jurl, jemail, jtoken); nil for any other focus.
function jira.field(state: State, name: string?): Field?
	return if name == "jurl" then state.jurl
		elseif name == "jemail" then state.jemail
		elseif name == "jtoken" then state.jtoken
		else nil
end

-- Sets (nil clears) the value of Jira field `fid` on task `id`, the new task's draft included.
function jira.set_value(state: State, id: string, fid: string, value: any)
	patch(state, id, function(item)
		local values = if type(item.jira_fields) == "table" then item.jira_fields else {}
		values[fid] = value
		item.jira_fields = if next(values) ~= nil then values else nil
	end)
	if state.jira.missing_task == id then
		state.jira.missing[fid] = nil
	end
end

-- Writes the Jira field being typed in (focus "jx") to its task: "live" and "commit" keep the
-- draft, "cancel" puts back what the field held when typing began. Blank clears the value.
function jira.save_text(state: State, mode: string)
	local f, fid = state.jx, state.jira.jx_field
	local id = f.task
	if not id or not fid then
		return
	end
	if mode == "cancel" then
		reset_field(f, f.base)
		f.task = id
	end
	local value: string? = if trim(f.text) == "" then nil else f.text
	local t = if state.fresh and state.fresh.id == id then state.fresh else todo_by_id(state, id)
	local held = if t and t.jira_fields then t.jira_fields[fid] else nil
	if held ~= value then
		jira.set_value(state, id, fid, value)
	end
end

local function set_focus(state: State, field: string?)
	-- A new task lives while its add row, its notes, a Jira field or a popover has focus.
	local drop = state.fresh ~= nil and field ~= "add" and field ~= "notes" and field ~= "picker" and field ~= "jx"
		and (state.focus == "add" or state.focus == "notes" or state.focus == "picker" or state.focus == "jx")
	if state.focus == "title" and field ~= "title" then
		save_field(state, state.title, "title", "commit")
		state.title.task = nil
	elseif state.focus == "notes" and field ~= "notes" then
		save_field(state, state.notes, "notes", "commit")
		state.notes.task = nil
	elseif state.focus == "jx" and field ~= "jx" then
		jira.save_text(state, "commit")
		state.jx.task = nil
	end
	if drop then
		drop_fresh(state)
	end
	local t = selected(state)
	if field == "notes" then
		if not t then
			return
		end
		state.detail_open = true
		if state.focus ~= "notes" then
			reset_field(state.notes, t.notes)
			state.notes.task = t.id
		end
	elseif field == "title" then
		if not t then
			return
		end
		state.detail_open = true
		if state.focus ~= "title" then
			reset_field(state.title, t.title)
			state.title.task = t.id
		end
	end
	state.focus = field
	local id: any = tern.json.null
	if field == "add" then
		id = "main.ws.left.add.field_" .. state.add.rev
	elseif field == "notes" then
		id = "main.ws.detail.notes_" .. state.notes.rev
	elseif field == "title" then
		id = "main.ws.detail.head.title_" .. state.title.rev
	elseif field == "picker" and state.pick and SEARCH[state.pick.kind] then
		id = "layer.q_" .. state.pick.q.rev
	elseif field == "jx" then
		local spec = jira.spec(state, state.jira.jx_field)
		if spec then
			id = jira.jx_path(spec) .. "-r" .. state.jx.rev
		end
	elseif field and jira.field(state, field) then
		id = "main.ws.jform." .. field .. "_" .. (jira.field(state, field) :: Field).rev
	end
	state.cx:frame({ { "focus", id } })
end

local function new_task(state: State)
	set_focus(state, nil)
	reset_field(state.add, "")
	state.fresh = {
		id = "", title = "", notes = "", priority = "none", done = false,
		archived = false, backlog = state.tab == "backlog",
		links = { cwd = last_project() }, agent = {},
	}
	state.detail_open = true
	state.sel = {}
	state.anchor = nil
	clear_confirm(state)
	set_focus(state, "add")
end

local function sync_fresh_title(state: State)
	if state.fresh then
		state.fresh.title = trim(state.add.text)
	end
end

-- Adds the task the add row holds (Enter there, or the new task card's buttons). Returns its
-- id; nil while the title is empty or when the file could not be written.
function card.add(state: State): string?
	local title = trim(state.add.text)
	if title == "" then
		return nil
	end
	local id = add_task(state, title)
	reset_field(state.add, "")
	set_focus(state, nil)
	return id
end

local function begin_rename(state: State)
	if not selected(state) then
		return
	end
	set_focus(state, "title")
	local f = state.title
	if #f.text > 0 then
		f.anchor, f.cur = 0, length_of(f.text)
	end
end

-- The field a Tern edit/undo event belongs to, when that field is the focused one.
local function field_of(state: State, id: string): Field?
	local f = if state.focus == "add" then state.add
		elseif state.focus == "notes" then state.notes
		elseif state.focus == "title" then state.title
		elseif state.focus == "picker" and state.pick then state.pick.q
		elseif state.focus == "jx" then state.jx
		else jira.field(state, state.focus)
	return if f and f.id == id then f else nil
end

-- Writes what a changed field holds: the detail fields go to the file, a popover's search
-- resets the highlighted row.
local function field_changed(state: State)
	if state.focus == "add" then
		sync_fresh_title(state)
	elseif state.focus == "title" then
		save_field(state, state.title, "title", "live")
	elseif state.focus == "notes" then
		save_field(state, state.notes, "notes", "live")
	elseif state.focus == "picker" and state.pick then
		state.pick.sel = 0
		state.pick.hint = nil
	elseif state.focus == "jx" then
		jira.save_text(state, "live")
	elseif jira.field(state, state.focus) then
		state.jira.form_error = nil
	end
end

-- Starts typing in the Jira field `fid` of the selected task's card (focus "jx"); the field
-- typed in before is written first.
function jira.focus_field(state: State, fid: string)
	local t = selected(state)
	local spec = jira.spec(state, fid)
	if not t or not spec then
		return
	end
	local j = state.jira
	if state.focus == "jx" then
		if j.jx_field == fid then
			return
		end
		jira.save_text(state, "commit")
	end
	local value = if t.jira_fields then t.jira_fields[fid] else nil
	j.jx_field = fid
	reset_field(state.jx, if type(value) == "string" then value else "")
	state.jx.multiline = not jira.inline(spec)
	state.jx.task = t.id
	set_focus(state, "jx")
end

-- Jira (Tickets tab) ------------------------------------------------------------

function jira.new(): Jira
	return {
		conn = "unknown",
		url = nil,
		email = nil,
		user = nil,
		project = nil,
		board = nil,
		projects = nil,
		boards = nil,
		boards_for = nil,
		sprints = nil,
		tickets = nil,
		loaded_at = nil,
		busy = {},
		last = {},
		-- Counted from the clock, so a restarted block never takes an old run's answers.
		req = math.floor(tern.now()),
		error = nil,
		form_error = nil,
		list_error = nil,
		cursor = nil,
		editing = false,
		want_board = false,
		post = { project = nil, components = {}, types = {} },
		comps = {},
		comps_error = {},
		types = {},
		def_type = {},
		meta_error = {},
		notes_required = {},
		fields = {},
		more = false,
		missing = {},
		missing_task = nil,
		pick_field = nil,
		jx_field = nil,
		view = jira.read_view(),
		folded = {},
	}
end

-- The tickets tab's stored view (VIEW_KEY): grouping by assignee unless set otherwise.
function jira.read_view(): { mine: boolean, group: string }
	local ok, v = pcall(tern.kv.get, jira.VIEW_KEY)
	local t: { [string]: any } = if ok and type(v) == "table" then v else {}
	return {
		mine = t.mine == true,
		group = if type(t.group) == "string" and jira.GROUP_LABEL[t.group] then t.group else "assignee",
	}
end

-- Changes the tickets tab's view (nil keeps that part) and stores it for every block.
function jira.set_view(state: State, mine: boolean?, group: string?)
	local j = state.jira
	if mine ~= nil then
		j.view.mine = mine
	end
	if group and jira.GROUP_LABEL[group] then
		j.view.group = group
		j.folded = {}
	end
	pcall(tern.kv.set, jira.VIEW_KEY, j.view)
end

-- Takes the connection snapshot the window sends with most answers.
function jira.apply_status(state: State, s: any)
	local j = state.jira
	j.conn = if s.connected == true then "connected" else "disconnected"
	if str_or_nil(s.url) ~= j.url then
		j.comps, j.comps_error = {}, {}
		j.types, j.def_type, j.meta_error, j.notes_required, j.fields = {}, {}, {}, {}, {}
	end
	j.url, j.email, j.user = str_or_nil(s.url), str_or_nil(s.email), str_or_nil(s.user)
	j.me = str_or_nil(s.me)
	local p, b, post = s.project, s.board, s.post
	local target: { project: JiraProject?, components: { [string]: JiraComponent | boolean }, types: { [string]: JiraType } } = { project = nil, components = {}, types = {} }
	if type(post) == "table" then
		local pp = post.project
		if type(pp) == "table" and str_or_nil(pp.key) then
			target.project = { key = pp.key, name = str_or_nil(pp.name) or pp.key }
		end
		for key, v in (if type(post.components) == "table" then post.components else {}) :: { [any]: any } do
			if type(key) == "string" and v == false then
				target.components[key] = false
			elseif type(key) == "string" and type(v) == "table" and str_or_nil(v.id) then
				target.components[key] = { id = v.id, name = str_or_nil(v.name) or v.id }
			end
		end
		for key, v in (if type(post.types) == "table" then post.types else {}) :: { [any]: any } do
			if type(key) == "string" and type(v) == "table" and str_or_nil(v.id) then
				target.types[key] = { id = v.id, name = str_or_nil(v.name) or v.id }
			end
		end
	end
	j.post = target
	local project: JiraProject? = if type(p) == "table" and str_or_nil(p.key)
		then { key = p.key, name = str_or_nil(p.name) or p.key }
		else nil
	local board: JiraBoard? = if type(b) == "table" and type(b.id) == "number"
		then { id = b.id, name = str_or_nil(b.name) or tostring(b.id), kind = str_or_nil(b.kind) }
		else nil
	if (if project then project.key else nil) ~= (if j.project then j.project.key else nil) then
		j.boards, j.boards_for = nil, nil
	end
	if (if board then board.id else nil) ~= (if j.board then j.board.id else nil) or j.conn ~= "connected" then
		j.sprints, j.tickets, j.loaded_at = nil, nil, nil
	end
	j.project, j.board = project, board
	-- The form shows what is stored, unless the user is typing there.
	if j.url and state.jurl.text == "" and state.focus ~= "jurl" then
		reset_field(state.jurl, j.url)
	end
	if j.email and state.jemail.text == "" and state.focus ~= "jemail" then
		reset_field(state.jemail, j.email)
	end
end

-- Asks for what the Tickets tab shows next: the connection first, then the boards of a
-- project without one, then the board's sprint (again after STALE_S, or now when `force`).
function jira.load(state: State, force: boolean)
	local j = state.jira
	if j.conn == "unknown" or (force and j.conn == "disconnected") then
		if not j.busy.status then
			jira.ask(state, "status", nil)
		end
		return
	end
	if j.conn ~= "connected" then
		return
	end
	if j.project and not j.board and j.boards_for ~= j.project.key and not j.busy.boards then
		jira.ask(state, "boards", { project = j.project.key })
	end
	if j.board and not j.busy.sprint
		and (force or j.tickets == nil or os.time() - (j.loaded_at or 0) >= jira.STALE_S) then
		j.error = nil
		jira.ask(state, "sprint", { board = tostring(j.board.id) })
	end
end

-- Opening the tab takes the view other blocks may have changed since.
function jira.enter(state: State)
	state.jira.view = jira.read_view()
	jira.load(state, false)
end

-- Whether the ticket is assigned to you: by Jira id, else (no id known) by display name.
function jira.is_mine(state: State, tk: Ticket): boolean
	local j = state.jira
	if j.me and tk.assignee_id then
		return tk.assignee_id == j.me
	end
	return tk.assignee ~= nil and tk.assignee == j.user
end

-- The sprint's tickets as the tab shows them: only yours while "only mine" is on, grouped by
-- assignee (you first, then by name, Unassigned last), by status (to do, in progress, done)
-- or in one headerless group. Inside a group tickets keep Jira's order (their rank).
function jira.groups(state: State): { TicketGroup }
	local j = state.jira
	local by = j.view.group
	local groups: { TicketGroup } = {}
	local index: { [string]: TicketGroup } = {}
	for _, tk in j.tickets or {} do
		local mine = jira.is_mine(state, tk)
		if mine or not j.view.mine then
			local id, label, rank = "all", "", 0
			if by == "assignee" and mine then
				id, label, rank = "me", "Assigned to you", 0
			elseif by == "assignee" and tk.assignee then
				id, label, rank = "a:" .. (tk.assignee_id or tk.assignee), tk.assignee, 1
			elseif by == "assignee" then
				id, label, rank = "none", "Unassigned", 2
			elseif by == "status" then
				id, label, rank = "s:" .. tk.status, tk.status, jira.CATEGORY_RANK[tk.category] or 2
			end
			local g: TicketGroup = index[id] or { id = id, label = label, tickets = {}, rank = rank, order = #groups + 1 }
			if not index[id] then
				index[id] = g
				table.insert(groups, g)
			end
			table.insert(g.tickets, tk)
		end
	end
	table.sort(groups, function(a: TicketGroup, b: TicketGroup): boolean
		if a.rank ~= b.rank then
			return a.rank < b.rank
		end
		if by == "assignee" and string.lower(a.label) ~= string.lower(b.label) then
			return string.lower(a.label) < string.lower(b.label)
		end
		return a.order < b.order
	end)
	return groups
end

-- The tickets the tab lists, top to bottom, leaving out those of folded groups.
function jira.shown(state: State): { Ticket }
	local out: { Ticket } = {}
	for _, g in jira.groups(state) do
		if not state.jira.folded[g.id] then
			for _, tk in g.tickets do
				table.insert(out, tk)
			end
		end
	end
	return out
end

function jira.choose_project(state: State, p: JiraProject)
	local j = state.jira
	if j.project and j.project.key == p.key then
		return
	end
	j.project, j.board = p, nil
	j.boards, j.boards_for = nil, nil
	j.sprints, j.tickets, j.loaded_at = nil, nil, nil
	j.error, j.list_error, j.cursor = nil, nil, nil
	j.want_board = true
	jira.ask(state, "select", { project = p.key, project_name = p.name })
	jira.ask(state, "boards", { project = p.key })
end

function jira.choose_board(state: State, b: JiraBoard)
	local j = state.jira
	j.board = b
	j.sprints, j.tickets, j.loaded_at = nil, nil, nil
	j.error, j.cursor = nil, nil
	local q: { [string]: string } = { board = tostring(b.id), board_name = b.name, board_kind = b.kind or "" }
	if j.project then
		q.project, q.project_name = j.project.key, j.project.name
	end
	jira.ask(state, "select", q)
	jira.ask(state, "sprint", { board = tostring(b.id) })
end

function jira.task_for(state: State, key: string): Todo?
	for _, t in state.todos do
		if t.jira and t.jira.key == key then
			return t
		end
	end
	return nil
end

function jira.ticket(state: State, key: string?): Ticket?
	for _, tk in state.jira.tickets or {} do
		if tk.key == key then
			return tk
		end
	end
	return nil
end

-- The highlighted ticket among those the tab lists; the first of them when none is.
function jira.selected(state: State): Ticket?
	local j = state.jira
	local list = jira.shown(state)
	for _, tk in list do
		if tk.key == j.cursor then
			return tk
		end
	end
	local tk = list[1]
	if tk then
		j.cursor = tk.key
	end
	return tk
end

function jira.move(state: State, delta: number?, to: number?)
	local list = jira.shown(state)
	local at = 0
	for i, tk in list do
		if tk.key == state.jira.cursor then
			at = i
		end
	end
	local tk = list[math.clamp(to or (at + (delta or 0)), 1, math.max(1, #list))]
	if tk then
		state.jira.cursor = tk.key
	end
end

-- The next free "t<N>" id of the file's task list, as add_task picks it.
function jira.free_id(list: { any }): string
	local taken: { [string]: boolean } = {}
	for _, item in list do
		if type(item) == "table" and type(item.id) == "string" then
			taken[item.id] = true
		end
	end
	local n = #list + 1
	while taken["t" .. n] do
		n += 1
	end
	return "t" .. n
end

-- Adds the ticket as the first task, linked by `jira`. Returns the id of the ticket's task,
-- also when another block added it first; nil when the file could not be written.
function jira.add_task(state: State, tk: Ticket): string?
	local url = if state.jira.url then state.jira.url .. "/browse/" .. tk.key else nil
	local notes: { string } = {}
	local description = if tk.description then trim(tk.description) else ""
	if description ~= "" then
		table.insert(notes, description)
	end
	for _, d in tk.details do
		table.insert(notes, d.name .. ":\n" .. d.text)
	end
	if url then
		table.insert(notes, url)
	end
	local cwd = last_project()
	local id: string? = nil
	local existing = false
	local written = rewrite(state, function(list)
		for _, item in list do
			if type(item) == "table" and type(item.id) == "string" and type(item.jira) == "table" and item.jira.key == tk.key then
				id, existing = item.id, true
				return false
			end
		end
		local new_id = jira.free_id(list)
		id = new_id
		table.insert(list, 1, {
			id = new_id,
			title = tk.key .. " " .. tk.summary,
			notes = table.concat(notes, "\n\n"),
			priority = "none",
			due = tern.json.null,
			done = false,
			links = if cwd then { cwd = cwd } else {},
			jira = { key = tk.key, url = url },
		})
		return true
	end)
	return if written or existing then id else nil
end

-- Shows the task on its tab with its card open.
function jira.show_task(state: State, t: Todo)
	switch_tab(state, if in_backlog(t) then "backlog" else "tasks")
	if t.archived and state.cfg.archived then
		state.arch_open = true
	elseif t.done and state.cfg.done_group then
		state.done_open = true
	end
	clear_sel(state)
	state.cursor = t.id
	state.anchor = t.id
	state.detail_open = true
	ensure_cursor(state)
end

-- Start / Enter (start) and Add to tasks / a: the ticket's task, made when missing. Starting
-- then does what Enter does on that task: focus its pane, resume its chat or launch omp.
function jira.ticket_task(state: State, tk: Ticket, start: boolean)
	local t = jira.task_for(state, tk.key)
	if not t then
		local id = jira.add_task(state, tk)
		t = if id then todo_by_id(state, id) else nil
		if not t then
			return
		end
		if not start then
			state.cx:toast("success", "Added " .. tk.key .. " to tasks")
		end
	elseif not start then
		jira.show_task(state, t)
		return
	end
	if start then
		activate(state, t)
	end
end

function jira.open_issue(state: State, key: string)
	local base = state.jira.url
	if base then
		state.cx:open(base .. "/browse/" .. key)
	end
end

-- Task card → Jira ----------------------------------------------------------------

-- Notes sent as an issue's description, at most (bytes).
jira.DESCRIPTION_MAX = 30000
-- Popover kinds of the Jira half; they need no task (jira_type and jira_field act on the card's).
jira.KINDS = {
	jira_project = true,
	jira_board = true,
	jira_target = true,
	jira_component = true,
	jira_type = true,
	jira_field = true,
	jira_group = true,
} :: { [string]: boolean }
-- Optional fields the card shows without "more fields": the ones most issues set.
jira.MAIN = { priority = true, labels = true, assignee = true, duedate = true, fixVersions = true } :: { [string]: boolean }

-- `s` cut to at most `max` bytes at a UTF-8 character boundary.
function jira.clip(s: string, max: number): string
	if #s <= max then
		return s
	end
	local cut = max
	while cut > 0 and bit32.band(string.byte(s, cut + 1) or 0, 0xC0) == 0x80 do
		cut -= 1
	end
	return string.sub(s, 1, cut)
end

-- Where the task card posts: the stored project, else the Tickets tab's, else the first one
-- Jira lists; with the project's stored component (false: none), else its first one. `ready`
-- is false until the components that decide it have loaded (or failed to).
function jira.target(state: State): (JiraProject?, JiraComponent?, boolean)
	local j = state.jira
	local p = j.post.project or j.project or (if j.projects then j.projects[1] else nil)
	if not p then
		return nil, nil, false
	end
	local list = j.comps[p.key]
	local stored = j.post.components[p.key]
	if stored == false then
		return p, nil, true
	end
	if type(stored) == "table" then
		if not list then
			return p, stored, true
		end
		-- One deleted in Jira since falls back to the default.
		for _, c in list do
			if c.id == stored.id then
				return p, c, true
			end
		end
	end
	if list then
		return p, list[1], true
	end
	return p, nil, j.comps_error[p.key] ~= nil
end

-- The issue type Post to Jira creates in `p`: the stored one while Jira still offers it, else
-- Jira's default. Until the project's types have loaded, the stored one (or nil).
function jira.kind(state: State, p: JiraProject): JiraType?
	local j = state.jira
	local stored = j.post.types[p.key]
	local list = j.types[p.key]
	if not list then
		return stored
	end
	if stored then
		for _, t in list do
			if t.id == stored.id then
				return t
			end
		end
	end
	return j.def_type[p.key] or list[1]
end

-- The create screen's fields of the card's target project and type (nil until loaded), with
-- that project and type.
function jira.form_fields(state: State): ({ JiraField }?, JiraProject?, JiraType?)
	local p = jira.target(state)
	local kind = if p then jira.kind(state, p) else nil
	if not p or not kind then
		return nil, p, kind
	end
	return state.jira.fields[p.key .. ":" .. kind.id], p, kind
end

-- The card's field `fid`, nil when the target type has none such.
function jira.spec(state: State, fid: string?): JiraField?
	local list: { JiraField } = jira.form_fields(state) or {}
	for _, f in list do
		if f.id == fid then
			return f
		end
	end
	return nil
end

-- Whether the field sits in a labelled row (choices, one-line text) rather than under its
-- own label (multi-line text).
function jira.inline(f: JiraField): boolean
	return not (f.kind == "text" and f.multiline)
end

-- Node id of a text field's input on the card, without the "-r<rev>" of the one being typed in
-- (set_focus needs it before the card is drawn; jira.card_rows draws it there).
function jira.jx_path(f: JiraField): string
	return if jira.inline(f) then "main.ws.detail.jira.rows.jf-" .. f.id .. ".value.jx-" .. f.id
		else "main.ws.detail.jira.texts.jf-" .. f.id .. ".jx-" .. f.id
end

-- Whether Jira refuses the issue while the card leaves the field empty.
function jira.needed(f: JiraField): boolean
	return f.required and not f.default
end

-- Whether the card shows the field while "more fields" is closed: what Jira needs, the custom
-- long texts (Definition of Done…), the usual ones (MAIN), and any the task already fills in
-- or is being typed in.
function jira.main_field(state: State, t: Todo, f: JiraField): boolean
	local j = state.jira
	return jira.needed(f) or (f.kind == "text" and f.id ~= "environment") or jira.MAIN[f.id] == true
		or (t.jira_fields ~= nil and t.jira_fields[f.id] ~= nil)
		or (state.focus == "jx" and j.jx_field == f.id)
		or (j.missing_task == t.id and j.missing[f.id] == true)
end

-- Asks for what the card still lacks: the project list, the target's components, its issue
-- types and the target type's fields. A failed list is not asked again; opening its popover
-- (or Retry, for the fields) asks again.
function jira.prefetch(state: State)
	local j = state.jira
	if j.conn ~= "connected" then
		return
	end
	local p = j.post.project or j.project or (if j.projects then j.projects[1] else nil)
	if not p then
		if not j.projects and not j.busy.projects and not j.list_error then
			jira.ask(state, "projects", nil)
		end
		return
	end
	if j.comps[p.key] == nil and j.comps_error[p.key] == nil and not j.busy.components then
		jira.ask(state, "components", { project = p.key })
	end
	local kind = jira.kind(state, p)
	local loaded = j.types[p.key] ~= nil and kind ~= nil and j.fields[p.key .. ":" .. kind.id] ~= nil
	if not loaded and j.meta_error[p.key] == nil and not j.busy.meta then
		local q: { [string]: string } = { project = p.key }
		if kind then
			q.type = kind.id
		end
		jira.ask(state, "meta", q)
	end
end

-- The project or component picked in the task card's popovers becomes the stored target.
-- `component` is a component id, false for none, or nil to keep the project's stored one.
function jira.choose_target(state: State, p: JiraProject, component: (string | boolean)?)
	local j = state.jira
	j.post.project = p
	local q: { [string]: string } = { project = p.key, project_name = p.name }
	if component == false then
		j.post.components[p.key] = false
		q.component = "none"
	elseif type(component) == "string" then
		for _, c in j.comps[p.key] or {} do
			if c.id == component then
				j.post.components[p.key] = c
				q.component, q.component_name = c.id, c.name
			end
		end
	end
	jira.ask(state, "target", q)
	jira.prefetch(state)
end

-- The issue type picked in the card becomes the project's stored one; its fields load next.
function jira.choose_type(state: State, p: JiraProject, kind: JiraType)
	state.jira.post.types[p.key] = kind
	jira.ask(state, "target", { project = p.key, project_name = p.name, type = kind.id, type_name = kind.name })
	jira.prefetch(state)
end

-- Local time's offset from UTC as Jira writes it ("+0100"). Luau's os.time reads a date
-- table as UTC, so local minus UTC fields is the offset, summer time included.
function jira.utc_offset(): string
	local now = os.time()
	local diff = os.time(os.date("*t", now) :: any) - os.time(os.date("!*t", now) :: any)
	local sign = if diff < 0 then "-" else "+"
	diff = math.abs(diff)
	return string.format("%s%02d%02d", sign, diff // 3600, (diff % 3600) // 60)
end

-- The task's values for `fields` in the shape Jira's create takes; the user fields set to
-- "me" (the window fills in the signed-in user); and per field id what is wrong: "required"
-- for one Jira needs but the task leaves empty, else what the value should look like.
function jira.payload(t: Todo, fields: { JiraField }): ({ [string]: any }, { string }, { [string]: string })
	local out: { [string]: any } = {}
	local users: { string } = {}
	local bad: { [string]: string } = {}
	for _, f in fields do
		local v = if t.jira_fields then t.jira_fields[f.id] else nil
		local text = if type(v) == "string" then str_or_nil(trim(v)) else nil
		if f.kind == "choice" and f.multi and type(v) == "table" then
			local list: { any } = {}
			for _, c in v do
				if type(c) == "table" and str_or_nil(c.id) then
					table.insert(list, { id = c.id })
				end
			end
			out[f.id] = if #list > 0 then list else nil
		elseif f.kind == "choice" and type(v) == "table" and str_or_nil(v.id) then
			out[f.id] = { id = v.id }
		elseif f.kind == "user" and v == "me" then
			table.insert(users, f.id)
		elseif text and f.kind == "number" then
			local n = tonumber(text)
			if n then
				out[f.id] = n
			else
				bad[f.id] = "a number"
			end
		elseif text and f.kind == "date" then
			if string.match(text, "^%d%d%d%d%-%d%d%-%d%d$") then
				out[f.id] = text
			else
				bad[f.id] = "a date like 2026-11-30"
			end
		elseif text and f.kind == "datetime" then
			local d, h, m = string.match(text, "^(%d%d%d%d%-%d%d%-%d%d)[ T](%d%d?):(%d%d)$")
			if d and h and m then
				out[f.id] = string.format("%sT%02d:%s:00.000%s", d, tonumber(h) :: number, m, jira.utc_offset())
			else
				bad[f.id] = "a time like 2026-11-30 14:00"
			end
		elseif text and f.kind == "labels" then
			local list: { string } = {}
			for word in string.gmatch(text, "[^%s,]+") do
				table.insert(list, word)
			end
			out[f.id] = list
		elseif text and f.kind == "text" then
			out[f.id] = text
		end
		local filled = out[f.id] ~= nil or (f.kind == "user" and v == "me")
		if not filled and not bad[f.id] and jira.needed(f) then
			bad[f.id] = if f.kind == "other" then "only settable in Jira" else "required"
		end
	end
	return out, users, bad
end

-- Post to Jira: an issue from the task (title, notes, the values of its card's Jira fields)
-- of the target type in the target project and component, which the window then stores as
-- the target; its answer links the task (jira.answer). Fields Jira needs that the task leaves
-- empty or holds wrongly stop it, marked on the card (Jira.missing).
function jira.post(state: State, t: Todo)
	local j = state.jira
	if t.jira or t.id == "" or j.busy["create:" .. t.id] or j.conn ~= "connected" then
		return
	end
	local p, comp, ready = jira.target(state)
	if not p or not ready then
		jira.prefetch(state)
		state.cx:toast("info", if p then "Loading the components of " .. p.name else "Loading the Jira projects", "Post again in a moment.")
		return
	end
	local fields, _, kind = jira.form_fields(state)
	-- Without the create screen (Jira refused it) the issue goes out as before the fields
	-- existed: Jira's default type, title, notes and component.
	if not fields and j.meta_error[p.key] == nil then
		jira.prefetch(state)
		state.cx:toast("info", "Loading the Jira fields of " .. p.name, "Post again in a moment.")
		return
	end
	local title = trim(t.title)
	if title == "" then
		state.cx:toast("warning", "Give the task a title first")
		return
	end
	local q: { [string]: string } = {
		task = t.id,
		project = p.key,
		project_name = p.name,
		component = if comp then comp.id else "",
		component_name = if comp then comp.name else "",
		summary = title,
		description = jira.clip(trim(t.notes), jira.DESCRIPTION_MAX),
	}
	if fields and kind then
		local values, users, bad = jira.payload(t, fields)
		local said: { string } = {}
		j.missing, j.missing_task = {}, t.id
		if j.notes_required[p.key] and trim(t.notes) == "" then
			j.missing.description = true
			table.insert(said, "Description (the task's notes)")
		end
		for _, f in fields do
			local why = bad[f.id]
			if why then
				j.missing[f.id] = true
				table.insert(said, if why == "required" then f.name else f.name .. ": " .. why)
			end
		end
		if #said > 0 then
			state.cx:toast("warning", "Fill in before posting to Jira", table.concat(said, " · "))
			return
		end
		j.missing_task = nil
		q.type, q.type_name = kind.id, kind.name
		if next(values) ~= nil then
			q.fields = tern.json.encode(values)
		end
		if #users > 0 then
			q.users = table.concat(users, ",")
		end
	end
	jira.ask(state, "create", q)
end

-- The answer to create: the new issue's link goes on the task it was made from.
function jira.posted(state: State, data: any, err: string?)
	local j = state.jira
	local task, key = str_or_nil(data.task), str_or_nil(data.key)
	if err or not task or not key then
		state.cx:toast("error", "Could not post the task to Jira", err or "Jira did not say which issue it created.")
		return
	end
	local url = str_or_nil(data.url) or (if j.url then j.url .. "/browse/" .. key else nil)
	local linked = false
	rewrite(state, function(list)
		for _, item in list do
			if type(item) == "table" and item.id == task then
				item.jira = { key = key, url = url }
				item.jira_fields = nil
				linked = true
				return true
			end
		end
		return false
	end)
	-- What the window used: the project, the component (if any) and the issue type.
	local where: { string } = {}
	for _, part in { data.project_name, data.component_name, data.kind } do
		if str_or_nil(part) then
			table.insert(where, part)
		end
	end
	if linked then
		state.cx:toast("success", "Posted to Jira as " .. key, table.concat(where, " · "))
	else
		state.cx:toast("warning", "Created " .. key .. " in Jira", "Its task is no longer in the file.")
	end
	if str_or_nil(data.warning) then
		state.cx:toast("warning", data.warning)
	end
end

-- Opens a linked task's issue: its stored link, else the connected site's.
function jira.open_task_issue(state: State, t: Todo)
	local link = t.jira
	if link and link.url then
		state.cx:open(link.url)
	elseif link then
		jira.open_issue(state, link.key)
	end
end

-- Connect / Save (or Enter in the form): the window checks and stores the connection; an empty
-- token field keeps the stored token.
function jira.connect(state: State)
	local j = state.jira
	if j.busy.connect then
		return
	end
	local url = trim(state.jurl.text)
	if url == "" then
		j.form_error = "Enter your Jira URL, like https://your-company.atlassian.net."
		return
	end
	if j.conn ~= "connected" and trim(state.jtoken.text) == "" then
		j.form_error = "Paste an API token."
		return
	end
	j.form_error = nil
	jira.ask(state, "connect", { url = url, email = trim(state.jemail.text), field = state.jtoken.id or "" })
end

-- The connection form while connected (c, or the account pill); Esc or Cancel closes it.
function jira.edit(state: State, on: boolean)
	local j = state.jira
	j.editing = on and j.conn == "connected"
	j.form_error = nil
	if not on then
		reset_field(state.jtoken, "")
		if jira.field(state, state.focus) then
			set_focus(state, nil)
		end
	end
end

-- An answer of the window's Jira half (see jira.ask). Answers to an older request of the same
-- slot, and the copies a second window sends, are dropped.
function jira.answer(state: State, data: any)
	if type(data) ~= "table" or type(data.op) ~= "string" then
		return
	end
	local j = state.jira
	local op: string = data.op
	local key = str_or_nil(data.key)
	local slot = jira.slot(op, key, str_or_nil(data.task))
	if j.last[slot] == nil or tonumber(data.req) ~= j.last[slot] then
		return
	end
	j.last[slot] = nil
	j.busy[slot] = nil
	local err = str_or_nil(data.error)
	if type(data.status) == "table" then
		jira.apply_status(state, data.status)
	end
	jira.handle(state, op, data, err, key)
	-- Whatever changed, the task card's target may now lack its projects or components.
	jira.prefetch(state)
end

-- What an answer does, by op (see jira.answer).
function jira.handle(state: State, op: string, data: any, err: string?, key: string?)
	local j = state.jira
	if op == "connect" then
		if err then
			j.form_error = err
			return
		end
		jira.edit(state, false)
		state.cx:toast("success", "Connected to Jira", if j.user then "Signed in as " .. j.user else j.url)
		jira.load(state, true)
	elseif op == "forget" then
		if err then
			state.cx:toast("error", "Could not disconnect Jira", err)
			return
		end
		jira.edit(state, false)
		j.projects = nil
		state.cx:toast("info", "Disconnected from Jira", "The token is removed from the keychain")
	elseif op == "status" then
		j.error = err
		-- Blocks ask at start too; the sprint loads once the Tickets tab shows.
		if state.tab == "tickets" then
			jira.load(state, false)
		end
	elseif op == "select" then
		if err then
			j.error = err
		end
	elseif op == "projects" then
		j.list_error = err
		if not err and type(data.projects) == "table" then
			local list: { JiraProject } = {}
			for _, p in data.projects do
				if type(p) == "table" and str_or_nil(p.key) then
					table.insert(list, { key = p.key, name = str_or_nil(p.name) or p.key })
				end
			end
			j.projects = list
		end
	elseif op == "boards" then
		j.list_error = err
		local project = str_or_nil(data.project)
		if err or type(data.boards) ~= "table" or not j.project or project ~= j.project.key then
			return
		end
		local list: { JiraBoard } = {}
		for _, b in data.boards do
			if type(b) == "table" and type(b.id) == "number" then
				table.insert(list, { id = b.id, name = str_or_nil(b.name) or tostring(b.id), kind = str_or_nil(b.kind) })
			end
		end
		j.boards, j.boards_for = list, project
		local wanted = j.want_board
		j.want_board = false
		if not j.board and #list == 1 then
			jira.choose_board(state, list[1])
		elseif not j.board and wanted and #list > 1 and state.tab == "tickets" and not state.pick and not state.focus then
			open_picker(state, "jira_board")
		end
	elseif op == "sprint" then
		if err then
			j.error = err
			return
		end
		if not j.board or tonumber(data.board) ~= j.board.id then
			return
		end
		local sprints: { Sprint } = {}
		for _, s in (if type(data.sprints) == "table" then data.sprints else {}) do
			if type(s) == "table" and type(s.id) == "number" then
				table.insert(sprints, { id = s.id, name = str_or_nil(s.name) or tostring(s.id), ends = str_or_nil(s.ends) })
			end
		end
		local tickets: { Ticket } = {}
		for _, t in (if type(data.tickets) == "table" then data.tickets else {}) do
			if type(t) == "table" and str_or_nil(t.key) then
				table.insert(tickets, {
					key = t.key,
					summary = str_or_nil(t.summary) or t.key,
					status = str_or_nil(t.status) or "Unknown",
					category = str_or_nil(t.category) or "new",
					kind = str_or_nil(t.kind),
					assignee = str_or_nil(t.assignee),
					assignee_id = str_or_nil(t.assignee_id),
					priority = str_or_nil(t.priority),
					description = str_or_nil(t.description),
					details = jira.details_of(t.details),
					sprint = str_or_nil(t.sprint),
				})
			end
		end
		j.sprints, j.tickets, j.loaded_at, j.error = sprints, tickets, os.time(), nil
		j.me = str_or_nil(data.me) or j.me
		if not jira.ticket(state, j.cursor) then
			j.cursor = if tickets[1] then tickets[1].key else nil
		end
	elseif op == "done" and key then
		if err then
			state.cx:toast("error", "Could not close " .. key .. " in Jira", err)
			return
		end
		local status = str_or_nil(data.jira_status) or "Done"
		for _, tk in j.tickets or {} do
			if tk.key == key then
				tk.status, tk.category = status, "done"
			end
		end
		if data.already == true then
			state.cx:toast("info", key .. " is already " .. status .. " in Jira")
		else
			state.cx:toast("success", "Closed " .. key .. " in Jira", "Status: " .. status)
		end
	elseif op == "components" then
		local project = str_or_nil(data.project)
		if not project then
			return
		end
		if err or type(data.components) ~= "table" then
			j.comps_error[project] = err or "Jira sent no components."
		else
			local list: { JiraComponent } = {}
			for _, c in data.components do
				if type(c) == "table" and str_or_nil(c.id) and str_or_nil(c.name) then
					table.insert(list, { id = c.id, name = c.name })
				end
			end
			j.comps[project], j.comps_error[project] = list, nil
		end
	elseif op == "target" then
		if err then
			state.cx:toast("error", "Could not save the Jira project", err)
		end
	elseif op == "create" then
		jira.posted(state, data, err)
	elseif op == "meta" then
		jira.meta_answer(state, data, err)
	end
end

-- A ticket's long text fields as jira.luau sends them ({ name, text }).
function jira.details_of(list: any): { { name: string, text: string } }
	local out: { { name: string, text: string } } = {}
	for _, d in (if type(list) == "table" then list else {}) :: { any } do
		if type(d) == "table" and str_or_nil(d.name) and str_or_nil(d.text) then
			table.insert(out, { name = d.name, text = d.text })
		end
	end
	return out
end

-- The answer to meta: a project's issue types and the fields of one type's create screen.
function jira.meta_answer(state: State, data: any, err: string?)
	local j = state.jira
	local project = str_or_nil(data.project)
	if not project then
		return
	end
	if err then
		j.meta_error[project] = err
		return
	end
	j.meta_error[project] = nil
	local types: { JiraType } = {}
	for _, t in (if type(data.types) == "table" then data.types else {}) :: { any } do
		if type(t) == "table" and str_or_nil(t.id) then
			table.insert(types, { id = t.id, name = str_or_nil(t.name) or t.id })
		end
	end
	j.types[project] = types
	local k = data.type
	if type(k) ~= "table" or not str_or_nil(k.id) then
		return
	end
	local kind: JiraType = { id = k.id, name = str_or_nil(k.name) or k.id }
	if data.default == true then
		j.def_type[project] = kind
	end
	j.notes_required[project] = data.notes_required == true
	local fields: { JiraField } = {}
	for _, f in (if type(data.fields) == "table" then data.fields else {}) :: { any } do
		if type(f) == "table" and str_or_nil(f.id) and str_or_nil(f.kind) then
			local choices: { JiraChoice } = {}
			for _, c in (if type(f.choices) == "table" then f.choices else {}) :: { any } do
				if type(c) == "table" and str_or_nil(c.id) and str_or_nil(c.name) then
					table.insert(choices, { id = c.id, name = c.name })
				end
			end
			table.insert(fields, {
				id = f.id,
				name = str_or_nil(f.name) or f.id,
				required = f.required == true,
				default = f.default == true,
				default_name = str_or_nil(f.default_name),
				kind = f.kind,
				multi = f.multi == true,
				multiline = f.multiline == true,
				choices = choices,
			})
		end
	end
	j.fields[project .. ":" .. kind.id] = fields
end

-- Popovers -----------------------------------------------------------------

type PickItem = {
	kind: string, -- "none" (the default/clear row), "opt", "dir" or "complete"
	path: string?, -- the value the row stores (a directory, model selector, level, ...)
	name: string,
	hint: string?,
	group: string?,
	current: boolean,
}

local function pick_base(state: State): string
	local t = selected(state)
	return (t and t.links.cwd) or state.cx.cwd or home_dir()
end

-- Directory to list for the typed path and the name prefix to filter by.
local function listing_target(text: string, base: string): (string, string)
	local full = expand(text, base)
	if string.sub(text, -1) == "/" or text == "~" or text == "." or text == ".." then
		return full, ""
	end
	return normalize(full .. "/.."), basename(full)
end

-- The typed text up to and including the last "/", where a completion goes.
local function completion_base(text: string): string
	if string.sub(text, -1) == "/" then
		return text
	elseif text == "~" or text == "." or text == ".." then
		return text .. "/"
	end
	return string.match(text, "^(.*/)") or ""
end

local function is_dir(p: string): boolean
	return (pcall(tern.fs.list, p))
end

-- Starts `ls` for the typed path's directory unless that listing is cached or in flight.
local function request_listing(state: State)
	local pk = state.pick
	if not pk or pk.kind ~= "project" then
		return
	end
	if not is_path_text(pk.q.text) then
		pk.want = nil
		return
	end
	local dir = listing_target(pk.q.text, pick_base(state))
	if pk.dir == dir or pk.want == dir then
		return
	end
	pk.want = dir
	tern.process.run({ "/bin/ls", "-1ALp", dir }, { timeout_ms = 3000 }, function(result: ProcessResult, _)
		local cur = state.pick
		if not cur or cur.want ~= dir then
			return
		end
		cur.want = nil
		local names: { string } = {}
		for line in string.gmatch(result.stdout, "[^\n]+") do
			if string.sub(line, -1) == "/" and line ~= ".git/" then
				table.insert(names, string.sub(line, 1, -2))
			end
		end
		table.sort(names, function(a, b)
			return string.lower(a) < string.lower(b)
		end)
		cur.dir = dir
		cur.names = names
		cur.missing = result.status ~= 0 and result.stdout == ""
		state.cx:render()
	end)
end

local function contains(haystack: string, filter: string): boolean
	return string.find(string.lower(haystack), filter, 1, true) ~= nil
end

local function project_items(state: State, pk: Pick, t: Todo): ({ PickItem }, string?)
	local items: { PickItem } = {}
	local current = t.links.cwd
	if is_path_text(pk.q.text) then
		local dir, prefix = listing_target(pk.q.text, pick_base(state))
		if pk.dir ~= dir then
			return items, "Loading…"
		end
		if pk.missing then
			return items, "No such directory"
		end
		local lowered = string.lower(prefix)
		for _, name in pk.names do
			if string.sub(string.lower(name), 1, #lowered) == lowered then
				local full = if dir == "/" then "/" .. name else dir .. "/" .. name
				table.insert(items, { kind = "complete", path = full, name = name, current = full == current })
			end
		end
		return items, if #items == 0 then "No sub-directories" else nil
	end
	local filter = string.lower(pk.q.text)
	if filter == "" then
		table.insert(items, { kind = "none", name = "No project", current = current == nil })
	end
	local seen: { [string]: boolean } = {}
	local function add(path: string, group: string)
		path = if path == "/" then path else string.gsub(path, "/+$", "")
		if seen[path] then
			return
		end
		seen[path] = true
		local name = basename(path)
		if filter ~= "" and not contains(name, filter) and not contains(path, filter) then
			return
		end
		table.insert(items, {
			kind = "dir",
			path = path,
			name = name,
			hint = abbreviate(normalize(path .. "/..")),
			group = group,
			current = path == current,
		})
	end
	for _, p in tern.pane.list() do
		if p.cwd and p.cwd ~= "" then
			add(p.cwd, "Open panes")
		end
	end
	for _, other in state.todos do
		if other.links.cwd then
			add(other.links.cwd, "Used in tasks")
		end
	end
	return items, if #items == 0 then "No matching projects" else nil
end

-- What a Jira field shows while the task leaves it empty: Jira's default, else nobody/none.
function jira.empty_label(f: JiraField): string
	if f.default then
		return if f.default_name then "Default: " .. f.default_name else "Default"
	end
	return if f.kind == "user" then "Nobody" else "None"
end

-- Whether the task's value `v` of a choice field holds the choice `id` (one or a list).
function jira.has_choice(v: any, id: string): boolean
	if type(v) ~= "table" then
		return false
	end
	if v.id ~= nil then
		return v.id == id
	end
	for _, c in v do
		if type(c) == "table" and c.id == id then
			return true
		end
	end
	return false
end

-- The text of a choice or user field's pill: the task's value, else jira.empty_label.
function jira.value_label(f: JiraField, v: any): string
	if v == "me" then
		return "Me"
	elseif type(v) == "table" and v.id ~= nil then
		return str_or_nil(v.name) or tostring(v.id)
	elseif type(v) == "table" then
		local names: { string } = {}
		for _, c in v do
			if type(c) == "table" then
				table.insert(names, str_or_nil(c.name) or tostring(c.id))
			end
		end
		if #names > 0 then
			return table.concat(names, ", ")
		end
	end
	return jira.empty_label(f)
end

-- Rows of the card's issue type popover, and of the choice popover of a Jira field
-- (Jira.pick_field): Jira's allowed values, or you for a user field. The none row clears it.
function jira.field_items(state: State, pk: Pick): ({ PickItem }, string?)
	local j = state.jira
	local filter = string.lower(pk.q.text)
	local items: { PickItem } = {}
	local p = jira.target(state)
	if not p then
		return items, "Pick a Jira project first"
	end
	if pk.kind == "jira_type" then
		local list = j.types[p.key]
		if not list then
			return items, if j.busy.meta then "Loading issue types…" else (j.meta_error[p.key] or "No issue types")
		end
		local current = jira.kind(state, p)
		for _, t in list do
			if filter == "" or contains(t.name, filter) then
				table.insert(items, { kind = "opt", path = t.id, name = t.name, current = current ~= nil and current.id == t.id })
			end
		end
		return items, if #items == 0 then "No matching issue types" else nil
	end
	local f = jira.spec(state, j.pick_field)
	local t = selected(state)
	if not f or not t then
		return items, "Jira no longer has this field"
	end
	local v = if t.jira_fields then t.jira_fields[f.id] else nil
	if filter == "" then
		table.insert(items, { kind = "none", name = jira.empty_label(f), current = v == nil })
	end
	if f.kind == "user" then
		if filter == "" or contains("me", filter) or (j.user ~= nil and contains(j.user, filter)) then
			table.insert(items, { kind = "opt", path = "me", name = "Me", hint = j.user, current = v == "me" })
		end
		return items, nil
	end
	for _, c in f.choices do
		if filter == "" or contains(c.name, filter) then
			table.insert(items, { kind = "opt", path = c.id, name = c.name, current = jira.has_choice(v, c.id) })
		end
	end
	return items, if #items > 1 or (filter ~= "" and #items > 0) then nil elseif #f.choices == 0 then "Jira offers no values" else "No matching values"
end

-- Rows of the Jira popovers: the Tickets tab's project and board, and the task card's target
-- project, component, issue type and field values (none needs a task).
function jira.pick_items(state: State, pk: Pick): ({ PickItem }, string?)
	local j = state.jira
	local filter = string.lower(pk.q.text)
	local items: { PickItem } = {}
	if pk.kind == "jira_type" or pk.kind == "jira_field" then
		return jira.field_items(state, pk)
	end
	if pk.kind == "jira_group" then
		local hints: { [string]: string } = {
			assignee = "You first, then by name",
			status = "To do, in progress, done",
			none = "Jira's order",
		}
		for _, g in jira.GROUPS do
			table.insert(items, { kind = "opt", path = g, name = jira.GROUP_LABEL[g], hint = hints[g], current = j.view.group == g })
		end
		return items, nil
	end
	if pk.kind == "jira_project" or pk.kind == "jira_target" then
		if not j.projects then
			return items, if j.busy.projects then "Loading projects…" else (j.list_error or "No projects")
		end
		local current = if pk.kind == "jira_target" then jira.target(state) else j.project
		for _, p in j.projects do
			if filter == "" or contains(p.name, filter) or contains(p.key, filter) then
				table.insert(items, {
					kind = "opt",
					path = p.key,
					name = p.name,
					hint = p.key,
					current = current ~= nil and current.key == p.key,
				})
			end
		end
		return items, if #items == 0 then "No matching projects" else nil
	end
	if pk.kind == "jira_component" then
		local p, comp, ready = jira.target(state)
		if not p then
			return items, "Pick a Jira project first"
		end
		if filter == "" then
			table.insert(items, { kind = "none", name = "No component", hint = p.name, current = ready and comp == nil })
		end
		local list = j.comps[p.key]
		if not list then
			return items, if j.busy.components then "Loading components…" else (j.comps_error[p.key] or "No components")
		end
		for _, c in list do
			if filter == "" or contains(c.name, filter) then
				table.insert(items, { kind = "opt", path = c.id, name = c.name, current = comp ~= nil and comp.id == c.id })
			end
		end
		return items, if #items == 0 then "No matching components" else nil
	end
	local boards = if j.project and j.boards_for == j.project.key then j.boards else nil
	if not boards then
		return items, if j.busy.boards then "Loading boards…" else (j.list_error or "No boards")
	end
	for _, b in boards do
		if filter == "" or contains(b.name, filter) then
			table.insert(items, {
				kind = "opt",
				path = tostring(b.id),
				name = b.name,
				hint = b.kind,
				current = j.board ~= nil and j.board.id == b.id,
			})
		end
	end
	return items, if #items > 0 then nil elseif #boards == 0 then "This project has no boards" else "No matching boards"
end

-- Rows of the open popover and a status line shown when there are none.
local function picker_items(state: State): ({ PickItem }, string?)
	local pk = state.pick
	local items: { PickItem } = {}
	if pk and jira.KINDS[pk.kind] then
		return jira.pick_items(state, pk)
	end
	local t = selected(state)
	if not pk or not t then
		return items, nil, 0
	end
	local filter = string.lower(pk.q.text)
	local status: string? = nil
	if pk.kind == "project" then
		return project_items(state, pk, t)
	elseif pk.kind == "model" then
		if filter == "" then
			table.insert(items, { kind = "none", name = "Default model", current = t.agent.model == nil })
		end
		if not state.models then
			status = if state.models_state == "error" then state.models_error else "Loading models…"
		else
			for _, m in state.models do
				if filter == "" or contains(m.selector, filter) then
					table.insert(items, {
						kind = "opt",
						path = m.selector,
						name = m.selector,
						hint = m.context,
						current = m.selector == t.agent.model,
					})
				end
			end
			if #items == 0 then
				status = "No matching models"
			end
		end
	elseif pk.kind == "chat" then
		if filter == "" then
			table.insert(items, { kind = "none", name = "New chat", current = t.links.omp_session == nil })
		end
		local chats = state.chats
		if not chats then
			status = if state.chats_loading then "Loading chats…" else "No chats found"
		else
			local base = t.links.cwd
			local matched = 0
			for pass = 1, 2 do
				for _, c in chats do
					if (pass == 1) == (base ~= nil and c.cwd == base) then
						if filter == "" or contains(c.title, filter) or contains(c.cwd, filter) then
							matched += 1
							table.insert(items, {
								kind = "opt",
								path = c.id,
								name = c.title,
								hint = basename(c.cwd),
								group = "Recent chats",
								current = c.id == t.links.omp_session,
							})
						end
					end
				end
			end
			if matched == 0 then
				status = if state.chats_loading then "Loading chats…" else "No matching chats"
			end
		end
	end
	return items, status
end

local function close_picker(state: State)
	state.pick = nil
	set_focus(state, if state.fresh then "add" else nil)
end

open_settings = function(state: State)
	state.pick = nil
	state.settings_sel = 1
	if state.focus then
		set_focus(state, nil)
	end
	state.lift = nil
	clear_confirm(state)
	refresh_cfg(state)
	state.settings_open = true
end

open_picker = function(state: State, kind: string)
	local is_jira = jira.KINDS[kind] == true
	local t = selected(state)
	if not t and not is_jira then
		return
	end
	if not is_jira then
		state.detail_open = true
	end
	state.pick = {
		kind = kind,
		task = if t then t.id else "",
		q = new_field("", false, nil),
		sel = 0,
		dir = nil,
		names = {},
		missing = false,
		want = nil,
		hint = nil,
	}
	local j = state.jira
	if kind == "model" then
		load_models(state)
	elseif kind == "chat" and t then
		scan_chats(state, t.links.cwd)
	elseif (kind == "jira_project" or kind == "jira_target") and not j.busy.projects then
		j.list_error = nil
		jira.ask(state, "projects", nil)
	elseif kind == "jira_board" and j.project and not j.busy.boards and j.boards_for ~= j.project.key then
		j.list_error = nil
		jira.ask(state, "boards", { project = j.project.key })
	elseif kind == "jira_component" then
		-- Asked again on every open, so components added in Jira since show up.
		local p = jira.target(state)
		if p and not j.busy.components then
			j.comps_error[p.key] = nil
			jira.ask(state, "components", { project = p.key })
		end
	elseif kind == "jira_type" then
		jira.prefetch(state)
	end
	local initial = picker_items(state)
	for i, it in initial do
		if it.current then
			state.pick.sel = i
			break
		end
	end
	set_focus(state, "picker")
end

-- A pick in a Jira popover. A multi-choice field's popover stays open: each pick adds or
-- removes one value; its none row clears them all.
function jira.apply_pick(state: State, kind: string, value: string?)
	local j = state.jira
	local t = selected(state)
	local f = if kind == "jira_field" then jira.spec(state, j.pick_field) else nil
	if f and t and f.multi and value then
		local held = if t.jira_fields then t.jira_fields[f.id] else nil
		local list: { any } = {}
		local had = false
		for _, c in (if type(held) == "table" and held.id == nil then held else {}) :: { any } do
			if type(c) == "table" and c.id == value then
				had = true
			elseif type(c) == "table" then
				table.insert(list, c)
			end
		end
		for _, c in (if had then {} else f.choices) :: { JiraChoice } do
			if c.id == value then
				table.insert(list, { id = c.id, name = c.name })
			end
		end
		jira.set_value(state, t.id, f.id, if #list > 0 then list else nil)
		return
	end
	close_picker(state)
	if kind == "jira_field" then
		if not f or not t then
			return
		end
		local chosen: any = nil
		for _, c in f.choices do
			if c.id == value then
				chosen = { id = c.id, name = c.name }
			end
		end
		jira.set_value(state, t.id, f.id, if f.kind == "user" and value == "me" then "me" else chosen)
	elseif kind == "jira_type" then
		local p = jira.target(state)
		local offered: { JiraType } = (if p then j.types[p.key] else nil) or {}
		for _, kt in offered do
			if p and kt.id == value then
				jira.choose_type(state, p, kt)
			end
		end
	elseif kind == "jira_group" then
		jira.set_view(state, nil, value)
	elseif kind == "jira_project" then
		for _, p in j.projects or {} do
			if p.key == value then
				jira.choose_project(state, p)
			end
		end
	elseif kind == "jira_board" then
		for _, b in j.boards or {} do
			if tostring(b.id) == value then
				jira.choose_board(state, b)
			end
		end
	elseif kind == "jira_target" then
		for _, p in j.projects or {} do
			if p.key == value then
				jira.choose_target(state, p, nil)
			end
		end
	elseif kind == "jira_component" then
		local p = jira.target(state)
		if p then
			jira.choose_target(state, p, value or false)
		end
	end
end

-- Stores the picked value (nil = the default/cleared value), writes the file and closes the popover.
local function apply_pick(state: State, kind: string, value: string?)
	local pk = state.pick
	if pk and jira.KINDS[kind] then
		jira.apply_pick(state, kind, value)
		return
	end
	close_picker(state)
	if not pk then
		return
	end
	if kind == "project" then
		pcall(tern.kv.set, LAST_PROJECT_KEY, value or "")
	end
	patch(state, pk.task, function(item)
		local null = tern.json.null
		if kind == "project" or kind == "chat" then
			local links = if type(item.links) == "table" then item.links else {}
			links[if kind == "project" then "cwd" else "omp_session"] = if value then value else null
			item.links = links
		elseif kind == "priority" then
			item.priority = value or "none"
		else
			local agent = if type(item.agent) == "table" then item.agent else {}
			agent[if kind == "model" then "model" else "thinking"] = if value then value else null
			item.agent = agent
		end
	end)
end

local function picker_key(state: State, key: Key): boolean
	local pk = state.pick
	if not pk then
		set_focus(state, nil)
		return true
	end
	local items = picker_items(state)
	local name = key.name
	local searchable = SEARCH[pk.kind] ~= nil
	if name == "escape" then
		close_picker(state)
	elseif name == "up" or name == "down" or name == "page_up" or name == "page_down" or name == "home" or name == "end" then
		local step = if name == "up" then -1 elseif name == "down" then 1 elseif name == "page_up" then -PAGE_ROWS else PAGE_ROWS
		if name == "home" then
			pk.sel = math.min(1, #items)
		elseif name == "end" then
			pk.sel = #items
		else
			pk.sel = math.clamp(pk.sel + step, if name == "up" then 0 else math.min(1, #items), #items)
		end
		pk.hint = nil
	elseif name == "tab" then
		local it = items[if pk.sel > 0 then pk.sel else 1]
		if pk.kind == "project" and is_path_text(pk.q.text) and it and it.kind == "complete" then
			reset_field(pk.q, completion_base(pk.q.text) .. it.name .. "/")
			pk.sel = 0
			pk.hint = nil
			request_listing(state)
		end
	elseif name == "enter" then
		local it = items[pk.sel]
		local typed_path = pk.kind == "project" and is_path_text(pk.q.text)
		if not it and searchable and not typed_path then
			for _, candidate in items do
				if candidate.kind ~= "none" then
					it = candidate
					break
				end
			end
		end
		if it then
			apply_pick(state, pk.kind, if it.kind == "none" then nil else it.path)
		elseif typed_path then
			local target = expand(pk.q.text, pick_base(state))
			if is_dir(target) then
				apply_pick(state, "project", target)
			else
				pk.hint = "Not a directory"
			end
		end
	elseif searchable then
		local what = edit_key(pk.q, key, state.cx)
		if what == nil then
			return false
		end
		if what == "text" then
			pk.sel = 0
			pk.hint = nil
		end
		request_listing(state)
	end
	return true
end

local function field_key(state: State, key: Key): boolean
	if state.focus == "picker" then
		return picker_key(state, key)
	end
	if state.focus == "add" then
		local what = edit_key(state.add, key, state.cx)
		if what == nil then
			return false
		elseif what == "blur" then
			local discard = state.fresh ~= nil
			set_focus(state, nil)
			if discard then
				reset_field(state.add, "")
			end
		elseif what == "submit" then
			card.add(state)
		elseif what == "text" then
			sync_fresh_title(state)
		end
		return true
	end
	if state.focus == "jx" then
		local what = edit_key(state.jx, key, state.cx)
		if what == nil then
			return false
		elseif key.name == "escape" then
			jira.save_text(state, "cancel")
		end
		if what == "blur" or what == "submit" then
			-- A new task's Jira field hands back to its add row, as its notes do.
			set_focus(state, if state.fresh then "add" else nil)
		elseif what == "text" then
			jira.save_text(state, "live")
		end
		return true
	end
	local jf = jira.field(state, state.focus)
	if jf then
		local what = edit_key(jf, key, state.cx)
		if what == nil then
			return false
		elseif what == "submit" then
			jira.connect(state)
		elseif what == "blur" and key.name == "tab" then
			-- Tab and Shift+Tab walk the form's three fields.
			local order = { "jurl", "jemail", "jtoken" }
			local at = table.find(order, state.focus) or 1
			set_focus(state, order[(at - 1 + (if key.shift then -1 else 1)) % #order + 1])
		elseif what == "blur" then
			set_focus(state, nil)
		elseif what == "text" then
			state.jira.form_error = nil
		end
		return true
	end
	if not selected(state) then
		set_focus(state, nil)
		return true
	end
	local f = if state.focus == "title" then state.title else state.notes
	local what = edit_key(f, key, state.cx)
	if what == nil then
		return false
	elseif key.name == "escape" then
		clear_confirm(state)
		local name = state.focus :: string
		save_field(state, f, name, "cancel")
		f.task = nil
		-- A new task's notes hand back to its add row, where Enter adds it.
		set_focus(state, if state.fresh then "add" else nil)
	elseif what == "blur" or what == "submit" then
		set_focus(state, if state.fresh then "add" else nil)
	elseif what == "text" then
		field_changed(state)
		if state.focus == "notes" and key.name == "enter" and not key.shift then
			save_field(state, f, "notes", "commit")
			f.conflict = false
		end
	end
	return true
end

-- View ------------------------------------------------------------------

local function el(tag: string, role: string, key: string, props: { [string]: any }?, children: { Node }?): Node
	local p: { [string]: any } = props or {}
	p.role = ROLE .. role
	p.key = key
	return ui.el(tag, p, children)
end

local FIELD_IDS = {
	field = "main.ws.left.add.field",
	notes = "main.ws.detail.notes",
	title = "main.ws.detail.head.title",
	q = "layer.q",
	jurl = "main.ws.jform.jurl",
	jemail = "main.ws.jform.jemail",
	jtoken = "main.ws.jform.jtoken",
}

-- A text field node whose text, caret and selection come from `f` while it is being
-- edited, else from `idle` with the caret at its end.
local function field_node(kind: string, props: { [string]: any }, f: Field?, idle: string): Node
	if f then
		f.id = FIELD_IDS[props.key] .. "_" .. f.rev
		props.key ..= "_" .. f.rev
		props.text = f.text
		props.cursor = utf16_offset(f.text, f.cur)
		if f.anchor and f.anchor ~= f.cur then
			props.anchor = utf16_offset(f.text, f.anchor)
		end
	else
		props.text = idle
		props.cursor = utf16_offset(idle, math.huge)
	end
	return ui.node(kind, props)
end

local function open_count(state: State): number
	local want = state.tab == "backlog"
	local open = 0
	for _, t in state.todos do
		if not t.done and not t.archived and in_backlog(t) == want then
			open += 1
		end
	end
	return open
end

local function tab_count(state: State): number
	local want = state.tab == "backlog"
	local n = 0
	for _, t in state.todos do
		if not t.archived and in_backlog(t) == want then
			n += 1
		end
	end
	return n
end

local function backlog_count(state: State): number
	local n = 0
	for _, t in state.todos do
		if in_backlog(t) then
			n += 1
		end
	end
	return n
end

local function archived_count(state: State): number
	local n = 0
	for _, t in state.todos do
		if t.archived then
			n += 1
		end
	end
	return n
end

local function badges(t: Todo, live: { [number]: boolean }): { Node }
	local out: { Node } = {}
	if t.priority ~= "none" then
		table.insert(out, el("span", "badge", "prio", { text = PRIORITY_LABEL[t.priority], tone = PRIORITY_TONE[t.priority] }))
	end
	local pane = t.links.tern_pane
	if pane and live[pane] == true then
		table.insert(out, el("span", "badge", "pane", { text = "pane", tone = "success" }))
	end
	if t.links.omp_session then
		table.insert(out, el("span", "badge", "omp", { text = "omp", tone = "accent" }))
	end
	if t.jira then
		table.insert(out, el("span", "badge", "jira", { text = t.jira.key, attrs = { ["data-kind"] = "jira" } }))
	end
	return out
end

local function row_view(state: State, t: Todo, live: { [number]: boolean }, lifted: Todo?, pos: { [string]: number }): Node
	local picked = t.id == state.cursor
	local kind = status_of(state, t, live)
	local glyph = el("button", "check", "check", {
		attrs = { ["data-status"] = kind },
		aria = STATUS_LABEL[kind] or (if t.done then "Mark as not done" else "Mark as done"),
		actions = { click = "glyph=" .. t.id, dblclick = "tap=" .. t.id },
	})
	local text: { Node } = { el("div", "title", "title", { text = t.title }) }
	-- Status line and badges share one wrapping line under the title, so nothing can
	-- overflow the row however narrow the block is.
	local meta: { Node } = {}
	local line = if state.cfg.status_line then agent_line(state, t, kind) else nil
	if line then
		table.insert(meta, el("div", "agent-line", "line", { text = line, attrs = { ["data-kind"] = kind } }))
	end
	if state.cfg.badges then
		for _, badge in badges(t, live) do
			table.insert(meta, badge)
		end
	end
	if #meta > 0 then
		table.insert(text, el("div", "meta", "meta", nil, meta))
	end
	-- While a task is picked up: it carries the accent bar (mark = pick); rows of its own group
	-- show a drop line above (they sit earlier) or below (later) on hover; rows of another
	-- group are dimmed (mark = drop) because a drop there only moves it to its group's edge.
	local drop = "off"
	local mark: string? = nil
	local tip: string? = nil
	if lifted then
		if t.id == lifted.id then
			mark = "pick"
			tip = "Click to put it down where it was"
		elseif group_of(t) == group_of(lifted) then
			drop = if (pos[t.id] or 0) < (pos[lifted.id] or 0) then "before" else "after"
			tip = "Move here"
		else
			drop = "edge"
			mark = "drop"
			tip = if group_of(t) > group_of(lifted) then "Move to the end of its group" else "Move to the start of its group"
		end
	end
	local grip = el("button", "grip", "grip", {
		aria = "Move",
		title = if lifted and t.id == lifted.id then "Cancel move" else "Pick up to move, then click where it goes",
		attrs = { ["data-active"] = if lifted and t.id == lifted.id then "true" else "false" },
		actions = { click = "lift=" .. t.id, dblclick = "tap=" .. t.id },
	})
	local multi = state.sel[t.id] == true
	local kids: { Node } = { glyph, el("div", "rowtext", "text", nil, text) }
	if multi then
		table.insert(kids, el("span", "tick", "tick"))
	end
	-- Time and row actions share a fixed box. Hover, confirmation or pick-up swaps them.
	local armed = state.confirm == t.id
	local label: string?, abs: string? = nil, nil
	if state.cfg.time and kind ~= "running" then
		label, abs = stamp_label(state, t)
	end
	local slot: { Node } = {}
	if label then
		table.insert(slot, el("span", "time", "time", { text = label, title = abs }))
	end
	local actions: { Node } = {}
	if state.cfg.row_actions then
		if not t.archived then
			table.insert(actions, el("button", "hbtn", "r-done", {
				aria = if t.done then "Mark as not done" else "Mark as done",
				title = if t.done then "Mark as not done" else "Mark as done",
				attrs = { ["data-kind"] = if t.done then "undone" else "done", ["data-row"] = "true" },
				actions = { click = "rdone=" .. t.id, dblclick = "tap=" .. t.id },
			}))
			table.insert(actions, el("button", "hbtn", "r-backlog", {
				aria = if t.backlog then "Back to tasks" else "Move to backlog",
				title = if t.backlog then "Back to tasks" else "Move to backlog",
				attrs = { ["data-kind"] = if t.backlog then "unbacklog" else "backlog", ["data-row"] = "true" },
				actions = { click = "rback=" .. t.id, dblclick = "tap=" .. t.id },
			}))
		end
		table.insert(actions, el("button", "hbtn", "r-archive", {
			aria = if t.archived then "Restore" else "Archive",
			title = if t.archived then "Restore" else "Archive",
			attrs = { ["data-kind"] = if t.archived then "restore" else "archive", ["data-row"] = "true" },
			actions = { click = "rarch=" .. t.id, dblclick = "tap=" .. t.id },
		}))
	end
	-- Keyboard deletion still needs a visible second-press confirmation when icons are off.
	if state.cfg.row_actions or armed then
		table.insert(actions, el("button", "hbtn", "r-delete", {
			text = if armed then "Delete?" else nil,
			aria = if armed then "Click again to delete permanently" else "Delete",
			title = if armed then "Click again to delete permanently" else "Delete",
			attrs = { ["data-kind"] = "delete", ["data-row"] = "true", ["data-confirm"] = if armed then "true" else "false" },
			actions = { click = "rdel=" .. t.id, dblclick = "tap=" .. t.id },
		}))
	end
	table.insert(actions, grip)
	table.insert(slot, el("div", "row-actions", "actions", nil, actions))
	table.insert(kids, el("div", "slot", "slot", {
		attrs = {
			["data-time"] = if label then "true" else "false",
			["data-actions"] = if state.cfg.row_actions or armed then "true" else "false",
			["data-active"] = if armed or (lifted and t.id == lifted.id) then "true" else "false",
		},
	}, slot))
	return el("div", "row", t.id, {
		attrs = {
			["data-state"] = if picked then "selected" else "idle",
			["data-multi"] = if multi then "true" else "false",
			["data-done"] = if t.done then "true" else "false",
			["data-archived"] = if t.archived then "true" else "false",
			["data-drop"] = drop,
		},
		mark = mark,
		title = tip,
		actions = { click = "sel=" .. t.id, dblclick = "open=" .. t.id },
	}, kids)
end

local function done_count(state: State): number
	local want = state.tab == "backlog"
	local n = 0
	for _, t in state.todos do
		if t.done and not t.archived and in_backlog(t) == want then
			n += 1
		end
	end
	return n
end

local function gear_button(): Node
	return el("button", "gear", "gear", {
		aria = "Settings",
		title = "Settings",
		actions = { click = "settings" },
	})
end

-- How many sprint tickets pass the "only mine" filter (all of them while it is off).
function jira.count(state: State): number
	local n = 0
	for _, tk in state.jira.tickets or {} do
		if not state.jira.view.mine or jira.is_mine(state, tk) then
			n += 1
		end
	end
	return n
end

-- Tasks · Backlog · Jira tickets: the tab strip of every tab.
function jira.tabs(state: State): Node
	local function tab(id: string, text: string): Node
		return el("button", "tabbtn", "tab-" .. id, {
			text = text,
			attrs = { ["data-active"] = if state.tab == id then "true" else "false" },
			actions = { click = "tab=" .. id },
		})
	end
	local tickets = state.jira.tickets
	return el("div", "tabs", "tabs", nil, {
		tab("tasks", "Tasks"),
		tab("backlog", "Backlog (" .. backlog_count(state) .. ")"),
		tab("tickets", if tickets then "Jira tickets (" .. jira.count(state) .. ")" else "Jira tickets"),
	})
end

local function left_view(state: State): Node
	local open = open_count(state)
	local archived = archived_count(state)
	local in_tab = tab_count(state)
	local backlog_tab = state.tab == "backlog"
	local subtitle = if in_tab == 0
		then (if backlog_tab then "Backlog is empty" elseif archived > 0 then "All archived" else "No tasks yet")
		elseif open > 0 then open .. " open"
		else "All done"
	local picked_n = #multi_ids(state)
	if picked_n >= 2 then
		subtitle ..= " · " .. picked_n .. " selected"
	end
	local tabs = jira.tabs(state)
	local head = el("div", "head", "head", nil, {
		el("div", "heading", "heading", { text = if backlog_tab then "Backlog" else "Tasks" }),
		el("div", "subtitle", "subtitle", { text = subtitle }),
		tabs,
	})
	local input = field_node("input", {
		key = "field",
		role = ROLE .. "input",
		placeholder = "Add a task",
	}, state.add, "")
	local add = el("div", "add", "add", nil, {
		el("span", "add-circle", "circle"),
		input,
	})
	local live = live_panes()
	local pos: { [string]: number } = {}
	for i, t in ordered(state.todos, state.tab, true, true) do
		pos[t.id] = i
	end
	local lifted: Todo? = nil
	for _, t in state.todos do
		if t.id == state.lift then
			lifted = t
		end
	end
	local rows: { Node } = {}
	for _, t in ordered(state.todos, state.tab, false, not state.cfg.done_group) do
		table.insert(rows, row_view(state, t, live, lifted, pos))
	end
	local done_n = done_count(state)
	if state.cfg.done_group and done_n > 0 then
		table.insert(rows, el("button", "arch-head", "donehead", {
			text = "Done (" .. done_n .. ")",
			attrs = { ["data-open"] = if state.done_open then "true" else "false" },
			actions = { click = "donehead" },
		}))
		if state.done_open then
			for _, t in state.todos do
				if t.done and not t.archived and in_backlog(t) == (state.tab == "backlog") then
					table.insert(rows, row_view(state, t, live, lifted, pos))
				end
			end
		end
	end
	if archived > 0 and state.tab == "tasks" and state.cfg.archived then
		table.insert(rows, el("button", "arch-head", "arch", {
			text = "Archived (" .. archived .. ")",
			attrs = { ["data-open"] = if state.arch_open then "true" else "false" },
			actions = { click = "arch" },
		}))
		if state.arch_open then
			for _, t in state.todos do
				if t.archived then
					table.insert(rows, row_view(state, t, live, lifted, pos))
				end
			end
		end
	end
	return el("div", "left", "left", nil, {
		head,
		add,
		el("div", "rows", "rows", { attrs = { ["data-lift"] = if lifted then "on" else "off" } }, rows),
	})
end

-- The popover is Tern's own picker sheet (the one omp's model and session pickers use): it
-- sits in the block's layer, centred and sized to the block, so it cannot be clipped at the
-- block's edges, and it virtualizes and scrolls its rows itself (wheel included).
local PICK_TITLE: { [string]: string } = {
	project = "Project",
	model = "Model",
	chat = "Chat",
	jira_project = "Jira",
	jira_board = "Board",
	jira_target = "Jira",
	jira_component = "Jira",
	jira_type = "Issue type",
	jira_field = "Jira",
	jira_group = "Group tickets by",
}
local PICK_NOUN: { [string]: string } = {
	project = "projects",
	model = "models",
	chat = "chats",
	jira_project = "projects",
	jira_board = "boards",
	jira_target = "projects",
	jira_component = "components",
	jira_type = "issue types",
	jira_field = "values",
	jira_group = "groupings",
}

local function picker_node(state: State): Node?
	local pk = state.pick
	if not pk then
		return nil
	end
	local list, status = picker_items(state)
	local items: { any } = {}
	local order: { any } = {}
	local current: { string } = {}
	local group: string? = nil
	for i, it in list do
		if it.kind ~= "none" and it.group and it.group ~= group then
			group = it.group
			table.insert(order, { group = it.group, label = it.group })
		end
		local id = "i" .. i
		table.insert(items, {
			id = id,
			label = if it.kind == "complete" then it.name .. "/" else it.name,
			detail = it.hint,
			mono = pk.kind == "model" and it.kind == "opt",
		})
		table.insert(order, id)
		if it.current then
			table.insert(current, id)
		end
	end
	-- The count reads "shown of total" only while filtering; unfiltered lists also hold the
	-- default/clear row, which is not part of the catalog.
	local total: number? = nil
	if pk.q.text ~= "" and pk.kind == "model" and state.models then
		total = #state.models
	elseif pk.q.text ~= "" and pk.kind == "chat" and state.chats then
		total = #state.chats
	end
	local failure = pk.hint or (if pk.kind == "model" and state.models_state == "error" then state.models_error else nil)
	local props: { [string]: any } = {
		key = "pick",
		role = ROLE .. "pick",
		size = "md",
		-- A Jira field's popover is titled by the field.
		title = if pk.kind == "jira_field" then (jira.spec(state, state.jira.pick_field) or { name = "Jira" }).name else PICK_TITLE[pk.kind],
		noun = PICK_NOUN[pk.kind],
		placeholder = SEARCH[pk.kind],
		query = pk.q.text,
		cursor = utf16_offset(pk.q.text, pk.q.cur),
		-- The search line is a native input in the layer (see pick_input); this one is hidden.
		items = items,
		order = order,
		current = current,
		selected = if pk.sel > 0 then "i" .. pk.sel else nil,
		total = total,
		empty = status,
		actions = {
			{ id = "pick-close", label = "Cancel", keys = { "esc" } },
			{ id = "pick-use", label = "Choose", keys = { "enter" }, primary = true },
		},
	}
	if failure then
		props.state = "error"
		props.message = failure
	elseif status and string.sub(status, 1, 7) == "Loading" then
		props.state = "loading"
	end
	return ui.node("picker", props)
end

-- The picker sheet draws its search line but cannot edit or select in it, so the layer
-- carries a native input placed over that line (styles.css); all three popovers search.
local function pick_input(state: State): Node
	local pk = state.pick :: Pick
	return field_node("input", {
		key = "q",
		role = ROLE .. "pickq",
		placeholder = SEARCH[pk.kind],
		aria = "Search",
	}, pk.q, "")
end

-- A pill button that opens the `kind` popover.
local function pill_box(state: State, kind: string, key: string, text: string, tone: string?, icon: string?): Node
	local open = state.pick ~= nil and state.pick.kind == kind
	return el("button", "pillbtn", key, {
		text = text,
		tone = tone,
		attrs = { ["data-icon"] = icon or "none", ["data-open"] = if open then "true" else "false" },
		actions = { click = "pick=" .. kind },
	})
end

-- A pill that acts on click (priority, level), with a glyph on the left and no chevron.
local function click_pill(key: string, text: string, tone: string?, icon: string, act: string): Node
	return el("button", "pillbtn", key, {
		text = text,
		tone = tone,
		attrs = { ["data-icon"] = icon, ["data-chev"] = "no", ["data-open"] = "false" },
		actions = { click = act },
	})
end

-- omp's own thinking-level symbols (nerd preset, packages/tui/src/theme/symbols.ts) and
-- the status line's "auto" marker; the hue per level is set in styles.css by data-level.
local LEVEL_GLYPH: { [string]: string } = {
	off = "\u{F05E}",
	minimal = "\u{F0A9E}",
	low = "\u{F0A9F}",
	medium = "\u{F0AA1}",
	high = "\u{F0AA3}",
	xhigh = "\u{F0AA5}",
	max = "\u{F06D}",
	auto = "\u{F074}",
}

local function level_pill(level: string?): Node
	local kids: { Node } = {}
	local glyph = if level then LEVEL_GLYPH[level] else nil
	if glyph then
		table.insert(kids, el("span", "level-ic", "ic", { text = glyph }))
	end
	table.insert(kids, el("span", "level-name", "name", { text = if level then LEVEL_LABEL[level] or level else "Default" }))
	return el("button", "pillbtn", "level", {
		attrs = { ["data-icon"] = "level", ["data-level"] = level or "default", ["data-chev"] = "no", ["data-open"] = "false" },
		actions = { click = "level" },
	}, kids)
end

-- The title of the task's chat. A chat the list lacks (new, or older than the scan limit)
-- triggers a rescan that reads it; one still missing afterwards is retried every 20 seconds.
local function chat_title(state: State, t: Todo): string
	local id = t.links.omp_session
	if not id then
		return "New chat"
	end
	for _, c in state.chats or {} do
		if c.id == id then
			return c.title
		end
	end
	local tried = state.chats_tried[id]
	if not state.chats_loading and (tried == nil or os.time() - tried >= 20) then
		state.chats_tried[id] = os.time()
		scan_chats(state, nil)
		return "Loading chat…"
	end
	return if state.chats_loading or tried == nil then "Loading chat…" else "Unknown chat"
end

-- A labelled row of the task card: the name in a fixed column, its controls after it. `mark`
-- flags the name: "required" (Jira needs it) or "missing" (Post to Jira found it lacking).
function card.row(key: string, label: string, kids: { Node }, mark: string?): Node
	return el("div", "prop", key, nil, {
		el("span", "plabel", "label", { text = label, attrs = { ["data-state"] = mark or "none" } }),
		el("div", "pval", "value", nil, kids),
	})
end

-- The mark of a Jira field's name on task `t` (see card.row).
function jira.mark(state: State, t: Todo, id: string, needed: boolean): string?
	local j = state.jira
	if j.missing_task == t.id and j.missing[id] then
		return "missing"
	end
	return if needed then "required" else nil
end

-- The text input of a Jira text-like field: the draft while it is being typed in (its key
-- gets "-r<rev>", as field_node does with "_<rev>"), else the task's value.
function jira.input(state: State, t: Todo, f: JiraField): Node
	local inline = jira.inline(f)
	local v = if t.jira_fields then t.jira_fields[f.id] else nil
	local idle = if type(v) == "string" then v else ""
	local props: { [string]: any } = {
		key = "jx-" .. f.id,
		role = ROLE .. (if inline then "jc-input" else "jc-area"),
		aria = f.name,
		placeholder = if f.kind == "number" then "0"
			elseif f.kind == "date" then "YYYY-MM-DD"
			elseif f.kind == "datetime" then "YYYY-MM-DD HH:MM"
			elseif f.kind == "labels" then "Labels, separated by spaces"
			else "Add " .. string.lower(f.name),
	}
	local fx = state.jx
	if state.focus == "jx" and state.jira.jx_field == f.id and fx.task == t.id then
		fx.id = jira.jx_path(f) .. "-r" .. fx.rev
		props.key ..= "-r" .. fx.rev
		props.text = fx.text
		props.cursor = utf16_offset(fx.text, fx.cur)
		if fx.anchor and fx.anchor ~= fx.cur then
			props.anchor = utf16_offset(fx.text, fx.anchor)
		end
	else
		props.text = idle
		props.cursor = utf16_offset(idle, math.huge)
	end
	return ui.node(if inline then "input" else "editor", props)
end

-- The control of a Jira field in its row: a pill that opens its choices (choice, user), a
-- text input, or a note for a field only Jira can set.
function jira.control(state: State, t: Todo, f: JiraField): Node
	if f.kind == "choice" or f.kind == "user" then
		local v = if t.jira_fields then t.jira_fields[f.id] else nil
		local open = state.pick ~= nil and state.pick.kind == "jira_field" and state.jira.pick_field == f.id
		return el("button", "pillbtn", "pick", {
			text = jira.value_label(f, v),
			tone = if v == nil then "muted" else nil,
			attrs = { ["data-icon"] = "none", ["data-open"] = if open then "true" else "false" },
			actions = { click = "jpick=" .. f.id },
		})
	elseif f.kind == "other" then
		return el("span", "jc-na", "na", { text = "Set in Jira" })
	end
	return jira.input(state, t, f)
end

-- The Jira part of the task card. A linked task shows its issue. An open task, while Jira is
-- connected, gets the draft of its issue: project, type, component, then the create screen's
-- fields (one-line ones in rows, long texts under their names; "more fields" opens the rest)
-- and Post to Jira. Nil when there is no Jira part.
function jira.section(state: State, t: Todo): Node?
	local j = state.jira
	local link = t.jira
	if link then
		return el("div", "dsec", "jira", nil, {
			el("div", "dsec-title", "title", { text = "Jira" }),
			card.row("issue", "Issue", {
				el("button", "pillbtn", "issue", {
					text = link.key,
					title = "Open " .. link.key .. " in Jira",
					attrs = { ["data-icon"] = "issue", ["data-chev"] = "ext", ["data-open"] = "false" },
					actions = { click = "jissue" },
				}),
			}),
		})
	end
	if j.conn ~= "connected" or t.done then
		return nil
	end
	local p, comp, ready = jira.target(state)
	local fields, _, kind = jira.form_fields(state)
	local project = if p then p.name elseif j.busy.projects then "Loading…" else "Pick a project"
	local component = if comp then comp.name elseif p and not ready then "Loading…" else "No component"
	local kind_label = if kind then kind.name elseif p and j.meta_error[p.key] then "Jira's default" else "Loading…"
	local rows: { Node } = {
		card.row("jproject", "Project", { pill_box(state, "jira_target", "jtarget", project, if p then nil else "muted", nil) }),
		card.row("jtype", "Type", { pill_box(state, "jira_type", "jtype", kind_label, if kind then nil else "muted", nil) }),
		card.row("jcomp", "Component", { pill_box(state, "jira_component", "jcomp", component, if comp then nil else "muted", nil) }),
	}
	local texts: { Node } = {}
	local hidden = 0
	local shown: { JiraField } = fields or {}
	for _, f in shown do
		if not j.more and not jira.main_field(state, t, f) then
			hidden += 1
		elseif jira.inline(f) then
			table.insert(rows, card.row("jf-" .. f.id, f.name, { jira.control(state, t, f) }, jira.mark(state, t, f.id, jira.needed(f))))
		else
			local mark = jira.mark(state, t, f.id, jira.needed(f))
			table.insert(texts, el("div", "jc-block", "jf-" .. f.id, nil, {
				el("span", "plabel", "label", { text = f.name, attrs = { ["data-state"] = mark or "none" } }),
				jira.input(state, t, f),
			}))
		end
	end
	local kids: { Node } = {
		el("div", "jc-head", "head", nil, {
			el("span", "jc-mark", "mark", { text = "Jira" }),
			el("span", "jc-sub", "sub", { text = "New issue" }),
		}),
		el("div", "jc-rows", "rows", nil, rows),
	}
	if #texts > 0 then
		table.insert(kids, el("div", "jc-texts", "texts", nil, texts))
	end
	if p and j.meta_error[p.key] then
		table.insert(kids, el("div", "jc-note", "error", { attrs = { ["data-tone"] = "error" } }, {
			el("span", "jc-note-text", "text", { text = "Jira's fields did not load: " .. j.meta_error[p.key] }),
			el("button", "jc-more", "retry", { text = "Retry", actions = { click = "jretry" } }),
		}))
	elseif p and not fields then
		table.insert(kids, el("div", "jc-note", "load", { text = "Loading Jira's fields…" }))
	end
	if j.missing_task == t.id and j.missing.description then
		table.insert(kids, el("div", "jc-note", "desc", { text = "Jira needs a description: write it in the notes above.", attrs = { ["data-tone"] = "warning" } }))
	end
	local post = jira.post_label(state, t) or "Post to Jira"
	local foot: { Node } = {}
	if hidden > 0 or j.more then
		table.insert(foot, el("button", "jc-more", "more", {
			text = if j.more then "Fewer fields" else hidden .. (if hidden == 1 then " more field" else " more fields"),
			attrs = { ["data-open"] = if j.more then "true" else "false" },
			actions = { click = "jmore" },
		}))
	end
	table.insert(foot, el("button", "pill", "jpost", {
		text = post,
		title = "Title becomes the summary, notes the description",
		attrs = { ["data-busy"] = if post == "Posting…" then "true" else "false", ["data-kind"] = "jira" },
		actions = { click = "jpost" },
	}))
	table.insert(kids, el("div", "jc-foot", "foot", nil, foot))
	return el("div", "jcomp", "jira", nil, kids)
end

-- The text of the card's Post to Jira button; nil when the task cannot be posted.
function jira.post_label(state: State, t: Todo): string?
	local j = state.jira
	if t.jira or t.done or j.conn ~= "connected" then
		return nil
	end
	if t.id ~= "" and j.busy["create:" .. t.id] then
		return "Posting…"
	end
	return if state.fresh == t then "Add and post to Jira" else "Post to Jira"
end

-- The task card: title, status, notes; then labelled rows for the task, the agent that runs
-- it and its Jira issue; then the actions. A new task (the draft) mirrors the add row's text
-- as its title and has no order buttons.
function card.view(state: State, t: Todo): Node
	local draft = state.fresh == t
	local notes = field_node("editor", {
		key = "notes",
		role = ROLE .. "notes",
		placeholder = if jira.post_label(state, t) then "Add notes. They become the Jira description." else "Add notes",
	}, if state.focus == "notes" then state.notes else nil, t.notes)
	local head_kids: { Node } = {}
	if draft then
		table.insert(head_kids, el("div", "detail-title", "title", {
			text = if t.title ~= "" then t.title else "New task",
			attrs = { ["data-empty"] = if t.title == "" then "true" else "false" },
		}))
	else
		table.insert(head_kids, field_node("editor", {
			key = "title",
			role = ROLE .. "detail-title",
			aria = "Task title",
		}, if state.focus == "title" then state.title else nil, t.title))
		table.insert(head_kids, el("button", "hbtn", "up", {
			aria = "Move up",
			title = "Move up (Alt+↑)",
			attrs = { ["data-kind"] = "up", ["data-edge"] = if can_move(state, t, -1) then "false" else "true" },
			actions = { click = "mv=up" },
		}))
		table.insert(head_kids, el("button", "hbtn", "down", {
			aria = "Move down",
			title = "Move down (Alt+↓)",
			attrs = { ["data-kind"] = "down", ["data-edge"] = if can_move(state, t, 1) then "false" else "true" },
			actions = { click = "mv=down" },
		}))
	end
	table.insert(head_kids, el("button", "close", "close", { aria = "Close", title = "Close", actions = { click = "close" } }))
	local kids: { Node } = { el("div", "detail-head", "head", nil, head_kids) }
	local kind = status_of(state, t, live_panes())
	if STATUS_LABEL[kind] then
		table.insert(kids, el("div", "chiprow", "chiprow", nil, {
			el("span", "statuschip", "chip", { text = STATUS_LABEL[kind], attrs = { ["data-kind"] = kind } }),
		}))
	end
	local _, _, sentence = stamp_label(state, t)
	if state.cfg.time and sentence then
		table.insert(kids, el("div", "stampline", "stamp", { text = sentence }))
	end
	table.insert(kids, notes)
	local task_rows: { Node } = {
		card.row("prio", "Priority", {
			click_pill("prio", PRIORITY_LABEL[t.priority], PILL_TONE[t.priority], "prio-" .. t.priority, "prio"),
		}),
	}
	if t.links.omp_session then
		local auto_on = if t.auto_title == nil then state.cfg.omp_titles == true else t.auto_title
		table.insert(task_rows, card.row("autotitle", "Auto title", {
			click_pill("autotitle", if auto_on then "On" else "Off", if auto_on then "success" else nil, "none", "autotitle"),
		}))
	end
	table.insert(kids, el("div", "dsec", "task", nil, task_rows))
	table.insert(kids, el("div", "dsec", "agent", nil, {
		el("div", "dsec-title", "title", { text = "Agent" }),
		card.row("model", "Model", { pill_box(state, "model", "model", t.agent.model or "Default model", nil, nil) }),
		card.row("level", "Thinking", { level_pill(t.agent.thinking) }),
		card.row("project", "Project", {
			pill_box(state, "project", "cwd", if t.links.cwd then project_label(state, t.links.cwd) else "No project", nil, "folder"),
			click_pill("worktree", if state.cfg.new_chat_worktree then "Worktree" else "Local", nil, "none", "worktree"),
		}),
		card.row("chat", "Chat", { pill_box(state, "chat", "chat", chat_title(state, t), nil, nil) }),
	}))
	local section = jira.section(state, t)
	if section then
		table.insert(kids, section)
	end
	local actions: { Node } = {}
	if draft then
		table.insert(actions, el("button", "pill", "add", {
			text = "Add task",
			title = "Add task (Enter)",
			attrs = { ["data-primary"] = "true" },
			actions = { click = "add" },
		}))
	else
		table.insert(actions, el("button", "pill", "done", {
			text = if t.done then "Mark as not done" else "Mark as done",
			actions = { click = "toggle=" .. t.id },
		}))
		table.insert(actions, el("button", "pill", "open", {
			text = primary_label(t),
			attrs = { ["data-primary"] = "true" },
			actions = { click = "primary" },
		}))
	end
	table.insert(kids, el("div", "buttons", "buttons", nil, actions))
	return el("div", "detail", "detail", {
		attrs = { ["data-focus"] = if state.focus == "notes" then "notes" else "none" },
	}, kids)
end

-- Tickets tab ---------------------------------------------------------------

-- "Fri 14 Nov" of an ISO stamp; nil when it is not one.
function jira.short_date(iso: string?): string?
	local ts = parse_iso(iso)
	return if ts then os.date("%a %d %b", ts) else nil
end

-- A sprint ticket: its task's status glyph once it has a task, else open/done by Jira.
function jira.row(state: State, tk: Ticket, live: { [number]: boolean }): Node
	local t = jira.task_for(state, tk.key)
	local kind = if t then status_of(state, t, live) elseif tk.category == "done" then "done" else "todo"
	local meta: { Node } = {
		el("span", "badge", "key", { text = tk.key, attrs = { ["data-kind"] = "jira" } }),
		el("span", "badge", "status", { text = tk.status, tone = jira.TONE[tk.category] or "muted" }),
	}
	-- Grouped by assignee, the group's header already names them.
	if tk.assignee and state.jira.view.group ~= "assignee" then
		table.insert(meta, el("span", "jmeta", "who", { text = tk.assignee }))
	end
	if t then
		local line = if t.done then "Task done" else agent_line(state, t, kind) or "In tasks"
		table.insert(meta, el("div", "agent-line", "line", { text = line, attrs = { ["data-kind"] = kind } }))
	end
	return el("div", "row", tk.key, {
		attrs = {
			["data-state"] = if state.jira.cursor == tk.key then "selected" else "idle",
			["data-done"] = if tk.category == "done" then "true" else "false",
		},
		actions = { click = "tsel=" .. tk.key, dblclick = "topen=" .. tk.key },
	}, {
		el("span", "check", "check", { attrs = { ["data-status"] = kind } }),
		el("div", "rowtext", "text", nil, {
			el("div", "title", "title", { text = tk.summary }),
			el("div", "meta", "meta", nil, meta),
		}),
	})
end

function jira.left(state: State): Node
	local j = state.jira
	local tickets = j.tickets
	local subtitle = ""
	-- The line in place of the rows: what to do next, or why there are none.
	local note: string? = nil
	if j.conn == "unknown" then
		subtitle = "Checking Jira…"
	elseif j.conn ~= "connected" then
		subtitle = "Not connected"
		note = "Connect Jira with the form on the right to see the current sprint here."
	elseif not j.project then
		subtitle = if j.user then "Signed in as " .. j.user else "Connected"
		note = "Pick the Jira project, then its board."
	elseif not j.board then
		subtitle = j.project.name
		note = if j.busy.boards then "Loading boards…" else "Pick a board of " .. j.project.name .. "."
	elseif not tickets then
		subtitle = j.board.name
		note = if j.busy.sprint then "Loading the sprint…" else nil
	else
		local sprints = j.sprints or {}
		if #sprints == 0 then
			subtitle = j.board.name
			note = "No active sprint on " .. j.board.name .. "."
		else
			local names: { string } = {}
			for _, s in sprints do
				table.insert(names, s.name)
			end
			local mine = jira.count(state)
			subtitle = table.concat(names, ", ") .. " · "
				.. (if j.view.mine then "yours: " .. mine .. " of " .. plural(#tickets, "ticket") else plural(#tickets, "ticket"))
			local ends = if #sprints == 1 then jira.short_date(sprints[1].ends) else nil
			if ends then
				subtitle ..= " · ends " .. ends
			end
			if #tickets == 0 then
				note = "The sprint has no tickets."
			end
		end
	end
	local kids: { Node } = {
		el("div", "head", "head", nil, {
			el("div", "heading", "heading", { text = "Jira tickets" }),
			el("div", "subtitle", "subtitle", { text = subtitle }),
			jira.tabs(state),
		}),
	}
	if j.conn == "connected" then
		local bar: { Node } = {
			pill_box(state, "jira_project", "jproject", if j.project then j.project.name else "Pick a project", if j.project then nil else "muted", nil),
		}
		if j.project then
			table.insert(bar, pill_box(state, "jira_board", "jboard", if j.board then j.board.name else "Pick a board", if j.board then nil else "muted", nil))
		end
		table.insert(bar, el("button", "hbtn", "jrefresh", {
			aria = "Reload the sprint",
			title = "Reload the sprint (r)",
			attrs = { ["data-kind"] = "refresh", ["data-busy"] = if j.busy.sprint then "true" else "false" },
			actions = { click = "jrefresh" },
		}))
		table.insert(bar, el("button", "pillbtn", "jaccount", {
			text = j.user or j.email or "Jira",
			title = (j.url or "") .. " · edit the connection (c)",
			attrs = { ["data-icon"] = "jira", ["data-chev"] = "no", ["data-open"] = if j.editing then "true" else "false" },
			actions = { click = "jedit" },
		}))
		table.insert(kids, el("div", "jbar", "jbar", nil, bar))
		if tickets and #tickets > 0 then
			-- The view: everyone's tickets or only yours, and how they are grouped.
			local function seg(mine: boolean, text: string): Node
				return el("button", "tabbtn", if mine then "mine" else "all", {
					text = text,
					title = (if mine then "Only the tickets assigned to you" else "Every ticket of the sprint") .. " (m switches)",
					attrs = { ["data-active"] = if j.view.mine == mine then "true" else "false" },
					actions = { click = "jmine=" .. (if mine then "on" else "off") },
				})
			end
			table.insert(kids, el("div", "jfilter", "jfilter", nil, {
				el("div", "jseg", "jseg", nil, { seg(false, "Everyone"), seg(true, "Only mine") }),
				pill_box(state, "jira_group", "jgroup",
					if j.view.group == "none" then "No grouping" else "Group by " .. string.lower(jira.GROUP_LABEL[j.view.group]),
					nil, nil),
			}))
		end
	end
	local rows: { Node } = {}
	if j.error then
		table.insert(rows, el("div", "jnote", "error", { text = j.error, attrs = { ["data-tone"] = "error" } }))
	end
	if note then
		table.insert(rows, el("div", "jnote", "note", { text = note }))
	end
	local live = live_panes()
	local groups = jira.groups(state)
	if tickets and #tickets > 0 and #groups == 0 then
		table.insert(rows, el("div", "jempty", "mine-none", nil, {
			el("div", "jnote", "note", { text = "Nothing in this sprint is assigned to you." }),
			el("button", "pill", "showall", { text = "Show everyone's tickets", actions = { click = "jmine=off" } }),
		}))
	end
	for i, g in groups do
		local folded = j.folded[g.id] == true
		if g.id ~= "all" then
			table.insert(rows, el("button", "arch-head", "g" .. i, {
				text = g.label .. " (" .. #g.tickets .. ")",
				title = if folded then "Show these tickets" else "Hide these tickets",
				attrs = { ["data-open"] = if folded then "false" else "true" },
				actions = { click = "jfold=" .. g.id },
			}))
		end
		if not folded then
			for _, tk in g.tickets do
				table.insert(rows, jira.row(state, tk, live))
			end
		end
	end
	table.insert(kids, el("div", "rows", "rows", { attrs = { ["data-lift"] = "off" } }, rows))
	return el("div", "left", "left", nil, kids)
end

function jira.card(state: State, tk: Ticket): Node
	local t = jira.task_for(state, tk.key)
	local chips: { Node } = {
		el("span", "badge", "key", { text = tk.key, attrs = { ["data-kind"] = "jira" } }),
		el("span", "badge", "status", { text = tk.status, tone = jira.TONE[tk.category] or "muted" }),
	}
	if tk.kind then
		table.insert(chips, el("span", "badge", "type", { text = tk.kind }))
	end
	if tk.priority then
		table.insert(chips, el("span", "badge", "prio", { text = tk.priority }))
	end
	local facts: { string } = { if tk.assignee then "Assignee: " .. tk.assignee else "Unassigned" }
	if tk.sprint then
		table.insert(facts, tk.sprint)
	end
	local kids: { Node } = {
		el("div", "detail-head", "head", nil, {
			el("div", "jtitle", "title", { text = tk.summary }),
		}),
		el("div", "meta", "chips", nil, chips),
		el("div", "jfacts", "facts", { text = table.concat(facts, " · ") }),
	}
	if t then
		local kind = status_of(state, t, live_panes())
		local line = if t.done then "Its task is done" else agent_line(state, t, kind) or "In your tasks"
		table.insert(kids, el("div", "chiprow", "taskchip", nil, {
			el("span", "statuschip", "chip", { text = line, attrs = { ["data-kind"] = kind } }),
		}))
	end
	table.insert(kids, el("div", if tk.description then "jdesc" else "jdesc-none", "desc", {
		text = tk.description or "No description.",
	}))
	-- Its long text fields (Definition of Done, Acceptance criteria…), each under its name.
	for i, d in tk.details do
		table.insert(kids, el("div", "jsec", "dt" .. i, { text = d.name }))
		table.insert(kids, el("div", "jdesc", "dd" .. i, { text = d.text }))
	end
	local buttons: { Node } = {
		el("button", "pill", "jira", { text = "Open in Jira", actions = { click = "tjira=" .. tk.key } }),
		el("button", "pill", "task", {
			text = if t then "Go to task" else "Add to tasks",
			actions = { click = (if t then "tgoto=" else "tadd=") .. tk.key },
		}),
	}
	if t and t.done and tk.category ~= "done" then
		table.insert(buttons, el("button", "pill", "close", {
			text = if state.jira.busy["done:" .. tk.key] then "Closing…" else "Close in Jira",
			actions = { click = "tclose=" .. tk.key },
		}))
	end
	table.insert(buttons, el("button", "pill", "start", {
		text = if t then primary_label(t) else "Start",
		actions = { click = "tstart=" .. tk.key },
	}))
	table.insert(kids, el("div", "jbuttons", "buttons", nil, buttons))
	return el("div", "detail", "detail", { attrs = { ["data-focus"] = "none" } }, kids)
end

-- The connection form. Its fields keep FIELD_IDS' paths (direct children of "jform").
function jira.form(state: State): Node
	local j = state.jira
	local connected = j.conn == "connected"
	local head: { Node } = { el("div", "jtitle", "title", { text = if connected then "Jira connection" else "Connect Jira" }) }
	if connected then
		table.insert(head, el("button", "close", "close", { aria = "Close", title = "Close (Esc)", actions = { click = "jcancel" } }))
	end
	local kids: { Node } = {
		el("div", "detail-head", "head", nil, head),
		el("div", "jhelp", "help", {
			text = "Jira Cloud: your Atlassian email and an API token. Jira Data Center: leave the email empty "
				.. "and use a personal access token. The token is kept in the system keychain.",
		}),
		el("div", "jlabel", "lurl", { text = "Jira URL" }),
		field_node("input", {
			key = "jurl",
			role = ROLE .. "jfield",
			placeholder = "https://your-company.atlassian.net",
			aria = "Jira URL",
		}, state.jurl, ""),
		el("div", "jlabel", "lemail", { text = "Email" }),
		field_node("input", {
			key = "jemail",
			role = ROLE .. "jfield",
			placeholder = "you@company.com",
			aria = "Email",
		}, state.jemail, ""),
		el("div", "jlabel", "ltoken", { text = "API token" }),
		field_node("input", {
			key = "jtoken",
			role = ROLE .. "jira-token",
			secret = true,
			placeholder = if connected then "Kept in the keychain; paste a new one to replace it" else "Paste the token",
			aria = "API token",
		}, state.jtoken, ""),
	}
	if j.form_error then
		table.insert(kids, el("div", "jnote", "error", { text = j.form_error, attrs = { ["data-tone"] = "error" } }))
	end
	local buttons: { Node } = {
		el("button", "pill", "token", { text = "Create a token", actions = { click = "jtokenpage" } }),
	}
	if connected then
		table.insert(buttons, el("button", "pill", "forget", {
			text = if j.busy.forget then "Disconnecting…" else "Disconnect",
			actions = { click = "jforget" },
		}))
	end
	table.insert(buttons, el("button", "pill", "connect", {
		text = if j.busy.connect then "Checking…" elseif connected then "Save" else "Connect",
		actions = { click = "jconnect" },
	}))
	table.insert(kids, el("div", "jbuttons", "buttons", nil, buttons))
	return el("div", "detail", "jform", { attrs = { ["data-focus"] = "none" } }, kids)
end

-- Keys on the Tickets tab while no field has focus.
function jira.key(state: State, key: Key): boolean
	if key.ctrl or key.alt or key.meta then
		return false
	end
	local j = state.jira
	local k = key.text or key.name
	local connected = j.conn == "connected"
	local tk = jira.selected(state)
	if key.name == "up" or k == "k" then
		jira.move(state, -1, nil)
	elseif key.name == "down" or k == "j" then
		jira.move(state, 1, nil)
	elseif key.name == "home" or k == "g" then
		jira.move(state, nil, 1)
	elseif key.name == "end" or k == "G" then
		jira.move(state, nil, #(j.tickets or {}))
	elseif key.name == "enter" then
		if tk and not j.editing then
			jira.ticket_task(state, tk, true)
		end
	elseif k == "a" then
		if tk then
			jira.ticket_task(state, tk, false)
		end
	elseif k == "o" then
		if tk then
			jira.open_issue(state, tk.key)
		end
	elseif k == "m" then
		if connected then
			jira.set_view(state, not j.view.mine, nil)
		end
	elseif k == "s" then
		if connected then
			open_picker(state, "jira_group")
		end
	elseif k == "r" then
		jira.load(state, true)
	elseif k == "p" then
		if connected then
			open_picker(state, "jira_project")
		end
	elseif k == "b" then
		if connected and j.project then
			open_picker(state, "jira_board")
		end
	elseif k == "c" then
		jira.edit(state, true)
		set_focus(state, "jurl")
	elseif key.name == "escape" and j.editing then
		jira.edit(state, false)
	elseif k == "," then
		open_settings(state)
	elseif k == "T" then
		switch_tab(state, "tasks")
	elseif k == "B" then
		switch_tab(state, "backlog")
	else
		return false
	end
	return true
end

-- Clicks on the Tickets tab; false for actions it does not own.
function jira.event(state: State, act: any, value: any): boolean
	local j = state.jira
	local tk = if type(value) == "string" then jira.ticket(state, value) else nil
	if act == "jmine" then
		jira.set_view(state, value == "on", nil)
		return true
	elseif act == "jfold" and type(value) == "string" then
		j.folded[value] = not j.folded[value]
		return true
	end
	if act == "tsel" or act == "topen" then
		if not tk then
			return true
		end
		j.cursor = tk.key
		if j.editing then
			jira.edit(state, false)
		end
		refresh_cfg(state)
		if act == "topen" and state.cfg.dblclick then
			jira.ticket_task(state, tk, true)
		end
	elseif act == "tstart" or act == "tadd" then
		if tk then
			jira.ticket_task(state, tk, act == "tstart")
		end
	elseif act == "tgoto" then
		local t = if type(value) == "string" then jira.task_for(state, value) else nil
		if t then
			jira.show_task(state, t)
		end
	elseif act == "tjira" then
		if type(value) == "string" then
			jira.open_issue(state, value)
		end
	elseif act == "tclose" then
		if type(value) == "string" and not j.busy["done:" .. value] then
			jira.ask(state, "done", { key = value })
		end
	elseif act == "jconnect" then
		jira.connect(state)
	elseif act == "jedit" then
		jira.edit(state, not j.editing)
	elseif act == "jcancel" then
		jira.edit(state, false)
	elseif act == "jforget" then
		if not j.busy.forget then
			jira.ask(state, "forget", nil)
		end
	elseif act == "jrefresh" then
		jira.load(state, true)
	elseif act == "jtokenpage" then
		state.cx:open(jira.TOKEN_PAGE)
	elseif act == "jpost" then
		-- The task card's Post to Jira; a new task is added first.
		local t = selected(state)
		if t and state.fresh == t then
			local id = card.add(state)
			t = if id then todo_by_id(state, id) else nil
			if not t and trim(state.add.text) == "" then
				state.cx:toast("warning", "Type the task's title first")
				set_focus(state, "add")
			end
		end
		if t then
			jira.post(state, t)
		end
	elseif act == "jpick" and type(value) == "string" then
		-- A Jira field's pill on the task card: its choices, or closes them.
		if state.pick and state.pick.kind == "jira_field" and j.pick_field == value then
			close_picker(state)
		else
			j.pick_field = value
			open_picker(state, "jira_field")
		end
	elseif act == "jmore" then
		j.more = not j.more
	elseif act == "jretry" then
		local p = jira.target(state)
		if p then
			j.meta_error[p.key] = nil
			jira.prefetch(state)
		end
	elseif act == "jissue" then
		local t = selected(state)
		if t then
			jira.open_task_issue(state, t)
		end
	else
		return false
	end
	return true
end

-- The modifier keys held during a click, as a set (Tern lists shift/ctrl/alt/meta).
local function mods_of(ev: UiEvent): { [string]: boolean }
	local out: { [string]: boolean } = {}
	local m = ev.mods
	if type(m) == "table" then
		for _, name in m do
			out[tostring(name)] = true
		end
		if out.cmd or out.super then
			out.meta = true
		end
	end
	return out
end

-- The card shown in place of the task card while two or more tasks are selected.
local function bulk_view(state: State, ids: { string }): Node
	local counts = { 0, 0, 0 }
	local all_done, all_archived = true, true
	for _, id in ids do
		local t = todo_by_id(state, id)
		if t then
			local g = group_of(t)
			counts[g] += 1
			if not t.done then
				all_done = false
			end
			if not t.archived then
				all_archived = false
			end
		end
	end
	local parts: { string } = {}
	for i, label in { "open", "done", "archived" } do
		if counts[i] > 0 then
			table.insert(parts, counts[i] .. " " .. label)
		end
	end
	local confirm = state.confirm_bulk
	return el("div", "detail", "bulk", { attrs = { ["data-focus"] = "none", ["data-bulk"] = "true" } }, {
		el("div", "bulk-title", "title", { text = #ids .. " tasks selected" }),
		el("div", "bulk-sub", "sub", { text = table.concat(parts, " · ") }),
		el("div", "bulk-buttons", "buttons", nil, {
			el("button", "pill", "backlog", {
				text = if bulk_all_backlog(state, ids) then "Back to tasks" else "To backlog",
				actions = { click = "bulk=backlog" },
			}),
			el("button", "pill", "archive", {
				text = if all_archived then "Restore" else "Archive",
				actions = { click = "bulk=archive" },
			}),
			el("button", "pill", "done", {
				text = if all_done then "Mark as not done" else "Mark done",
				actions = { click = "bulk=done" },
			}),
			el("button", "pill", "delete", {
				text = if confirm then "Delete " .. #ids .. "?" else "Delete",
				attrs = { ["data-confirm"] = if confirm then "true" else "false" },
				actions = { click = "bulk=delete" },
			}),
			el("button", "pill", "clear", { text = "Clear", actions = { click = "bulk=clear" } }),
		}),
	})
end

-- The settings sheet: Tern's picker sheet (as the project/model/chat popovers use) with one
-- card row per setting: label, switch badge, one-line description. No query, so no search.
local function settings_node(state: State): Node
	local items: { any } = {}
	local order: { any } = {}
	for _, s in SETTINGS do
		local on = state.cfg[s.id] == true
		table.insert(items, {
			id = s.id,
			label = s.label,
			detail = s.hint,
			badges = { { text = if on then "On" else "Off", tone = if on then "success" else "muted" } },
			tone = if on then "success" else "muted",
		})
		table.insert(order, s.id)
	end
	return ui.node("picker", {
		key = "settings",
		role = ROLE .. "settings",
		size = "md",
		layout = "cards",
		preview = "none",
		title = "Settings",
		noun = "settings",
		items = items,
		order = order,
		selected = SETTINGS[math.clamp(state.settings_sel, 1, #SETTINGS)].id,
		actions = {
			{ id = "settings-toggle", label = "Toggle", keys = { "space" } },
			{ id = "settings-close", label = "Close", keys = { "esc" }, primary = true },
		},
	})
end

-- Keys while the settings sheet is open: it owns them all (modified keys go to Tern).
local function settings_key(state: State, key: Key): boolean
	if key.ctrl or key.alt or key.meta then
		return false
	end
	local k = key.text or key.name
	local n = #SETTINGS
	if key.name == "escape" or k == "," then
		state.settings_open = false
	elseif key.name == "up" or k == "k" then
		state.settings_sel = math.max(1, state.settings_sel - 1)
	elseif key.name == "down" or k == "j" then
		state.settings_sel = math.min(n, state.settings_sel + 1)
	elseif key.name == "home" then
		state.settings_sel = 1
	elseif key.name == "end" then
		state.settings_sel = n
	elseif key.name == "space" or k == " " or key.name == "enter" then
		toggle_setting(state, SETTINGS[math.clamp(state.settings_sel, 1, n)].id)
	end
	return true
end

local function task_path(args: { string }, saved: any): (string?, string?)
	if args[1] then
		return args[1], nil
	end
	if type(saved) == "table" and type(saved.path) == "string" and saved.path ~= "" then
		return saved.path, nil
	end
	local ok, last = pcall(tern.kv.get, "todo-proto.file")
	if not ok then
		return nil, "Cannot read the last task file setting: " .. tostring(last)
	end
	local path: string
	if type(last) == "string" and last ~= "" then
		path = last
	else
		local home = tern.getenv("HOME")
		if not home or home == "" then
			return nil, "HOME is not set on this host. Open an explicit task file or set HOME for the Tern daemon."
		end
		path = string.gsub(home, "/+$", "") .. "/todos.todo.json"
	end
	local exists_ok, exists = pcall(tern.fs.exists, path)
	if not exists_ok then
		return nil, "Cannot check task file " .. path .. ": " .. tostring(exists)
	end
	if not exists then
		local wrote, reason = pcall(tern.fs.write, path, tern.json.encode({ todos = tern.json.array() }, true) .. "\n")
		if not wrote then
			return nil, "Cannot create task file " .. path .. ": " .. tostring(reason)
		end
	end
	return path, nil
end

local function root(children: { Node }): Node
	local col = ui.col(children)
	local p: { [string]: any } = col.p or {}
	p.role = ROLE .. "main"
	col.p = p
	return col
end

tern.block.define("list", {
	init = function(cx: BlockCx, args: { string }, saved: any): State
		local previous = running[cx.pane]
		if previous then
			retire(previous)
		end
		local path, path_error = task_path(args, saved)
		local state: State = {
			cx = cx,
			path = path,
			todos = {},
			cursor = nil,
			error = path_error,
			timer = nil,
			focus = nil,
			detail_open = true,
			fresh = nil,
			add = new_field("", false, nil),
			notes = new_field("", true, nil),
			title = new_field("", false, TITLE_MAX),
			pick = nil,
			models = nil,
			models_state = "idle",
			models_error = nil,
			chats = nil,
			chats_loading = false,
			chats_token = 0,
			chats_tried = {},
			agent_states = {},
			states_at = 0,
			previous_live = nil,
			debug_states = {},
			states_sig = "",
			closed_panes = nil,
			st_timer = nil,
			since = {},
			nudge_seen = 0,
			launched = {},
			arch_open = false,
			done_open = false,
			tab = "tasks",
			confirm = nil,
			confirm_timer = nil,
			lift = nil,
			tap = nil,
			launching = {},
			sel = {},
			anchor = nil,
			confirm_bulk = false,
			closing = {},
			cfg = read_settings(),
			settings_open = false,
			settings_sel = 1,
			settings_tap = nil,
			sess_mtime = {},
			sess_path = {},
			sess_tried = {},
			sess_busy = false,
			fsw = false,
			tick = nil,
			jira = jira.new(),
			jurl = new_field("", false, nil),
			jemail = new_field("", false, nil),
			jtoken = new_field("", false, nil),
			jx = new_field("", true, nil),
		}
		running[cx.pane] = state
		if not saved and state.path and string.sub(state.path, 1, 1) == "/" then
			pcall(tern.kv.set, "todo-proto.file", state.path)
		end
		state.nudge_seen = nudge_n(state) or 0
		auto_import.arm()
		if state.path then
			load(state)
			poll(state)
			watch_files(state)
			scan_chats(state, nil)
			update_states(state)
			poll_states(state)
			poll_sessions(state)
			start_tick(state)
			-- The task card's Jira rows show once the window says Jira is connected.
			tern.timer(1, function()
				if alive(state) and state.jira.conn == "unknown" and not state.jira.busy.status then
					jira.ask(state, "status", nil)
					state.cx:render()
				end
			end)
		end
		return state
	end,

	save = function(state: State): any
		return { path = state.path }
	end,

	features = { "edit", "undo" },
	title = function(state: State): string?
		return "Tasks (" .. open_count(state) .. ")"
	end,

	view = function(state: State, _cx: BlockCx): BlockView
		if state.error then
			local card = ui.card({ ui.span("Could not load todos", "strong") }, { ui.md(state.error) })
			local p: { [string]: any } = card.p or {}
			p.tone = "error"
			card.p = p
			return { main = root({ card }) }
		end
		refresh_cfg(state)
		local cols: { Node } = {}
		if state.tab == "tickets" then
			local j = state.jira
			table.insert(cols, jira.left(state))
			if j.conn == "disconnected" or j.editing then
				table.insert(cols, jira.form(state))
			elseif j.conn == "connected" then
				local tk = jira.selected(state)
				if tk then
					table.insert(cols, jira.card(state, tk))
				end
			end
		else
			table.insert(cols, left_view(state))
			local t = selected(state)
			local picked_ids = multi_ids(state)
			if #picked_ids >= 2 then
				table.insert(cols, bulk_view(state, picked_ids))
			elseif t and state.detail_open then
				table.insert(cols, card.view(state, t))
			end
		end
		local jira_pick = state.pick ~= nil and jira.KINDS[state.pick.kind] == true
		local hint = el("div", "hint", "hint", {
				text = if state.focus == "picker" and jira_pick
					then "↑↓ choose  ·  type to search  ·  ⏎ pick  ·  Esc close"
					elseif state.focus == "picker"
					then "↑↓ PgUp PgDn choose  ·  Tab complete path  ·  ⏎ pick  ·  Esc close"
					elseif jira.field(state, state.focus)
					then "Enter connect  ·  Tab next field  ·  Esc leave field"
					elseif state.focus == "jx"
					then (if state.jx.multiline then "Enter new line  ·  Tab save  ·  Esc cancel" else "Enter save  ·  Esc cancel")
					elseif state.focus == "title"
					then "Enter save  ·  Esc cancel"
					elseif state.focus == "notes"
					then "Enter new line  ·  Tab save  ·  Esc cancel"
					elseif state.focus
					then "Enter " .. (if state.focus == "add" then "add task" else "new line") .. "  ·  Esc leave field"
					else if state.lift
						then "Click a task to move it there  ·  click the grip or Esc to cancel"
						elseif state.tab == "tickets"
						then "j/k move  ·  ⏎ start  ·  a add to tasks  ·  o open in Jira  ·  m only mine  ·  s group  ·  r reload  ·  p project  ·  b board  ·  c connection  ·  T tasks  ·  , settings"
						elseif next(state.sel) ~= nil
						then "⇧↑↓ extend  ·  v mark  ·  ⌘A all  ·  space done  ·  b backlog  ·  z archive  ·  ⌫⌫ delete  ·  Esc clear  ·  , settings"
						else "j/k move  ·  space done  ·  ⏎ open  ·  Tab add  ·  e notes  ·  F2 rename  ·  p project  ·  b backlog  ·  B tab  ·  T Jira tickets  ·  z archive  ·  ⌫ delete  ·  v select  ·  , settings",
		})
		local dockkids: { Node } = {}
		if state.cfg.hints then
			table.insert(dockkids, hint)
		end
		table.insert(dockkids, gear_button())
		local dock = ui.col({ el("div", "dockrow", "dockrow", nil, dockkids) })
		local dp: { [string]: any } = dock.p or {}
		dp.role = ROLE .. "dock"
		dock.p = dp
		local layer: Node? = nil
		local sheet = picker_node(state)
		if sheet then
			layer = ui.col({ sheet, pick_input(state) })
		elseif state.settings_open then
			layer = ui.col({ settings_node(state) })
		end
		return { main = root({ el("div", "ws", "ws", nil, cols) }), dock = dock, layer = layer }
	end,

	key = function(state: State, key: Key, cx: BlockCx): boolean?
		if not state.path then
			return false
		end
		if state.settings_open then
			return settings_key(state, key)
		end
		if state.focus then
			return field_key(state, key)
		end
		if state.tab == "tickets" then
			return jira.key(state, key)
		end
		if key.shift and not (key.ctrl or key.alt or key.meta) and (key.name == "up" or key.name == "down") then
			extend(state, if key.name == "up" then -1 else 1)
			return true
		end
		if (key.meta or key.ctrl) and not (key.alt or key.shift) and key.name == "a" then
			select_all(state)
			return true
		end
		if (key.alt and not key.ctrl and not key.meta) or (key.meta and key.shift and not key.ctrl and not key.alt) then
			if key.name == "up" or key.name == "down" then
				step(state, if key.name == "up" then -1 else 1)
				return true
			end
		end
		if key.ctrl or key.alt or key.meta then
			return false
		end
		local i = index_of(state)
		local k = key.text or key.name
		-- The card is hidden while several rows are selected, so keys that edit it do nothing.
		if #multi_ids(state) >= 2 and (k == "e" or k == "n" or k == "p" or key.name == "f2") then
			return true
		end
		if key.name == "up" or k == "k" then
			move(state, i - 1)
		elseif key.name == "down" or k == "j" then
			move(state, i + 1)
		elseif key.name == "home" or k == "g" then
			move(state, 1)
		elseif key.name == "end" or k == "G" then
			move(state, #state.todos)
		elseif key.name == "space" or k == " " or k == "x" then
			local ids = multi_ids(state)
			local t = selected(state)
			if #ids >= 2 then
				bulk_done(state, ids)
			elseif t then
				toggle_done(state, t.id)
			end
		elseif k == "v" then
			if state.cursor then
				toggle_mark(state, state.cursor)
			end
		elseif key.name == "enter" then
			local t = selected(state)
			if t then
				activate(state, t)
			end
		elseif key.name == "tab" or k == "a" then
			new_task(state)
		elseif k == "e" then
			set_focus(state, "notes")
		elseif key.name == "f2" or k == "n" then
			begin_rename(state)
		elseif k == "," then
			open_settings(state)
		elseif k == "p" then
			open_picker(state, "project")
		elseif k == "r" then
			refresh(state)
		elseif k == "z" then
			local t = selected(state)
			if t then
				archive_toggle(state, t)
			end
		elseif k == "b" then
			local t = selected(state)
			if t then
				backlog_toggle(state, t)
			end
		elseif k == "B" then
			switch_tab(state, if state.tab == "backlog" then "tasks" else "backlog")
		elseif k == "T" then
			switch_tab(state, "tickets")
		elseif k == "Z" then
			toggle_archived(state)
		elseif key.name == "delete" or key.name == "backspace" then
			delete_press(state)
		elseif key.name == "escape" and (state.confirm or state.confirm_bulk or state.lift or next(state.sel) ~= nil) then
			if state.lift or state.confirm or state.confirm_bulk then
				clear_confirm(state)
				state.lift = nil
			else
				clear_sel(state)
				state.anchor = nil
			end
		else
			return false
		end
		return true
	end,

	event = function(state: State, ev: UiEvent, _cx: BlockCx)
		if ev.ev == "action" and ev.act == "todo.states" then
			local ok, snapshot = pcall(tern.json.decode, if type(ev.json) == "string" then ev.json else "")
			if ok and type(snapshot) == "table" and type(snapshot.states) == "table" then
				local native_ids: { [string]: number } = {}
				local ambiguous: { [string]: boolean } = {}
				for _, pane in tern.pane.list() do
					local key = tostring(pane.pane % 17592186044416)
					if native_ids[key] ~= nil then
						ambiguous[key] = true
					end
					native_ids[key] = pane.pane
				end
				local states: { [string]: string } = {}
				for key, word in snapshot.states do
					local native_id = native_ids[key]
					if type(key) == "string" and type(word) == "string" and native_id and not ambiguous[key] then
						states[tostring(native_id)] = word
					end
				end
				state.agent_states = states
				state.states_at = tern.now()
			end
			if type(ev.window) == "string" then
				state.window = ev.window
			end
			return
		elseif ev.ev == "action" and ev.act == "todo.settings" then
			open_settings(state)
			return
		elseif ev.ev == "action" and ev.act == jira.link.ACT then
			local ok, data = pcall(tern.json.decode, if type(ev.json) == "string" then ev.json else "")
			if ok then
				jira.answer(state, data)
			end
			return
		end
		if state.settings_open then
			if (ev.ev == "select" or ev.ev == "activate") and type(ev.item) == "string" then
				for i, s in SETTINGS do
					if s.id == ev.item then
						state.settings_sel = i
						local now = tern.now()
						local tap = state.settings_tap
						state.settings_tap = { id = s.id, at = now }
						-- A double click delivers select then activate: it flips once.
						if ev.ev == "select" or not (tap and tap.id == s.id and now - tap.at < TAP_MS) then
							toggle_setting(state, s.id)
						end
					end
				end
			elseif ev.ev == "action" then
				if ev.act == "settings-toggle" then
					toggle_setting(state, SETTINGS[math.clamp(state.settings_sel, 1, #SETTINGS)].id)
				elseif ev.act == "settings-close" or ev.act == "close" then
					state.settings_open = false
				end
			end
			return
		end
		if ev.ev == "focus" and type(ev.id) == "string" then
			-- A Jira field of the task card: "…jx-<field id>", "-r<rev>" while typed in.
			local jx = string.match(ev.id, "%.jx%-([^.]-)%-r%d+$") or string.match(ev.id, "%.jx%-([^.]+)$")
			if jx then
				jira.focus_field(state, jx)
				return
			end
			local tail = string.match(ev.id, "%.(%a+)_?%d*$")
			if tail == "field" then
				set_focus(state, "add")
			elseif tail == "notes" then
				set_focus(state, "notes")
			elseif tail == "title" then
				set_focus(state, "title")
			elseif tail == "jurl" or tail == "jemail" or tail == "jtoken" then
				set_focus(state, tail)
			end
			return
		end
		if ev.ev == "edit" or ev.ev == "undo" then
			local f = if type(ev.id) == "string" then field_of(state, ev.id) else nil
			if f then
				local what = if ev.ev == "undo" then (if undo_step(f, false) then "text" else nil) else apply_edit(f, ev)
				if what == "text" then
					field_changed(state)
					if state.focus == "picker" then
						request_listing(state)
					end
				end
			end
			return
		end
		if (ev.ev == "select" or ev.ev == "activate") and state.pick and type(ev.item) == "string" then
			-- One click picks, as the popover did before it became a sheet.
			local it = picker_items(state)[tonumber(string.sub(ev.item, 2)) or 0]
			if it then
				apply_pick(state, state.pick.kind, if it.kind == "none" then nil else it.path)
			end
			return
		end
		if ev.ev ~= "action" then
			return
		end
		local act, value = ev.act, ev.value
		if state.focus == "title" or state.focus == "notes" or state.focus == "jx" then
			-- A new task's notes and Jira fields hand back to its add row, so the card's buttons
			-- still see it.
			set_focus(state, if state.fresh and state.focus ~= "title" then "add" else nil)
		end
		if jira.event(state, act, value) then
			return
		end
		local t = selected(state)
		-- Anything but a row click, the grip or a row double click puts a picked-up task down.
		if state.lift and act ~= "sel" and act ~= "lift" and act ~= "open" and act ~= "tap" then
			state.lift = nil
		end
		if act == "worktree" then
			toggle_setting(state, "new_chat_worktree")
			return
		end
		if act == "sel" and type(value) == "string" then
			if state.focus then
				state.pick = nil
				set_focus(state, nil)
			end
			local m = mods_of(ev)
			local carried = state.lift
			if m.meta or m.ctrl then
				toggle_mark(state, value)
			elseif m.shift then
				state.lift = nil
				state.cursor = value
				state.detail_open = true
				select_range(state, value)
			else
				if carried then
					-- The click drops the picked-up task here; it stays selected.
					state.lift = nil
					if carried ~= value then
						reorder(state, carried, value)
					end
					value = carried
				end
				clear_sel(state)
				state.anchor = value
				state.cursor = value
				state.detail_open = true
			end
		elseif act == "lift" and type(value) == "string" then
			if repeated(state, "lift=" .. value) then
				return
			end
			if state.focus then
				state.pick = nil
				set_focus(state, nil)
			end
			if state.lift == value then
				state.lift = nil
			else
				if state.cursor ~= value then
					clear_confirm(state)
				end
				state.cursor = value
				state.lift = value
				clear_sel(state)
			end
		elseif act == "open" and type(value) == "string" then
			-- Double click: select the row, open its card, then do what Enter does.
			if state.focus then
				state.pick = nil
				set_focus(state, nil)
			end
			state.lift = nil
			clear_sel(state)
			if state.cursor ~= value then
				clear_confirm(state)
			end
			state.cursor = value
			state.detail_open = true
			refresh_cfg(state)
			if state.cfg.dblclick then
				for _, candidate in state.todos do
					if candidate.id == value then
						activate(state, candidate)
					end
				end
			end
		elseif (act == "rarch" or act == "rdel") and type(value) == "string" then
			-- A button on the row itself: it acts on that task alone, whatever is selected.
			if act == "rarch" and repeated(state, act .. "=" .. value) then
				return
			end
			local target: Todo? = nil
			for _, candidate in state.todos do
				if candidate.id == value then
					target = candidate
				end
			end
			if target then
				if act == "rarch" or next(state.sel) ~= nil then
					clear_sel(state)
				end
				if act == "rarch" then
					archive_toggle(state, target)
				else
					delete_one(state, target)
				end
			end
		elseif act == "settings" then
			open_settings(state)
		elseif act == "mv" then
			step(state, if value == "up" then -1 else 1)
		elseif act == "tap" then
			-- The double click on a glyph or grip: its clicks already ran, and having an
			-- action of its own keeps it from reaching the row's double click.
		elseif act == "toggle" and type(value) == "string" then
			toggle_done(state, value)
		elseif act == "close" then
			if state.focus == "notes" then
				set_focus(state, nil)
			end
			clear_confirm(state)
			state.detail_open = false
		elseif act == "glyph" and type(value) == "string" then
			if repeated(state, "glyph=" .. value) then
				return
			end
			local target: Todo? = nil
			for _, candidate in state.todos do
				if candidate.id == value then
					target = candidate
				end
			end
			if target then
				local kind = status_of(state, target, live_panes())
				if kind == "todo" or kind == "done" then
					toggle_done(state, value)
				else
					activate(state, target)
				end
			end
		elseif act == "prio" and t then
			cycle_priority(state, t)
		elseif act == "autotitle" and t then
			toggle_auto_title(state, t)
		elseif act == "level" and t then
			cycle_level(state, t)
		elseif act == "primary" and t then
			activate(state, t)
		elseif act == "add" then
			if not card.add(state) and trim(state.add.text) == "" then
				state.cx:toast("warning", "Type the task's title first")
				set_focus(state, "add")
			end
		elseif act == "pick" and type(value) == "string" then
			if state.pick and state.pick.kind == value then
				close_picker(state)
			else
				open_picker(state, value)
			end
		elseif act == "pick-close" then
			close_picker(state)
		elseif act == "pick-use" and state.pick then
			picker_key(state, { name = "enter" } :: any)
		elseif act == "tab" and (value == "tasks" or value == "backlog" or value == "tickets") then
			switch_tab(state, value)
		elseif act == "rdone" and type(value) == "string" then
			if repeated(state, "rdone=" .. value) then
				return
			end
			clear_sel(state)
			toggle_done(state, value)
		elseif act == "rback" and type(value) == "string" then
			if repeated(state, "rback=" .. value) then
				return
			end
			for _, candidate in state.todos do
				if candidate.id == value then
					clear_sel(state)
					backlog_toggle(state, candidate)
				end
			end
		elseif act == "donehead" then
			toggle_done_open(state)
		elseif act == "arch" then
			toggle_archived(state)
		elseif act == "bulk" then
			bulk_action(state, value)
		end
	end,
})
