--[[
    Automatic error reporting

    A better way to handle errors: send them to a server instead of waiting for players to report them.

    This library was initially created to address gm_construct_13_beta issues but evolved into a small
    standalone solution.

    ---------------------------

    Data to be sent:
        realm         SERVER or CLIENT
        databaseName  An arbitrary name given to identify the buggy addon
        msg           A brief one-line message containing a hint as to why the error occurred
        map           Map name. Knowing the map can help if it has scripts or if it's important to scripts
        gamemode      Game mode name. Addons target certain game modes and ignoring this can generate errors
        stack         The text that appears in the console showing the function calls that created the bug
        quantity      How many times an error occurred since the last time it was reported
        versionDate   The addon GMA timestamp, used to ignore reports from older addon releases. Legacy addons are set to 0

    This information is extremely basic and does not identify users in any way, therefore
    it's collected under the General Data Protection Regulation (GDPR) Legitimate Interest
    legal basis.

    By the way, a system to receive the reports is needed, so I created a small website people can use
    as a starting point: https://github.com/Xalalau/gerror

    You can currently see it running here: https://gerror.xalalau.com/

    - Xalalau Xubilozo
]]

-- Variables

local version = 2

local printResponses = false

local baseReportDelay = 1 -- Base delay between reports of the same error. The final delay will always be incremented by the API to protect the server from looping errors

_G["ErrorAPIV" .. version] = _G["ErrorAPIV" .. version] or {
    registered = { --[[
        {
            -- Configurable, base:

            boolean enabled      = true to send errors,
            string  url          = server URL,
            string  databaseName = SQL table name,

            -- Configurable, identify the addon. Requires at least 1 field to work:

            string  wsid             = OPTIONAL workshop addon WSID,
            string  legacyFolderName = OPTIONAL addon folder name inside the addons directory (will be disabled if the folder doesn't exist)
            table   searchSubstrings = OPTIONAL { string error message substring (at least 3 letters), ... }

            -- Internal:

            string  versionDate = the time when the workshop addon was last updated or 0 for legacy/scanned addons
            boolean isUrlOnline = if the URL is online,
            table   errors = {
                [string error ID] = {
                    string error,    -- The main error message, one line
                    string stack,    -- Full error stack, multiple lines
                    int    quantity, -- Error count
                    bool   queuing   -- If the error is waiting to be sent again it queues new occurrences
                }, ...
            }
        }, ...       ]]
    },
    fastFind = {
        wsid = {}, -- All tables here store { [string some key] = { table addonData, ... }, ... } 
        folderName = {},
        substring = {}
    },
    fastCheckErrors = {} -- { [string error message] = boolean found or not by the API } -- Used to prevent processing of recurring errors that don't concern the API
}

local ErrorAPI = _G["ErrorAPIV" .. version]

-- Error API internal issues caught by xpcall
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
            print("ErrorAPI: WARNING!!! Offline URL: " .. addonData.url)
        end
    )
end

