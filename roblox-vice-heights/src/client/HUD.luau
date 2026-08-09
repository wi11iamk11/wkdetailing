--!nonstrict
--[[
	HUD
	Cash, health and armour, wanted stars, the weapon readout, the speedometer
	and the current objective. Everything reads from ClientState, so this file
	contains no game logic at all.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local Util = require(Shared.Util)
local WeaponCatalog = require(Shared.WeaponCatalog)

local ClientState = require(script.Parent.ClientState)
local UiKit = require(script.Parent.UiKit)

local HUD = {}

local player = Players.LocalPlayer
local STAR = "\u{2605}"

local widgets = {}

--------------------------------------------------------------------------------
-- Construction
--------------------------------------------------------------------------------

local function buildCash(parent: Instance)
	local label = UiKit.text({
		Name = "Cash",
		Position = UDim2.new(1, -24, 0, 18),
		Size = UDim2.fromOffset(240, 34),
		AnchorPoint = Vector2.new(1, 0),
		Font = Enum.Font.GothamBold,
		TextSize = 30,
		TextColor3 = Config.UI.Cash,
		TextXAlignment = Enum.TextXAlignment.Right,
		TextStrokeTransparency = 0.6,
		Text = "$0",
		Parent = parent,
	})
	widgets.cash = label

	ClientState.onChange("cash", function(value)
		label.Text = Util.money(value or 0)
	end)
end

local function buildStars(parent: Instance)
	local holder = UiKit.new("Frame", {
		Name = "Wanted",
		Position = UDim2.new(1, -24, 0, 58),
		Size = UDim2.fromOffset(200, 30),
		AnchorPoint = Vector2.new(1, 0),
		BackgroundTransparency = 1,
		Parent = parent,
	})
	UiKit.new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Right,
		Padding = UDim.new(0, 4),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = holder,
	})

	local stars = {}
	for index = 1, Config.Wanted.MaxStars do
		stars[index] = UiKit.text({
			Name = "Star" .. index,
			LayoutOrder = index,
			Size = UDim2.fromOffset(26, 30),
			Font = Enum.Font.GothamBold,
			TextSize = 26,
			Text = STAR,
			TextColor3 = Color3.fromRGB(60, 62, 70),
			TextXAlignment = Enum.TextXAlignment.Center,
			TextStrokeTransparency = 0.5,
			Parent = holder,
		})
	end

	local flashing = false
	ClientState.onChange("wanted", function(value)
		local count = value or 0
		for index, star in stars do
			star.TextColor3 = index <= count and Config.UI.Accent or Color3.fromRGB(60, 62, 70)
			star.Visible = index <= math.max(count, 1) or count > 0
		end
		holder.Visible = count > 0

		if count > 0 and not flashing then
			flashing = true
			task.spawn(function()
				while ClientState.get("wanted") > 0 do
					local active = ClientState.get("wanted")
					for index, star in stars do
						if index <= active then
							star.TextTransparency = 0.65
						end
					end
					task.wait(0.45)
					for index, star in stars do
						if index <= active then
							star.TextTransparency = 0
						end
					end
					task.wait(0.45)
				end
				for _, star in stars do
					star.TextTransparency = 0
				end
				flashing = false
			end)
		end
	end)
end

local function buildVitals(parent: Instance)
	local holder = UiKit.new("Frame", {
		Name = "Vitals",
		Position = UDim2.new(0, 24, 1, -30),
		Size = UDim2.fromOffset(260, 18),
		AnchorPoint = Vector2.new(0, 1),
		BackgroundTransparency = 1,
		Parent = parent,
	})

	local healthTrack, healthFill = UiKit.bar(Config.UI.Health, {
		Name = "Health",
		Size = UDim2.fromOffset(260, 8),
		Position = UDim2.fromOffset(0, 0),
		Parent = holder,
	})
	local armorTrack, armorFill = UiKit.bar(Config.UI.Armor, {
		Name = "Armor",
		Size = UDim2.fromOffset(260, 6),
		Position = UDim2.fromOffset(0, 12),
		Parent = holder,
	})

	widgets.health = healthFill
	widgets.armor = armorFill

	ClientState.onChange("health", function(value)
		local ratio = math.clamp((value or 100) / Config.Combat.MaxHealth, 0, 1)
		healthFill.Size = UDim2.fromScale(ratio, 1)
		healthTrack.Visible = true
	end)

	ClientState.onChange("armor", function(value)
		local ratio = math.clamp((value or 0) / Config.Combat.MaxArmor, 0, 1)
		armorFill.Size = UDim2.fromScale(ratio, 1)
		armorTrack.Visible = ratio > 0
	end)
