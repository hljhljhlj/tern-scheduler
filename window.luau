-- Window half: Tern's UI side. Keeps the schedule in tern.kv, delivers the
-- prompt into one fixed omp block, and records the last runs for `Patrol: status`.
local CWD = "~/Project"
local INTERVAL_MS = 6 * 3600 * 1000
local LATE_MS = 2 * 3600 * 1000
local TICK_MS = 30 * 1000
local HISTORY = 10
local OWNER_STALE_MS = 15 * 60 * 1000
local HEARTBEAT_MS = 5 * 60 * 1000
local OLD_TASK = "pityplan patrol"

local function now_ms()
	return os.time() * 1000
end

local function state()
	return tern.kv.get("state") or {}
end

local function save(s)
	tern.kv.set("state", s)
end

local function test_mode()
	return tern.fs.exists(tern.plugin.dir .. "/test-once")
end

local function interval()
	return test_mode() and 60 * 1000 or INTERVAL_MS
end

local function prompt_text()
	local name = test_mode() and "test-prompt.md" or "prompt.md"
	return tern.fs.read(tern.plugin.dir .. "/" .. name)
end

local function usable(cx, pane)
	if type(pane) ~= "number" then
		return false
	end
	local info = cx.session:pane(pane)
	return info ~= nil and info.kind == "agent"
end

local function target(cx)
	local s = state()
	if usable(cx, s.pane) then
		return s.pane
	end
	local titled = cx.session:resolve("patrol")
	if usable(cx, titled) then
		return titled
	end
	return nil
end

local function deliver(cx, prompt)
	local pane = target(cx)
	if pane then
		cx.agents:ask(pane, prompt)
		return pane, false
	end
	local created = cx.agents:start({ prompt = prompt, cwd = CWD, how = "tab" })
	return created, true
end

local function record(s, outcome, detail)
	s.runs = s.runs or {}
	table.insert(s.runs, { at = now_ms(), outcome = outcome, detail = detail })
	while #s.runs > HISTORY do
		table.remove(s.runs, 1)
	end
end

local function when_text(ms)
	if type(ms) ~= "number" then
		return "unscheduled"
	end
	return os.date("%Y-%m-%d %H:%M", math.floor(ms / 1000))
end

local function drop_old_task()
	for _, task in ipairs(tern.carly.tasks()) do
		if task.title == OLD_TASK and task.by == "plugin:" .. tern.plugin.id then
			tern.carly.cancel(task.id)
			tern.log.warn("patrol: cancelled old task", tostring(task.id))
		end
	end
end

-- One window owns the schedule. The owner refreshes a heartbeat; another window
-- takes over only when that heartbeat is older than OWNER_STALE_MS.
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

local function tick(cx)
	local s = state()
	local now = now_ms()
	local owns, dirty = own(cx, s, now)
	if dirty then
		save(s)
	end
	if not owns then
		tern.timer(TICK_MS, tick)
		return
	end
	if type(s.next) ~= "number" then
		s.next = now + interval()
		save(s)
	elseif now >= s.next then
		local due = s.next
		s.next = now + interval()
		save(s) -- claim the slot before delivering, so a second window skips it
		if now - due > LATE_MS then
			record(s, "missed")
		else
			local ok, pane, created = pcall(function()
				return deliver(cx, prompt_text())
			end)
			if ok then
				s.pane = pane
				record(s, created and "opened" or "sent")
			else
				record(s, "failed", tostring(pane))
				cx:toast("error", "patrol: run failed", tostring(pane))
			end
		end
		s.next = now + interval()
		save(s)
	end
	tern.timer(TICK_MS, tick)
end

tern.command({
	id = "run",
	title = "Patrol: run now",
	icon = "play",
	run = function(cx)
		local ok, pane, created = pcall(function()
			return deliver(cx, prompt_text())
		end)
		if not ok then
			cx:toast("error", "patrol: run failed", tostring(pane))
			return
		end
		local s = state()
		s.pane = pane
		record(s, "manual")
		save(s)
		cx:toast("info", "patrol: 已投递", created and ("新 block " .. pane) or ("block " .. pane))
	end,
})

tern.command({
	id = "pin",
	title = "Patrol: pin this block",
	icon = "pin",
	run = function(cx)
		local focused = cx.session:focused()
		if not focused then
			cx:toast("error", "patrol: 没有聚焦的 block")
			return
		end
		local ok, err = pcall(cx.agents.get, cx.agents, focused)
		if not ok then
			cx:toast("error", "patrol: 聚焦的不是 agent block", tostring(err))
			return
		end
		local s = state()
		s.pane = focused
		save(s)
		cx:toast("success", "patrol: 目标已固定", "pane " .. focused)
	end,
})

tern.command({
	id = "status",
	title = "Patrol: status",
	icon = "clock",
	run = function(cx)
		local s = state()
		local last = s.runs and s.runs[#s.runs]
		cx:toast(
			"info",
			"patrol: next " .. when_text(s.next),
			last and (when_text(last.at) .. " " .. last.outcome) or "no runs yet"
		)
	end,
})

tern.timer(1000, function(cx)
	pcall(drop_old_task)
	tick(cx)
end)
