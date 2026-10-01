--!strict

local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace        = game:GetService("Workspace")
local HttpService      = game:GetService("HttpService")
local TweenService     = game:GetService("TweenService")

local LP     = Players.LocalPlayer
local Camera = Workspace.CurrentCamera

type Vec3 = Vector3
type Vec2 = Vector2
type AnyFn = (...any) -> ...any

type TargetInfo = {
	model: Model,
	hum: Humanoid,
	part: BasePart,
	bonePos: Vec3,
	screen: Vec2,
	worldDist: number,
	score: number,
	visible: boolean,
}

local Compat = {}

Compat.has = function(name: string): boolean
	return typeof((_G :: any)[name]) == "function"
end

Compat.call = function(name: string, ...: any): any
	local fn = (_G :: any)[name]
	if typeof(fn) ~= "function" then return nil end
	local ok, res = pcall(fn, ...)
	if not ok then return nil end
	return res
end

Compat.getclipboard = function(): string?
	if Compat.has("getclipboard") then
		return Compat.call("getclipboard")
	end
	return nil
end

Compat.setclipboard = function(text: string): boolean
	if Compat.has("setclipboard") then
		return Compat.call("setclipboard", text) ~= nil
	end
	if Compat.has("toclipboard") then
		return Compat.call("toclipboard", text) ~= nil
	end
	return false
end

Compat.getgenv = function(): {[string]: any}
	if Compat.has("getgenv") then
		local g = Compat.call("getgenv")
		if type(g) == "table" then return g end
	end
	return (_G :: any)
end

Compat.gethui = function(): Instance?
	if Compat.has("gethui") then
		local h = Compat.call("gethui")
		if typeof(h) == "Instance" then return h end
	end
	return nil
end

Compat.protectgui = function(gui: Instance)
	if Compat.has("protectgui") then
		pcall(function()
			(_G :: any).protectgui(gui)
		end)
	end
end

Compat.getUIParent = function(): Instance
	local hui = Compat.gethui()
	if hui then return hui end
	local ok, cg = pcall(function() return game:GetService("CoreGui") end)
	if ok and cg then return cg end
	return LP:WaitForChild("PlayerGui")
end

local GLog = (function()
	local LEVELS = { DEBUG = 1, INFO = 2, WARN = 3, ERROR = 4 }
	local ICONS = { DEBUG = "·", INFO = "i", WARN = "!", ERROR = "X" }

	local Logger = {}
	Logger.__index = Logger

	function Logger.new(prefix: string, level: string?)
		return setmetatable({
			prefix = prefix,
			level = level or "INFO",
			history = {},
		}, Logger)
	end

	function Logger:log(level: string, ...: any)
		if LEVELS[level] < LEVELS[self.level] then return end
		local parts = {}
		for _, v in ipairs({...}) do
			table.insert(parts, typeof(v) == "Instance" and v:GetFullName() or tostring(v))
		end
		local line = string.format("[%s %s] %s", ICONS[level], self.prefix, table.concat(parts, " "))
		print(line)
		table.insert(self.history, { level = level, text = line, time = os.clock() })
		if #self.history > 500 then table.remove(self.history, 1) end
	end

	function Logger:debug(...) self:log("DEBUG", ...) end
	function Logger:info(...)  self:log("INFO", ...) end
	function Logger:warn(...)  self:log("WARN", ...) end
	function Logger:error(...) self:log("ERROR", ...) end

	return Logger.new("AA", "INFO")
end)()

local EventBus = {}
EventBus.__index = EventBus

function EventBus.new()
	return setmetatable({ listeners = {}, once = {} }, EventBus)
end

function EventBus:on(event: string, cb: AnyFn): () -> ()
	local list = self.listeners[event]
	if not list then
		list = {}
		self.listeners[event] = list
	end
	table.insert(list, cb)
	return function()
		for i = #list, 1, -1 do
			if list[i] == cb then table.remove(list, i) end
		end
	end
end

function EventBus:once_on(event: string, cb: AnyFn)
	local list = self.once[event]
	if not list then
		list = {}
		self.once[event] = list
	end
	table.insert(list, cb)
end

function EventBus:emit(event: string, ...: any)
	local list = self.listeners[event]
	if list then
		for _, cb in ipairs(list) do
			local ok, err = pcall(cb, ...)
			if not ok then GLog:error("EventBus[" .. event .. "]:", err) end
		end
	end
	local once = self.once[event]
	if once then
		self.once[event] = nil
		for _, cb in ipairs(once) do pcall(cb, ...) end
	end
end

function EventBus:clear()
	self.listeners = {}
	self.once = {}
end

type SchemaEntry = {
	type: string,
	default: any,
	min: number?,
	max: number?,
	enum: {any}?,
	label: string?,
	desc: string?,
	unit: string?,
	page: string?,
	format: string?,
}

local SCHEMA_VERSION = 2

local SCHEMA: {[string]: SchemaEntry} = {
	HOLD_TO_AIM        = { type = "boolean", default = true,  label = "按住右键", desc = "松开停止辅助", page = "main" },
	ONLY_WHEN_FIRING   = { type = "boolean", default = false, label = "仅开火时", desc = "需游戏支持", page = "main" },
	TEAM_CHECK         = { type = "boolean", default = false, label = "队伍检测", desc = "不锁定队友", page = "main" },
	ALIVE_CHECK        = { type = "boolean", default = true,  label = "存活检测", desc = "忽略死亡目标", page = "main" },

	REACTION_TIME_MS   = { type = "number", default = 140, min = 0, max = 500, label = "反应延迟", desc = "发现目标后延迟", unit = " ms", format = "%.0f", page = "reaction" },
	RELEASE_TIME_MS    = { type = "number", default = 80,  min = 0, max = 300, label = "释放延迟", desc = "松手后回正时间", unit = " ms", format = "%.0f", page = "reaction" },

	MOVE_CURVE         = { type = "string", default = "EaseOut", enum = { "Human", "EaseOut", "Linear", "EaseInOut" }, label = "缓动曲线", desc = "相机跟随风格", page = "move" },
	MOVE_SPEED_PEAK    = { type = "number", default = 2400, min = 500, max = 6000, label = "峰值速度", unit = "°/s", format = "%.0f", page = "move" },
	CATCH_UP_POWER     = { type = "number", default = 1.4,  min = 0.5, max = 2.5, label = "追赶指数", desc = "越大越快接近目标", format = "%.2f", page = "move" },

	PREDICTION_ENABLED = { type = "boolean", default = true, label = "移动预测", desc = "预判目标移动", page = "move" },
	PREDICTION_FACTOR  = { type = "number", default = 0.12, min = 0, max = 0.5, label = "预测强度", desc = "提前量系数", format = "%.2f", page = "move" },
	PREDICTION_ACCEL   = { type = "number", default = 0.4, min = 0, max = 1.0, label = "加速度权重", desc = "二次项强度", format = "%.2f", page = "move" },

	JITTER_AMPLITUDE   = { type = "number", default = 0.15, min = 0, max = 1,   label = "抖动幅度", unit = "°", format = "%.2f", page = "reaction" },
	JITTER_FREQUENCY   = { type = "number", default = 6.5,  min = 1, max = 15,  label = "抖动频率", unit = " Hz", format = "%.1f", page = "reaction" },
	BREATH_AMPLITUDE   = { type = "number", default = 0.08, min = 0, max = 0.5, label = "呼吸幅度", unit = "°", format = "%.2f", page = "reaction" },
	BREATH_FREQUENCY   = { type = "number", default = 0.22, min = 0.05, max = 1, label = "呼吸频率", unit = " Hz", format = "%.2f", page = "reaction" },

	FOV_VERTICAL       = { type = "number", default = 75,  min = 20, max = 200, label = "FOV", desc = "垂直视野角度", unit = "°", format = "%.0f", page = "move" },
	DYNAMIC_FOV        = { type = "boolean", default = true, label = "动态 FOV", desc = "随状态缩放视野", page = "move" },
	FOV_AIM_SCALE      = { type = "number", default = 0.7, min = 0.3, max = 1.0, label = "开镜缩放", format = "%.2f", page = "move" },
	MAX_WORLD_DIST     = { type = "number", default = 500, min = 50, max = 2000, label = "最大距离", unit = " studs", format = "%.0f", page = "move" },
	MIN_WORLD_DIST     = { type = "number", default = 3,   min = 0, max = 20,   label = "最小距离", unit = " studs", format = "%.1f", page = "move" },

	TARGET_MODE        = { type = "string", default = "Look", enum = { "Look", "Nearest", "Threat" }, label = "选择方式", desc = "如何决定锁定谁", page = "target" },
	LOOK_DWELL_TIME    = { type = "number", default = 0.20, min = 0, max = 1, label = "停留时间", desc = "视线需停留多久", unit = " s", format = "%.2f", page = "target" },
	STICKY_BONUS       = { type = "number", default = 0.6,  min = 0.1, max = 1.0, label = "粘性", desc = "越小越稳", format = "%.2f", page = "target" },
	LOCK_COOLDOWN      = { type = "number", default = 0.5,  min = 0, max = 2, label = "重锁冷却", unit = " s", format = "%.2f", page = "target" },

	BREAK_ON_FLICK     = { type = "boolean", default = true, label = "急甩解锁", page = "target" },
	FLICK_SPEED        = { type = "number", default = 2000, min = 500, max = 5000, label = "甩动阈值", unit = " px/s", format = "%.0f", page = "target" },
	BREAK_ON_REVERSE   = { type = "boolean", default = true, label = "反向解锁", page = "target" },
	REVERSE_ANGLE      = { type = "number", default = 100, min = 30, max = 180, label = "反向角度", unit = "°", format = "%.0f", page = "target" },

	RECOIL_COMPENSATE  = { type = "boolean", default = false, label = "启用压枪", page = "misc" },
	RECOIL_PITCH       = { type = "number", default = 0.8, min = 0, max = 3, label = "每发下压", unit = "°", format = "%.2f", page = "misc" },
	RECOIL_DECAY       = { type = "number", default = 4, min = 0, max = 15, label = "恢复速度", format = "%.1f", page = "misc" },

	USE_WALL_CHECK     = { type = "boolean", default = true, label = "穿墙检测", desc = "忽略墙后目标", page = "misc" },
	VISIBILITY_EVERY   = { type = "number", default = 4, min = 1, max = 20, label = "检测间隔", unit = " 帧", format = "%.0f", page = "misc" },
	IGNORE_TRANSPARENT = { type = "boolean", default = true, label = "忽略半透明", page = "misc" },
	FRAME_RAY_BUDGET   = { type = "number", default = 4, min = 1, max = 16, label = "帧预算", desc = "每帧最大射线次数", format = "%.0f", page = "misc" },

	BONE_HEAD_WEIGHT   = { type = "number", default = 0.85, min = 0, max = 1, label = "头部权重", format = "%.2f", page = "misc" },
	BONE_TORSO_WEIGHT  = { type = "number", default = 0.15, min = 0, max = 1, label = "胸部权重", format = "%.2f", page = "misc" },

	SHOW_FOV           = { type = "boolean", default = true, label = "显示 FOV", page = "misc" },
	SHOW_TARGET_BOX    = { type = "boolean", default = true, label = "显示目标框", page = "misc" },
	SHOW_TARGET_LINE   = { type = "boolean", default = true, label = "显示锁定连线", page = "misc" },
	SHOW_CROSSHAIR     = { type = "boolean", default = true, label = "显示准星点", page = "misc" },
	SHOW_TARGET_LIST   = { type = "boolean", default = false, label = "显示目标列表", page = "misc" },
}

