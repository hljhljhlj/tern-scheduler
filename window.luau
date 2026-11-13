-- Prompt Scheduler, window half: keeps each task's next run in tern.kv and
-- delivers its prompt into one fixed agent block per task.
local TICK_MS = 30 * 1000
local LATE_MS = 2 * 3600 * 1000
local MIN_INTERVAL_MS = 30 * 1000
local HISTORY = 10
local OWNER_STALE_MS = 15 * 60 * 1000
local HEARTBEAT_MS = 5 * 60 * 1000
local UNITS = { s = 1000, m = 60 * 1000, h = 3600 * 1000, d = 24 * 3600 * 1000 }
local warned = {}

local function warn_once(key, text)
	if warned[key] then
		return false
	end
	warned[key] = true
	tern.log.warn("scheduler: " .. text)
	return true
end

local function now_ms()
	return os.time() * 1000
end

local function state()
	return tern.kv.get("state") or {}
end

local function save(s)
	tern.kv.set("state", s)
end

local function task_state(s, id)
	s.tasks = s.tasks or {}
	if s.tasks[id] == nil then
		s.tasks[id] = {}
	end
	return s.tasks[id]
end

-- Returns the task list, or nil plus a reason when the configuration cannot be
-- read. The caller surfaces the reason instead of silently doing nothing.
local function tasks()
	local ok, raw = pcall(tern.fs.read, tern.plugin.dir .. "/tasks.json")
	if not ok then
		return nil, "cannot read tasks.json: " .. tostring(raw)
	end
	local ok_json, parsed = pcall(tern.json.decode, raw)
	if not ok_json or type(parsed) ~= "table" then
		return nil, "tasks.json is not a JSON array"
	end
	return parsed
end

local function test_mode()
	return tern.fs.exists(tern.plugin.dir .. "/test-once")
end

local function interval_ms(task)
	if test_mode() then
		return 60 * 1000
	end
	local n, unit = tostring(task.every or ""):match("^(%d+)([smhd])$")
	if not n then
		return nil
	end
	local ms = tonumber(n) * UNITS[unit]
	if ms < MIN_INTERVAL_MS then
		return nil
	end
	return ms
end

local function prompt_text(task)
	local name = tostring(task.prompt or "")
	if test_mode() then
		name = string.gsub(name, "%.md$", ".test.md")
	end
	return tern.fs.read(tern.plugin.dir .. "/" .. name)
end

local function usable(cx, pane)
	if type(pane) ~= "number" then
		return false
	end
	local info = cx.session:pane(pane)
	return info ~= nil and info.kind == "agent"
end

local function hash_tail(text)
	local h = 5381
	for i = 1, #text do
		h = (h * 33 + string.byte(text, i)) % 2147483647
	end
	return h
end

