local component = require("component")
local computer = require("computer")
local robot = require("robot")
local shell = require("shell")
local sides = require("sides")
local bit32 = require('bit32')
local math = require('math')
if not component.isAvailable("robot") then
	io.stderr:write("can only run on robots")
	return
end

if not component.isAvailable('geolyzer') then
	io.stderr:write("can only run with a geolyzer")
	return
end

if not component.isAvailable('inventory_controller') then
	io.stderr:write('can only run with an inventory controller')
	return
end

local args, options = shell.parse(...)

if options.h then
	io.write('Usage: digore [-lnhs]\n')
	io.write(' -s: shutdown when done.\n')
	io.write(' -h: show this usage\n')
	--io.write(' -l: specific max length of a single tunnel\n')
	io.write(' -n: specific max number of tunnels\n')
	return
end

local max_tunnel = 1
local tunnel_cnt = 0
local max_length = 6
if options.n then
	max_tunnel = tonumber(args[1])
	if not max_tunnel or max_tunnel < 1 then 
		io.write('invalid number')
		return
	end
end


--local size = tonumber(args[1])
--if not size then
--	io.stderr:write("invalid size")
--	return
--end

local function pass() end

local r = component.robot
local geo = component.geolyzer
local inv_ctrl = component.inventory_controller
local x, y, z, f = 0, 0, 0, 0
local delta = {[0] = function() x = x + 1 end, [1] = function() y = y + 1 end,
							 [2] = function() x = x - 1 end, [3] = function() y = y - 1 end,
							 [4] = function() z = z + 1 end, [5] = function() z = z - 1 end}
local start_slot = 1
local max_slot = r.inventorySize()
				
local function turnRight()
	robot.turnRight()
	f = (f + 1) % 4
end

local function turnLeft()
	robot.turnLeft()
	f = (f - 1) % 4
end

local function turnTowards(side)
	if f == side - 1 then
		turnRight()
	else
		while f ~= side do
			turnLeft()
		end
	end
end

local function resetXyz()
	x, y, z = 0, 0, 0
end

local function manhattan()
	return math.abs(x) + math.abs(y) + math.abs(z)
end

local function rface(f)
	return bit32.bxor(f,2)
end

local checkedDrop -- forward declaration

local function clearBlock(side, cannotRetry)
	while r.suck(side) do
		checkedDrop()
	end
	local result, reason = r.swing(side)
	if result then
		checkedDrop()
	else
		local _, what = r.detect(side)
		if cannotRetry and what ~= "air" and what ~= "entity" then
			return false
		end
	end
	return true
end

local function tryMove(side,force)
	side = side or sides.forward
	if force then
		local tries = 5
		while not r.move(side) do
			local _, what = r.detect(side)
			if what ~= 'entity' then tries = tries - 1 end
			if not clearBlock(side, tries < 1) then
				return false
			end
		end
	else
		local _, what = r.detect(side)
		if what ~= "air" and what ~= "entity" then
			return false
		end
		r.move(side)
	end
	if side == sides.down then
		z = z + 1
	elseif side == sides.up then
		z = z - 1
	else
		delta[f]()
	end
	return true
end
	
local function forward()
	tryMove(sides.forward, true)
end

local function moveTo(tx, ty, tz)
	local axes = {
		function(force)
			if z > tz then
				return tryMove(sides.up,force)
			end
			if z < tz then
				return tryMove(sides.down,force)
			end
			return false
		end,
		function(force)
			if y > ty then
				turnTowards(3)
				return tryMove(sides.forward,force)
			elseif y < ty then
				turnTowards(1)
				return tryMove(sides.forward,force)
			end
			return false
		end,
		function(force)
			if x > tx then
				turnTowards(2)
				return tryMove(sides.forward,force)
			elseif x < tx then
				turnTowards(0)
				return tryMove(sides.forward,force)
			end
			return false
		end
	}
	while x~=tx or y~=ty or z~=tz do
		if axes[1]() or axes[2]() or axes[3]() then 
			pass()
		elseif axes[1](true) or axes[2](true) or axes[3](true) then pass()
		else 
			return false
		end
	end
	return true
end

function checkedDrop(force)
	local empty = 0
	local inv_size = robot.inventorySize()
	
	for slot = start_slot, inv_size do
		if robot.count(slot) == 0 then
			empty = empty + 1
		end
	end
	if empty == 0 or force and empty < inv_size then
		local ox, oy, oz, of = x, y, z, f
		moveTo(0, 0, 0)
		turnTowards(2)

		for slot = start_slot, inv_size do
			if robot.count(slot) > 0 then
				robot.select(slot)
				local wait = 1
				repeat
					if not robot.drop() then
						os.sleep(wait)
						wait = math.min(10, wait + 1)
					end
				until robot.count(slot) == 0
			end
		end
		robot.select(start_slot)

		moveTo(ox, oy, oz)
		turnTowards(of)
	end
end

local function turn(i)
	if i % 2 == 1 then
		turnRight()
	else
		turnLeft()
	end
end

local function equip()
	if not equip_slot then
		return false 
	end
	robot.equip(equip_slot)
	return true
end

local function isOre(side)
	return string.match(geo.analyze(side).name,'[Oo][Rr][Ee]')
end

local function bfs()
	if isOre(sides.up) then
		tryMove(sides.up,true)
		bfs()
		tryMove(sides.down,true)
	end
	if isOre(sides.down) then
		tryMove(sides.down,true)
		bfs()
		tryMove(sides.up,true)
	end
	local has_ore = false
	for side = 2,5 do
		if isOre(side) then
			has_ore = true
			break
		end
	end
	if not has_ore then return end
	for i = 1,4 do
		if isOre(sides.forward) then
			forward()
			bfs()
			r.move(sides.back)
			delta[rface(f)]()
		end
		turnLeft()
	end
end


local function checkAll()
	local maht = manhattan()
	if maht * 25 + 500 > computer.energy() then
		return false, 'energy'
	end
	if r.space() < 1 then
		return false, 'full'
	end
	return true, ''
end

local function loop()
	while true do
		local ok, reason = checkAll()
		if (not ok) and reason == 'full' then 
			ox, oy, oz, of = x, y, z, of
			moveTo(0,0,0)
			checkedDrop()
			moveTo(ox,oy,oz)
			turnTowards(of)
		elseif (not ok) and reason == 'energy' then
			moveTo(0,0,0)
			io.write('No energy\nWork stopped.\n')
			return false
		end
		turnTowards(0)
		forward()
		bfs()
		if manhattan() > max_length then
			moveTo(0,0,0)
			checkedDrop()
			return
		end
	end
end

local function exit(ret)
	ret = ret or 0
	local ckl = component.chunkloader
	if ckl and ckl.isActive() then 
		ckl.setActive(false)
	end
	if options.s then
		computer.shutdown()
	end
	os.exit(ret)
end

function main()
	local ckl = component.chunkloader
	if ckl and not ckl.isActive() then
		ckl.setActive(true)
	end
	local sy = 0
	for tunnel_cnt = 1, max_tunnel do
		moveTo(0, sy, 0)
		turnTowards(0)
		loop()
		sy = 3 + sy
	end
end

main()