local Config = {}
Config.__index = Config

function Config.new()
	local self = setmetatable({
		data = {},
		bus = EventBus.new(),
		schema = SCHEMA,
		version = SCHEMA_VERSION,
	}, Config)
	for k, def in pairs(SCHEMA) do
		self.data[k] = def.default
	end
	self.data.__version = SCHEMA_VERSION
	return self
end

function Config:get(key: string): any
	return self.data[key]
end

function Config:set(key: string, value: any)
	local def = SCHEMA[key]
	if not def then GLog:warn("Unknown key: " .. key) return end

	if def.type == "number" then
		if type(value) ~= "number" then return end
		if value ~= value then return end
		if def.min and value < def.min then value = def.min end
		if def.max and value > def.max then value = def.max end
	elseif def.type == "string" then
		if type(value) ~= "string" then return end
		if def.enum then
			local ok = false
			for _, v in ipairs(def.enum) do if v == value then ok = true break end end
			if not ok then return end
		end
	elseif def.type == "boolean" then
		if type(value) ~= "boolean" then return end
	end

	local old = self.data[key]
	if old == value then return end
	self.data[key] = value
	self.bus:emit("changed", key, value, old)
end

function Config:apply(patch: {[string]: any})
	for k, v in pairs(patch) do self:set(k, v) end
end

function Config:reset()
	for k, def in pairs(SCHEMA) do
		self:set(k, def.default)
	end
	self.bus:emit("reset")
end

function Config:serialize(): string
	local out = {}
	for k, v in pairs(self.data) do
		out[k] = v
	end
	out.__version = SCHEMA_VERSION
	return HttpService:JSONEncode(out)
end

function Config:deserialize(json: string): boolean
	local ok, data = pcall(HttpService.JSONDecode, HttpService, json)
	if not ok or type(data) ~= "table" then return false end
	for k, v in pairs(data) do
		if k ~= "__version" then self:set(k, v) end
	end
	return true
end

local Services = {}

Services.CameraService = (function()
	local M = { camera = Camera }

	function M.read(): (Vec3, number, number)
		local cf = M.camera.CFrame
		local look = cf.LookVector
		local yaw = math.atan2(-look.X, -look.Z)
		local pitch = math.asin(math.clamp(look.Y, -1, 1))
		return cf.Position, yaw, pitch
	end

	function M.write(origin: Vec3, yaw: number, pitch: number)
		M.camera.CFrame = CFrame.fromOrientation(pitch, yaw, 0) + origin
	end

	function M.setScriptable()
		if not M._orig then M._orig = M.camera.CameraType end
		M.camera.CameraType = Enum.CameraType.Scriptable
	end

	function M.restore()
		if M._orig then
			M.camera.CameraType = M._orig
			M._orig = nil
		end
	end

	function M.viewport(): Vec2
		return M.camera.ViewportSize
	end

	return M
end)()

Services.InputService = (function()
	local M = { bus = EventBus.new(), connections = {} }
	local lastPos: Vec2? = nil
	local lastDir: Vec2 = Vec2.zero
	local speed = 0

	function M.mouseScreen(): Vec2
		return UserInputService:GetMouseLocation()
	end

	function M.mouseViewport(): Vec2
		local ok, inset = pcall(function() return UserInputService:GetGuiInset() end)
		local gi = (ok and inset) or Vec2.new(0, 36)
		return M.mouseScreen() - gi
	end

	function M.speed(): number return speed end
	function M.direction(): Vec2 return lastDir end

	function M.update(dt: number)
		local p = M.mouseScreen()
		if lastPos then
			local delta = p - lastPos
			speed = delta.Magnitude / math.max(dt, 1/240)
			if delta.Magnitude > 0.01 then lastDir = delta.Unit end
			M.bus:emit("moved", delta, speed)
		end
		lastPos = p
	end

	function M.bindMouse(btn: Enum.UserInputType, onDown: () -> (), onUp: (() -> ())?)
		local c1 = UserInputService.InputBegan:Connect(function(input, gpe)
			if gpe then return end
			if input.UserInputType == btn then onDown() end
		end)
		table.insert(M.connections, c1)
		if onUp then
			local c2 = UserInputService.InputEnded:Connect(function(input)
				if input.UserInputType == btn then onUp() end
			end)
			table.insert(M.connections, c2)
		end
	end

	function M.bindKey(key: Enum.KeyCode, cb: () -> ())
		local c = UserInputService.InputBegan:Connect(function(input, gpe)
			if gpe then return end
			if input.KeyCode == key then cb() end
		end)
		table.insert(M.connections, c)
	end

	function M.disconnect()
		for _, c in ipairs(M.connections) do c:Disconnect() end
		M.connections = {}
	end

	return M
end)()

Services.PlayerCache = (function()
	local M = {}
	local entries: {[Player]: {char: Model?, hum: Humanoid?, head: BasePart?, hrp: BasePart?}} = {}
	local conns = {}

	local function refresh(p: Player)
		local e = entries[p]
		if not e then
			e = {}
			entries[p] = e
		end
		local char = p.Character
		e.char = char
		if char then
			e.hum = char:FindFirstChildOfClass("Humanoid")
			e.head = char:FindFirstChild("Head") :: BasePart?
			e.hrp = char:FindFirstChild("HumanoidRootPart") :: BasePart?
		else
			e.hum, e.head, e.hrp = nil, nil, nil
		end
	end

	local function track(p: Player)
		refresh(p)
		table.insert(conns, p.CharacterAdded:Connect(function() refresh(p) end))
		table.insert(conns, p.CharacterRemoving:Connect(function()
			local e = entries[p]
			if e then e.char, e.hum, e.head, e.hrp = nil, nil, nil, nil end
		end))
	end

	function M.start()
		for _, p in ipairs(Players:GetPlayers()) do
			if p ~= LP then track(p) end
		end
		table.insert(conns, Players.PlayerAdded:Connect(function(p)
			if p ~= LP then track(p) end
		end))
		table.insert(conns, Players.PlayerRemoving:Connect(function(p)
			entries[p] = nil
		end))
	end

	function M.get(p: Player)
		return entries[p]
	end

	function M.all(): {[Player]: any}
		return entries
	end

	function M.stop()
		for _, c in ipairs(conns) do c:Disconnect() end
		conns = {}
		entries = {}
	end

	return M
end)()

Services.VisibilityService = (function()
	local M = {}
	local cache: {[BasePart]: {result: boolean, at: number}} = {}
	local TTL = 0.12
	local frameCount = 0
	local frameUsed = 0
	local budget = 4

	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.IgnoreWater = true

	function M.setBudget(n: number)
		budget = math.max(1, n)
	end

	function M.tickFrame()
		frameCount += 1
		frameUsed = 0
	end

	function M.check(part: BasePart, ignoreTransparent: boolean): boolean
		local now = os.clock()
		local c = cache[part]
		if c and now - c.at < TTL then return c.result end
		if frameUsed >= budget then
			return c and c.result or true
		end
		frameUsed += 1

		rp.FilterDescendantsInstances = { LP.Character, Camera }
		local origin = Camera.CFrame.Position
		local hit = Workspace:Raycast(origin, part.Position - origin, rp)

		local visible = true
		if hit then
			if hit.Instance:IsDescendantOf(part.Parent) then
				visible = true
			elseif ignoreTransparent and hit.Instance.Transparency > 0.7 then
				visible = true
			else
				visible = false
			end
		end

		cache[part] = { result = visible, at = now }
		return visible
	end

	function M.clear() cache = {} end

	return M
end)()

Services.PerformanceService = (function()
	local M = {}
	local samples: {number} = {}
	local SIZE = 90
	local t0 = 0

	function M.begin() t0 = os.clock() end
	function M.endFrame()
		if t0 > 0 then
			table.insert(samples, os.clock() - t0)
			if #samples > SIZE then table.remove(samples, 1) end
		end
	end

	function M.average(): number
		if #samples == 0 then return 0 end
		local s = 0
		for _, v in ipairs(samples) do s += v end
		return s / #samples
	end

	function M.fps(): number
		local avg = M.average()
		return avg > 0 and 1 / avg or 0
	end

	return M
end)()

