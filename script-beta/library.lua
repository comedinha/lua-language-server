local lni    = require 'lni'
local fs     = require 'bee.filesystem'
local config = require 'config'
local util   = require 'utility'
local lang   = require 'language'
local client = require 'provider.client'

local m = {}

local function mergeEnum(lib, locale)
    if not lib or not locale then
        return
    end
    local pack = {}
    for _, enum in ipairs(lib) do
        if enum.enum then
            pack[enum.enum] = enum
        end
        if enum.code then
            pack[enum.code] = enum
        end
    end
    for _, enum in ipairs(locale) do
        if pack[enum.enum] then
            if enum.description then
                pack[enum.enum].description = enum.description
            end
        end
        if pack[enum.code] then
            if enum.description then
                pack[enum.code].description = enum.description
            end
        end
    end
end

local function mergeField(lib, locale)
    if not lib or not locale then
        return
    end
    local pack = {}
    for _, field in ipairs(lib) do
        if field.field then
            pack[field.field] = field
        end
    end
    for _, field in ipairs(locale) do
        if pack[field.field] then
            if field.description then
                pack[field.field].description = field.description
            end
        end
    end
end

local function mergeLocale(libs, locale)
    if not libs or not locale then
        return
    end
    for name in pairs(locale) do
        if libs[name] then
            if locale[name].description then
                libs[name].description = locale[name].description
            end
            mergeEnum(libs[name].enums, locale[name].enums)
            mergeField(libs[name].fields, locale[name].fields)
        end
    end
end

local function isMatchVersion(version)
    if not version then
        return true
    end
    local runtimeVersion = config.config.runtime.version
    if type(version) == 'table' then
        for i = 1, #version do
            if version[i] == runtimeVersion then
                return true
            end
        end
    else
        if version == runtimeVersion then
            return true
        end
    end
    return false
end

local function insertGlobal(tbl, key, value)
    if not isMatchVersion(value.version) then
        return false
    end
    if not value.doc then
        value.doc = key
    end
    tbl[key] = {
        type  = 'library',
        name  = key,
        child = {},
        value = value,
    }
    value.library = tbl[key]
    return true
end