-- Conversation fingerprint: message count plus a hash of the last message. A
-- block that switched to a different conversation no longer matches, so the
-- task reopens its own block instead of prompting a stranger's chat.
local function fingerprint(cx, pane)
	local ok, list = pcall(cx.agents.transcript, cx.agents, pane, { last = 1000 })
	if not ok or type(list) ~= "table" then
		return nil
	end
	local last = list[#list]
	return { n = #list, tail = hash_tail(last and last.text or "") }
end

-- An empty transcript means "unknown", not "a different conversation": a
-- fingerprint captured before the block took its first prompt must never
-- trigger a reopen.
local function fp_matches(fp, now_fp)
	if fp == nil or fp.n == 0 or now_fp == nil then
		return true
	end
	return now_fp.n == fp.n and now_fp.tail == fp.tail
end

-- Agent panes inside task.place's session (and tab, when named). The title
-- fallback only ever considers these, so a same-named pane elsewhere can no
-- longer receive the prompt.
local function scoped_panes(cx, task)
	local place = type(task.place) == "table" and task.place or nil
	if not place or not place.session then
		return nil
	end
	local session = cx.session:find_session(tostring(place.session))
	if not session then
		return {}
	end
	local tabs = {}
	for _, tab in ipairs(cx.session:tabs()) do
		if tab.session == session and (not place.tab or tab.name == tostring(place.tab)) then
			tabs[tab.id] = true
		end
	end
	local panes = {}
	for _, info in ipairs(cx.session:panes()) do
		if tabs[info.tab] and info.kind == "agent" then
			panes[#panes + 1] = info
		end
	end
	return panes
end

local function target(cx, task, ts)
	if usable(cx, ts.pane) then
		if fp_matches(ts.fp, fingerprint(cx, ts.pane)) then
			return ts.pane
		end
		warn_once("drift:" .. task.id, task.id .. ": pinned block changed conversation; reopening")
		return nil
	end
	local scoped = scoped_panes(cx, task)
	if scoped then
		for _, info in ipairs(scoped) do
			if fp_matches(ts.fp, fingerprint(cx, info.pane)) then
				return info.pane
			end
		end
		return nil
	end
	-- No placement configured: title lookup, but only at the task's own cwd.
	for _, spec in ipairs({ task.id, task.title }) do
		local resolved = cx.session:resolve(tostring(spec))
		if usable(cx, resolved) then
			local info = cx.session:pane(resolved)
			if not task.cwd or info.cwd == task.cwd then
				return resolved
			end
		end
	end
	return nil
end

-- Moves a freshly opened block to where task.place asks for it:
--   { "session": "name" }                     a dedicated session (created if missing)
--   { "session": "name", "tab": "name" }      ... into that session's tab (created if missing)
--   { "tab": "name" }                         that tab in the current session
local function plain_shell(cx, tab)
	for _, info in ipairs(cx.session:panes()) do
		if info.tab == tab and info.command == nil and info.program ~= nil then
			return info.pane
		end
	end
	return nil
end

local function place_block(cx, pane, p)
	local session, born_tab
	if p.session then
		session = cx.session:find_session(tostring(p.session))
		if not session then
			local made = cx.sessions:create({ name = tostring(p.session) })
			session = made and made.id
			-- A new session is born with one empty shell tab; remember it so the
			-- block's own tab can replace it.
			for _, info in ipairs(cx.session:sessions()) do
				if info.id == session then
					born_tab = info.tabs and info.tabs[1]
				end
			end
		end
	else
		local current = cx.sessions:current()
		session = current and current.id
	end
	if not session then
		return false
	end
	local moved
	if p.tab then
		local tab = cx.session:find_tab(tostring(p.tab), session)
		if tab then
			moved = cx.layout:move_to_tab(pane, tab, { focus = false }) and tab
		end
	end
	if not moved then
		local tab = cx.layout:move_to_new_tab(pane, session, { focus = false })
		if tab and p.tab then
			cx.layout:name_tab(tab, tostring(p.tab))
		end
		moved = tab
	end
	if born_tab and moved ~= born_tab then
		local shell = plain_shell(cx, born_tab)
		if shell then
			pcall(function()
				cx.layout:close(shell)
			end)
		end
	end
	return moved ~= nil
end

-- Returns pane, created, note. note is set when the block opened but could not
-- be moved to task.place, so the caller can surface it instead of reporting a
-- clean "opened".
local function deliver(cx, task, ts, prompt)
	local pane = target(cx, task, ts)
	if pane then
		cx.agents:ask(pane, prompt)
		return pane, false, nil
	end
	local created = cx.agents:start({ prompt = prompt, cwd = task.cwd or "~", how = "tab" })
	local note
	if type(task.place) == "table" then
		local ok, placed = pcall(place_block, cx, created, task.place)
		if not ok then
			note = "place error: " .. tostring(placed)
		elseif not placed then
			note = "place failed; block stays in the current session"
		end
	end
	return created, true, note
end

-- The prompt lands in the block's transcript only after the block takes it,
-- so the fingerprint is retried with growing delays until the transcript is
-- non-empty.
local function refresh_fp(task_id, pane)
	local delays = { 4000, 11000, 30000, 60000 }
	local function attempt(i)
		tern.timer(delays[i], function(cx)
			local settled = false
			local ok = pcall(function()
				local fp = fingerprint(cx, pane)
				if fp and fp.n > 0 then
					local s = state()
					local ts = task_state(s, task_id)
					if ts.pane == pane then
						ts.fp = fp
						save(s)
					end
					settled = true
				end
			end)
			if not ok then
				warn_once("fp:" .. task_id, task_id .. ": fingerprint refresh failed")
				settled = true
			end
			if not settled and i < #delays then
				attempt(i + 1)
			elseif not settled then
				warn_once("fp:" .. task_id, task_id .. ": transcript still empty; fingerprint left unknown")
			end
		end)
	end
	attempt(1)
end

local function record(ts, outcome, detail)
	ts.runs = ts.runs or {}
	table.insert(ts.runs, { at = now_ms(), outcome = outcome, detail = detail })
	while #ts.runs > HISTORY do
		table.remove(ts.runs, 1)
	end
end

local function when_text(ms)
	if type(ms) ~= "number" then
		return "unscheduled"
	end
	return os.date("%Y-%m-%d %H:%M", math.floor(ms / 1000))
end

-- One window owns the schedule; the owner refreshes a heartbeat and another
-- window takes over only once that heartbeat is stale.
local function own(cx, s, now)
	local key = cx:window_key()
	if s.owner == key then
		if type(s.heartbeat) ~= "number" or now - s.heartbeat >= HEARTBEAT_MS then
			s.heartbeat = now
			return true, true
		end
		return true, false
	end
	if type(s.owner) == "string" and type(s.heartbeat) == "number" and now - s.heartbeat < OWNER_STALE_MS then
		return false, false
	end
	s.owner = key
	s.heartbeat = now
	return true, true
end

-- A due slot is claimed in kv before anything is delivered: the claim (the new
-- next) is saved first, re-read, and only the window whose token survived
-- delivers. A crash can therefore lose a run, never duplicate one.
local function run_task(cx, task, s, now)
	local ts = task_state(s, task.id)
	local interval = interval_ms(task)
	if not interval then
		return false
	end
	local dirty = false
	if ts.interval ~= interval then
		local had_interval = type(ts.interval) == "number"
		ts.interval = interval
		-- Adopt the interval without moving an already-armed slot (state written
		-- by older versions has no interval); recompute only real changes.
		if had_interval or type(ts.next) ~= "number" then
			ts.next = now + interval
		end
		dirty = true
	end
	if type(ts.next) ~= "number" then
		ts.next = now + interval
		return true
	end
	if now < ts.next then
		return dirty
	end
	local due = ts.next
	ts.next = now + interval
	local token = tostring(now) .. ":" .. cx:window_key()
	ts.claim = token
	local saved = pcall(save, s)
	if not saved then
		-- The claim never reached disk; forget it and retry on the next tick.
		ts.next = due
		ts.claim = nil
		return false
	end
	local fresh = state()
	local fts = ((fresh.tasks or {})[task.id])
	if type(fts) ~= "table" or fts.claim ~= token then
		return false
	end
	if now - due > LATE_MS then
		record(ts, "missed")
		save(s)
		return true
	end
	local ok, pane, created, note = pcall(deliver, cx, task, ts, prompt_text(task))
	if ok then
		ts.pane = pane
		record(ts, created and "opened" or "sent", note)
		if note then
			cx:toast("error", task.id .. ": " .. note, nil)
		end
		refresh_fp(task.id, pane)
	else
		record(ts, "failed", tostring(pane))
		cx:toast("error", task.id .. ": run failed", tostring(pane))
	end
	save(s)
	return true
end

local function tick(cx)
	local ok, err = pcall(function()
		local s = state()
		local now = now_ms()
		local owns, dirty = own(cx, s, now)
		if dirty then
			save(s)
		end
		if not owns then
			return
		end
		local list, cfg_err = tasks()
		if cfg_err then
			if warn_once("config", cfg_err) then
				cx:toast("error", "scheduler: " .. cfg_err, nil)
			end
			return
		end
		for _, task in ipairs(list) do
			if type(task) == "table" and type(task.id) == "string" then
				if not interval_ms(task) then
					if warn_once("every:" .. task.id, task.id .. ": bad every " .. tostring(task.every)) then
						cx:toast("error", "scheduler: " .. task.id .. ": bad every " .. tostring(task.every), nil)
					end
				else
					local ok_run, changed = pcall(run_task, cx, task, s, now_ms())
					dirty = dirty or (ok_run and changed)
				end
			end
		end
		if dirty then
			save(s)
		end
	end)
	if not ok then
		tern.log.warn("scheduler: tick failed: " .. tostring(err))
	end
	tern.timer(TICK_MS, tick)
end

local function items()
	local s = state()
	local list = {}
	for _, task in ipairs(tasks()) do
		local ts = (s.tasks or {})[task.id] or {}
		local last = ts.runs and ts.runs[#ts.runs]
		table.insert(list, {
			label = task.title or task.id,
			detail = "next " .. when_text(ts.next)
				.. (last and (" · last " .. when_text(last.at) .. " " .. last.outcome) or " · no runs"),
			task = task,
		})
	end
	return list
end

tern.command({
	id = "tasks",
	title = "Scheduler: tasks",
	icon = "list",
	run = function(cx)
		local list = items()
		if #list == 0 then
			cx:toast("info", "scheduler: tasks.json 里没有任务")
			return
		end
		cx:pick({ items = list, placeholder = "选择任务，回车立即运行" }):next(function(choice, err, pick_cx)
			if not choice or not pick_cx then
				return
			end
			local task = choice.task
			local ok, pane, created, note = pcall(function()
				local s = state()
				local ts = task_state(s, task.id)
				local pane, created, note = deliver(pick_cx, task, ts, prompt_text(task))
				ts.pane = pane
				record(ts, "manual", note)
				save(s)
				return pane, created, note
			end)
			if not ok then
				pick_cx:toast("error", task.id .. ": run failed", tostring(pane))
				return
			end
			refresh_fp(task.id, pane)
			if note then
				pick_cx:toast("error", task.id .. ": " .. note, nil)
			end
			pick_cx:toast("info", task.id .. ": 已投递", created and ("新 block " .. pane) or ("block " .. pane))
		end)
	end,
})

tern.command({
	id = "pin",
	title = "Scheduler: pin this block",
	icon = "pin",
	run = function(cx)
		local focused = cx.session:focused()
		if not focused then
			cx:toast("error", "scheduler: 没有聚焦的 block")
			return
		end
		local ok, err = pcall(cx.agents.get, cx.agents, focused)
		if not ok then
			cx:toast("error", "scheduler: 聚焦的不是 agent block", tostring(err))
			return
		end
		local list = items()
		if #list == 0 then
			cx:toast("info", "scheduler: tasks.json 里没有任务")
			return
		end
		cx:pick({ items = list, placeholder = "把聚焦的 block 固定给哪个任务" }):next(function(choice, _err, pick_cx)
			if not choice or not pick_cx then
				return
			end
			local s = state()
			local ts = task_state(s, choice.task.id)
			ts.pane = focused
			ts.fp = fingerprint(pick_cx, focused)
			save(s)
			pick_cx:toast("success", choice.task.id .. ": 目标已固定", "pane " .. focused)
		end)
	end,
})

tern.command({
	id = "status",
	title = "Scheduler: status",
	icon = "clock",
	run = function(cx)
		local list = items()
		if #list == 0 then
			cx:toast("info", "scheduler: tasks.json 里没有任务")
			return
		end
		local nearest
		for _, item in ipairs(list) do
			local ts = ((state().tasks or {})[item.task.id]) or {}
			if type(ts.next) == "number" and (nearest == nil or ts.next < nearest) then
				nearest = ts.next
			end
		end
		cx:toast("info", "scheduler: " .. #list .. " 个任务", "最近一次 " .. when_text(nearest))
	end,
})

tern.timer(1000, tick)