Services.TargetService = (function()
	local M = {}
	local lastTarget: Model? = nil
	local velTrack: {[Model]: {pos: Vec3, vel: Vec3, accel: Vec3, lastV: Vec3, at: number}} = {}
	local candidateQueue: {Model} = {}
	local queueIndex = 0

	function M.setLastTarget(m: Model?) lastTarget = m end
	function M.getLastTarget(): Model? return lastTarget end

	function M.getVelocity(model: Model): Vec3
		local t = velTrack[model]
		return t and t.vel or Vec3.zero
	end

	function M.getAcceleration(model: Model): Vec3
		local t = velTrack[model]
		return t and t.accel or Vec3.zero
	end

	function M.trackVelocity(model: Model, pos: Vec3, dt: number)
		local t = velTrack[model]
		if t then
			local rawV = (pos - t.pos) / math.max(dt, 1e-4)
			t.vel = t.vel:Lerp(rawV, 0.35)
			local rawA = (t.vel - t.lastV) / math.max(dt, 1e-4)
			t.accel = t.accel:Lerp(rawA, 0.2)
			t.lastV = t.vel
			t.pos = pos
			t.at = os.clock()
		else
			velTrack[model] = {
				pos = pos,
				vel = Vec3.zero,
				accel = Vec3.zero,
				lastV = Vec3.zero,
				at = os.clock(),
			}
		end
	end

	function M.cleanup()
		local now = os.clock()
		for m, t in pairs(velTrack) do
			if now - t.at > 2 then velTrack[m] = nil end
		end
	end

	function M.setQueue(models: {Model})
		candidateQueue = models
		if queueIndex >= #candidateQueue then queueIndex = 0 end
	end

	function M.nextInQueue(): Model?
		if #candidateQueue == 0 then return nil end
		queueIndex = (queueIndex % #candidateQueue) + 1
		return candidateQueue[queueIndex]
	end

	function M.prevInQueue(): Model?
		if #candidateQueue == 0 then return nil end
		queueIndex = queueIndex - 1
		if queueIndex < 1 then queueIndex = #candidateQueue end
		return candidateQueue[queueIndex]
	end

	function M.getQueue(): {Model}
		return candidateQueue
	end

	local BONE_PRIORITY = {
		{ name = "Head",            weight = 1.0, scoreBase = 1.0 },
		{ name = "UpperTorso",      weight = 0.6, scoreBase = 0.75 },
		{ name = "Torso",           weight = 0.5, scoreBase = 0.6 },
		{ name = "HumanoidRootPart", weight = 0.3, scoreBase = 0.4 },
	}

	function M.getAimPartByDistance(char: Model, dist: number): BasePart?
		local idx = 1
		if dist < 80 then idx = 1
		elseif dist < 200 then idx = 2
		elseif dist < 400 then idx = 3
		else idx = 4 end
		local entry = BONE_PRIORITY[math.min(idx, #BONE_PRIORITY)]
		local p = char:FindFirstChild(entry.name)
		if p and p:IsA("BasePart") then return p end
		for _, e in ipairs(BONE_PRIORITY) do
			local q = char:FindFirstChild(e.name)
			if q and q:IsA("BasePart") then return q end
		end
		return nil
	end

	function M.getBonePos(char: Model, hw: number, tw: number): Vec3?
		local head = char:FindFirstChild("Head")
		local torso = char:FindFirstChild("UpperTorso") or char:FindFirstChild("Torso")
		local sum, total = Vec3.zero, 0
		if head and head:IsA("BasePart") then
			sum += head.Position * hw
			total += hw
		end
		if torso and torso:IsA("BasePart") then
			sum += torso.Position * tw
			total += tw
		end
		if total <= 0 then
			local hrp = char:FindFirstChild("HumanoidRootPart")
			return (hrp and hrp:IsA("BasePart")) and hrp.Position or nil
		end
		return sum / total
	end

	function M.getAimPart(char: Model): BasePart?
		for _, e in ipairs(BONE_PRIORITY) do
			local p = char:FindFirstChild(e.name)
			if p and p:IsA("BasePart") then return p end
		end
		return nil
	end

	function M.isValid(model: Model?): boolean
		if not model or not model:IsDescendantOf(Workspace) then return false end
		local hum = model:FindFirstChildOfClass("Humanoid")
		return hum ~= nil and hum.Health > 0
	end

	function M.facingFactor(char: Model, myPos: Vec3): number
		local hrp = char:FindFirstChild("HumanoidRootPart")
		if not (hrp and hrp:IsA("BasePart")) then return 0.5 end
		local toMe = myPos - hrp.Position
		if toMe.Magnitude < 1e-3 then return 0 end
		return (1 - hrp.CFrame.LookVector:Dot(toMe.Unit)) * 0.5
	end

	function M.collect(cfg: Config, mouseV: Vec2): {TargetInfo}
		local cam = Services.CameraService.camera
		local camPos = cam.CFrame.Position
		local vp = cam.ViewportSize
		local aspect = vp.X / math.max(vp.Y, 1)
		local fovV = cfg:get("FOV_VERTICAL")
		if cfg:get("DYNAMIC_FOV") then
			local scale = 1.0
			if state and state.aiming then scale *= cfg:get("FOV_AIM_SCALE") end
			fovV = fovV * scale
		end
		local fovH = fovV * aspect
		local maxD = cfg:get("MAX_WORLD_DIST")
		local minD = cfg:get("MIN_WORLD_DIST")
		local maxD2 = maxD * maxD
		local minD2 = minD * minD
		local hw = cfg:get("BONE_HEAD_WEIGHT")
		local tw = cfg:get("BONE_TORSO_WEIGHT")
		local teamCheck = cfg:get("TEAM_CHECK")
		local aliveCheck = cfg:get("ALIVE_CHECK")
		local myTeam = LP.Team
		local mode = cfg:get("TARGET_MODE")
		local sticky = cfg:get("STICKY_BONUS")

		local list: {TargetInfo} = {}
		local cache = Services.PlayerCache.all()

		for p, entry in pairs(cache) do
			if p == LP then continue end
			if teamCheck and myTeam and p.Team == myTeam then continue end
			local char = entry.char
			if not char then continue end
			local hum = entry.hum
			if not hum then continue end
			if aliveCheck and hum.Health <= 0 then continue end

			local bonePos = M.getBonePos(char, hw, tw)
			if not bonePos then continue end
			local part = entry.head or M.getAimPart(char)
			if not part then continue end

			local offset = bonePos - camPos
			local wd2 = offset.X * offset.X + offset.Y * offset.Y + offset.Z * offset.Z
			if wd2 > maxD2 or wd2 < minD2 then continue end
			local wd = math.sqrt(wd2)

			M.trackVelocity(char, bonePos, 1 / 60)

			local sp, onScreen = cam:WorldToViewportPoint(bonePos)
			if not onScreen or sp.Z <= 0 then continue end

			local v2 = Vec2.new(sp.X, sp.Y)
			local d = v2 - mouseV
			local nx, ny = d.X / (fovH * 0.5), d.Y / (fovV * 0.5)
			local fovTerm = nx * nx + ny * ny
			if fovTerm > 1 then continue end
			fovTerm = math.sqrt(fovTerm)

			local score: number
			if mode == "Look" then
				score = fovTerm
			elseif mode == "Nearest" then
				score = wd / maxD
			else
				local distTerm = wd / maxD
				local healthTerm = hum.Health / math.max(hum.MaxHealth, 1)
				local facingTerm = M.facingFactor(char, camPos)
				score = fovTerm * 0.5 + distTerm * 0.2 + healthTerm * 0.15 + facingTerm * 0.15
			end
			if lastTarget == char then score *= sticky end

			table.insert(list, {
				model = char, hum = hum, part = part,
				bonePos = bonePos, screen = v2,
				worldDist = wd, score = score,
				visible = true,
			})
		end

		table.sort(list, function(a, b) return a.score < b.score end)

		local top: {Model} = {}
		for i = 1, math.min(8, #list) do
			top[i] = list[i].model
		end
		M.setQueue(top)

		return list
	end

	return M
end)()

local Easing = {
	Linear = function(t: number): number return t end,
	EaseOut = function(t: number): number return 1 - (1 - t) ^ 2 end,
	EaseInOut = function(t: number): number
		return t < 0.5 and 2 * t * t or 1 - (-2 * t + 2) ^ 2 / 2
	end,
	Human = function(t: number): number
		if t < 0.15 then return (t / 0.15) ^ 2 * 0.05 end
		if t < 0.7 then return 0.05 + (t - 0.15) / 0.55 * 0.85 end
		return 0.9 + (1 - (1 - (t - 0.7) / 0.3) ^ 2) * 0.1
	end,
}

local Humanizer = {}
Humanizer.__index = Humanizer

function Humanizer.new(cfg: Config)
	return setmetatable({
		cfg = cfg,
		jitterPhase = 0,
		breathPhase = 0,
	}, Humanizer)
end

local function wrapPi(a: number): number
	return ((a + math.pi) % (2 * math.pi)) - math.pi
end

function Humanizer:step(current: number, target: number, dt: number): number
	local delta = wrapPi(target - current)
	local absDelta = math.abs(delta)
	local curve = self.cfg:get("MOVE_CURVE")
	local reach = math.min(1, absDelta / math.rad(15))
	local speedScale = curve == "Human" and (0.25 + 0.75 * reach) or 1
	local peak = math.rad(self.cfg:get("MOVE_SPEED_PEAK")) * speedScale
	local catchUp = (absDelta > math.rad(2)) and 1.0 or (absDelta / math.rad(2))
	catchUp = catchUp ^ self.cfg:get("CATCH_UP_POWER")

	local maxStep = peak * dt * catchUp
	if absDelta <= maxStep then return target end
	return current + math.sign(delta) * maxStep
end

function Humanizer:jitter(dt: number): (number, number)
	self.jitterPhase += dt * self.cfg:get("JITTER_FREQUENCY") * 2 * math.pi
	self.breathPhase += dt * self.cfg:get("BREATH_FREQUENCY") * 2 * math.pi
	local ja = self.cfg:get("JITTER_AMPLITUDE") * math.rad(1)
	local ba = self.cfg:get("BREATH_AMPLITUDE") * math.rad(1)
	local jy = math.sin(self.jitterPhase) * ja
	local jp = math.cos(self.jitterPhase * 1.3) * ja
	local by = math.sin(self.breathPhase) * ba
	local bp = math.sin(self.breathPhase * 0.7) * ba
	return jy + by, jp + bp
end

function Humanizer:applyEasing(progress: number): number
	local curve = self.cfg:get("MOVE_CURVE")
	local fn = Easing[curve] or Easing.Human
	return fn(math.clamp(progress, 0, 1))
end

local Predictor = {}
Predictor.__index = Predictor

function Predictor.new(cfg: Config)
	return setmetatable({ cfg = cfg }, Predictor)
end

function Predictor:predict(model: Model, currentPos: Vec3, projectileSpeed: number): Vec3
	if not self.cfg:get("PREDICTION_ENABLED") then return currentPos end
	local vel = Services.TargetService.getVelocity(model)
	local accel = Services.TargetService.getAcceleration(model)
	local factor = self.cfg:get("PREDICTION_FACTOR")
	local accelFactor = self.cfg:get("PREDICTION_ACCEL")

	local camPos = Camera.CFrame.Position
	local dist = (currentPos - camPos).Magnitude
	local t = 0
	if projectileSpeed > 0 then
		t = dist / projectileSpeed
	else
		t = factor
	end

	local linear = vel * (factor + t)
	local quad = accel * (0.5 * accelFactor * t * t)
	return currentPos + linear + quad
end

local RecoilController = {}
RecoilController.__index = RecoilController

function RecoilController.new(cfg: Config)
	return setmetatable({ cfg = cfg, pitch = 0 }, RecoilController)
end

function RecoilController:add(amount: number)
	if not self.cfg:get("RECOIL_COMPENSATE") then return end
	self.pitch += amount * math.rad(self.cfg:get("RECOIL_PITCH"))
end

function RecoilController:update(dt: number)
	if not self.cfg:get("RECOIL_COMPENSATE") then
		self.pitch = 0
		return
	end
	self.pitch *= math.exp(-self.cfg:get("RECOIL_DECAY") * dt)
end

function RecoilController:get(): number return self.pitch end

local AimState = {
	IDLE      = "idle",
	REACTING  = "reacting",
	LOCKING   = "locking",
	LOCKED    = "locked",
	RELEASING = "releasing",
}

local AimController = {}
AimController.__index = AimController

function AimController.new(cfg: Config, bus: EventBus)
	return setmetatable({
		cfg = cfg,
		bus = bus,
		humanizer = Humanizer.new(cfg),
		recoil = RecoilController.new(cfg),
		predictor = Predictor.new(cfg),

		enabled = false,
		state = AimState.IDLE,

		target = nil :: Model?,
		aimPart = nil :: BasePart?,

		baseYaw = 0, basePitch = 0,
		curYaw = 0, curPitch = 0,

		pendingLockAt = 0,
		releaseAt = 0,
		releaseFromYaw = 0,
		releaseFromPitch = 0,

		lookCandidate = nil :: Model?,
		lookStartAt = 0,
		cooldownUntil = 0,

		frameCount = 0,
		lastCandidates = {},
	}, AimController)
end

function AimController:_setState(s: string)
	if self.state == s then return end
	local old = self.state
	self.state = s
	self.bus:emit("stateChanged", s, old)
end

function AimController:setEnabled(v: boolean)
	if self.enabled == v then return end
	self.enabled = v
	self.bus:emit("enabled", v)

	if v then
		Services.CameraService.setScriptable()
		local _, y, p = Services.CameraService.read()
		self.baseYaw, self.basePitch = y, p
		self.curYaw, self.curPitch = y, p
		self.humanizer.jitterPhase = 0
		self.humanizer.breathPhase = 0
		self.pendingLockAt = os.clock() + self.cfg:get("REACTION_TIME_MS") / 1000
		self:_setState(AimState.REACTING)
	else
		local _, y, p = Services.CameraService.read()
		self.releaseFromYaw, self.releaseFromPitch = y, p
		self.releaseAt = os.clock()
		self.target, self.aimPart = nil, nil
		self.lookCandidate = nil
		self:_setState(AimState.RELEASING)
	end
end

function AimController:cycleTarget(dir: number)
	if not self.enabled then return end
	local q = Services.TargetService.getQueue()
	if #q == 0 then return end
	local next = dir > 0 and Services.TargetService.nextInQueue() or Services.TargetService.prevInQueue()
	if not next then return end
	local part = Services.TargetService.getAimPart(next)
	if not part then return end
	self.target = next
	self.aimPart = part
	Services.TargetService.setLastTarget(next)
	self.bus:emit("targetAcquired", next)
	self:_setState(AimState.LOCKED)
end

function AimController:_unlock(t: number)
	if self.target then self.bus:emit("targetLost", self.target) end
	self.target, self.aimPart = nil, nil
	self.cooldownUntil = t + self.cfg:get("LOCK_COOLDOWN")
	self:_setState(AimState.IDLE)
end

function AimController:_updateTarget(mouseV: Vec2, t: number)
	local cfg = self.cfg

	if self.target and not Services.TargetService.isValid(self.target) then
		self.target, self.aimPart = nil, nil
		self.lookCandidate = nil
	end

	if self.target then
		if cfg:get("BREAK_ON_FLICK") and Services.InputService.speed() > cfg:get("FLICK_SPEED") then
			self:_unlock(t)
		elseif cfg:get("BREAK_ON_REVERSE") then
			local hrp = self.target:FindFirstChild("HumanoidRootPart")
			if hrp and hrp:IsA("BasePart") then
				local sp = Services.CameraService.camera:WorldToViewportPoint(hrp.Position)
				if sp.Z > 0 then
					local dirToT = Vec2.new(sp.X, sp.Y) - mouseV
					if dirToT.Magnitude > 5 then
						local dot = Services.InputService.direction():Dot(dirToT.Unit)
						if dot < -math.cos(math.rad(cfg:get("REVERSE_ANGLE"))) then
							self:_unlock(t)
						end
					end
				end
			end
		end
	end

	if not self.target and t >= self.cooldownUntil then
		local list = Services.TargetService.collect(cfg, mouseV)
		self.lastCandidates = list

		if #list > 0 then
			local best = list[1]

			if cfg:get("USE_WALL_CHECK") then
				local found = nil
				local limit = math.min(cfg:get("FRAME_RAY_BUDGET"), #list)
				for i = 1, limit do
					if Services.VisibilityService.check(list[i].part, cfg:get("IGNORE_TRANSPARENT")) then
						found = list[i]
						break
					end
				end
				if not found then
					self.lookCandidate = nil
					return
				end
				best = found
			end

			if cfg:get("TARGET_MODE") == "Look" then
				if self.lookCandidate ~= best.model then
					self.lookCandidate = best.model
					self.lookStartAt = t
					self:_setState(AimState.LOCKING)
					return
				end
				if t - self.lookStartAt < cfg:get("LOOK_DWELL_TIME") then
					self:_setState(AimState.LOCKING)
					return
				end
			end

			self.target = best.model
			self.aimPart = best.part
			Services.TargetService.setLastTarget(best.model)
			self.bus:emit("targetAcquired", best.model)
			self:_setState(AimState.LOCKED)
		else
			self.lastCandidates = {}
			self:_setState(AimState.IDLE)
		end
	end
end

function AimController:_updateRelease(dt: number)
	if self.releaseAt <= 0 then
		Services.CameraService.restore()
		if self.state == AimState.RELEASING then
			self:_setState(AimState.IDLE)
		end
		return
	end
	local elapsed = os.clock() - self.releaseAt
	local t = elapsed / (self.cfg:get("RELEASE_TIME_MS") / 1000)
	if t >= 1 then
		self.releaseAt = 0
		Services.CameraService.restore()
		self:_setState(AimState.IDLE)
		return
	end
	local pos, _, _ = Services.CameraService.read()
	local decay = 1 - t
	local y = self.releaseFromYaw + (self.curYaw - self.releaseFromYaw) * decay
	local p = self.releaseFromPitch + (self.curPitch - self.releaseFromPitch) * decay
	Services.CameraService.write(pos, y, p)
end

function AimController:update(dt: number)
	self.frameCount += 1
	Services.InputService.update(dt)
	Services.VisibilityService.tickFrame()

	if self.frameCount % 30 == 0 then
		Services.TargetService.cleanup()
	end

	if not self.enabled then
		self:_updateRelease(dt)
		return
	end

	local t = os.clock()
	if t < self.pendingLockAt then return end

	local pos, rawYaw, rawPitch = Services.CameraService.read()
	if Services.InputService.speed() > 100 then
		self.baseYaw, self.basePitch = rawYaw, rawPitch
	end

	local mouseV = Services.InputService.mouseViewport()
	self:_updateTarget(mouseV, t)
	self.recoil:update(dt)

	local desiredYaw, desiredPitch = rawYaw, rawPitch

	if self.target and self.aimPart then
		local bonePos = Services.TargetService.getBonePos(
			self.target,
			self.cfg:get("BONE_HEAD_WEIGHT"),
			self.cfg:get("BONE_TORSO_WEIGHT")
		) or self.aimPart.Position

		bonePos = self.predictor:predict(self.target, bonePos, 0)

		local dir = bonePos - pos
		if dir.Magnitude > 0.1 then
			local u = dir.Unit
			local wantYaw = math.atan2(-u.X, -u.Z)
			local wantPitch = math.asin(math.clamp(u.Y, -1, 1))

			self.curYaw = self.humanizer:step(self.curYaw, wantYaw, dt)
			self.curPitch = self.humanizer:step(self.curPitch, wantPitch, dt)

			local dy = wrapPi(self.curYaw - rawYaw)
			local dp = self.curPitch - rawPitch
			local easedY = self.humanizer:applyEasing(math.min(1, math.abs(dy) / math.rad(20)))
			local easedP = self.humanizer:applyEasing(math.min(1, math.abs(dp) / math.rad(20)))

			desiredYaw = rawYaw + dy * easedY
			desiredPitch = rawPitch + dp * easedP
		end
	else
		local k = math.exp(-8 * dt)
		self.curYaw = self.curYaw + (rawYaw - self.curYaw) * (1 - k)
		self.curPitch = self.curPitch + (rawPitch - self.curPitch) * (1 - k)
		desiredYaw = self.curYaw
		desiredPitch = self.curPitch
	end

	desiredPitch -= self.recoil:get()
	local jy, jp = self.humanizer:jitter(dt)
	desiredYaw += jy
	desiredPitch += jp
	desiredPitch = math.clamp(desiredPitch, -math.rad(89), math.rad(89))
	Services.CameraService.write(pos, desiredYaw, desiredPitch)
end

local Theme = {
	bg         = Color3.fromRGB(16, 17, 21),
	bg2        = Color3.fromRGB(24, 26, 32),
	bg3        = Color3.fromRGB(36, 39, 48),
	bgHover    = Color3.fromRGB(46, 50, 62),
	border     = Color3.fromRGB(50, 54, 68),
	borderSoft = Color3.fromRGB(40, 43, 54),
	text       = Color3.fromRGB(232, 236, 244),
	textDim    = Color3.fromRGB(138, 144, 162),
	textMute   = Color3.fromRGB(94, 100, 118),
	accent     = Color3.fromRGB(96, 168, 255),
	success    = Color3.fromRGB(88, 214, 141),
	warning    = Color3.fromRGB(238, 190, 92),
	danger     = Color3.fromRGB(235, 96, 108),
}

local function new(class: string, props: {[string]: any}?, parent: Instance?): Instance
	local inst = Instance.new(class)
	if props then
		for k, v in pairs(props) do
			(inst :: any)[k] = v
		end
	end
	if parent then inst.Parent = parent end
	return inst
end

local function corner(inst: Instance, r: number?)
	new("UICorner", { CornerRadius = UDim.new(0, r or 6) }, inst)
end

local function stroke(inst: Instance, color: Color3, thickness: number?, transparency: number?)
	return new("UIStroke", {
		Color = color,
		Thickness = thickness or 1,
		Transparency = transparency or 0,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	}, inst)
end

local function pad(inst: Instance, t: number, b: number?, l: number?, r: number?)
	new("UIPadding", {
		PaddingTop = UDim.new(0, t),
		PaddingBottom = UDim.new(0, b or t),
		PaddingLeft = UDim.new(0, l or t),
		PaddingRight = UDim.new(0, r or t),
	}, inst)
end

local function tween(inst: Instance, dur: number, props: {[string]: any})
	local info = TweenInfo.new(dur, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local tw = TweenService:Create(inst, info, props)
	tw:Play()
	return tw
end

local Widgets = {}

function Widgets.card(parent: Instance, order: number): Frame
	local c = new("Frame", {
		Size = UDim2.new(1, 0, 0, 0),
		BackgroundColor3 = Theme.bg2,
		BorderSizePixel = 0,
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = order,
	}, parent) :: Frame
	corner(c, 8)
	stroke(c, Theme.borderSoft, 1, 0.4)
	new("UIListLayout", {
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, 6),
	}, c)
	pad(c, 10, 10, 12, 12)
	return c
end

function Widgets.section(parent: Instance, title: string, sub: string?): Frame
	local wrap = new("Frame", {
		Size = UDim2.new(1, 0, 0, sub and 34 or 20),
		BackgroundTransparency = 1,
	}, parent) :: Frame
	new("TextLabel", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 18),
		Font = Enum.Font.GothamBold,
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = Theme.accent,
		Text = "▎" .. title,
	}, wrap)
	if sub then
		new("TextLabel", {
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 14),
			Position = UDim2.fromOffset(0, 18),
			Font = Enum.Font.Gotham,
			TextSize = 10,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = Theme.textMute,
			Text = sub,
		}, wrap)
	end
	return wrap
end

function Widgets.toggle(parent: Instance, cfg: Config, key: string)
	local def = cfg.schema[key]
	if not def then return end
	local T = Theme

	local row = new("Frame", {
		Size = UDim2.new(1, 0, 0, def.desc and 42 or 28),
		BackgroundTransparency = 1,
	}, parent) :: Frame

	new("TextLabel", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -50, 0, def.desc and 20 or 28),
		Font = Enum.Font.GothamMedium,
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = T.text,
		Text = def.label or key,
	}, row)

	if def.desc then
		new("TextLabel", {
			BackgroundTransparency = 1,
			Size = UDim2.new(1, -50, 0, 16),
			Position = UDim2.fromOffset(0, 20),
			Font = Enum.Font.Gotham,
			TextSize = 10,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = T.textMute,
			Text = def.desc,
		}, row)
	end

	local track = new("Frame", {
		Size = UDim2.fromOffset(38, 20),
		Position = UDim2.new(1, -38, 0, 4),
		BackgroundColor3 = T.bg3,
		BorderSizePixel = 0,
	}, row) :: Frame
	corner(track, 10)
	stroke(track, T.borderSoft, 1, 0.5)

	local knob = new("Frame", {
		Size = UDim2.fromOffset(16, 16),
		Position = UDim2.new(0, 2, 0.5, -8),
		BackgroundColor3 = T.textMute,
		BorderSizePixel = 0,
	}, track) :: Frame
	corner(knob, 8)

	local function refresh(animate: boolean)
		local on = cfg:get(key)
		local bgTarget = on and T.success or T.bg3
		local knobTarget = on and Color3.fromRGB(255, 255, 255) or T.textMute
		local knobPos = on and UDim2.new(1, -18, 0.5, -8) or UDim2.new(0, 2, 0.5, -8)
		if animate then
			tween(track, 0.18, { BackgroundColor3 = bgTarget })
			tween(knob, 0.18, { Position = knobPos, BackgroundColor3 = knobTarget })
		else
			track.BackgroundColor3 = bgTarget
			knob.Position = knobPos
			knob.BackgroundColor3 = knobTarget
		end
	end
	refresh(false)

	local btn = new("TextButton", {
		Size = UDim2.new(1, 0, 1, 0),
		BackgroundTransparency = 1,
		Text = "",
	}, row) :: TextButton
	btn.MouseButton1Click:Connect(function()
		cfg:set(key, not cfg:get(key))
		refresh(true)
	end)

	return refresh