end

local function buildWeapon(parent: Instance)
	local panel = UiKit.panel({
		Name = "Weapon",
		Position = UDim2.new(1, -24, 1, -24),
		Size = UDim2.fromOffset(210, 62),
		AnchorPoint = Vector2.new(1, 1),
		Parent = parent,
	})

	local name = UiKit.text({
		Name = "Name",
		Position = UDim2.fromOffset(14, 8),
		Size = UDim2.fromOffset(182, 20),
		Font = Enum.Font.GothamBold,
		TextSize = 16,
		Text = "Fists",
		Parent = panel,
	})

	local ammo = UiKit.text({
		Name = "Ammo",
		Position = UDim2.fromOffset(14, 30),
		Size = UDim2.fromOffset(182, 24),
		Font = Enum.Font.GothamBold,
		TextSize = 22,
		TextColor3 = Config.UI.Accent,
		Text = "-",
		Parent = panel,
	})

	local function refresh()
		local id = ClientState.get("equipped") or "fists"
		local def = WeaponCatalog.get(id)
		if not def then
			return
		end
		name.Text = def.name

		if def.melee then
			ammo.Text = "\u{221E}"
			return
		end

		local reserve = 0
		local weapons = ClientState.get("weapons")
		if type(weapons) == "table" and weapons[id] then
			reserve = weapons[id].reserve or 0
		end

		local reloading = ClientState.get("reloading")
		if type(reloading) == "number" and reloading > 0 then
			ammo.Text = "<font color='#e2a04a'>RELOADING</font>"
		else
			ammo.Text = string.format(
				"%d <font size='14' color='#8a8c94'>/ %d</font>",
				ClientState.get("mag") or 0,
				reserve
			)
		end
	end

	ClientState.onChange("equipped", refresh)
	ClientState.onChange("mag", refresh)
	ClientState.onChange("weapons", refresh)
	ClientState.onChange("reloading", function(value)
		refresh()
		if type(value) == "number" and value > 0 then
			task.delay(value, refresh)
		end
	end)
end

local function buildSpeedometer(parent: Instance)
	local panel = UiKit.panel({
		Name = "Speedo",
		Position = UDim2.new(1, -24, 1, -98),
		Size = UDim2.fromOffset(210, 54),
		AnchorPoint = Vector2.new(1, 1),
		Visible = false,
		Parent = parent,
	})

	local speed = UiKit.text({
		Name = "Speed",
		Position = UDim2.fromOffset(14, 6),
		Size = UDim2.fromOffset(182, 30),
		Font = Enum.Font.GothamBold,
		TextSize = 26,
		Text = "0",
		Parent = panel,
	})
	local unit = UiKit.text({
		Name = "Unit",
		Position = UDim2.fromOffset(14, 34),
		Size = UDim2.fromOffset(182, 14),
		TextSize = 12,
		TextColor3 = Config.UI.Muted,
		Text = "MPH",
		Parent = panel,
	})
	local damage = UiKit.text({
		Name = "Damage",
		Position = UDim2.fromOffset(120, 34),
		Size = UDim2.fromOffset(76, 14),
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Right,
		TextColor3 = Config.UI.Muted,
		Text = "",
		Parent = panel,
	})

	widgets.speedo = panel
	widgets.speedText = speed
	widgets.speedDamage = damage
	unit.Visible = true
end

