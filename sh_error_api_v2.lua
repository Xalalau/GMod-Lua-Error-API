do return end -- temporarily disabled, I need to review the code to decrease the number of server requests

--[[
    Automatic error reporting

    An better way to handle errors: send them to a server instead of waiting for players to report

    This library was initially created to address gm_construct_13_beta issues but evolved to a small
    standalone solution.

    ---------------------------

    Data to be sent:
        realm         SERVER or CLIENT
        databaseName  An arbitrary name given to identify the buggy addon
        msg           A brief 1 line message containing a hint as to why the error occurred
        map           Map name. Knowing the map can help if it has scripts of if it's important to scripts
        gamemode      Game mode name. Addons target certain game modes and disrespecting this can generate errors
        stack         The text that appears in the console showing the function calls that created the bug
        quantity      How many times an error occurred since the last time it was reported
        versionDate   The addon gma timestamp, used to ignore reports from older addon releases. Legacy addons are set to 0

    This information is extremely basic and does not identify users in any way, therefore
    it's collected under the General Data Protection Regulation (GDPR) Legitimate Interest
    legal basis.

    By the way, a system to receive the reports is needed, so I created an small website people can use
    as a start point: https://github.com/Xalalau/gerror

    You can currently see it running here: https://gerror.xalalau.com/

    - Xalalau Xubilozo
]]

-- Vars

local version = 2

local printResponses = false

local reportDelay = 10 -- Delay between reports of the same error. Set to 0 to disable