end

function Widgets.slider(parent: Instance, cfg: Config, key: string)
	local def = cfg.schema[key]
	if not def then return end
	local T = Theme
	local min = def.min or 0
	local max = def.max or 100
	local fmt = def.format or "%.2f"
	local unit = def.unit or ""
	local step = (max - min) / 100

	local row = new("Frame", {
		Size = UDim2.new(1, 0, 0, def.desc and 58 or 46),
		BackgroundTransparency = 1,
	}, parent) :: Frame

	new("TextLabel", {
		BackgroundTransparency = 1,
		Size = UDim2.new(0.7, 0, 0, 18),
		Font = Enum.Font.GothamMedium,
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = T.text,
		Text = def.label or key,
	}, row)

	local valLbl = new("TextLabel", {
		BackgroundTransparency = 1,
		Size = UDim2.new(0.3, 0, 0, 18),
		Position = UDim2.new(0.7, 0, 0, 0),
		Font = Enum.Font.Code,
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Right,
		TextColor3 = T.accent,
		Text = string.format(fmt, cfg:get(key)) .. unit,
	}, row) :: TextLabel

	if def.desc then
		new("TextLabel", {
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 12),
			Position = UDim2.fromOffset(0, 17),
			Font = Enum.Font.Gotham,
			TextSize = 9,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = T.textMute,
			Text = def.desc,
		}, row)
	end

	local track = new("Frame", {
		Size = UDim2.new(1, 0, 0, 6),
		Position = UDim2.new(0, 0, 0, def.desc and 44 or 32),
		BackgroundColor3 = T.bg3,
		BorderSizePixel = 0,
	}, row) :: Frame
	corner(track, 3)

	local initT = (cfg:get(key) - min) / (max - min)
	local fill = new("Frame", {
		Size = UDim2.new(initT, 0, 1, 0),
		BackgroundColor3 = T.accent,
		BorderSizePixel = 0,
	}, track) :: Frame
	corner(fill, 3)

	local knob = new("Frame", {
		AnchorPoint = Vec2.new(0.5, 0.5),
		Size = UDim2.fromOffset(14, 14),
		Position = UDim2.new(initT, 0, 0.5, 0),
		BackgroundColor3 = Color3.fromRGB(255, 255, 255),
		BorderSizePixel = 0,
	}, track) :: Frame
	corner(knob, 7)
	stroke(knob, T.border, 1, 0.6)

	local dragging = false

	local function setFromX(x: number, snap: boolean)
		local absX = track.AbsolutePosition.X
		local w = track.AbsoluteSize.X
		local t = math.clamp((x - absX) / math.max(w, 1), 0, 1)
		local raw = min + t * (max - min)
		local value = snap and (math.floor(raw / step + 0.5) * step) or raw
		value = math.clamp(value, min, max)
		cfg:set(key, value)
		valLbl.Text = string.format(fmt, value) .. unit
		local p = (value - min) / (max - min)
		fill.Size = UDim2.new(p, 0, 1, 0)
		knob.Position = UDim2.new(p, 0, 0.5, 0)
	end

	track.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			setFromX(input.Position.X, false)
			tween(track, 0.1, { BackgroundColor3 = T.bgHover })
		end
	end)

	UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
			or input.UserInputType == Enum.UserInputType.Touch) then
			setFromX(input.Position.X, false)
		end
	end)

	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			if dragging then
				setFromX(input.Position.X, true)
				tween(track, 0.1, { BackgroundColor3 = T.bg3 })
			end
			dragging = false
		end
	end)

	return function()
		local v = cfg:get(key)
		valLbl.Text = string.format(fmt, v) .. unit
		local p = (v - min) / (max - min)
		fill.Size = UDim2.new(p, 0, 1, 0)
		knob.Position = UDim2.new(p, 0, 0.5, 0)
	end
