--[[
	SPIDER WALL WALK  v2   (made for Delta / mobile, works on PC too)

	What changed compared to the old script
	  * Floating spider-web button to turn wall walk ON / OFF (drag it anywhere, tap it to toggle)
	  * Brand new camera: it turns WITH the surface you walk on, so it never flips or inverts on
	    walls / roofs, and the sensitivity is the normal Roblox feel (with light smoothing)
	  * The old script ran a full copy of Roblox's PlayerModule next to the game's own camera, so two
	    cameras were fighting each other (that is what caused the flipping + the fast sensitivity).
	    This version only uses ONE camera while wall walk is on, and hands the game's camera back when off.
	  * Wall walk survives respawning and sitting down, and turns off cleanly (character stands up again)

	Tweak things in CONFIG below.
]]

------------------------------------------------------------------------------------------------------
-- SERVICES / SETUP
------------------------------------------------------------------------------------------------------
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer
while not LocalPlayer do
	task.wait()
	LocalPlayer = Players.LocalPlayer
end

local env = (getgenv and getgenv()) or _G
if env.__SpiderWallWalk then
	pcall(function()
		env.__SpiderWallWalk.Destroy()
	end)
	env.__SpiderWallWalk = nil
end

local CONFIG = {
	CameraSensitivity = 1.0, -- 1 = normal Roblox feel. 0.7 = slower, 1.3 = faster
	CameraSmoothing = 30, -- lower = smoother / floatier, higher = more direct (20-40 is good)
	JumpMultiplier = 1.2, -- jump strength while wall walking
	ButtonSize = 46, -- size of the floating spider button (pixels)
	DownRays = 16, -- surface detection rays (lower = faster on weak phones, higher = smoother corners)
	FeelerRays = 8,
	DefaultZoom = 12.5, -- camera distance if it can't be read from the game's camera
	StartEnabled = false, -- true = wall walk turns on by itself when the script runs
}

local UserGameSettings
pcall(function()
	UserGameSettings = UserSettings():GetService("UserGameSettings")
end)

local GRAV_BIND = "SpiderWW_Gravity"
local CAM_BIND = "SpiderWW_Camera"

------------------------------------------------------------------------------------------------------
-- MATH / SHARED HELPERS
------------------------------------------------------------------------------------------------------
local ZERO = Vector3.new(0, 0, 0)
local UNIT_Y = Vector3.new(0, 1, 0)
local IDENTITY = CFrame.new()
local PI2 = math.pi * 2

local function clamp(x, a, b)
	if x < a then
		return a
	elseif x > b then
		return b
	end
	return x
end

local function perpendicular(v)
	local a = (math.abs(v.X) < 0.9) and Vector3.new(1, 0, 0) or Vector3.new(0, 0, 1)
	return v:Cross(a).Unit
end

-- rotation that takes unit vector u onto unit vector v (axis is used when they point opposite ways)
local function rotationBetween(u, v, axis)
	local dot = u:Dot(v)
	if dot < -0.99999 then
		return CFrame.fromAxisAngle(axis or perpendicular(u), math.pi)
	end
	local c = u:Cross(v)
	local w = 1 + dot
	local len = math.sqrt(c:Dot(c) + w * w)
	return CFrame.new(0, 0, 0, c.X / len, c.Y / len, c.Z / len, w / len)
end

local function makeParams(list)
	local p = RaycastParams.new()
	p.FilterType = Enum.RaycastFilterType.Exclude
	p.IgnoreWater = true
	p.FilterDescendantsInstances = list
	pcall(function()
		p.RespectCanCollide = true
	end)
	return p
end