-- Check if the registered URLs are online
local function AutoCheckURL(addonData)
    if not timer.Exists(addonData.url) then
        timer.Create(addonData.url, math.random(500, 600), 0, function()
            if not addonData.isUrlOnline then
                CheckURL(addonData)
            else
                timer.Remove(addonData.url)
            end
        end)
    end
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
        string url = server URL,

        -- Define at least one addon identifier:

        string  wsid             = OPTIONAL workshop addon WSID,
        string  legacyFolderName = OPTIONAL addon folder name inside the addons directory (will be disabled if the folder doesn't exist)
        table   searchSubstrings = OPTIONAL { string error message substring (at least 3 letters), ... }

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

    if not url then print("ErrorAPI: " .. errorMsgStart .. " Missing URL.") return end
    if not databaseName then print("ErrorAPI: " .. errorMsgStart .. " Missing databaseName.") return end
    if databaseName == "" then print("ErrorAPI: " .. errorMsgStart .. " databaseName can't be an empty string.") return end
    if wsid == "" then print("ErrorAPI: " .. errorMsgStart .. " WSID can't be an empty string.") return end
    if legacyFolderName == "" then print("ErrorAPI: " .. errorMsgStart .. " legacyFolderName can't be an empty string.") return end
    if not isstring(url) then print("ErrorAPI: " .. errorMsgStart .. " URL must be a string.") return end
    if not isstring(databaseName) then print("ErrorAPI: " .. errorMsgStart .. " databaseName must be a string.") return end
    if searchSubstrings and not istable(searchSubstrings) then print("ErrorAPI: " .. errorMsgStart .. " searchSubstrings must be a table.") return end
    if wsid and not isstring(wsid) then print("ErrorAPI: " .. errorMsgStart .. " WSID must be a string.") return end
    if legacyFolderName and not isstring(legacyFolderName) then print("ErrorAPI: " .. errorMsgStart .. " legacyFolderName must be a string.") return end
    if not string.find(url, "http", 1, true) then print("ErrorAPI: " .. errorMsgStart .. " Please write the URL in full") return end

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
        print("ErrorAPI: Addon GMA not found or WSID not provided for database " .. databaseName .. ". addonData.versionDate will be set as 0.")
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

    print("ErrorAPI: database " .. databaseName .. " registered (WSID " .. (wsid or "None") .. ")")

    -- Ping the database URL
    AutoCheckURL(addonData)

    timer.Simple(0, function() -- Trick to avoid calling HTTP too early
        CheckURL(addonData)
    end)

    return addonData
end

-- Succeeded to send an error to the server
local function OnReportSuccess(addonData, msg, resp, reportedQuantity)
    if printResponses then
        print(resp)
    end

    -- Reset the counting
    addonData.errors[msg].quantity = addonData.errors[msg].quantity - reportedQuantity

    -- Finish the steps
    addonData.errors[msg].queuing = false
end

-- Failed to send an error to the server
local function OnReportFail(addonData, msg, resp)
    if printResponses then
        print(resp)
    end

    -- Finish the steps
    addonData.errors[msg].queuing = false

    -- Check if the database is online
    AutoCheckURL(addonData)
end

-- Send script error to server
local function Report(addonData, msg)
    if not addonData.isUrlOnline then return end

    local reportedQuantity = addonData.errors[msg].quantity
    local parameters = {
        realm = SERVER and "SERVER" or "CLIENT",
        databaseName = addonData.databaseName,
        msg = msg,
        stack = addonData.errors[msg].stack,
        map = game.GetMap(),
        gamemode = engine.ActiveGamemode(),
        quantity = tostring(reportedQuantity),
        versionDate = tostring(addonData.versionDate)
    }

    -- Set "queuing" to true
    addonData.errors[msg].queuing = true

    -- Send error report to the server
    local incrementalDelay = addonData.errors[msg].totalQuantity / 100000 -- Protect the server from looping errors

    timer.Simple(baseReportDelay + incrementalDelay, function()
        if addonData.isUrlOnline then
            parameters.quantity = tostring(reportedQuantity)

            http.Post(addonData.url .. "/add.php", parameters,
                function(resp)
                    OnReportSuccess(addonData, msg, resp, reportedQuantity)
                end,
                function(resp)
                    OnReportFail(addonData, msg, resp)
                end
            )
        else
            addonData.errors[msg].queuing = false
        end
    end)
end

-- Register a newly found error
local function Create(addonData, msg, stack)
    addonData.errors[msg] = {
        totalQuantity = 1,
        quantity = 1,
        queuing = true -- Initialize the error status as "queuing" to avoid conflicts with concurrent occurrences
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
end

-- Deal with recurring errors
local function Update(addonData, msg)
    -- Increase the error count
    addonData.errors[msg].quantity = addonData.errors[msg].quantity + 1
    addonData.errors[msg].totalQuantity = addonData.errors[msg].totalQuantity + 1
end

-- Search for substrings in the script error main message
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

-- Decide whether an error should be reported or not
local function ProcessError(msg, stack, addonTitle, addonId)
    if not next(ErrorAPI.registered) then return {} end
    if ErrorAPI.fastCheckErrors[msg] == false then return {} end -- false means we've already checked the error and it's not useful for the API

    local addonDataList = {}

    if ErrorAPI.fastCheckErrors[msg] == nil then
        -- Search for WSID
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

    return addonDataList
end

-- The main function
local function Main(msg, realm, stack, addonTitle, addonId)
    -- Process error
    local addonDataList = ProcessError(msg, stack, addonTitle, addonId)

    -- Report wanted results
    if next(addonDataList) then
        local gotReport, ret = nil

        -- addonData will be changed in Create or Update functions
        for addonData, _ in pairs(addonDataList) do
            if addonData.errors[msg] == nil then
                Create(addonData, msg, stack)
                Report(addonData, msg)
            else
                Update(addonData, msg)

                if not addonData.errors[msg].queuing then
                    Report(addonData, msg)
                end
            end
        end
    end
end

-- The holy OnLuaError hook, that we almost had to kill Rubat to be released
--      https://github.com/Facepunch/garrysmod-requests/issues/149
hook.Add("OnLuaError", "sev_errors_handler_v" .. version, function(msg, realm, stack, addonTitle, addonId)
    xpcall(Main, PrintInternalError, msg, realm, stack, addonTitle, addonId)
end)