end

function Widgets.pill(parent: Instance, cfg: Config, key: string, options: {any}, labels: {string}?)
	local def = cfg.schema[key]
	if not def then return end
	local T = Theme
	local row = new("Frame", {
		Size = UDim2.new(1, 0, 0, def.desc and 46 or 30),
		BackgroundTransparency = 1,
	}, parent) :: Frame

	if def.label then
		new("TextLabel", {
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 16),
			Font = Enum.Font.GothamMedium,
			TextSize = 12,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = T.text,
			Text = def.label,
		}, row)
	end

	local btns: {TextButton} = {}
	local container = new("Frame", {
		Size = UDim2.new(1, 0, 0, 26),
		Position = UDim2.new(0, 0, 0, def.label and (def.desc and 38 or 20) or 0),
		BackgroundColor3 = T.bg3,
		BorderSizePixel = 0,
	}, row) :: Frame
	corner(container, 6)
	pad(container, 2)
	new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		Padding = UDim.new(0, 2),
		VerticalAlignment = Enum.VerticalAlignment.Center,
	}, container)

	for i, opt in ipairs(options) do
		local b = new("TextButton", {
			Size = UDim2.new(1/#options, -(4*(#options-1))/#options, 1, -4),
			BackgroundColor3 = T.bg3,
			BorderSizePixel = 0,
			Font = Enum.Font.GothamMedium,
			TextSize = 11,
			TextColor3 = T.textDim,
			Text = labels and labels[i] or tostring(opt),
			AutoButtonColor = false,
		}, container) :: TextButton
		corner(b, 4)
		btns[i] = b
	end

	local function refresh(animate: boolean)
		local current = cfg:get(key)
		for i, opt in ipairs(options) do
			local on = opt == current
			local target = on and T.accent or T.bg3
			local textTarget = on and Color3.fromRGB(255, 255, 255) or T.textDim
			if animate then
				tween(btns[i], 0.15, { BackgroundColor3 = target, TextColor3 = textTarget })
			else
				btns[i].BackgroundColor3 = target
				btns[i].TextColor3 = textTarget
			end
		end
	end

	for i, opt in ipairs(options) do
		btns[i].MouseButton1Click:Connect(function()
			cfg:set(key, opt)
			refresh(true)
		end)
	end

	refresh(false)
	return refresh
end

function Widgets.button(parent: Instance, text: string, color: Color3?, onClick: () -> ())
	local T = Theme
	local baseColor = color or T.accent
	local b = new("TextButton", {
		Size = UDim2.new(1, 0, 0, 32),
		BackgroundColor3 = baseColor,
		BorderSizePixel = 0,
		Font = Enum.Font.GothamBold,
		TextSize = 12,
		TextColor3 = Color3.fromRGB(255, 255, 255),
		Text = text,
		AutoButtonColor = false,
	}, parent) :: TextButton
	corner(b, 6)

	b.MouseEnter:Connect(function()
		tween(b, 0.12, { BackgroundColor3 = baseColor:Lerp(Color3.fromRGB(255, 255, 255), 0.15) })
	end)
	b.MouseLeave:Connect(function()
		tween(b, 0.12, { BackgroundColor3 = baseColor })
	end)
	b.MouseButton1Click:Connect(onClick)
end

function Widgets.stat(parent: Instance, label: string, initial: string): (TextLabel, TextLabel)
	local T = Theme
	local row = new("Frame", {
		Size = UDim2.new(1, 0, 0, 16),
		BackgroundTransparency = 1,
	}, parent) :: Frame

	local lbl = new("TextLabel", {
		BackgroundTransparency = 1,
		Size = UDim2.new(0.45, 0, 1, 0),
		Font = Enum.Font.Gotham,
		TextSize = 11,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = T.textDim,
		Text = label,
	}, row) :: TextLabel

	local val = new("TextLabel", {
		BackgroundTransparency = 1,
		Size = UDim2.new(0.55, 0, 1, 0),
		Position = UDim2.new(0.45, 0, 0, 0),
		Font = Enum.Font.Code,
		TextSize = 11,
		TextXAlignment = Enum.TextXAlignment.Right,
		TextColor3 = T.text,
		Text = initial,
	}, row) :: TextLabel

	return lbl, val
end

local PAGES = {
	{ id = "main",     icon = "◉",  label = "主页" },
	{ id = "reaction", icon = "⚡", label = "反应" },
	{ id = "move",     icon = "⟿",  label = "移动" },
	{ id = "target",   icon = "◎",  label = "目标" },
	{ id = "misc",     icon = "⚙",  label = "其他" },
}

local function buildPanel(cfg: Config, aim: AimController, bus: EventBus): (ScreenGui, any)
	local T = Theme
	local uiParent = Compat.getUIParent()

	local gui = new("ScreenGui", {
		Name = "AAPro_" .. tostring(math.random(100000, 999999)),
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = 999,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	}, uiParent) :: ScreenGui
	Compat.protectgui(gui)

	local origParent = uiParent
	gui.AncestryChanged:Connect(function(_, parent)
		if not parent then
			task.defer(function()
				pcall(function() gui.Parent = origParent end)
			end)
		end
	end)

	local panel = new("Frame", {
		Name = "Panel",
		Position = UDim2.fromOffset(24, 80),
		Size = UDim2.fromOffset(320, 460),
		BackgroundColor3 = T.bg,
		BackgroundTransparency = 0.03,
		BorderSizePixel = 0,
		ClipsDescendants = true,
		Active = true,
	}, gui) :: Frame
	corner(panel, 12)
	stroke(panel, T.border, 1, 0.2)

	local header = new("Frame", {
		Name = "Header",
		Size = UDim2.new(1, 0, 0, 44),
		BackgroundColor3 = T.bg2,
		BorderSizePixel = 0,
	}, panel) :: Frame
	corner(header, 12)

	local dragBar = new("TextButton", {
		Size = UDim2.new(1, -110, 1, 0),
		BackgroundTransparency = 1,
		Text = "",
		AutoButtonColor = false,
	}, header) :: TextButton

	local titleAccent = new("Frame", {
		Size = UDim2.new(0, 3, 0, 20),
		Position = UDim2.fromOffset(14, 12),
		BackgroundColor3 = T.accent,
		BorderSizePixel = 0,
	}, header) :: Frame
	corner(titleAccent, 2)

	new("TextLabel", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -100, 0, 20),
		Position = UDim2.fromOffset(24, 6),
		Font = Enum.Font.GothamBold,
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = T.text,
		Text = "Aim Bot Pro",
	}, header)

	new("TextLabel", {
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(120, 16),
		Position = UDim2.fromOffset(24, 24),
		Font = Enum.Font.Code,
		TextSize = 10,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = T.textMute,
		Text = "v8 · injector",
	}, header)

	local statusDot = new("Frame", {
		Size = UDim2.fromOffset(8, 8),
		Position = UDim2.new(1, -100, 0.5, -4),
		BackgroundColor3 = T.textMute,
		BorderSizePixel = 0,
	}, header) :: Frame
	corner(statusDot, 4)

	local statusLbl = new("TextLabel", {
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(60, 20),
		Position = UDim2.new(1, -90, 0.5, -10),
		Font = Enum.Font.GothamBold,
		TextSize = 11,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = T.textMute,
		Text = "OFF",
	}, header)

	local function titleButton(icon: string, xOff: number, color: Color3, onClick: () -> ()): TextButton
		local b = new("TextButton", {
			Size = UDim2.fromOffset(26, 26),
			Position = UDim2.new(1, xOff, 0.5, -13),
			BackgroundColor3 = T.bg3,
			BorderSizePixel = 0,
			Font = Enum.Font.GothamBold,
			TextSize = 13,
			TextColor3 = color,
			Text = icon,
			AutoButtonColor = false,
		}, header) :: TextButton
		corner(b, 6)
		b.MouseEnter:Connect(function() tween(b, 0.1, { BackgroundColor3 = T.bgHover }) end)
		b.MouseLeave:Connect(function() tween(b, 0.1, { BackgroundColor3 = T.bg3 }) end)
		b.MouseButton1Click:Connect(onClick)
		return b
	end

	local collapseBtn = titleButton("−", -34, T.text, function() end)
	local closeBtn = titleButton("×", -4, T.danger, function() end)

	local dragging = false
	local dragStart = Vec2.zero
	local panelStart = UDim2.new(0, 24, 0, 80)

	dragBar.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			dragStart = Vec2.new(input.Position.X, input.Position.Y)
			panelStart = panel.Position
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
			or input.UserInputType == Enum.UserInputType.Touch) then
			local dx = input.Position.X - dragStart.X
			local dy = input.Position.Y - dragStart.Y
			panel.Position = UDim2.new(
				panelStart.X.Scale, panelStart.X.Offset + dx,
				panelStart.Y.Scale, panelStart.Y.Offset + dy
			)
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end)

	local tabBar = new("Frame", {
		Size = UDim2.new(1, -20, 0, 34),
		Position = UDim2.fromOffset(10, 52),
		BackgroundColor3 = T.bg2,
		BorderSizePixel = 0,
	}, panel) :: Frame
	corner(tabBar, 8)
	pad(tabBar, 3)
	new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		Padding = UDim.new(0, 3),
		VerticalAlignment = Enum.VerticalAlignment.Center,
	}, tabBar)

	local contentArea = new("Frame", {
		Size = UDim2.new(1, -20, 1, -100),
		Position = UDim2.fromOffset(10, 92),
		BackgroundTransparency = 1,
	}, panel) :: Frame

	local pages: {[string]: ScrollingFrame} = {}
	local tabButtons: {[string]: TextButton} = {}

	for _, page in ipairs(PAGES) do
		local btn = new("TextButton", {
			Size = UDim2.new(1/#PAGES, -(3*(#PAGES-1))/#PAGES, 1, -6),
			BackgroundColor3 = T.bg3,
			BorderSizePixel = 0,
			Font = Enum.Font.GothamBold,
			TextSize = 11,
			TextColor3 = T.textDim,
			Text = page.icon .. " " .. page.label,
			AutoButtonColor = false,
		}, tabBar) :: TextButton
		corner(btn, 5)
		tabButtons[page.id] = btn
	end

	for _, page in ipairs(PAGES) do
		local sc = new("ScrollingFrame", {
			Size = UDim2.new(1, 0, 1, 0),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			ScrollBarThickness = 3,
			ScrollBarImageColor3 = T.border,
			ScrollBarImageTransparency = 0.4,
			CanvasSize = UDim2.new(0, 0, 0, 0),
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
			Visible = false,
			ScrollingDirection = Enum.ScrollingDirection.Y,
		}, contentArea) :: ScrollingFrame
		pad(sc, 2)
		new("UIListLayout", {
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 8),
		}, sc)
		pages[page.id] = sc
	end

	local function switchTab(id: string)
		for pid, p in pairs(pages) do
			p.Visible = pid == id
		end
		for tid, btn in pairs(tabButtons) do
			local on = tid == id
			tween(btn, 0.15, {
				BackgroundColor3 = on and T.accent or T.bg3,
				TextColor3 = on and Color3.fromRGB(255, 255, 255) or T.textDim,
			})
		end
	end

	for id, btn in pairs(tabButtons) do
		btn.MouseButton1Click:Connect(function() switchTab(id) end)
	end

	local mainPage = pages.main

	local statusCard = Widgets.card(mainPage, 1)
	local statusBigRow = new("Frame", {
		Size = UDim2.new(1, 0, 0, 46),
		BackgroundTransparency = 1,
	}, statusCard) :: Frame

	local bigStatus = new("TextLabel", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 30),
		Font = Enum.Font.GothamBold,
		TextSize = 22,
		TextColor3 = T.textMute,
		Text = "OFF",
	}, statusBigRow) :: TextLabel

	local subStatus = new("TextLabel", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 14),
		Position = UDim2.fromOffset(0, 30),
		Font = Enum.Font.Gotham,
		TextSize = 10,
		TextColor3 = T.textMute,
		Text = "按住右键启用辅助",
	}, statusBigRow) :: TextLabel

	local statCard = Widgets.card(mainPage, 2)
	Widgets.section(statCard, "运行状态")
	local _, fpsVal = Widgets.stat(statCard, "FPS", "0")
	local _, stateVal = Widgets.stat(statCard, "状态", "idle")
	local _, tgtVal = Widgets.stat(statCard, "锁定目标", "—")
	local _, velVal = Widgets.stat(statCard, "目标速度", "0.0")
	local _, mseVal = Widgets.stat(statCard, "鼠标速度", "0")
	local _, rayVal = Widgets.stat(statCard, "射线预算", "0/4")

	local listCard = Widgets.card(mainPage, 3)
	Widgets.section(listCard, "目标列表", "FOV 内候选")
	local listContainer = new("Frame", {
		Size = UDim2.new(1, 0, 0, 0),
		BackgroundTransparency = 1,
		AutomaticSize = Enum.AutomaticSize.Y,
	}, listCard) :: Frame
	new("UIListLayout", {
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, 3),
	}, listContainer)

	local presetCard = Widgets.card(mainPage, 4)
	Widgets.section(presetCard, "快速预设", "一键切换风格")
	local PRESETS: {[string]: {[string]: any}} = {
		legit = {
			REACTION_TIME_MS = 200, MOVE_CURVE = "Human",
			MOVE_SPEED_PEAK = 1600, CATCH_UP_POWER = 1.0,
			JITTER_AMPLITUDE = 0.25, FOV_VERTICAL = 60,
			TARGET_MODE = "Look", LOOK_DWELL_TIME = 0.35,
			PREDICTION_ENABLED = false,
		},
		balanced = {
			REACTION_TIME_MS = 120, MOVE_CURVE = "EaseOut",
			MOVE_SPEED_PEAK = 2400, CATCH_UP_POWER = 1.3,
			JITTER_AMPLITUDE = 0.15, FOV_VERTICAL = 75,
			TARGET_MODE = "Look", LOOK_DWELL_TIME = 0.20,
			PREDICTION_ENABLED = true, PREDICTION_FACTOR = 0.12,
		},
		aggressive = {
			REACTION_TIME_MS = 30, MOVE_CURVE = "Linear",
			MOVE_SPEED_PEAK = 4000, CATCH_UP_POWER = 2.0,
			JITTER_AMPLITUDE = 0, FOV_VERTICAL = 120,
			TARGET_MODE = "Nearest", LOOK_DWELL_TIME = 0,
			PREDICTION_ENABLED = true, PREDICTION_FACTOR = 0.18,
			PREDICTION_ACCEL = 0.6,
		},
	}
	local presetRow = new("Frame", {
		Size = UDim2.new(1, 0, 0, 30),
		BackgroundTransparency = 1,
	}, presetCard) :: Frame
	new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		Padding = UDim.new(0, 4),
	}, presetRow)

	for _, name in ipairs({ "legit", "balanced", "aggressive" }) do
		local labels = { legit = "稳健", balanced = "平衡", aggressive = "激进" }
		local b = new("TextButton", {
			Size = UDim2.new(1/3, -3, 1, 0),
			BackgroundColor3 = T.bg3,
			BorderSizePixel = 0,
			Font = Enum.Font.GothamMedium,
			TextSize = 11,
			TextColor3 = T.text,
			Text = labels[name],
			AutoButtonColor = false,
		}, presetRow) :: TextButton
		corner(b, 6)
		b.MouseEnter:Connect(function() tween(b, 0.1, { BackgroundColor3 = T.bgHover }) end)
		b.MouseLeave:Connect(function() tween(b, 0.1, { BackgroundColor3 = T.bg3 }) end)
		b.MouseButton1Click:Connect(function() cfg:apply(PRESETS[name]) end)
	end

	local switchCard = Widgets.card(mainPage, 5)
	Widgets.section(switchCard, "启用方式")
	Widgets.toggle(switchCard, cfg, "HOLD_TO_AIM")
	Widgets.toggle(switchCard, cfg, "ONLY_WHEN_FIRING")
	Widgets.toggle(switchCard, cfg, "TEAM_CHECK")
	Widgets.toggle(switchCard, cfg, "ALIVE_CHECK")

	local reactionPage = pages.reaction
	local reactCard = Widgets.card(reactionPage, 1)
	Widgets.section(reactCard, "反应延迟", "模拟人的思考时间")
	Widgets.slider(reactCard, cfg, "REACTION_TIME_MS")
	Widgets.slider(reactCard, cfg, "RELEASE_TIME_MS")

	local jitterCard = Widgets.card(reactionPage, 2)
	Widgets.section(jitterCard, "手抖 / 呼吸", "让瞄准更自然")
	Widgets.slider(jitterCard, cfg, "JITTER_AMPLITUDE")
	Widgets.slider(jitterCard, cfg, "JITTER_FREQUENCY")
	Widgets.slider(jitterCard, cfg, "BREATH_AMPLITUDE")
	Widgets.slider(jitterCard, cfg, "BREATH_FREQUENCY")

	local movePage = pages.move
	local curveCard = Widgets.card(movePage, 1)
	Widgets.section(curveCard, "移动曲线", "相机跟随风格")
	Widgets.pill(curveCard, cfg, "MOVE_CURVE",
		{ "Human", "EaseOut", "Linear", "EaseInOut" },
		{ "人体", "缓出", "线性", "缓入出" })
	Widgets.slider(curveCard, cfg, "MOVE_SPEED_PEAK")
	Widgets.slider(curveCard, cfg, "CATCH_UP_POWER")

	local predCard = Widgets.card(movePage, 2)
	Widgets.section(predCard, "预测", "预判目标移动")
	Widgets.toggle(predCard, cfg, "PREDICTION_ENABLED")
	Widgets.slider(predCard, cfg, "PREDICTION_FACTOR")
	Widgets.slider(predCard, cfg, "PREDICTION_ACCEL")

	local fovCard = Widgets.card(movePage, 3)
	Widgets.section(fovCard, "视野范围", "锁定区域大小")
	Widgets.slider(fovCard, cfg, "FOV_VERTICAL")
	Widgets.toggle(fovCard, cfg, "DYNAMIC_FOV")
	Widgets.slider(fovCard, cfg, "FOV_AIM_SCALE")
	Widgets.slider(fovCard, cfg, "MAX_WORLD_DIST")
	Widgets.slider(fovCard, cfg, "MIN_WORLD_DIST")

	local targetPage = pages.target
	local selectCard = Widgets.card(targetPage, 1)
	Widgets.section(selectCard, "选择方式", "如何决定锁定谁")
	Widgets.pill(selectCard, cfg, "TARGET_MODE",
		{ "Look", "Nearest", "Threat" },
		{ "视线", "最近", "威胁" })
	Widgets.slider(selectCard, cfg, "LOOK_DWELL_TIME")
	Widgets.slider(selectCard, cfg, "STICKY_BONUS")
	Widgets.slider(selectCard, cfg, "LOCK_COOLDOWN")

	local breakCard = Widgets.card(targetPage, 2)
	Widgets.section(breakCard, "打破锁定", "什么时候松开目标")
	Widgets.toggle(breakCard, cfg, "BREAK_ON_FLICK")
	Widgets.slider(breakCard, cfg, "FLICK_SPEED")
	Widgets.toggle(breakCard, cfg, "BREAK_ON_REVERSE")
	Widgets.slider(breakCard, cfg, "REVERSE_ANGLE")

	local miscPage = pages.misc

	local recoilCard = Widgets.card(miscPage, 1)
	Widgets.section(recoilCard, "后坐力补偿", "自动压枪")
	Widgets.toggle(recoilCard, cfg, "RECOIL_COMPENSATE")
	Widgets.slider(recoilCard, cfg, "RECOIL_PITCH")
	Widgets.slider(recoilCard, cfg, "RECOIL_DECAY")

	local detectCard = Widgets.card(miscPage, 2)
	Widgets.section(detectCard, "检测", "射线与遮挡")
	Widgets.toggle(detectCard, cfg, "USE_WALL_CHECK")
	Widgets.toggle(detectCard, cfg, "IGNORE_TRANSPARENT")
	Widgets.slider(detectCard, cfg, "FRAME_RAY_BUDGET")
	Widgets.slider(detectCard, cfg, "VISIBILITY_EVERY")

	local boneCard = Widgets.card(miscPage, 3)
	Widgets.section(boneCard, "骨骼权重", "瞄准点混合")
	Widgets.slider(boneCard, cfg, "BONE_HEAD_WEIGHT")
	Widgets.slider(boneCard, cfg, "BONE_TORSO_WEIGHT")

	local visualCard = Widgets.card(miscPage, 4)
	Widgets.section(visualCard, "视觉", "覆盖层开关")
	Widgets.toggle(visualCard, cfg, "SHOW_FOV")
	Widgets.toggle(visualCard, cfg, "SHOW_TARGET_BOX")
	Widgets.toggle(visualCard, cfg, "SHOW_TARGET_LINE")
	Widgets.toggle(visualCard, cfg, "SHOW_CROSSHAIR")
	Widgets.toggle(visualCard, cfg, "SHOW_TARGET_LIST")

	local cfgCard = Widgets.card(miscPage, 5)
	Widgets.section(cfgCard, "配置", "导入导出")
	Widgets.button(cfgCard, "复制到剪贴板", T.bg3, function()
		if Compat.setclipboard(cfg:serialize()) then
			GLog:info("Config copied")
		end
	end)
	Widgets.button(cfgCard, "从剪贴板导入", T.bg3, function()
		local text = Compat.getclipboard()
		if text and cfg:deserialize(text) then
			GLog:info("Config imported")
		end
	end)
	Widgets.button(cfgCard, "恢复默认", T.bg3, function()
		cfg:reset()
	end)
	Widgets.button(cfgCard, "隐藏面板 (F1)", T.danger, function()
		gui.Enabled = false
	end)

	switchTab("main")

	local expandedSize = UDim2.fromOffset(320, 460)
	local collapsedSize = UDim2.fromOffset(320, 44)
	local isCollapsed = false

	closeBtn.MouseButton1Click:Connect(function() gui.Enabled = false end)
	collapseBtn.MouseButton1Click:Connect(function()
		isCollapsed = not isCollapsed
		panel.Size = isCollapsed and collapsedSize or expandedSize
		tabBar.Visible = not isCollapsed
		contentArea.Visible = not isCollapsed
		collapseBtn.Text = isCollapsed and "+" or "−"
	end)

	local fovCircle = new("Frame", {
		Name = "FovCircle",
		AnchorPoint = Vec2.new(0.5, 0.5),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(cfg:get("FOV_VERTICAL"), cfg:get("FOV_VERTICAL")),
		Visible = cfg:get("SHOW_FOV"),
		ZIndex = 2,
	}, gui) :: Frame
	corner(fovCircle, 999)
	local fovStroke = stroke(fovCircle, T.success, 1.5, 0.3)

	local crosshair = new("Frame", {
		Name = "Crosshair",
		AnchorPoint = Vec2.new(0.5, 0.5),
		BackgroundColor3 = T.accent,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(3, 3),
		Visible = cfg:get("SHOW_CROSSHAIR"),
		ZIndex = 4,
	}, gui) :: Frame
	corner(crosshair, 999)
	stroke(crosshair, Color3.fromRGB(255, 255, 255), 1, 0.3)

	local targetBox = new("Frame", {
		Name = "TargetBox",
		AnchorPoint = Vec2.new(0.5, 0.5),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(40, 60),
		Visible = false,
		ZIndex = 3,
	}, gui) :: Frame
	corner(targetBox, 4)
	local boxStroke = stroke(targetBox, T.danger, 2, 0)

	local targetLine = new("Frame", {
		Name = "TargetLine",
		AnchorPoint = Vec2.new(0, 0.5),
		BackgroundColor3 = T.danger,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(0, 1),
		BackgroundTransparency = 0.6,
		Visible = false,
		ZIndex = 2,
	}, gui) :: Frame

	cfg.bus:on("changed", function(key: string, value: any)
		if key == "FOV_VERTICAL" then
			fovCircle.Size = UDim2.fromOffset(value, value)
		elseif key == "SHOW_FOV" then
			fovCircle.Visible = value
		elseif key == "SHOW_CROSSHAIR" then
			crosshair.Visible = value
		elseif key == "SHOW_TARGET_BOX" and not value then
			targetBox.Visible = false
		elseif key == "SHOW_TARGET_LINE" and not value then
			targetLine.Visible = false
		end
	end)

	local hud = {
		gui = gui,
		panel = panel,
		fovCircle = fovCircle,
		fovStroke = fovStroke,
		crosshair = crosshair,
		targetBox = targetBox,
		boxStroke = boxStroke,
		targetLine = targetLine,
		bigStatus = bigStatus,
		subStatus = subStatus,
		statusDot = statusDot,
		statusLbl = statusLbl,
		fpsVal = fpsVal,
		stateVal = stateVal,
		tgtVal = tgtVal,
		velVal = velVal,
		mseVal = mseVal,
		rayVal = rayVal,
		listContainer = listContainer,
		collapse = function()
			isCollapsed = not isCollapsed
			panel.Size = isCollapsed and collapsedSize or expandedSize
			tabBar.Visible = not isCollapsed
			contentArea.Visible = not isCollapsed
			collapseBtn.Text = isCollapsed and "+" or "−"
		end,
	}

	return gui, hud