-- ray params that ignore every player's character (used for surface detection + camera collision)
local worldParams = makeParams({})
local charListTime = 0
local function syncWorldParams()
	local now = os.clock()
	if now - charListTime > 0.5 then
		charListTime = now
		local list = {}
		for _, p in ipairs(Players:GetPlayers()) do
			if p.Character then
				list[#list + 1] = p.Character
			end
		end
		worldParams.FilterDescendantsInstances = list
	end
end

------------------------------------------------------------------------------------------------------
-- CONTROLS  (reads the game's own thumbstick / keyboard so nothing is duplicated)
------------------------------------------------------------------------------------------------------
local Controls = { controls = nil, jumpUntil = 0, conns = {} }

function Controls.Init()
	table.insert(
		Controls.conns,
		UserInputService.JumpRequest:Connect(function()
			Controls.jumpUntil = os.clock() + 0.15
		end)
	)
	task.spawn(function()
		pcall(function()
			local scripts = LocalPlayer:WaitForChild("PlayerScripts", 8)
			local pm = scripts and scripts:WaitForChild("PlayerModule", 8)
			if pm then
				Controls.controls = require(pm):GetControls()
			end
		end)
	end)
end

function Controls.Destroy()
	for _, c in ipairs(Controls.conns) do
		c:Disconnect()
	end
	Controls.conns = {}
end

-- Fallback: turn Humanoid.MoveDirection back into "camera relative" input
local function moveFromHumanoid(hum, camCF)
	local md = hum.MoveDirection
	if md.Magnitude < 0.05 then
		return ZERO
	end
	local _, _, _, R00, R01, R02, _, _, R12, _, _, R22 = camCF:GetComponents()
	local c, s
	if R12 < 1 and R12 > -1 then
		c, s = R22, R02
	else
		c, s = R00, -R01 * math.sign(R12)
	end
	local n = math.sqrt(c * c + s * s)
	if n < 1e-4 then
		return ZERO
	end
	return Vector3.new((c * md.X - s * md.Z) / n, 0, (s * md.X + c * md.Z) / n)
end

function Controls.GetMove(hum, camCF)
	local c = Controls.controls
	if c then
		local ok, v = pcall(c.GetMoveVector, c)
		if ok and typeof(v) == "Vector3" and v.Magnitude > 0.01 then
			return v
		end
	end
	return moveFromHumanoid(hum, camCF)
end

function Controls.IsJumping(hum)
	if os.clock() < Controls.jumpUntil then
		return true
	end
	if hum.Jump then
		return true
	end
	if not UserInputService:GetFocusedTextBox() and UserInputService:IsKeyDown(Enum.KeyCode.Space) then
		return true
	end
	return false
end

------------------------------------------------------------------------------------------------------
-- CAMERA  (turns with the surface, normal sensitivity, no inversion)
------------------------------------------------------------------------------------------------------
local TOUCH_SENS = Vector2.new(0.00945 * math.pi, 0.003375 * math.pi) -- Roblox default touch feel
local MOUSE_SENS = Vector2.new(0.002 * math.pi, 0.0015 * math.pi) -- Roblox default mouse feel
local MAX_PITCH = math.rad(80)

local CameraCtl = {}
CameraCtl.__index = CameraCtl

function CameraCtl.new()
	local self = setmetatable({}, CameraCtl)
	self.active = false
	self.releasing = false
	self.firstPerson = false
	self.look = Vector3.new(0, 0, -1)
	self.prevUp = UNIT_Y
	self.zoom = 12.5
	self.curDist = 12.5
	self.pendYaw = 0
	self.pendPitch = 0
	self.conns = {}
	self.touches = {}
	return self
end

local function zoomLimits()
	local lo = math.max(LocalPlayer.CameraMinZoomDistance, 0.5)
	local hi = math.max(LocalPlayer.CameraMaxZoomDistance, lo)
	return lo, hi
end

function CameraCtl:InMoveArea(pos)
	local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
	local tg = pg and pg:FindFirstChild("TouchGui")
	if tg then
		local tcf = tg:FindFirstChild("TouchControlFrame")
		local frame = tcf and (tcf:FindFirstChild("DynamicThumbstickFrame") or tcf:FindFirstChild("ThumbstickFrame"))
		if frame and frame:IsA("GuiObject") and frame.Visible then
			local ap, as = frame.AbsolutePosition, frame.AbsoluteSize
			return pos.X >= ap.X and pos.Y >= ap.Y and pos.X <= ap.X + as.X and pos.Y <= ap.Y + as.Y
		end
		return false
	end
	local cam = Workspace.CurrentCamera
	if not cam then
		return false
	end
	local vs = cam.ViewportSize
	if vs.X < vs.Y then
		return pos.Y > vs.Y * 0.6
	end
	return pos.X < vs.X * 0.4 and pos.Y > vs.Y / 3
end

function CameraCtl:AddRotation(delta, sens)
	local invert = 1
	if UserGameSettings then
		pcall(function()
			invert = UserGameSettings:GetCameraYInvertValue()
		end)
	end
	local k = CONFIG.CameraSensitivity
	self.pendYaw = self.pendYaw + delta.X * sens.X * k
	self.pendPitch = self.pendPitch - delta.Y * sens.Y * k * invert
end

function CameraCtl:Pinch()
	local pts = {}
	for _, p in pairs(self.touches) do
		pts[#pts + 1] = p
	end
	if #pts < 2 then
		return
	end
	local d = (pts[1] - pts[2]).Magnitude
	if self.pinchDist then
		local lo, hi = zoomLimits()
		local scale = clamp(d / math.max(self.pinchDist, 0.01), 0.1, 10)
		self.zoom = clamp(self.pinchZoom / scale, lo, hi)
	else
		self.pinchDist = d
		self.pinchZoom = self.zoom
	end
end

function CameraCtl:ConnectInput()
	self:DisconnectInput()
	local conns = {}
	self.conns = conns
	self.touches = {}
	self.moveTouch = nil
	self.pinchDist = nil
	self.rmb = false

	conns[#conns + 1] = UserInputService.InputBegan:Connect(function(input, processed)
		local t = input.UserInputType
		if t == Enum.UserInputType.Touch then
			if processed then
				return
			end
			local pos = input.Position
			if not self.moveTouch and self:InMoveArea(pos) then
				self.moveTouch = input
				return
			end
			if self.isBlocked and self.isBlocked(pos) then
				return
			end
			self.touches[input] = Vector2.new(pos.X, pos.Y)
			self.pinchDist = nil
		elseif t == Enum.UserInputType.MouseButton2 then
			if processed then
				return
			end
			self.rmb = true
			UserInputService.MouseBehavior = Enum.MouseBehavior.LockCurrentPosition
		end
	end)

	conns[#conns + 1] = UserInputService.InputChanged:Connect(function(input, processed)
		local t = input.UserInputType
		if t == Enum.UserInputType.Touch then
			local last = self.touches[input]
			if not last then
				return
			end
			local pos = Vector2.new(input.Position.X, input.Position.Y)
			local delta = pos - last
			self.touches[input] = pos
			local n = 0
			for _ in pairs(self.touches) do
				n = n + 1
			end
			if n == 1 then
				self:AddRotation(delta, TOUCH_SENS)
			elseif n == 2 then
				self:Pinch()
			end
		elseif t == Enum.UserInputType.MouseMovement then
			if self.rmb then
				self:AddRotation(Vector2.new(input.Delta.X, input.Delta.Y), MOUSE_SENS)
			end
		elseif t == Enum.UserInputType.MouseWheel then
			if not processed then
				local lo, hi = zoomLimits()
				self.zoom = clamp(self.zoom * (1 - input.Position.Z * 0.15), lo, hi)
			end
		end
	end)

	conns[#conns + 1] = UserInputService.InputEnded:Connect(function(input)
		if input == self.moveTouch then
			self.moveTouch = nil
		end
		if self.touches[input] then
			self.touches[input] = nil
			self.pinchDist = nil
		end
		if input.UserInputType == Enum.UserInputType.MouseButton2 then
			self.rmb = false
			if UserInputService.MouseBehavior == Enum.MouseBehavior.LockCurrentPosition then
				UserInputService.MouseBehavior = Enum.MouseBehavior.Default
			end
		end
	end)
end

function CameraCtl:DisconnectInput()
	for _, c in ipairs(self.conns) do
		c:Disconnect()
	end
	self.conns = {}
	self.touches = {}
	if self.rmb then
		self.rmb = false
		if UserInputService.MouseBehavior == Enum.MouseBehavior.LockCurrentPosition then
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		end
	end
end

function CameraCtl:SetFirstPerson(fp)
	if fp == self.firstPerson then
		return
	end
	self.firstPerson = fp
	local char = self.character
	if not char then
		return
	end
	for _, d in ipairs(char:GetDescendants()) do
		if d:IsA("BasePart") and not d:FindFirstAncestorWhichIsA("Tool") then
			d.LocalTransparencyModifier = fp and 1 or 0
		end
	end
end

function CameraCtl:Start(getUp, getFocus, isBlocked, character)
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	if self.active then
		self:Finish()
	end
	self.active = true
	self.releasing = false
	self.getUp = getUp
	self.getFocus = getFocus
	self.isBlocked = isBlocked
	self.character = character
	self.firstPerson = false
	self.pendYaw, self.pendPitch = 0, 0

	local up = getUp()
	self.prevUp = up
	self.look = cam.CFrame.LookVector
	local lo, hi = zoomLimits()
	local dist = (cam.CFrame.Position - getFocus(up)).Magnitude
	if dist ~= dist or dist < 0.5 then
		dist = CONFIG.DefaultZoom or 12.5
	end
	self.zoom = clamp(dist, lo, hi)
	self.curDist = self.zoom

	self.savedType = cam.CameraType
	cam.CameraType = Enum.CameraType.Scriptable

	pcall(function()
		RunService:UnbindFromRenderStep(CAM_BIND)
	end)
	RunService:BindToRenderStep(CAM_BIND, Enum.RenderPriority.Camera.Value + 1, function(dt)
		local ok, err = pcall(self.Step, self, dt)
		if not ok then
			self.errors = (self.errors or 0) + 1
			if self.errors == 1 then
				warn("[SpiderWallWalk] camera error: " .. tostring(err))
			end
		end
	end)
	self:ConnectInput()
end

-- smooth hand-back: the view rolls back upright over a moment, then the game's camera takes over again
function CameraCtl:Stop(instant)
	if not self.active then
		return
	end
	self:DisconnectInput()
	if instant then
		self:Finish()
		return
	end
	self.releasing = true
	self.releaseTime = 0
	self.relUp = self.prevUp
end

function CameraCtl:Finish()
	pcall(function()
		RunService:UnbindFromRenderStep(CAM_BIND)
	end)
	self:DisconnectInput()
	self:SetFirstPerson(false)
	local cam = Workspace.CurrentCamera
	if cam and self.active then
		cam.CameraType = self.savedType or Enum.CameraType.Custom
	end
	self.active = false
	self.releasing = false
end

function CameraCtl:ResolveDistance(focus, look, dt)
	local lo, hi = zoomLimits()
	self.zoom = clamp(self.zoom, lo, hi)
	local want = self.zoom
	local obs = want
	if want > 1.1 then
		syncWorldParams()
		local res = Workspace:Raycast(focus, -look * (want + 0.4), worldParams)
		if res then
			obs = math.max(res.Distance - 0.4, 0.6)
		end
	end
	if obs < self.curDist then
		self.curDist = obs
	else
		self.curDist = self.curDist + (math.min(want, obs) - self.curDist) * (1 - math.exp(-dt * 10))
	end
	return self.curDist
end

function CameraCtl:Step(dt)
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	dt = math.min(dt, 0.1)
	if cam.CameraType ~= Enum.CameraType.Scriptable then
		cam.CameraType = Enum.CameraType.Scriptable
	end

	local up
	local finishing = false
	if self.releasing then
		self.releaseTime = self.releaseTime + dt
		local axis = self.look:Cross(self.relUp)
		axis = (axis.Magnitude > 1e-4) and axis.Unit or perpendicular(self.relUp)
		local rot = IDENTITY:Lerp(rotationBetween(self.relUp, UNIT_Y, axis), 1 - math.exp(-dt * 9))
		self.relUp = (rot * self.relUp).Unit
		up = self.relUp
		if (up - UNIT_Y).Magnitude < 0.02 or self.releaseTime > 0.8 then
			up = UNIT_Y
			finishing = true
		end
	else
		up = self.getUp()
	end

	-- carry the view along while "up" changes (this is what stops it from flipping / inverting)
	local prevUp = self.prevUp
	if (up - prevUp).Magnitude > 1e-6 then
		local right = self.look:Cross(prevUp)
		local axis = (right.Magnitude > 1e-4) and right.Unit or perpendicular(prevUp)
		self.look = (rotationBetween(prevUp, up, axis) * self.look).Unit
		self.prevUp = up
	end

	-- smoothed input
	local a = 1 - math.exp(-dt * CONFIG.CameraSmoothing)
	local dyaw = self.pendYaw * a
	local dpitch = self.pendPitch * a
	self.pendYaw = self.pendYaw - dyaw
	self.pendPitch = self.pendPitch - dpitch
	dyaw = clamp(dyaw, -0.5, 0.5)
	dpitch = clamp(dpitch, -0.4, 0.4)

	local look = self.look
	if dyaw ~= 0 then
		look = CFrame.fromAxisAngle(up, -dyaw) * look
	end
	local right = look:Cross(up)
	right = (right.Magnitude > 1e-4) and right.Unit or perpendicular(up)
	local pitch = math.asin(clamp(look:Dot(up), -1, 1))
	local newPitch = clamp(pitch + dpitch, -MAX_PITCH, MAX_PITCH)
	if newPitch ~= pitch then
		look = CFrame.fromAxisAngle(right, newPitch - pitch) * look
	end
	look = look.Unit
	self.look = look

	local focus = self.getFocus(up)
	right = look:Cross(up).Unit
	local camUp = right:Cross(look)
	local dist = self:ResolveDistance(focus, look, dt)
	self:SetFirstPerson(dist < 1.1)
	cam.CFrame = CFrame.fromMatrix(focus - look * dist, right, camUp, -look)
	cam.Focus = CFrame.new(focus)

	if finishing then
		self:Finish()
	end
end

------------------------------------------------------------------------------------------------------
-- ANIMATION + SOUND  (PlatformStand switches the game's own animations off, so we drive them)
------------------------------------------------------------------------------------------------------
-- Default Roblox animations (only used if the game's Animate script has none)
local DEFAULT_PACK = {
	R15 = {
		idle = { { 507766388, 9 }, { 507766666, 1 }, { 507766951, 1 } },
		walk = { { 507777826, 1 } },
		run = { { 507767714, 1 } },
		jump = { { 507765000, 1 } },
		fall = { { 507767968, 1 } },
	},
	R6 = {
		idle = { { 180435571, 9 }, { 180435792, 1 } },
		walk = { { 180426354, 1 } },
		jump = { { 125750702, 1 } },
		fall = { { 180436148, 1 } },
	},
}

-- Reads YOUR animation pack from the character's Animate script (the same ids the game uses for you)
local function readPack(character, rig)
	local pack = {}
	local animate = character:FindFirstChild("Animate")
	for _, name in ipairs({ "idle", "walk", "run", "jump", "fall" }) do
		local list = {}
		local folder = animate and animate:FindFirstChild(name)
		if folder then
			local kids = folder:GetChildren()
			table.sort(kids, function(x, y)
				return x.Name < y.Name
			end)
			for _, a in ipairs(kids) do
				if a:IsA("Animation") and a.AnimationId ~= "" then
					local w = 1
					local wo = a:FindFirstChild("Weight")
					if wo and (wo:IsA("NumberValue") or wo:IsA("IntValue")) then
						w = wo.Value
					end
					list[#list + 1] = { a.AnimationId, w }
				end
			end
		end
		if #list == 0 then
			list = DEFAULT_PACK[rig][name] or {}
		end
		pack[name] = list
	end
	return pack
end

local AnimCtl = {}
AnimCtl.__index = AnimCtl

function AnimCtl.new(humanoid, character)
	local self = setmetatable({}, AnimCtl)
	self.rig = (humanoid.RigType == Enum.HumanoidRigType.R6) and "R6" or "R15"
	self.state = nil
	self.dead = false
	self.lastMove = nil
	self.idleTrack = nil
	self.idle = {}
	self.all = {}
	self.conns = {}

	local loader = humanoid:FindFirstChildOfClass("Animator") or humanoid
	local pack = readPack(character, self.rig)

	local function load(entry, looped)
		if not entry then
			return nil
		end
		local anim = Instance.new("Animation")
		anim.AnimationId = (type(entry[1]) == "number") and ("rbxassetid://" .. entry[1]) or entry[1]
		local ok, track = pcall(function()
			return loader:LoadAnimation(anim)
		end)
		if ok and track then
			track.Priority = Enum.AnimationPriority.Action
			track.Looped = looped
			self.all[#self.all + 1] = track
			return track
		end
		return nil
	end

	local multi = #pack.idle > 1
	for _, e in ipairs(pack.idle) do
		local t = load(e, not multi)
		if t then
			self.idle[#self.idle + 1] = { track = t, weight = e[2] }
			if multi then
				-- like the default Animate script: when one idle finishes, pick the next one
				table.insert(
					self.conns,
					t.Ended:Connect(function()
						if not self.dead and self.state == "idle" and self.idleTrack == t then
							self:PlayIdle()
						end
					end)
				)
			end
		end
	end
	self.walk = load(pack.walk[1], true)
	self.run = (self.rig == "R15") and load(pack.run[1], true) or nil
	self.jump = load(pack.jump[1], false)
	self.fall = load(pack.fall[1], true)
	return self
end

function AnimCtl:PlayIdle()
	local set = self.idle
	if #set == 0 then
		return
	end
	local total = 0
	for _, e in ipairs(set) do
		total = total + e.weight
	end
	local roll = math.random() * total
	local pick = set[1]
	for _, e in ipairs(set) do
		roll = roll - e.weight
		if roll <= 0 then
			pick = e
			break
		end
	end
	self.idleTrack = pick.track
	pick.track:Play(0.15)
end

local function stopTrack(t, fade)
	if t then
		t:Stop(fade)
	end
end

function AnimCtl:StopState(state)
	if state == "idle" then
		for _, e in ipairs(self.idle) do
			e.track:Stop(0.15)
		end
	elseif state == "move" then
		stopTrack(self.walk, 0.15)
		stopTrack(self.run, 0.15)
	elseif state == "jump" then
		stopTrack(self.jump, 0.1)
	elseif state == "fall" then
		stopTrack(self.fall, 0.15)
	end
end

function AnimCtl:StartState(state)
	if state == "idle" then
		self:PlayIdle()
	elseif state == "move" then
		if self.walk then
			self.walk:Play(0.15)
		end
		if self.run then
			self.run:Play(0.15)
		end
	elseif state == "jump" then
		if self.jump then
			self.jump:Play(0.1)
		end
	elseif state == "fall" then
		if self.fall then
			self.fall:Play(0.2)
		end
	end
end

function AnimCtl:UpdateMove(speed)
	local walk, run = self.walk, self.run
	if self.rig == "R6" or not (walk and run) then
		local only = walk or run
		if only then
			local sp = (self.rig == "R6") and (speed / 14.5) or (speed / 16 * 1.25)
			if not self.lastMove or math.abs(sp - self.lastMove) > 0.03 then
				only:AdjustSpeed(sp)
				self.lastMove = sp
			end
		end
		return
	end
	-- R15: blend your walk and run animations by speed (same way the default Animate script does)
	local rs = speed / 16 * 1.25
	if self.lastMove and math.abs(rs - self.lastMove) < 0.02 then
		return
	end
	self.lastMove = rs
	local eps = 0.0001
	local ww, rw
	if rs < 0.33 then
		ww, rw = 1, eps
	elseif rs < 0.66 then
		local w = (rs - 0.33) / 0.33
		ww, rw = 1 - w + eps, w + eps
	else
		ww, rw = eps, 1
	end
	walk:AdjustWeight(ww)
	run:AdjustWeight(rw)
	walk:AdjustSpeed(rs)
	run:AdjustSpeed(rs)
end

function AnimCtl:Set(state, speed)
	if state ~= self.state then
		local old = self.state
		self.state = state
		self.lastMove = nil
		if old then
			self:StopState(old)
		end
		self:StartState(state)
	end
	if state == "move" then
		self:UpdateMove(speed or 0)
	end
end

function AnimCtl:Destroy()
	self.dead = true
	for _, c in ipairs(self.conns) do
		c:Disconnect()
	end
	self.conns = {}
	for _, t in ipairs(self.all) do
		pcall(function()
			t:Stop(0.1)
			t:Destroy()
		end)
	end
	self.all = {}
end

local SoundCtl = {}
SoundCtl.__index = SoundCtl

function SoundCtl.new(hrp)
	local self = setmetatable({}, SoundCtl)
	local run = hrp:FindFirstChild("Running")
	if not (run and run:IsA("Sound")) then
		run = Instance.new("Sound")
		run.Name = "SWW_Running"
		run.SoundId = "rbxasset://sounds/action_footsteps_plastic.mp3"
		run.Looped = true
		run.Pitch = 1.85
		run.Volume = 0.65
		run.RollOffMaxDistance = 150
		run.Parent = hrp
		self.own = run
	end
	self.run = run
	local jump = hrp:FindFirstChild("Jumping")
	self.jump = (jump and jump:IsA("Sound")) and jump or nil
	return self
end

function SoundCtl:SetRunning(on)
	if self.run.Playing ~= on then
		self.run.Playing = on
	end
end

function SoundCtl:Jump()
	if self.jump then
		self.jump.TimePosition = 0
		self.jump.Playing = true
	end
end

function SoundCtl:Destroy()
	pcall(function()
		self.run.Playing = false
		if self.own then
			self.own:Destroy()
		end
	end)
end

------------------------------------------------------------------------------------------------------
-- GRAVITY CONTROLLER  (sticks you to whatever surface you walk on)
------------------------------------------------------------------------------------------------------
local LOWER_RADIUS_OFFSET = 3
local ODD_DOWN_START, EVEN_DOWN_START = 3, 2
local ODD_DOWN_END, EVEN_DOWN_END = 1.66666, 1
local FEELER_LENGTH, FEELER_START, FEELER_RADIUS, FEELER_APEX, FEELER_WEIGHT = 2, 2, 3.5, 1, 8
local WALK_FORCE = 200 / 3

local Gravity = {}
Gravity.__index = Gravity

function Gravity.new(character, humanoid, hrp, hooks)
	local self = setmetatable({}, Gravity)
	self.Character = character
	self.Humanoid = humanoid
	self.HRP = hrp
	self.Hooks = hooks or {}
	self.GravityUp = UNIT_Y
	self.Jumped = false
	self.JumpTick = 0
	self.Conns = {}
	self.Destroyed = false
	self.LastPart = nil
	self.LastPartCFrame = nil

	-- clean up leftovers from an earlier run
	for _, inst in ipairs(character:GetDescendants()) do
		if string.sub(inst.Name, 1, 4) == "SWW_" then
			inst:Destroy()
		end
	end

	self.GroundParams = makeParams({ character })

	-- how high the root part sits above the ground (works for R6 / R15 / scaled avatars)
	local height
	local res = Workspace:Raycast(hrp.Position, Vector3.new(0, -12, 0), self.GroundParams)
	if res and res.Distance > 1.5 and res.Distance < 9 then
		height = res.Distance
	elseif humanoid.RigType == Enum.HumanoidRigType.R6 then
		height = hrp.Size.Y / 2 + 2
	else
		height = hrp.Size.Y / 2 + humanoid.HipHeight
	end
	local radius = clamp(height / 3, 0.6, 3)
	local drop = height - radius + 0.05
	self.Radius = radius

	if humanoid.RigType == Enum.HumanoidRigType.R6 then
		self.HeadOffset = 1.5
	elseif humanoid.AutomaticScalingEnabled then
		self.HeadOffset = 1.5 + (hrp.Size.Y / 2 - 1)
	else
		self.HeadOffset = 2
	end

	-- ball under the feet (this is what actually touches the surface)
	local collider = Instance.new("Part")
	collider.Name = "SWW_Collider"
	collider.Shape = Enum.PartType.Ball
	collider.Size = Vector3.new(radius * 2, radius * 2, radius * 2)
	collider.Transparency = 1
	collider.CanCollide = true
	collider.CanQuery = false
	collider.CanTouch = false
	collider.Massless = true
	collider.CustomPhysicalProperties = PhysicalProperties.new(0.7, 0.3, 0, 1, 1)
	pcall(function()
		collider.CollisionGroup = hrp.CollisionGroup
	end)
	collider.CFrame = hrp.CFrame * CFrame.new(0, -drop, 0)
	collider.Parent = character
	local weld = Instance.new("Weld")
	weld.Name = "SWW_Weld"
	weld.Part0 = hrp
	weld.Part1 = collider
	weld.C0 = CFrame.new(0, -drop, 0)
	weld.Parent = collider
	self.Collider = collider

	local att = Instance.new("Attachment")
	att.Name = "SWW_Attachment"
	att.Parent = hrp
	self.Attachment = att

	local vf = Instance.new("VectorForce")
	vf.Name = "SWW_Force"
	vf.Attachment0 = att
	vf.RelativeTo = Enum.ActuatorRelativeTo.World
	vf.ApplyAtCenterOfMass = true
	vf.Force = ZERO
	vf.Parent = hrp
	self.VForce = vf

	local ao = Instance.new("AlignOrientation")
	ao.Name = "SWW_Align"
	ao.Mode = Enum.OrientationAlignmentMode.OneAttachment
	ao.Attachment0 = att
	ao.RigidityEnabled = false
	ao.MaxTorque = math.huge
	ao.MaxAngularVelocity = math.huge
	ao.Responsiveness = 50
	ao.CFrame = hrp.CFrame - hrp.CFrame.Position
	ao.Parent = hrp
	self.Align = ao

	self.SavedPlatformStand = humanoid.PlatformStand
	humanoid.PlatformStand = true

	self.Anim = AnimCtl.new(humanoid, character)
	self.Sound = SoundCtl.new(hrp)

	pcall(function()
		RunService:UnbindFromRenderStep(GRAV_BIND)
	end)
	RunService:BindToRenderStep(GRAV_BIND, Enum.RenderPriority.Input.Value + 1, function(dt)
		local ok, err = pcall(self.Step, self, dt)
		if not ok then
			self.StepErrors = (self.StepErrors or 0) + 1
			if self.StepErrors == 1 then
				warn("[SpiderWallWalk] step error: " .. tostring(err))
			end
		end
	end)
	table.insert(
		self.Conns,
		RunService.Heartbeat:Connect(function()
			pcall(self.OnHeartbeat, self)
		end)
	)
	table.insert(
		self.Conns,
		character.AncestryChanged:Connect(function(_, parent)
			if not parent then
				self:Destroy()
			end
		end)
	)
	return self
end

function Gravity:GetFocus(up)
	local hrp = self.HRP
	return hrp.Position + up * self.HeadOffset + hrp.CFrame:VectorToWorldSpace(self.Humanoid.CameraOffset)
end

function Gravity:Grounded()
	local res = Workspace:Raycast(
		self.Collider.Position,
		-self.GravityUp * (self.Radius + 0.6),
		self.GroundParams
	)
	return res ~= nil
end

-- the "brain": looks around the feet and decides which way is up
function Gravity:ComputeUp(oldUp)
	local hrpCF = self.HRP.CFrame
	local isR15 = self.Humanoid.RigType == Enum.HumanoidRigType.R15
	local origin = isR15 and hrpCF.Position or (hrpCF.Position + 0.35 * oldUp)

	local look = hrpCF.LookVector
	local radial
	if math.abs(look:Dot(oldUp)) < 0.999 then
		radial = look:Cross(oldUp)
	else
		radial = hrpCF.RightVector:Cross(oldUp)
	end
	if radial.Magnitude < 1e-4 then
		radial = perpendicular(oldUp)
	else
		radial = radial.Unit
	end

	local centerHit = Workspace:Raycast(origin, -25 * oldUp, worldParams)
	local mainNormal = centerHit and centerHit.Normal or ZERO
	local hits = centerHit and 1 or 0

	local downSum = ZERO
	local nDown = CONFIG.DownRays
	for i = 1, nDown do
		local dtheta = PI2 * ((i - 1) / nDown)
		local weight = 0.25 + 0.75 * math.abs(math.cos(dtheta))
		local even = (i % 2 == 0)
		local sr = even and EVEN_DOWN_START or ODD_DOWN_START
		local er = even and EVEN_DOWN_END or ODD_DOWN_END
		local off = CFrame.fromAxisAngle(oldUp, dtheta) * radial
		local dir = LOWER_RADIUS_OFFSET * -oldUp + (er - sr) * off
		local res = Workspace:Raycast(origin + sr * off, 25 * dir.Unit, worldParams)
		if res then
			downSum = downSum + weight * res.Normal
			hits = hits + 1
		end
	end

	local feelSum = ZERO
	local nFeel = CONFIG.FeelerRays
	for i = 1, nFeel do
		local dtheta = PI2 * ((i - 1) / nFeel)
		local weight = 0.25 + 0.75 * math.abs(math.cos(dtheta))
		local off = CFrame.fromAxisAngle(oldUp, dtheta) * radial
		local dir = (FEELER_RADIUS * off + LOWER_RADIUS_OFFSET * -oldUp).Unit
		local fo = origin + oldUp * FEELER_APEX + FEELER_START * dir
		local res = Workspace:Raycast(fo, FEELER_LENGTH * dir, worldParams)
		if res then
			feelSum = feelSum + FEELER_WEIGHT * weight * res.Normal
			hits = hits + 1
		end
	end

	if hits > 0 then
		local sum = mainNormal + downSum + feelSum
		if sum.Magnitude > 1e-3 then
			return sum.Unit
		end
	end
	return oldUp
end

function Gravity:OnHeartbeat()
	if self.Destroyed then
		return
	end
	local res = Workspace:Raycast(
		self.Collider.Position,
		-self.GravityUp * (self.Radius * 1.1),
		self.GroundParams
	)
	local hit = res and res.Instance
	local cf = hit and hit.CFrame
	if hit and hit == self.LastPart and cf ~= self.LastPartCFrame and self.LastPartCFrame then
		-- ride moving platforms
		local offset = self.LastPartCFrame:ToObjectSpace(self.HRP.CFrame)
		self.HRP.CFrame = cf:ToWorldSpace(offset)
	end
	self.LastPart = hit
	self.LastPartCFrame = cf
end

local function jumpSpeed(hum)
	if hum.UseJumpPower then
		return hum.JumpPower
	end
	return math.sqrt(2 * Workspace.Gravity * hum.JumpHeight)
end

function Gravity:Step(dt)
	if self.Destroyed then
		return
	end
	local cam = Workspace.CurrentCamera
	local hrp, hum = self.HRP, self.Humanoid
	if not cam or not hrp.Parent then
		return
	end
	dt = clamp(dt, 1 / 240, 1 / 15)
	syncWorldParams()

	-- 1. which way is up (smoothed for the camera, instant for the physics)
	local oldUp = self.GravityUp
	local newUp = self:ComputeUp(oldUp)
	local camCF = cam.CFrame
	local rot = IDENTITY:Lerp(rotationBetween(oldUp, newUp, camCF.RightVector), 1 - 0.85 ^ (dt * 60))
	self.GravityUp = (rot * oldUp).Unit

	-- 2. input -> world move direction (camera relative, along the surface)
	local move = Controls.GetMove(hum, camCF)
	local fDot = camCF.LookVector:Dot(newUp)
	local cForward = (math.abs(fDot) > 0.5) and (camCF.UpVector * -math.sign(fDot)) or camCF.LookVector
	local left = cForward:Cross(-newUp)
	if left.Magnitude < 1e-3 then
		left = perpendicular(newUp)
	else
		left = left.Unit
	end
	local back = newUp:Cross(left)
	local worldMove = back * move.Z - left * move.X
	if worldMove.Magnitude > 1 then
		worldMove = worldMove.Unit
	end
	local moving = worldMove.Magnitude > 0.02

	-- 3. body orientation (stand on the surface, face the way you walk)
	local hrpLook = hrp.CFrame.LookVector
	local charF = back * hrpLook:Dot(back) + left * hrpLook:Dot(left)
	if charF.Magnitude < 0.05 then
		charF = -back
	end
	charF = charF.Unit
	local charCF = CFrame.fromMatrix(ZERO, charF:Cross(newUp).Unit, newUp, -charF)
	local turn = IDENTITY
	if moving then
		turn = IDENTITY:Lerp(rotationBetween(charF, worldMove.Unit, newUp), 1 - 0.3 ^ (dt * 60))
	end
	local charRot = turn * charCF
	if self.Hooks.firstPersonLook then
		local fp = self.Hooks.firstPersonLook()
		if fp then
			local hlv = fp - newUp * newUp:Dot(fp)
			if hlv.Magnitude > 0.05 then
				hlv = hlv.Unit
				charRot = CFrame.fromMatrix(ZERO, hlv:Cross(newUp).Unit, newUp, -hlv)
			end
		end
	end

	-- 4. jump
	local now = os.clock()
	local grounded = self:Grounded()
	if self.Jumped and now - self.JumpTick > 0.25 then
		self.Jumped = false
	end
	if grounded and not self.Jumped and Controls.IsJumping(hum) then
		hrp.AssemblyLinearVelocity = hrp.AssemblyLinearVelocity + newUp * (jumpSpeed(hum) * CONFIG.JumpMultiplier)
		self.Jumped = true
		self.JumpTick = now
		self.Sound:Jump()
	end

	-- 5. forces
	local mass = hrp.AssemblyMass
	local gForce = Workspace.Gravity * mass * (UNIT_Y - newUp)
	local cVel = hrp.AssemblyLinearVelocity
	local upVel = cVel:Dot(newUp)
	local hVel = cVel - upVel * newUp
	if hVel:Dot(hVel) < 1 then
		hVel = ZERO
	end
	local dVel = worldMove * hum.WalkSpeed - hVel
	local fMag = math.min(10000, WALK_FORCE * mass * dVel.Magnitude / (dt * 60))
	local walkForce = (fMag > 0) and (dVel.Unit * fMag) or ZERO
	self.VForce.Force = walkForce + gForce
	self.Align.CFrame = charRot

	-- 6. animation (your animation pack) + sound
	local state = "idle"
	if grounded then
		if moving then
			state = "move"
		end
	elseif self.Jumped and upVel > 0 then
		state = "jump"
	else
		state = "fall"
	end
	self.Anim:Set(state, hVel.Magnitude)
	self.Sound:SetRunning(grounded and moving and hVel.Magnitude > 2)
end

function Gravity:Destroy()
	if self.Destroyed then
		return
	end
	self.Destroyed = true
	pcall(function()
		RunService:UnbindFromRenderStep(GRAV_BIND)
	end)
	for _, c in ipairs(self.Conns) do
		c:Disconnect()
	end
	self.Conns = {}
	if self.Anim then
		self.Anim:Destroy()
	end
	if self.Sound then
		self.Sound:Destroy()
	end
	for _, inst in ipairs({ self.Collider, self.VForce, self.Align, self.Attachment }) do
		pcall(function()
			inst:Destroy()
		end)
	end
	local hrp, hum = self.HRP, self.Humanoid
	if hum and hum.Parent and hum.Health > 0 then
		if hrp and hrp.Parent then
			-- stand upright again, same spot, same heading
			local look = hrp.CFrame.LookVector
			local flat = Vector3.new(look.X, 0, look.Z)
			if flat.Magnitude < 0.1 then
				local u = hrp.CFrame.UpVector
				flat = Vector3.new(u.X, 0, u.Z)
			end
			if flat.Magnitude < 0.1 then
				flat = Vector3.new(0, 0, -1)
			end
			local pos = hrp.Position
			hrp.CFrame = CFrame.new(pos, pos + flat.Unit)
			hrp.AssemblyAngularVelocity = ZERO
		end
		hum.PlatformStand = false
	end
	if self.Hooks.onDestroy then
		self.Hooks.onDestroy(self)
	end
end

------------------------------------------------------------------------------------------------------
-- SPIDER BUTTON  (web + spiders running around it + legs that grow when ON)
------------------------------------------------------------------------------------------------------
local COLOR_OFF = Color3.fromRGB(150, 160, 185)
local COLOR_ON = Color3.fromRGB(255, 64, 98)
local STAGGER = 0.4
local FOLD = math.rad(140)

local function easeOutCubic(x)
	return 1 - (1 - x) ^ 3
end

local function easeOutBack(x)
	local c1 = 1.70158
	local c3 = c1 + 1
	return 1 + c3 * (x - 1) ^ 3 + c1 * (x - 1) ^ 2
end

local function newLine(parent, x1, y1, x2, y2, th, color, z)
	local f = Instance.new("Frame")
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.BorderSizePixel = 0
	f.BackgroundColor3 = color
	f.ZIndex = z
	local dx, dy = x2 - x1, y2 - y1
	f.Size = UDim2.fromOffset(math.sqrt(dx * dx + dy * dy) + 0.6, th)
	f.Position = UDim2.fromOffset((x1 + x2) / 2, (y1 + y2) / 2)
	f.Rotation = math.deg(math.atan2(dy, dx))
	f.Parent = parent
	return f
end

-- draws a spider web (diameter lines + polygon rings, slightly sagging) out of thin frames
local function buildWeb(parent, cx, cy, R, o, out)
	for i = 0, o.lines - 1 do
		local a = math.rad(i * 180 / o.lines)
		local dx, dy = math.cos(a) * R, math.sin(a) * R
		out[#out + 1] = newLine(parent, cx - dx, cy - dy, cx + dx, cy + dy, o.th, o.color, o.z)
	end
	for _, rk in ipairs(o.rings) do
		local rho = R * rk
		for j = 0, o.sides - 1 do
			local a0 = math.rad(j * 360 / o.sides)
			local a1 = math.rad((j + 1) * 360 / o.sides)
			local x0, y0 = cx + rho * math.cos(a0), cy + rho * math.sin(a0)
			local x1, y1 = cx + rho * math.cos(a1), cy + rho * math.sin(a1)
			if o.sag >= 1 then
				out[#out + 1] = newLine(parent, x0, y0, x1, y1, o.th, o.color, o.z)
			else
				local am = math.rad((j + 0.5) * 360 / o.sides)
				local rm = rho * math.cos(math.rad(180 / o.sides)) * o.sag
				local mx, my = cx + rm * math.cos(am), cy + rm * math.sin(am)
				out[#out + 1] = newLine(parent, x0, y0, mx, my, o.th, o.color, o.z)
				out[#out + 1] = newLine(parent, mx, my, x1, y1, o.th, o.color, o.z)
			end
		end
	end
end

local function placeSegment(frame, th, x1, y1, x2, y2)
	local dx, dy = x2 - x1, y2 - y1
	local len = math.sqrt(dx * dx + dy * dy)
	if len < 0.6 then
		frame.Visible = false
		return
	end
	frame.Visible = true
	frame.Position = UDim2.fromOffset((x1 + x2) / 2, (y1 + y2) / 2)
	frame.Size = UDim2.fromOffset(len + th * 0.6, th)
	frame.Rotation = math.deg(math.atan2(dy, dx))
end

local function addCorner(inst, scale)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(scale, 0)
	c.Parent = inst
	return c
end

-- tiny spider: drawn facing UP inside its own square, the square is rotated to face where it runs.
-- leg = { angle of upper leg (deg, 0 = right, -90 = up), bend of lower leg }
local SPIDER_LEGS = { { -58, 32 }, { -20, 30 }, { 18, 28 }, { 54, 30 } }

local function buildSpider(parent, m, out)
	local u = m / 18
	local spider = { u = u, legs = {} }
	for side = 1, 2 do
		for j = 1, 4 do
			local def = SPIDER_LEGS[j]
			local leg = { base = def[1], bend = def[2], mirror = 1 }
			if side == 2 then
				leg.base, leg.bend, leg.mirror = 180 - def[1], -def[2], -1
			end
			-- alternating gait: legs 1+3 on one side move with legs 2+4 on the other
			leg.phase = ((side == 1) == (j % 2 == 1)) and 0 or math.pi
			for _, key in ipairs({ "a", "b" }) do
				local f = Instance.new("Frame")
				f.AnchorPoint = Vector2.new(0.5, 0.5)
				f.BorderSizePixel = 0
				f.BackgroundColor3 = COLOR_OFF
				f.ZIndex = 6
				f.Size = UDim2.fromOffset(2, 1)
				f.Parent = parent
				out[#out + 1] = f
				leg[key] = f
			end
			spider.legs[#spider.legs + 1] = leg
		end
	end
	local function blob(cx, cy, w, h)
		local f = Instance.new("Frame")
		f.AnchorPoint = Vector2.new(0.5, 0.5)
		f.Position = UDim2.fromOffset(cx * u, cy * u)
		f.Size = UDim2.fromOffset(w * u, h * u)
		f.BackgroundColor3 = COLOR_OFF
		f.BorderSizePixel = 0
		f.ZIndex = 6
		addCorner(f, 0.5)
		f.Parent = parent
		out[#out + 1] = f
	end
	blob(9, 11.4, 5.4, 6.6) -- abdomen
	blob(9, 7.0, 3.8, 4.2) -- head
	return spider
end

local function poseSpider(spider, step, amp)
	local u = spider.u
	local ax, ay = 9 * u, 7.6 * u
	local th = math.max(1, 1.1 * u)
	for _, leg in ipairs(spider.legs) do
		local ph = step + leg.phase
		local a1 = math.rad(leg.base + leg.mirror * math.sin(ph) * amp)
		local a2 = a1 + math.rad(leg.bend)
		local lift = 1 - 0.18 * math.max(0, math.cos(ph))
		local kx = ax + math.cos(a1) * 3.4 * u * lift
		local ky = ay + math.sin(a1) * 3.4 * u * lift
		local tx = kx + math.cos(a2) * 4.0 * u * lift
		local ty = ky + math.sin(a2) * 4.0 * u * lift
		placeSegment(leg.a, th, ax, ay, kx, ky)
		placeSegment(leg.b, th, kx, ky, tx, ty)
	end
end

local UI = {}
UI.__index = UI

function UI.new(onToggle)
	local self = setmetatable({}, UI)
	local SIZE = CONFIG.ButtonSize
	local HALF = SIZE / 2
	local scale = SIZE / 62
	self.size, self.half, self.scale = SIZE, HALF, scale
	self.conns = {}
	self.t = 0
	self.blend, self.target = 0, 0
	self.grow, self.legTarget = 0, 0
	self.legsShown = false
	self.legClock = 0
	self.dragging = false
	self.scaleTarget = 1
	self.pos, self.targetPos = nil, nil
	self.webLines, self.spiderParts, self.legStrokes = {}, {}, {}

	local gui = Instance.new("ScreenGui")
	gui.Name = "SpiderWallWalkUI"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 999
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	self.gui = gui

	local holder = Instance.new("Frame")
	holder.Name = "Holder"
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.Size = UDim2.fromOffset(SIZE, SIZE)
	holder.Position = UDim2.new(1, -70, 0.36, 0)
	holder.BackgroundTransparency = 1
	holder.Parent = gui
	self.holder = holder

	local uiScale = Instance.new("UIScale") -- gentle "lift" while you drag it
	uiScale.Parent = holder
	self.uiScale = uiScale

	-- legs (behind the body)
	local legsFrame = Instance.new("Frame")
	legsFrame.Name = "Legs"
	legsFrame.BackgroundTransparency = 1
	legsFrame.Size = UDim2.fromScale(1, 1)
	legsFrame.ZIndex = 1
	legsFrame.Parent = holder

	local defs = {
		{ -38, -78, -30 },
		{ -12, -42, -2 },
		{ 12, 42, 2 },
		{ 38, 78, 30 },
	}
	self.legs = {}
	for i = 1, 8 do
		local d = defs[(i + 1) // 2]
		local root, femur, tibia = d[1], d[2], d[3]
		if i % 2 == 0 then -- mirror to the left side
			root, femur, tibia = 180 - root, 180 - femur, 180 - tibia
		end
		local rel = math.rad(tibia - femur)
		local leg = {
			root = math.rad(root),
			femur = math.rad(femur),
			rel = rel,
			sign = (rel >= 0) and 1 or -1,
			delay = STAGGER * (i - 1) / 7,
			phase = i * 0.93,
			l1 = 15 * scale,
			l2 = 20 * scale,
			th1 = 4 * scale,
			th2 = 3 * scale,
		}
		for _, which in ipairs({ "seg1", "seg2" }) do
			local seg = Instance.new("Frame")
			seg.AnchorPoint = Vector2.new(0.5, 0.5)
			seg.BackgroundColor3 = Color3.fromRGB(26, 26, 34)
			seg.BorderSizePixel = 0
			seg.Visible = false
			seg.ZIndex = 1
			seg.Size = UDim2.fromOffset(2, 2)
			addCorner(seg, 0.5)
			local stroke = Instance.new("UIStroke")
			stroke.Thickness = 1
			stroke.Color = COLOR_OFF
			stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
			stroke.Parent = seg
			self.legStrokes[#self.legStrokes + 1] = stroke
			seg.Parent = legsFrame
			leg[which] = seg
		end
		self.legs[i] = leg
	end

	-- body
	local body = Instance.new("Frame")
	body.Name = "Body"
	body.Size = UDim2.fromScale(1, 1)
	body.BackgroundColor3 = Color3.new(1, 1, 1)
	body.BorderSizePixel = 0
	body.ZIndex = 3
	addCorner(body, 0.5)
	local grad = Instance.new("UIGradient")
	grad.Color = ColorSequence.new(Color3.fromRGB(34, 35, 48), Color3.fromRGB(9, 9, 14))
	grad.Rotation = 90
	grad.Parent = body
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = math.max(1.5, 2 * scale)
	stroke.Color = COLOR_OFF
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = body
	body.Parent = holder
	self.stroke = stroke

	-- web (slowly turns)
	local web = Instance.new("Frame")
	web.Name = "Web"
	web.AnchorPoint = Vector2.new(0.5, 0.5)
	web.Position = UDim2.fromScale(0.5, 0.5)
	web.Size = UDim2.fromOffset(SIZE, SIZE)
	web.BackgroundTransparency = 1
	web.ZIndex = 4
	web.Parent = holder
	self.web = web
	local small = SIZE < 54
	buildWeb(web, HALF, HALF, HALF - 4, {
		lines = 4,
		sides = 8,
		rings = small and { 0.34, 0.64, 1.0 } or { 0.26, 0.5, 0.75, 1.0 },
		sag = 0.88,
		th = small and 1.2 or 1.6,
		color = COLOR_OFF,
		z = 4,
	}, self.webLines)

	local core = Instance.new("Frame")
	core.Name = "Core"
	core.AnchorPoint = Vector2.new(0.5, 0.5)
	core.Position = UDim2.fromScale(0.5, 0.5)
	core.Size = UDim2.fromOffset(math.max(4, 7 * scale), math.max(4, 7 * scale))
	core.BackgroundColor3 = COLOR_OFF
	core.BorderSizePixel = 0
	core.ZIndex = 5
	addCorner(core, 0.5)
	core.Parent = holder
	self.core = core

	-- little spiders running around the rim of the web
	self.spiders = {}
	local sdefs = {
		{ angle = 0.5, dir = 1, speed = 1.15, rate = 2.1, phase = 0.0 },
		{ angle = 2.6, dir = -1, speed = 0.95, rate = 1.7, phase = 1.9 },
		{ angle = 4.6, dir = 1, speed = 1.35, rate = 2.6, phase = 3.7 },
	}
	for _, c in ipairs(sdefs) do
		local m = 22 * scale
		local f = Instance.new("Frame")
		f.Name = "RunningSpider"
		f.AnchorPoint = Vector2.new(0.5, 0.5)
		f.Size = UDim2.fromOffset(m, m)
		f.BackgroundTransparency = 1
		f.ZIndex = 6
		f.Parent = holder
		c.spider = buildSpider(f, m, self.spiderParts)
		c.step = c.phase
		c.frame = f
		poseSpider(c.spider, c.step, 18)
		self.spiders[#self.spiders + 1] = c
	end

	-- tap / drag (hit area is a little bigger than the button so it is easy to press)
	local hit = Instance.new("TextButton")
	hit.Name = "Hit"
	hit.AnchorPoint = Vector2.new(0.5, 0.5)
	hit.Position = UDim2.fromScale(0.5, 0.5)
	hit.Size = UDim2.new(1, 12, 1, 12)
	hit.BackgroundTransparency = 1
	hit.Text = ""
	hit.AutoButtonColor = false
	hit.ZIndex = 10
	hit.Parent = holder
	addCorner(hit, 0.5)

	local dragInput, dragStart, anchorPos, dragMoved
	hit.InputBegan:Connect(function(input)
		local t = input.UserInputType
		if t == Enum.UserInputType.Touch or t == Enum.UserInputType.MouseButton1 then
			dragInput = input
			dragStart = Vector2.new(input.Position.X, input.Position.Y)
			dragMoved = false
		end
	end)
	table.insert(
		self.conns,
		UserInputService.InputChanged:Connect(function(input)
			if not dragInput then
				return
			end
			local isDrag = input == dragInput
				or (
					dragInput.UserInputType == Enum.UserInputType.MouseButton1
					and input.UserInputType == Enum.UserInputType.MouseMovement
				)
			if not isDrag then
				return
			end
			local cur = Vector2.new(input.Position.X, input.Position.Y)
			if not dragMoved and (cur - dragStart).Magnitude > 8 then
				dragMoved = true
				local ap, as = holder.AbsolutePosition, holder.AbsoluteSize
				anchorPos = Vector2.new(ap.X + as.X / 2, ap.Y + as.Y / 2)
				self.pos = anchorPos
				self.targetPos = anchorPos
				self.dragging = true
				self.scaleTarget = 1.12
			end
			if dragMoved then
				local cam = Workspace.CurrentCamera
				local vp = cam and cam.ViewportSize or Vector2.new(800, 600)
				local p = anchorPos + (cur - dragStart)
				local m = HALF + 6
				self.targetPos = Vector2.new(clamp(p.X, m, vp.X - m), clamp(p.Y, m, vp.Y - m))
			end
		end)
	)
	table.insert(
		self.conns,
		UserInputService.InputEnded:Connect(function(input)
			if input == dragInput then
				dragInput = nil
				if dragMoved then
					self.dragging = false
					self.scaleTarget = 1
				else
					onToggle()
				end
			end
		end)
	)

	table.insert(
		self.conns,
		RunService.RenderStepped:Connect(function(dt)
			self:Step(math.min(dt, 0.1))
		end)
	)

	-- mount (hidden gui container first, then CoreGui, then PlayerGui)
	local candidates = {}
	pcall(function()
		if gethui then
			candidates[#candidates + 1] = gethui()
		end
	end)
	pcall(function()
		candidates[#candidates + 1] = game:GetService("CoreGui")
	end)
	candidates[#candidates + 1] = LocalPlayer:WaitForChild("PlayerGui")
	for _, parent in ipairs(candidates) do
		local ok = pcall(function()
			gui.Parent = parent
		end)
		if ok and gui.Parent == parent then
			break
		end
	end

	return self
end

function UI:ApplyColor()
	local c = COLOR_OFF:Lerp(COLOR_ON, self.blend)
	self.stroke.Color = c
	self.core.BackgroundColor3 = c
	for _, f in ipairs(self.webLines) do
		f.BackgroundColor3 = c
	end
	for _, f in ipairs(self.spiderParts) do
		f.BackgroundColor3 = c
	end
	for _, s in ipairs(self.legStrokes) do
		s.Color = c
	end
end

function UI:Pulse()
	local SIZE = self.size
	local ring = Instance.new("Frame")
	ring.AnchorPoint = Vector2.new(0.5, 0.5)
	ring.Position = UDim2.fromScale(0.5, 0.5)
	ring.Size = UDim2.fromOffset(SIZE, SIZE)
	ring.BackgroundTransparency = 1
	ring.ZIndex = 2
	addCorner(ring, 0.5)
	local st = Instance.new("UIStroke")
	st.Thickness = 2
	st.Color = (self.target > 0) and COLOR_ON or COLOR_OFF
	st.Parent = ring
	ring.Parent = self.holder
	local info = TweenInfo.new(0.55, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(ring, info, { Size = UDim2.fromOffset(SIZE * 2.1, SIZE * 2.1) }):Play()
	TweenService:Create(st, info, { Transparency = 1 }):Play()
	task.delay(0.6, function()
		ring:Destroy()
	end)
end

function UI:SetState(on)
	self.target = on and 1 or 0
	self.legTarget = on and 1 or 0
	self:Pulse()
end

function UI:IsOver(pos)
	local ap, as = self.holder.AbsolutePosition, self.holder.AbsoluteSize
	local m = 10
	return pos.X >= ap.X - m and pos.X <= ap.X + as.X + m and pos.Y >= ap.Y - m and pos.Y <= ap.Y + as.Y + m
end

function UI:UpdateLegs(t)
	local g = self.grow
	if g <= 0.0005 then
		if self.legsShown then
			for _, leg in ipairs(self.legs) do
				leg.seg1.Visible = false
				leg.seg2.Visible = false
			end
			self.legsShown = false
		end
		return
	end
	self.legsShown = true
	local half = self.half
	local idleK = clamp((g - 0.8) / 0.2, 0, 1) -- idle motion fades in once the legs are out
	for _, leg in ipairs(self.legs) do
		local p = clamp((g - leg.delay) / (1 - STAGGER), 0, 1)
		local fp = easeOutCubic(clamp(p / 0.6, 0, 1)) -- upper leg stretches out first
		local tp = clamp((p - 0.35) / 0.65, 0, 1)
		local te = math.max(easeOutBack(tp), 0) -- lower leg unfolds after (small overshoot)
		local fold = 1 - tp

		-- idle: slow flex + an occasional twitch (standing, not walking)
		local sway1 = math.sin(t * 1.9 + leg.phase) * 0.07 * idleK
		local sway2 = math.sin(t * 2.7 + leg.phase * 1.7) * 0.13 * idleK
		local twitch = (math.max(0, math.sin(t * 0.8 + leg.phase * 2.3)) ^ 14) * 0.3 * idleK

		local a1 = leg.femur + sway1
		local a2 = a1 + leg.rel + leg.sign * (fold * FOLD + twitch) + sway2
		local rx = half + math.cos(leg.root) * (half - 2)
		local ry = half + math.sin(leg.root) * (half - 2)
		local kx = rx + math.cos(a1) * leg.l1 * fp
		local ky = ry + math.sin(a1) * leg.l1 * fp
		local tx = kx + math.cos(a2) * leg.l2 * te
		local ty = ky + math.sin(a2) * leg.l2 * te
		placeSegment(leg.seg1, leg.th1, rx, ry, kx, ky)
		placeSegment(leg.seg2, leg.th2, kx, ky, tx, ty)
	end
end

function UI:Step(dt)
	self.t = self.t + dt
	local t = self.t
	local half, scale = self.half, self.scale

	-- smooth dragging: the button eases toward your finger instead of snapping to it
	if self.targetPos then
		local a = 1 - math.exp(-dt * 26)
		self.pos = self.pos:Lerp(self.targetPos, a)
		if not self.dragging and (self.targetPos - self.pos).Magnitude < 0.05 then
			self.pos = self.targetPos
			self.targetPos = nil
		end
		self.holder.Position = UDim2.fromOffset(self.pos.X, self.pos.Y)
	end
	local sc = self.uiScale.Scale
	if sc ~= self.scaleTarget then
		sc = sc + (self.scaleTarget - sc) * (1 - math.exp(-dt * 16))
		if math.abs(sc - self.scaleTarget) < 0.002 then
			sc = self.scaleTarget
		end
		self.uiScale.Scale = sc
	end

	if self.blend ~= self.target then
		local step = dt / 0.35
		if self.target > self.blend then
			self.blend = math.min(self.target, self.blend + step)
		else
			self.blend = math.max(self.target, self.blend - step)
		end
		self:ApplyColor()
	end

	if self.grow ~= self.legTarget then
		if self.legTarget > self.grow then
			self.grow = math.min(1, self.grow + dt / 1.0)
		else
			self.grow = math.max(0, self.grow - dt / 0.45)
		end
	end

	self.web.Rotation = (t * (6 + 14 * self.blend)) % 360

	-- spiders: run around the rim in stop-and-go bursts, legs moving as they go
	self.legClock = self.legClock + dt
	local poseNow = self.legClock >= (1 / 30)
	if poseNow then
		self.legClock = 0
	end
	for _, c in ipairs(self.spiders) do
		local gait = 0.35 + 0.65 * math.abs(math.sin(t * c.rate + c.phase))
		local boost = 1 + 0.8 * self.blend
		c.angle = c.angle + c.dir * c.speed * gait * dt * boost
		c.step = c.step + gait * c.speed * dt * 14 * boost
		local r = half + scale + math.sin(t * 5 + c.phase * 2) * 1.2 * scale
		c.frame.Position = UDim2.fromOffset(half + math.cos(c.angle) * r, half + math.sin(c.angle) * r)
		c.frame.Rotation = math.deg(c.angle) + ((c.dir > 0) and 180 or 0) + math.sin(t * 9 + c.phase) * 6
		if poseNow then
			poseSpider(c.spider, c.step, 18)
		end
	end

	if self.grow > 0 or self.legsShown then
		self:UpdateLegs(t)
	end
end

function UI:Destroy()
	for _, c in ipairs(self.conns) do
		c:Disconnect()
	end
	self.conns = {}
	pcall(function()
		self.gui:Destroy()
	end)
end

------------------------------------------------------------------------------------------------------
-- MANAGER  (toggle, respawn, sitting)
------------------------------------------------------------------------------------------------------
local Manager = {}
Manager.__index = Manager

function Manager.new(cameraCtl)
	local self = setmetatable({}, Manager)
	self.enabled = false
	self.controller = nil
	self.camera = cameraCtl
	self.conns = {}
	self.charConns = {}
	return self
end

function Manager:TryStart()
	if not self.enabled then
		return
	end
	if self.controller and not self.controller.Destroyed then
		return
	end
	local char = LocalPlayer.Character
	if not char or not char.Parent then
		return
	end
	local hum = char:FindFirstChildOfClass("Humanoid")
	local hrp = char:FindFirstChild("HumanoidRootPart") or (hum and hum.RootPart)
	if not hum or not hrp or hum.Health <= 0 or hum.Sit then
		return
	end

	local camera = self.camera
	local hooks = {
		firstPersonLook = function()
			if camera.firstPerson then
				return camera.look
			end
			return nil
		end,
		onDestroy = function(ctl)
			if self.controller == ctl then
				self.controller = nil
				camera:Stop()
			end
		end,
	}
	local ok, ctl = pcall(Gravity.new, char, hum, hrp, hooks)
	if not ok then
		warn("[SpiderWallWalk] could not start: " .. tostring(ctl))
		return
	end
	self.controller = ctl
	camera:Start(function()
		return ctl.GravityUp
	end, function(up)
		return ctl:GetFocus(up)
	end, self.isBlocked, char)
end

function Manager:StopController()
	local ctl = self.controller
	if ctl then
		ctl:Destroy()
	end
end

function Manager:BindCharacter(char)
	for _, c in ipairs(self.charConns) do
		c:Disconnect()
	end
	self.charConns = {}
	local hum = char:WaitForChild("Humanoid", 10)
	if not hum then
		return
	end
	table.insert(
		self.charConns,
		hum.Died:Connect(function()
			self:StopController()
		end)
	)
	table.insert(
		self.charConns,
		hum.Seated:Connect(function(active)
			if active then
				self:StopController()
			else
				task.delay(0.15, function()
					self:TryStart()
				end)
			end
		end)
	)
end

function Manager:SetEnabled(on)
	on = on and true or false
	if self.enabled == on then
		return
	end
	self.enabled = on
	if on then
		self:TryStart()
	else
		self:StopController()
	end
	if self.onChanged then
		self.onChanged(on)
	end
end

function Manager:Toggle()
	self:SetEnabled(not self.enabled)
end

function Manager:Init()
	if LocalPlayer.Character then
		task.spawn(function()
			self:BindCharacter(LocalPlayer.Character)
		end)
	end
	table.insert(
		self.conns,
		LocalPlayer.CharacterAdded:Connect(function(char)
			task.spawn(function()
				self:BindCharacter(char)
				if self.enabled then
					char:WaitForChild("HumanoidRootPart", 10)
					task.wait(0.5)
					self:TryStart()
				end
			end)
		end)
	)
end

function Manager:Destroy()
	self.enabled = false
	self:StopController()
	self.camera:Stop(true)
	for _, c in ipairs(self.conns) do
		c:Disconnect()
	end
	for _, c in ipairs(self.charConns) do
		c:Disconnect()
	end
	self.conns, self.charConns = {}, {}
end

------------------------------------------------------------------------------------------------------
-- BOOT
------------------------------------------------------------------------------------------------------
Controls.Init()

local cameraCtl = CameraCtl.new()
local manager = Manager.new(cameraCtl)
local ui = UI.new(function()
	manager:Toggle()
end)
manager.isBlocked = function(pos)
	return ui:IsOver(pos)
end
manager.onChanged = function(on)
	ui:SetState(on)
end
manager:Init()

env.__SpiderWallWalk = {
	Destroy = function()
		manager:Destroy()
		ui:Destroy()
		Controls.Destroy()
	end,
}

if CONFIG.StartEnabled then
	manager:SetEnabled(true)
end
