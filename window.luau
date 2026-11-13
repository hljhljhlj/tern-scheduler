-- Prompt Scheduler, window half: keeps each task's next run in tern.kv and
-- delivers its prompt into one fixed agent block per task.
local TICK_MS = 30 * 1000
local LATE_MS = 2 * 3600 * 1000
local HISTORY = 10
local OWNER_STALE_MS = 15 * 60 * 1000
local HEARTBEAT_MS = 5 * 60 * 1000
local UNITS = { s = 1000, m = 60 * 1000, h = 3600 * 1000, d = 24 * 3600 * 1000 }

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

local function tasks()
	local ok, raw = pcall(tern.fs.read, tern.plugin.dir .. "/tasks.json")
	if not ok then
		return {}
	end
	local ok_json, parsed = pcall(tern.json.decode, raw)
	if not ok_json or type(parsed) ~= "table" then
		return {}
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
	return tonumber(n) * UNITS[unit]
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

local function target(cx, task, ts)
	if usable(cx, ts.pane) then
		return ts.pane
	end
	for _, spec in ipairs({ task.id, task.title }) do
		local resolved = cx.session:resolve(tostring(spec))
		if usable(cx, resolved) then
			return resolved
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

local function deliver(cx, task, ts, prompt)
	local pane = target(cx, task, ts)
	if pane then
		cx.agents:ask(pane, prompt)
		return pane, false
	end
	local created = cx.agents:start({ prompt = prompt, cwd = task.cwd or "~", how = "tab" })
	if type(task.place) == "table" then
		local ok, err = pcall(place_block, cx, created, task.place)
		if not ok then
			tern.log.warn(task.id .. ": place failed: " .. tostring(err))
		end
	end
	return created, true
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

-- Claims the slot before delivering, so a second window cannot double-run it.
local function run_task(cx, task, s, now)
	local ts = task_state(s, task.id)
	local interval = interval_ms(task)
	if not interval then
		return false
	end
	local dirty = false
	if type(ts.next) ~= "number" then
		ts.next = now + interval
		return true
	end
	local now2 = now_ms()
	if now2 < ts.next then
		return false
	end
	local due = ts.next
	ts.next = now2 + interval
	dirty = true
	if now2 - due > LATE_MS then
		record(ts, "missed")
	else
		local ok, pane, created = pcall(function()
			return deliver(cx, task, ts, prompt_text(task))
		end)
		if ok then
			ts.pane = pane
			record(ts, created and "opened" or "sent")
		else
			record(ts, "failed", tostring(pane))
			cx:toast("error", task.id .. ": run failed", tostring(pane))
		end
	end
	return dirty
end

local function tick(cx)
	local s = state()
	local now = now_ms()
	local owns, dirty = own(cx, s, now)
	if dirty then
		save(s)
	end
	if owns then
		for _, task in ipairs(tasks()) do
			local ok, changed = pcall(run_task, cx, task, s, now_ms())
			dirty = dirty or (ok and changed)
		end
		if dirty then
			save(s)
		end
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
			local ok, pane, created = pcall(function()
				local s = state()
				local ts = task_state(s, task.id)
				local pane, created = deliver(pick_cx, task, ts, prompt_text(task))
				record(ts, "manual")
				save(s)
				return pane, created
			end)
			if ok then
				pick_cx:toast("info", task.id .. ": 已投递", created and ("新 block " .. pane) or ("block " .. pane))
			else
				pick_cx:toast("error", task.id .. ": run failed", tostring(pane))
			end
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
			task_state(s, choice.task.id).pane = focused
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
