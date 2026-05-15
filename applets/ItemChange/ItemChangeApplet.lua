local pairs, ipairs, tostring, tonumber, type, getmetatable = pairs, ipairs, tostring, tonumber, type, getmetatable

local oo            = require("loop.simple")
local Applet        = require("jive.Applet")
local Framework     = require("jive.ui.Framework")

local jnt                    = jnt
local jiveMain               = jiveMain

module(..., Framework.constants)
oo.class(_M, Applet)

local _player = false
local _server = false

function init(self)
    jnt:subscribe(self)
    log:info("itemchange applet initialized")
end

function free(self)
	-- unsubscribe from this player's itemchange
	if _player then
		_player:unsubscribe('/slim/itemchange/' .. _player:getId())
	end

	_player = false
end

-- notify_playerDelete
-- this is called when the player disappears
function notify_playerDelete(self, player)
	log:debug("notify_playerDelete(", player, ")")

	if _player == player then
		-- unsubscribe from this player's itemchange
		if _player then
			_player:unsubscribe('/slim/itemchange/' .. _player:getId())
		end
		self.playerOrServerChangeInProgress = true
	end
end

-- notify_playerCurrent
-- this is called when the current player changes (possibly from no player)
function notify_playerCurrent(self, player)
	log:info("itemchange:notify_playerCurrent(", player, ")")

	if _player ~= player then
		-- free current player, since it has changed from one player to another
		if _player then
			self:free()
		end
	end

	-- nothing to do if we don't have a player
	-- NOTE don't move this, the code above needs to run when disconnecting
	-- for all players.
	if not player then
		return
	end

	if not _server and not self.serverInitComplete then
		--serverInitComplete check to avoid reselecting server on a soft_reset
		self.serverInitComplete = true
		_server = appletManager:callService("getInitialSlimServer")
		log:info("No server, Fetching initial server, ", _server)
	end

	--can't subscribe to itemchange until we have a server
	if not player:getSlimServer() then
		return
	end

	if not player:getSlimServer():isConnected() then
		log:info("player changed from:", _player, " to ", player, " but server not yet connected")
		return
	end

	self.playerOrServerChangeInProgress = false

	log:info("player changed from:", _player, " to ", player, " for server: ", player:getSlimServer(), " from server: ", _server)

	_player = player
	_server = player:getSlimServer()

	local _playerId = _player:getId()

	log:info('\nSubscribing to /slim/itemchange/\n', _playerId)
	local cmd = { 'itemchange' }
	_player:subscribe(
		'/slim/itemchange/' .. _playerId,
		_changeItem(self),
		_playerId,
		cmd
	)
end

local function _findWidgetById(container, id)

    if not container then
        return nil
    end

    if container.id == id then
        return container
    end

    if container.widgets then

        for _, widget in ipairs(container.widgets) do

            local found = _findWidgetById(widget, id)

            if found then
                return found
            end
        end
    end

    return nil
end

local ipairs = ipairs
local pairs = pairs
local tostring = tostring
local type = type
local getmetatable = getmetatable

local function dumpObject(obj, indent, visited)

    indent = indent or ""
    visited = visited or {}

    if not obj then
        return
    end

    if visited[obj] then
        log:warn(indent .. "*RECURSION*")
        return
    end

    visited[obj] = true

    log:warn(indent .. "OBJECT: " .. tostring(obj))
    log:warn(indent .. "TYPE: " .. type(obj))

    --
    -- propriétés Lua visibles
    --
    for k, v in pairs(obj) do

        log:warn(
            indent ..
            "PROP " ..
            tostring(k) ..
            " = " ..
            tostring(v)
        )
    end

    --
    -- metatable
    --
    local mt = getmetatable(obj)

    if mt then

        log:warn(indent .. "METATABLE:")

        for k, v in pairs(mt) do

            if type(v) == "function" then

                log:warn(
                    indent ..
                    "  METHOD " ..
                    tostring(k)
                )

            else

                log:warn(
                    indent ..
                    "  META " ..
                    tostring(k) ..
                    " = " ..
                    tostring(v)
                )
            end
        end

        --
        -- méthodes __index
        --
        if mt.__index then

            log:warn(indent .. "METATABLE.__index:")

            for k, v in pairs(mt.__index) do

                if type(v) == "function" then

                    log:warn(
                        indent ..
                        "  METHOD " ..
                        tostring(k)
                    )

                else

                    log:warn(
                        indent ..
                        "  FIELD " ..
                        tostring(k) ..
                        " = " ..
                        tostring(v)
                    )
                end
            end
        end
    end

    --
    -- widgets enfants
    --
    if obj.widgets then

        log:warn(indent .. "CHILDREN:")

        for _, child in ipairs(obj.widgets) do
            dumpObject(child, indent .. "    ", visited)
        end
    end
