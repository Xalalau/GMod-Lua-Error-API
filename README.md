# GMod Lua Error API

Don't wait for players to report issues, get the errors automatically!

## Why would I want this API instead of building my own?

Because I carefully wrote my API to be reloadable, accessible, and error-proof, while also running as fast as possible! It has been battle-tested by hundreds of thousands of players on my addons, and it **works**.

## Shared data

Here it is (http.Post):

```
    realm         'SERVER' or 'CLIENT'
    databaseName  An arbitrary name given to identify the addon database
    msg           A brief 1-line message containing a hint as to why the error occurred
    map           Map name. Knowing the map can help if it has scripts or if it's important to scripts
    gamemode      Game mode name. Addons target certain game modes, and ignoring this can generate errors
    stack         The text that appears in the console showing the function calls that created the bug
    quantity      How many times an error occurred since the last time it was reported
    versionDate   The addon gma timestamp, used to ignore reports from older addon releases. Legacy addons are set to 0
```

The sent information is extremely basic and does not identify users in any way. Therefore, it's collected under the General Data Protection Regulation (GDPR) Legitimate Interest legal basis and requires no authorization from players.

## How to use

Add the following lines to your project, changing the API version if needed and inputting your own settings:

```Lua
timer.Simple(0, function()
    http.Fetch("https://raw.githubusercontent.com/Xalalau/GMod-Lua-Error-API/main/sh_error_api_v2.lua", function(APICode, len, headers, code)
        if code == 200 then
            RunString(APICode)
            ErrorAPIV2:RegisterAddon(
                "https://mywebsite.com", -- database URL
                "database_name", -- database name
                "0123456789" -- workshop addon wsid
            )
        end
        InitMyAddon()
    end, function()
        InitMyAddon()
    end)
end)
```

I'd put it in ``/lua/autorun/somefile.lua``, so both server and client errors will be processed.

The ErrorAPIV2() call returns the object responsible for controlling how the API works. These are its current properties (for version 2):
```
    -- Configurable, base:

    boolean enabled      = true to send errors,
    string  url          = server URL,
    string  databaseName = SQL table name,

    -- Configurable, identify the addon. Requires at least 1 field to work:

    string  wsid             = OPTIONAL workshop addon wsid,
    string  legacyFolderName = OPTIONAL addon folder name inside the addons directory (will be disabled if the folder doesn't exist)
    table   searchSubstrings = OPTIONAL { string error msg substring (at least 3 letters), ... }
```

Note1: Check sh_error_api_v2.lua for extra internal settings.

Note2: There's no problem with the API being loaded by multiple addons; it was designed to work like that. No information will be lost.

## Data usage example

You can currently see this API feeding data here: https://gerror.xalalau.com/

It helps me a lot to keep gm_construct_13_beta stable.

The code for gerror is VERY simple and open-source: https://github.com/Xalalau/gerror

I'm avoiding building a complex solution because I like my free time, but the possibilities are endless here.

Maybe the best way to deal with this data is setting up a service like Sentry (https://sentry.io/), but I'm not sure as I've never used it before.

## Why is this API being hotloaded instead of using the Steam Workshop?

The Workshop is certainly a viable option, but I don't want to force players to subscribe to yet another addon just to make our lives easier.

With hotloading:
- No one needs to subscribe to a new addon
- Devs don't need to copy the code manually and end up generating version chaos and conflicts
- API updates are still delivered automatically
- Errors are still reported normally

The only disadvantage of this method is that it won't catch initialization errors if the addons don't wait for it to load.

Enjoy!