_G["ErrorAPIV" .. version] = _G["ErrorAPIV" .. version] or {
    registered = { --[[
        {
            -- Configurable, base:

            boolean enabled      = true to send errors,
            string  url          = server url,
            string  databaseName = SQL table name,

            -- Configurable, identify the addon. Requires at least 1 field to work:

            string  wsid             = OPTIONAL workshop addon wsid,
            string  legacyFolderName = OPTIONAL addon folder name inside the addons directory (will be disabled if the folder doesn't exist)
            table   searchSubstrings = OPTIONAL { string error msg substring (at least 3 letters), ... }

            -- Internal:

            string  versionDate = the time when the workshop addon was last updated or 0 for legacy/scanned addons
            boolean isUrlOnline = if the url is online,
            table   errors = {
                [string error ID] = {
                    string error,    -- The main error message, 1 line
                    string stack,    -- Full error stack, multiple lines
                    int    quantity, -- Error count
                    bool   queuing   -- If the error is waiting to be sent again it queues new occurences
                }, ...
            }
        }, ...       ]]
    },
    fastFind = {
        wsid = {}, -- All tables here store { [string some key] = { table addonDAta, ... }, ... } 
        folderName = {},
        substring = {}
    },
    fastCheckErrors = {} -- { [string error msg] = boolean found or not by the API } -- Used to prevent processing of recurring errors that don't concern the API
}

local ErrorAPI = _G["ErrorAPIV" .. version]

-- Error API internal issues got by xpcall
local function PrintInternalError(err)
    print("ErrorAPI: Internal error: " .. err)
end

-- Check if a registered URL is online
local function CheckURL(addonData)
    http.Post(
        addonData.url .. "/ping.php",
        {},
        function(response)
            if printResponses then
                print(response)
            end

            addonData.isUrlOnline = true
        end,
        function()
            addonData.isUrlOnline = false
            print("ErrorAPI: WARNING!!! Offline url: " .. addonData.url)
        end
    )
end

-- Check if the registered URLs are online
local function AutoCheckURL(addonData)
    if not timer.Exists(addonData.url) then
        timer.Simple(0, function() -- Trick to avoid calling http too early
            CheckURL(addonData)
        end)
    end

    timer.Create(addonData.url, 600, 0, function()
        if not addonData.isUrlOnline then
            CheckURL(addonData)
        else
            timer.Remove(addonData.url)
        end
    end)
end

-- Make it easier to find the addons as processing errors can be an intensive task
local function AddToFastFind(addonData)
    if addonData.wsid then
        if not ErrorAPI.fastFind.wsid[addonData.wsid] then 
            ErrorAPI.fastFind.wsid[addonData.wsid] = {}
        end
        table.insert(ErrorAPI.fastFind.wsid[addonData.wsid], addonData)
    end

    if addonData.legacyFolderName then
        if not ErrorAPI.fastFind.folderName[addonData.legacyFolderName] then 
            ErrorAPI.fastFind.folderName[addonData.legacyFolderName] = {}
        end

        table.insert(ErrorAPI.fastFind.folderName[addonData.legacyFolderName], addonData)
    end

    if addonData.searchSubstrings then
        for k, substring in ipairs(addonData.searchSubstrings) do
            if not ErrorAPI.fastFind.substring[substring] then 
                ErrorAPI.fastFind.substring[substring] = {}
            end
    
            table.insert(ErrorAPI.fastFind.substring[substring], addonData)
        end
    end
end

-- Register an addon to send errors
--[[
    Arguments:
        -- Required:

        string databaseName = database name,
        string url = server url,

        -- Define at least one addon identifier:

        string  wsid             = OPTIONAL workshop addon wsid,
        string  legacyFolderName = OPTIONAL addon folder name inside the addons directory (will be disabled if the folder doesn't exist)
        table   searchSubstrings = OPTIONAL { string error msg substring (at least 3 letters), ... }

    return:
        success = table addonData -- Explained above
        fail = nil
]]
function ErrorAPI:RegisterAddon(url, databaseName, wsid, legacyFolderName, searchSubstrings)
    local errorMsgStart = "Failed to register database " .. databaseName .. "."

    -- Strongly check the arguments to avoid errors
    if not wsid and not legacyFolderName and not searchSubstrings then
        print("ErrorAPI: " .. errorMsgStart .. " Define at least 1 addon identifier")
        return
    end

    if not url then print("ErrorAPI: " .. errorMsgStart .. " Missing url.") return end
    if not databaseName then print("ErrorAPI: " .. errorMsgStart .. " Missing databaseName.") return end
    if databaseName == "" then print("ErrorAPI: " .. errorMsgStart .. " databaseName can't be an empty string.") return end
    if wsid == "" then print("ErrorAPI: " .. errorMsgStart .. " wsid can't be an empty string.") return end
    if legacyFolderName == "" then print("ErrorAPI: " .. errorMsgStart .. " legacyFolderName can't be an empty string.") return end
    if not isstring(url) then print("ErrorAPI: " .. errorMsgStart .. " url must be a string.") return end
    if not isstring(databaseName) then print("ErrorAPI: " .. errorMsgStart .. " databaseName must be a string.") return end
    if searchSubstrings and not istable(searchSubstrings) then print("ErrorAPI: " .. errorMsgStart .. " searchSubstrings must be a table.") return end
    if wsid and not isstring(wsid) then print("ErrorAPI: " .. errorMsgStart .. " wsid must be a string.") return end
    if legacyFolderName and not isstring(legacyFolderName) then print("ErrorAPI: " .. errorMsgStart .. " legacyFolderName must be a string.") return end
    if not string.find(url, "http", 1, true) then print("ErrorAPI: " .. errorMsgStart .. " Please write the url in full") return end

    if searchSubstrings then
        local count = 1
        for k, v in SortedPairs(searchSubstrings) do
            if isstring(k) or k ~= count or not isstring(v) then print("ErrorAPI: " .. errorMsgStart .. " searchSubstrings table must contain only strings.") return end
            if string.len(v) <= 3 then print("ErrorAPI: " .. errorMsgStart .. " searchSubstrings can't be less than 3 characters.") return end
            count = count + 1
        end
    end

    local versionDate = 0
    if wsid then
        for k, addonInfo in ipairs(engine.GetAddons()) do
            if addonInfo.wsid == wsid then
                versionDate = addonInfo.updated
                break
            end
        end
    end
    if versionDate == 0 then
        print("ErrorAPI: Addon gma not found or wsid not provided for database " .. databaseName .. ". addonData.versionDate will be set as 0.")
        return
    end

    -- Unregister older instances of this entry
    if next(ErrorAPI.registered) then
        for k, addonData in ipairs(ErrorAPI.registered) do
            local remove = false

            if wsid then
                if addonData.wsid == wsid then
                    remove = true
                end
            else
                if addonData.databaseName == databaseName then
                    remove = true
                end
            end

            if remove then
                print("ErrorAPI: An old entry for database " .. databaseName .. " has been removed from the API.")
                table.remove(ErrorAPI.registered, k)
                break
            end
        end
    end

    -- Register the addon
    local addonData = {
        enabled = true,
        url = url,
        databaseName = databaseName,
        wsid = wsid,
        legacyFolderName = legacyFolderName,
        searchSubstrings = searchSubstrings,
        versionDate = versionDate,
        isUrlOnline = nil,
        errors = {}
    }

    table.insert(ErrorAPI.registered, addonData)

    AddToFastFind(addonData)

    print("ErrorAPI: database " .. databaseName .. " registered (wsid " .. wsid .. ")")

    -- Ping the database url
    AutoCheckURL(addonData)

    return addonData
end

-- Process delayed reports. This mode is supposed to protect the webserver from overloading
    -- After we stop queuing an error we should send what's stored.
    -- To do so, first we wait 0.1s to cover looping errors, as they will call Report() anyway.
    -- Then if it's not the case, we'll check the error quantity. 0 means nothing new happened,
    -- so we can go away from these timers. But if we got new error registered, we need to send
    -- them and repeat the whole cycle using the same delay.

    -- Note1: I like to create recursive functions with timers because they create tail calls and save memory
    -- Note2: incrementalDelay is exponencial. It's meant to protect the server against looping errors
local function HandleDelayedReports(msg, parameters, addonData, incrementalDelay)
    incrementalDelay = incrementalDelay or 0

    timer.Simple(reportDelay + incrementalDelay, function()
        addonData.errors[msg].queuing = false

        timer.Simple(0.1, function()
            if addonData.errors[msg].queuing == false and addonData.isUrlOnline then
                if addonData.errors[msg].quantity > 0 then
                    parameters.quantity = tostring(addonData.errors[msg].quantity)

                    http.Post(addonData.url .. "/add.php", parameters,
                        function(resp)
                            if printResponses then
                                print(resp)
                            end

                            addonData.errors[msg].quantity = 0
                        end
                    )

                    addonData.errors[msg].queuing = true

                    HandleDelayedReports(msg, parameters, addonData, (incrementalDelay or 1) * 2)
                end
            end
        end)
    end)
end

-- Send script error to server
local function Report(addonData, msg)
    if not addonData.isUrlOnline then return end

    local parameters = {
        realm = SERVER and "SERVER" or "CLIENT",
        databaseName = addonData.databaseName,
        msg = msg,
        stack = addonData.errors[msg].stack,
        map = game.GetMap(),
        gamemode = engine.ActiveGamemode(),
        quantity = tostring(addonData.errors[msg].quantity),
        versionDate = tostring(addonData.versionDate)
    }

    -- Set "queuing" to true
    addonData.errors[msg].queuing = true

    -- Send the error as it is, so we always register it
    http.Post(addonData.url .. "/add.php", parameters,
        function(resp)
            if printResponses then
                print(resp)
            end

            -- Reset the counting
            addonData.errors[msg].quantity = 0

            -- Finish the steps if no delay is provided
            if reportDelay == 0 then
                addonData.errors[msg].queuing = false
            end
        end,
        function(resp)
            if printResponses then
                print(resp)
            end

            -- Finish the steps if no delay is provided
            if reportDelay == 0 then
                addonData.errors[msg].queuing = false
            end

            -- Check if the database is online
            AutoCheckURL(addonData)
        end
    )

    -- Process delayed reports. This mode is supposed to protect the webserver from overloading
    if reportDelay > 0 then
        HandleDelayedReports(msg, parameters, addonData)
    end
end

-- Search for substrings in the script error main msg
local function Scan(msg)
    local addonDataList = {}
    local selected = {}

    for k, substring in ipairs(ErrorAPI.fastFind.substring) do
        if string.find(msg, substring, nil, true) then -- Patterns feature is actually turned off for performance
            for k2, addonData in ipairs(ErrorAPI.fastFind.substring[substring]) do
                if not selected[addonData] then
                    table.insert(addonDataList, addonData)
                    selected[addonData] = true
                end
            end
        end
    end

    return selected
end

-- Register a new found error
local function Create(addonData, msg, stack)
    addonData.errors[msg] = {
        quantity = 1,
        queuing = true -- Initialize the error status as "queuing" to avoid conflicts with concurrent occurences
    }

    -- Format the stack
    local stackFormatted = "stack traceback:\n"

    for k, line in ipairs(stack) do
        stackFormatted = stackFormatted .. "    " .. line.File .. ":" .. line.Line

        if line.Function and line.Function ~= "" then
            stackFormatted = stackFormatted .. ": in function " .. line.Function
        end

        stackFormatted = stackFormatted .. "\n"
    end

    addonData.errors[msg].stack = stackFormatted

    -- Report the new error
    Report(addonData, msg)
end

-- Deal with recurring errors
local function Update(addonData, msg)
    -- Increase the error counting
    addonData.errors[msg].quantity = addonData.errors[msg].quantity + 1

    -- Report the current error count if it's not already waiting to be sent
    if not addonData.errors[msg].queuing then
        Report(addonData, msg)
    end
end

-- Decide whether an error should be reported or not
local function ProcessError(msg, stack, addonTitle, addonId)
    if not next(ErrorAPI.registered) then return end
    if ErrorAPI.fastCheckErrors[msg] == false then return end -- false means we've already checked the error and it's not usefull for the API

    local addonDataList = {}

    if ErrorAPI.fastCheckErrors[msg] == nil then
        -- Search for wsid
        if addonId and ErrorAPI.fastFind.wsid[addonId] then
            for k, addonData in ipairs(ErrorAPI.fastFind.wsid[addonId]) do
                addonDataList[addonData] = true
            end
        end

        -- Search for folder name
        if isstring(addonTitle) and ErrorAPI.fastFind.folderName[addonTitle] then
            for k, addonData in ipairs(ErrorAPI.fastFind.folderName[addonTitle]) do
                addonDataList[addonData] = true
            end
        end

        -- Search for substrings
        if next(ErrorAPI.fastFind.substring) then
            local succ, partialAddonDataList = xpcall(Scan, PrintInternalError, msg)

            if succ then
                for k, addonData in ipairs(partialAddonDataList) do
                    addonDataList[addonData] = true
                end
            end
        end

        -- Register the results
        if next(addonDataList) then
            if not ErrorAPI.fastCheckErrors[msg] then
                ErrorAPI.fastCheckErrors[msg] = addonDataList
            end
        else
            ErrorAPI.fastCheckErrors[msg] = false
        end
    else
        -- Get earlier results
        addonDataList = ErrorAPI.fastCheckErrors[msg]
    end

    -- Process results
    if next(addonDataList) then
        for addonData, _ in pairs(addonDataList) do
            if addonData.errors[msg] == nil then
                xpcall(Create, PrintInternalError, addonData, msg, stack)
            else
                xpcall(Update, PrintInternalError, addonData, msg)
            end
        end
    end
end

-- The holy OnLuaError hook, that we almost had to kill Rubat to be released
--      https://github.com/Facepunch/garrysmod-requests/issues/149
hook.Add("OnLuaError", "sev_errors_handler_v" .. version, function(str, realm, stack, addonTitle, addonId)
    ProcessError(str, stack, addonTitle, addonId)
end)