end

local function dumpWidget(widget, indent, visited)

    indent = indent or ""
    visited = visited or {}

    if not widget then
        return
    end

    if visited[widget] then
        log:warn(indent .. "*RECURSION*")
        return
    end

    visited[widget] = true

    log:warn(indent .. "OBJECT: " .. tostring(widget))

    --
    -- type tolua
    --
    if tolua and tolua.type then
        log:warn(indent .. "TOLUA TYPE: " .. tostring(tolua.type(widget)))
    end

    --
    -- propriétés Lua
    --
    for k,v in pairs(widget) do
        log:warn(indent .. "PROP " .. tostring(k) .. "=" .. tostring(v))
    end

    --
    -- méthodes natives
    --
    local mt = getmetatable(widget)

    if mt and mt.__index then

        for k,v in pairs(mt.__index) do

            if type(v) == "function" then
                log:warn(indent .. "METHOD " .. tostring(k))
            end
        end
    end

    --
    -- enfants via getWidgets()
    --
    if widget.getWidgets then

        local children = widget:getWidgets()

        if children then

            log:warn(indent .. "CHILDREN:")

            for _, child in ipairs(children) do
                dumpWidget(child, indent .. "    ", visited)
            end
        end
    end
end

function _changeItem(self, chunk)
	return function(chunk, err)
        menuId = chunk.data[2]
        itemIndex = chunk.data[3]
        newState = chunk.data[4]
        playerId = chunk.data[5]
        log:debug("_changeItem closure menu " .. menuId .. "item index " .. itemIndex .. " to state " .. newState .. " for player " .. playerId)
        
        itemIndex = tonumber(itemIndex)
        
        local stack = Framework.windowStack

        if not stack then
            log:warn("no window stack")
            return
        end

        if not stack[1] then
            log:warn("no window in stack")
            return
        end

        local i = 1
        log:debug("Exploring stack")

        while stack[i] do
            log:debug("Stack " .. i)
            local window = stack[i]
            if window.windowId then
                log:debug("testing window " .. window.windowId)
            else
                log:debug("window with no id")
            end
            if window.windowId and (tostring(window.windowId) == tostring(menuId)) then
                log:debug("window ok")
                --log:warn("Menu")
				--dumpObject(window.widgets[1]:getItems().data.cmd)
				--local menu = jiveMain:getMenuItem(menuId)
				--log:warn("menu")
				--dumpObject(menu)

				--log:warn("menus")
				--dumpObject(jiveMain:getMenuTable())
				--log:warn("nodes")				
				--dumpObject(jiveMain:getNodeTable())

				--dumpObject(window.widgets)
                --log:warn("A")
				--dumpObject(window.widgets[1])
                --log:warn("Aa")
				--dumpObject(window.widgets[1].widgets['textinput'])
                --log:warn("AA")
				--dumpObject(window.widgets[1].widgets[itemIndex])
                --log:warn("AAA")
				--dumpObject(window.widgets[1].widgets[itemIndex].widgets)
                --log:warn("AAQ")
				--dumpObject(window.widgets[1].widgets[itemIndex].widgets['check'])
                --log:warn("AAT")
				--dumpObject(window.widgets[1].widgets[itemIndex].widgets['text'])
                --log:warn("AAI")
				--dumpObject(window.widgets[1].widgets[itemIndex].widgets['icon'])
                --log:warn("AAR")
				--dumpObject(window.widgets[1].widgets[itemIndex].widgets['arrow'])
                local item = window.widgets[1].widgets[itemIndex]
                if (item._type == "checkbox") then
                    item.widgets['check']:setSelected(tonumber(newState) ~= 0)
                elseif (item._type == "choice") then
                    item.widgets['check']:setSelectedIndex(tonumber(newState))
                end
				
				--local mygroup = window.widgets[1].widgets[1]
				--for k,v in pairs(mygroup) do
				--	log:warn("W " .. tostring(k) .. "=" .. tostring(v) .. " type " .. type(k))
				--	local retrievedMeta = getmetatable(k)
				--	log:warn("W " .. tostring(retrievedMeta) .. "=" .. tostring(v) .. " type " .. type(retrievedMeta))
				--	if type(retrievedMeta) == "table" then
				--		for l,m in pairs(retrievedMeta) do
				--			log:warn("X " .. tostring(k) .. "=" .. tostring(v))
				--		end
				--	end
				--end

				--log:warn("children")				
				--dumpObject(window.widgets[1].widgets[1].widgets[1])
				
				--log:warn("children2")				
				--local child = window.widgets[1].widgets[1]:getWidget(1)
				--log:warn(tostring(child))
				
                --log:warn("reloading")
                --window:show()

                return
            end

            i = i + 1
        end
    end
end