local function insertOther(tbl, key, value)
    if not value.version then
        return
    end
    if not tbl[key] then
        tbl[key] = {}
    end
    if type(value.version) == 'string' then
        tbl[key][#tbl[key]+1] = value.version
    elseif type(value.version) == 'table' then
        for _, version in ipairs(value.version) do
            if type(version) == 'string' then
                tbl[key][#tbl[key]+1] = version
            end
        end
    end
    table.sort(tbl[key])
end

local function insertCustom(tbl, key, value, libName)
    if not tbl[key] then
        tbl[key] = {}
    end
    tbl[key][#tbl[key]+1] = libName
    table.sort(tbl[key])
end

local function isEnableGlobal(libName)
    if config.config.runtime.library[libName] then
        return true
    end
    if libName:sub(1, 1) == '@' then
        return true
    end
    return false
end

local function mergeSource(alllibs, name, lib, libName)
    if not lib.source then
        if isEnableGlobal(libName) then
            local suc = insertGlobal(alllibs.global, name, lib)
            if not suc then
                insertOther(alllibs.other, name, lib)
            end
        else
            insertCustom(alllibs.custom, name, lib, libName)
        end
        return
    end
    for _, source in ipairs(lib.source) do
        local sourceName = source.name or name
        if source.type == 'global' then
            if isEnableGlobal(libName) then
                local suc = insertGlobal(alllibs.global, sourceName, lib)
                if not suc then
                    insertOther(alllibs.other, sourceName, lib)
                end
            else
                insertCustom(alllibs.custom, sourceName, lib, libName)
            end
        elseif source.type == 'library' then
            insertGlobal(alllibs.library, sourceName, lib)
        elseif source.type == 'object' then
            insertGlobal(alllibs.object, sourceName, lib)
        end
    end
end

local function copy(t)
    local new = {}
    for k, v in pairs(t) do
        new[k] = v
    end
    return new
end

local function insertChild(tbl, name, key, value)
    if not name or not key then
        return
    end
    if not isMatchVersion(value.version) then
        return
    end
    if not value.doc then
        value.doc = ('%s.%s'):format(name, key)
    end
    if not tbl[name] then
        tbl[name] = {
            type = 'library',
            name = name,
            child = {},
        }
    end
    tbl[name].child[key] = {
        type  = 'library',
        name  = key,
        value = value,
    }
    value.library = tbl[name].child[key]
end

local function mergeParent(alllibs, name, lib, libName)
    for _, parent in ipairs(lib.parent) do
        if parent.type == 'global' then
            if isEnableGlobal(libName) then
                insertChild(alllibs.global, parent.name, name, lib)
            end
        elseif parent.type == 'library' then
            insertChild(alllibs.library, parent.name, name, lib)
        elseif parent.type == 'object' then
            insertChild(alllibs.object,  parent.name, name, lib)
        end
    end
end

local function mergeLibs(alllibs, libs, libName)
    if not libs then
        return
    end
    for _, lib in pairs(libs) do
        if lib.parent then
            mergeParent(alllibs, lib.name, lib, libName)
        else
            mergeSource(alllibs, lib.name, lib, libName)
        end
    end
end

local function loadLocale(language, relative)
    local localePath = ROOT / 'locale' / language / relative
    local localeBuf = util.loadFile(localePath:string())
    if localeBuf then
        local locale = util.container()
        xpcall(lni, log.error, localeBuf, localePath:string(), {locale})
        return locale
    end
    return nil
end

local function fix(libs)
    for name, lib in pairs(libs) do
        lib.name = lib.name or name
    end
end

local function scan(path)
    local result = {path}
    local i = 0
    return function ()
        i = i + 1
        local current = result[i]
        if not current then
            return nil
        end
        if fs.is_directory(current) then
            for path in current:list_directory() do
                result[#result+1] = path
            end
        end
        return current
    end
end

local function markLibrary(library)
    for _, lib in pairs(library) do
        lib.fields  = {}
        if lib.child then
            for _, child in util.sortPairs(lib.child) do
                table.insert(lib.fields, child)
                child.parent = library
            end
        end
    end
end

local function getDocFormater()
    local version = config.config.runtime.version
    if client.client() == 'vscode' then
        if version == 'Lua 5.1' then
            return 'HOVER_NATIVE_DOCUMENT_LUA51'
        elseif version == 'Lua 5.2' then
            return 'HOVER_NATIVE_DOCUMENT_LUA52'
        elseif version == 'Lua 5.3' then
            return 'HOVER_NATIVE_DOCUMENT_LUA53'
        elseif version == 'Lua 5.4' then
            return 'HOVER_NATIVE_DOCUMENT_LUA54'
        elseif version == 'LuaJIT' then
            return 'HOVER_NATIVE_DOCUMENT_LUAJIT'
        end
    else
        if version == 'Lua 5.1' then
            return 'HOVER_DOCUMENT_LUA51'
        elseif version == 'Lua 5.2' then
            return 'HOVER_DOCUMENT_LUA52'
        elseif version == 'Lua 5.3' then
            return 'HOVER_DOCUMENT_LUA53'
        elseif version == 'Lua 5.4' then
            return 'HOVER_DOCUMENT_LUA54'
        elseif version == 'LuaJIT' then
            return 'HOVER_DOCUMENT_LUAJIT'
        end
    end
end

local function convertLink(text)
    local fmt = getDocFormater()
    return text:gsub('%$([%.%w]+)', function (name)
        if fmt then
            return ('[%s](%s)'):format(name, lang.script(fmt, 'pdf-' .. name))
        else
            return ('`%s`'):format(name)
        end
    end):gsub('§([%.%w]+)', function (name)
        if fmt then
            return ('[§%s](%s)'):format(name, lang.script(fmt, name))
        else
            return ('`%s`'):format(name)
        end
    end)
end

local function compileSingleMetaDoc(script, metaLang)
    local middleBuf = {}
    local compileBuf = {}

    local last = 1
    for start, lua, finish in script:gmatch '()%-%-%-%#([^\n\r]*)()' do
        middleBuf[#middleBuf+1] = ('PUSH [===[%s]===]'):format(script:sub(last, start - 1))
        middleBuf[#middleBuf+1] = lua
        last = finish
    end
    middleBuf[#middleBuf+1] = ('PUSH [===[%s]===]'):format(script:sub(last))
    local middleScript = table.concat(middleBuf, '\n')

    local env = setmetatable({
        PUSH = function (text)
            compileBuf[#compileBuf+1] = text
        end,
        DES = function (name)
            local des = metaLang[name]
            if not des then
                des = ('Miss locale <%s>'):format(name)
            end
            if name:find('.', 1, true) then
                compileBuf[#compileBuf+1] = convertLink(des)
                compileBuf[#compileBuf+1] = '\n'
            else
                compileBuf[#compileBuf+1] = '---\n'
                for line in util.eachLine(des) do
                    compileBuf[#compileBuf+1] = '---'
                    compileBuf[#compileBuf+1] = convertLink(line)
                    compileBuf[#compileBuf+1] = '\n'
                end
                compileBuf[#compileBuf+1] = '---\n'
            end
        end,
    }, { __index = _ENV })

    if config.config.runtime.version == 'LuaJIT' then
        env.VERSION = 5.1
        env.JIT = true
    else
        env.VERSION = tonumber(config.config.runtime.version:sub(-3))
        env.JIT = false
    end

    util.saveFile((ROOT / 'log' / 'middleScript.lua'):string(), middleScript)

    assert(load(middleScript, middleScript, 't', env))()
    return table.concat(compileBuf)
end

local function loadMetaLocale(langID, result)
    result = result or {}
    local path = (ROOT / 'locale' / langID / 'meta.lni'):string()
    local lniContent = util.loadFile(path)
    if lniContent then
        xpcall(lni, log.error, lniContent, path, {result})
    end
    return result
end

local function compileMetaDoc()
    local langID  = lang.id
    local version = config.config.runtime.version
    local metapath = ROOT / 'meta' / config.config.runtime.meta:gsub('%$%{(.-)%}', {
        version  = version,
        language = langID,
    })
    if fs.exists(metapath) then
        --return
    end

    local metaLang = loadMetaLocale('en-US')
    if langID ~= 'en-US' then
        loadMetaLocale(langID, metaLang)
    end
    --log.debug('metaLang:', util.dump(metaLang))

    m.metaPath = metapath:string()
    m.metaPaths = {}
    fs.create_directory(metapath)
    local templateDir = ROOT / 'meta' / 'template'
    for fullpath in templateDir:list_directory() do
        local filename = fullpath:filename()
        local metaDoc = compileSingleMetaDoc(util.loadFile(fullpath:string()), metaLang)
        local filepath = metapath / filename
        util.saveFile(filepath:string(), metaDoc)
        m.metaPaths[#m.metaPaths+1] = filepath:string()
    end
end

local function initFromLni()
    local id = lang.id
    m.global  = util.container()
    m.library = util.container()
    m.object  = util.container()
    m.other   = util.container()
    m.custom  = util.container()

    for libPath in (ROOT / 'libs'):list_directory() do
        local libName = libPath:filename():string()
        for path in scan(libPath) do
            local libs
            local buf = util.loadFile(path:string())
            if buf then
                libs = util.container()
                xpcall(lni, log.error, buf, path:string(), {libs})
                fix(libs)
            end
            local relative = fs.relative(path, ROOT)

            local locale = loadLocale('en-US', relative)
            mergeLocale(libs, locale)
            if id ~= 'en-US' then
                locale = loadLocale(id, relative)
                mergeLocale(libs, locale)
            end
            mergeLibs(m, libs, libName)
        end
    end

    markLibrary(m.global)
    markLibrary(m.library)
    markLibrary(m.object)
    markLibrary(m.other)
    markLibrary(m.custom)
end

local function initFromMetaDoc()
    m.global  = util.container()
    m.library = util.container()
    m.object  = util.container()
    m.other   = util.container()
    m.custom  = util.container()
    compileMetaDoc()
end

local function init()
    if DEVELOP or TEST then
        initFromMetaDoc()
    else
        initFromLni()
    end
end

function m.init()
    init()
end

return m