local function buildObjective(parent: Instance)
	local panel = UiKit.panel({
		Name = "Objective",
		Position = UDim2.new(0, 24, 0, 18),
		Size = UDim2.fromOffset(300, 76),
		Visible = false,
		Parent = parent,
	})

	local title = UiKit.text({
		Name = "Title",
		Position = UDim2.fromOffset(14, 8),
		Size = UDim2.fromOffset(272, 18),
		Font = Enum.Font.GothamBold,
		TextSize = 14,
		TextColor3 = Config.UI.Accent,
		Text = "",
		Parent = panel,
	})
	local body = UiKit.text({
		Name = "Body",
		Position = UDim2.fromOffset(14, 28),
		Size = UDim2.fromOffset(272, 20),
		TextSize = 16,
		Text = "",
		Parent = panel,
	})
	local meta = UiKit.text({
		Name = "Meta",
		Position = UDim2.fromOffset(14, 50),
		Size = UDim2.fromOffset(272, 16),
		TextSize = 13,
		TextColor3 = Config.UI.Muted,
		Text = "",
		Parent = panel,
	})

	ClientState.onChange("objective", function(value)
		if type(value) ~= "table" then
			panel.Visible = false
			return
		end
		panel.Visible = true
		title.Text = string.format("%s  -  %d/%d", value.mission, value.stage, value.stages)
		body.Text = value.text or ""

		local pieces = {}
		if value.timeLeft and value.timeLeft > 0 then
			table.insert(pieces, Util.clock(value.timeLeft))
		end
		if value.extra then
			table.insert(pieces, value.extra)
		end
		meta.Text = table.concat(pieces, "   ")
	end)
end

local function buildRobbery(parent: Instance)
	local panel = UiKit.panel({
		Name = "Robbery",
		Position = UDim2.new(0.5, 0, 0, 90),
		Size = UDim2.fromOffset(260, 44),
		AnchorPoint = Vector2.new(0.5, 0),
		Visible = false,
		Parent = parent,
	})
	local label = UiKit.text({
		Position = UDim2.fromOffset(14, 6),
		Size = UDim2.fromOffset(232, 16),
		TextSize = 13,
		Text = "Emptying the register",
		Parent = panel,
	})
	local _, fill = UiKit.bar(Config.UI.Accent, {
		Size = UDim2.fromOffset(232, 8),
		Position = UDim2.fromOffset(14, 26),
		Parent = panel,
	})
	label.Visible = true

	local total = Config.Economy.StoreRobbery.Duration
	local hideTask
	ClientState.onChange("robbery", function(value)
		if type(value) ~= "number" or value <= 0 then
			panel.Visible = false
			return
		end
		panel.Visible = true
		fill.Size = UDim2.fromScale(math.clamp(1 - value / total, 0, 1), 1)
		if hideTask then
			task.cancel(hideTask)
		end
		-- The server stops sending updates the moment the robbery ends.
		hideTask = task.delay(1.5, function()
			panel.Visible = false
		end)
	end)
end

--------------------------------------------------------------------------------
-- Start
--------------------------------------------------------------------------------

function HUD.start()
	local screen = UiKit.screen("ViceHUD", 10)

	buildCash(screen)
	buildStars(screen)
	buildVitals(screen)
	buildWeapon(screen)
	buildSpeedometer(screen)
	buildObjective(screen)
	buildRobbery(screen)

	-- Health also arrives locally, which is smoother than waiting for a patch.
	local function watchCharacter(character: Model)
		local humanoid = character:WaitForChild("Humanoid", 10)
		if humanoid then
			humanoid.HealthChanged:Connect(function(health)
				ClientState.merge({ health = health })
			end)
			ClientState.merge({ health = humanoid.Health })
		end
		character:GetAttributeChangedSignal("Armor"):Connect(function()
			ClientState.merge({ armor = character:GetAttribute("Armor") or 0 })
		end)
	end

	player.CharacterAdded:Connect(watchCharacter)
	if player.Character then
		task.spawn(watchCharacter, player.Character)
	end
end

--- VehicleController feeds the speedometer; HUD does not go looking for cars.
function HUD.setVehicle(model: Model?, speedMph: number?)
	if not widgets.speedo then
		return
	end
	if not model then
		widgets.speedo.Visible = false
		return
	end
	widgets.speedo.Visible = true
	widgets.speedText.Text = tostring(math.floor((speedMph or 0) + 0.5))

	local health = model:GetAttribute("Health") or Config.Vehicle.MaxHealth
	local ratio = health / Config.Vehicle.MaxHealth
	if ratio > 0.6 then
		widgets.speedDamage.Text = ""
	else
		widgets.speedDamage.Text = string.format(
			"<font color='%s'>%d%%</font>",
			ratio > 0.3 and "#e2a04a" or "#e24848",
			math.floor(ratio * 100)
		)
	end
end

return HUD