end

local Main = {}

function Main.run()
	GLog:info("Booting Aim Assist Pro (injector)")

	if (_G :: any).__AA_PRO_ACTIVE and (_G :: any).__AA_PRO_ACTIVE.unload then
		pcall(function()
			(_G :: any).__AA_PRO_ACTIVE.unload()
		end)
	end

	local cfg = Config.new()
	local bus = EventBus.new()
	local aim = AimController.new(cfg, bus)

	local connections: {RBXScriptConnection} = {}

	Services.PlayerCache.start()

	Services.InputService.bindMouse(
		Enum.UserInputType.MouseButton2,
		function()
			if cfg:get("HOLD_TO_AIM") then
				aim:setEnabled(true)
			else
				aim:setEnabled(not aim.enabled)
			end
		end,
		function()
			if cfg:get("HOLD_TO_AIM") then
				aim:setEnabled(false)
			end
		end
	)

	table.insert(connections, LP.CharacterAdded:Connect(function()
		aim.target = nil
		aim.aimPart = nil
		Services.VisibilityService.clear()
	end))

	local gui, hud = buildPanel(cfg, aim, bus)

	Services.InputService.bindKey(Enum.KeyCode.F1, function()
		gui.Enabled = not gui.Enabled
	end)
	Services.InputService.bindKey(Enum.KeyCode.F2, function()
		hud.collapse()
	end)
	Services.InputService.bindKey(Enum.KeyCode.LeftBracket, function()
		aim:cycleTarget(-1)
	end)
	Services.InputService.bindKey(Enum.KeyCode.RightBracket, function()
		aim:cycleTarget(1)
	end)

	local lastTargetPos: Vec3? = nil
	local targetVel: Vec3 = Vec3.zero
	local lastHudUpdate = 0
	local lastListUpdate = 0

	bus:on("targetAcquired", function()
		lastTargetPos = nil
		targetVel = Vec3.zero
	end)
	bus:on("targetLost", function()
		lastTargetPos = nil
		targetVel = Vec3.zero
	end)

	local listRows: {TextLabel} = {}
	local function ensureListRow(i: number): TextLabel
		if listRows[i] then return listRows[i] end
		local lbl = new("TextLabel", {
			Size = UDim2.new(1, 0, 0, 16),
			BackgroundTransparency = 1,
			Font = Enum.Font.Code,
			TextSize = 10,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = Theme.textDim,
			Text = "",
			LayoutOrder = i,
		}, hud.listContainer) :: TextLabel
		listRows[i] = lbl
		return lbl
	end

	local frameConn = RunService.RenderStepped:Connect(function(dt: number)
		Services.PerformanceService.begin()
		Services.VisibilityService.setBudget(cfg:get("FRAME_RAY_BUDGET"))

		aim:update(dt)

		local now = os.clock()
		local m = Services.InputService.mouseScreen()
		hud.fovCircle.Position = UDim2.fromOffset(m.X, m.Y)
		hud.crosshair.Position = UDim2.fromOffset(m.X, m.Y)

		local on = aim.enabled
		local T = Theme
		hud.fovStroke.Color = aim.target and T.danger or (on and T.accent or T.success)
		hud.statusDot.BackgroundColor3 = on and T.success or T.textMute
		hud.statusLbl.Text = on and "ON" or "OFF"
		hud.statusLbl.TextColor3 = on and T.success or T.textMute
		hud.bigStatus.Text = on and "ON" or "OFF"
		hud.bigStatus.TextColor3 = on and T.success or T.textMute

		local stateText = tostring(aim.state)
		if stateText == "reacting" then
			hud.subStatus.Text = "反应中..."
		elseif stateText == "locking" then
			hud.subStatus.Text = "视线停留..."
		elseif stateText == "locked" then
			hud.subStatus.Text = "已锁定"
		elseif stateText == "releasing" then
			hud.subStatus.Text = "释放中..."
		else
			hud.subStatus.Text = "按住右键启用辅助"
		end

		if aim.target and aim.aimPart then
			local pos = aim.aimPart.Position
			if lastTargetPos then
				local raw = (pos - lastTargetPos) / math.max(dt, 1e-4)
				targetVel = targetVel:Lerp(raw, 0.4)
			end
			lastTargetPos = pos
		end

		if cfg:get("SHOW_TARGET_BOX") and aim.target and aim.aimPart then
			local sp, onScreen = Camera:WorldToViewportPoint(aim.aimPart.Position)
			if onScreen and sp.Z > 0 then
				hud.targetBox.Visible = true
				hud.targetBox.Position = UDim2.fromOffset(sp.X, sp.Y)
				local dist = (aim.aimPart.Position - Camera.CFrame.Position).Magnitude
				local size = math.clamp(1600 / math.max(dist, 1), 26, 150)
				hud.targetBox.Size = UDim2.fromOffset(size, size * 1.35)

				if cfg:get("SHOW_TARGET_LINE") then
					local mx, my = m.X, m.Y
					local dx, dy = sp.X - mx, sp.Y - my
					local len = math.sqrt(dx * dx + dy * dy)
					local ang = math.deg(math.atan2(dy, dx))
					hud.targetLine.Visible = true
					hud.targetLine.Position = UDim2.fromOffset(mx, my)
					hud.targetLine.Size = UDim2.fromOffset(len, 1)
					hud.targetLine.Rotation = ang
				else
					hud.targetLine.Visible = false
				end
			else
				hud.targetBox.Visible = false
				hud.targetLine.Visible = false
			end
		else
			hud.targetBox.Visible = false
			hud.targetLine.Visible = false
		end

		if now - lastHudUpdate > 0.1 then
			lastHudUpdate = now
			hud.fpsVal.Text = string.format("%.0f", Services.PerformanceService.fps())
			hud.stateVal.Text = aim.state
			hud.tgtVal.Text = aim.target and aim.target.Name or "—"
			hud.velVal.Text = string.format("%.1f", targetVel.Magnitude)
			hud.mseVal.Text = string.format("%.0f", Services.InputService.speed())
			hud.rayVal.Text = string.format("%d/%d",
				cfg:get("FRAME_RAY_BUDGET"), cfg:get("FRAME_RAY_BUDGET"))
		end

		if cfg:get("SHOW_TARGET_LIST") and now - lastListUpdate > 0.15 then
			lastListUpdate = now
			local candidates = aim.lastCandidates
			for i = 1, math.min(6, #candidates) do
				local row = ensureListRow(i)
				local c = candidates[i]
				local name = c.model.Name
				if #name > 14 then name = name:sub(1, 12) .. ".." end
				local marker = (aim.target == c.model) and "◉ " or "○ "
				row.Text = string.format("%s%s  %.0f  %.2f",
					marker, name, c.worldDist, c.score)
				row.TextColor3 = (aim.target == c.model) and T.accent or T.textDim
				row.Visible = true
			end
			for i = math.min(6, #candidates) + 1, #listRows do
				listRows[i].Visible = false
			end
		elseif not cfg:get("SHOW_TARGET_LIST") then
			for _, row in ipairs(listRows) do
				row.Visible = false
			end
		end

		Services.PerformanceService.endFrame()
	end)
	table.insert(connections, frameConn)

	local function unload()
		GLog:info("Unloading Aim Bot Pro")
		for _, c in ipairs(connections) do
			pcall(function() c:Disconnect() end)
		end
		connections = {}

		Services.InputService.disconnect()
		Services.PlayerCache.stop()
		Services.VisibilityService.clear()

		pcall(function() Services.CameraService.restore() end)

		if aim.enabled then
			aim:setEnabled(false)
		end

		pcall(function() gui:Destroy() end)

		(_G :: any).__AA_PRO_ACTIVE = nil
	end

	local api = {
		version = "v8-injector",
		config = cfg,
		aim = aim,
		bus = bus,
		unload = unload,
		setEnabled = function(v: boolean) aim:setEnabled(v) end,
		addRecoil = function(n: number) aim.recoil:add(n) end,
		importConfig = function(json: string) return cfg:deserialize(json) end,
		exportConfig = function() return cfg:serialize() end,
	}

	(_G :: any).__AA_PRO_ACTIVE = api

	GLog:info("Boot complete (v8-injector)")
	return api
end

return Main.run()
