-- RoWorld | Diagnostico V3 - LOBBY + cliente (somente leitura)
-- Objetivo: localizar controladores locais, mapear modulos que faltaram no V2
-- e procurar, se existir, uma instancia do estado atual do jogo em memoria.
-- Nao dispara remotes, nao faz require(), nao executa codigo descompilado,
-- nao monitora chat, nao exporta nomes/IDs de jogadores e nao envia nada pela internet.

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local Players = game:GetService("Players")
local localPlayer = Players.LocalPlayer

local DEFAULT_FOLDER = [[C:\Users\Usuario\Downloads\Rofront]]
local FILE_NAME = "RoWorld_Diagnostico_V3_Lobby_" .. os.date("%Y%m%d_%H%M%S") .. ".json"
local MAX_SOURCE_PER_MODULE = 42000
local MAX_SOURCE_PER_CLIENT = 14000
local MAX_TOTAL_SOURCE = 390000
local MAX_CLIENT_SCRIPTS = 55
local MAX_GC_ITEMS = 25000
local MAX_GC_SECONDS = 2.5

-- Modulos COMPLEMENTARES aos 14 exportados no V2.
-- Ajuste a lista apenas se souber que o jogo foi atualizado.
local TARGETS = {
    {"Core", "WorldMap"},
    {"Core", "MapCodec"},
    {"Core", "SimNav"},
    {"Core", "SimArsenal"},
    {"Core", "Teams"},
    {"Net", "Coop"},
    {"Net", "MapFetch"},
    {"Data", "MapList"},
    {"Data", "Starter"},
    {"Data", "Staging"},
    {"Data", "Tribes"},
    {"Data", "Nations"}
}

local report = {
    reportVersion = 3,
    mode = "lobby_safe_readonly",
    createdUTC = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    universeId = game.GameId,
    placeId = game.PlaceId,
    purpose = "Completar mapa de codigo cliente e procurar estado ativo de partida; somente leitura.",
    safety = {
        "Nao usa require(), FireServer(), InvokeServer() ou loadstring().",
        "Nao captura mensagens de chat nem nomes de jogadores.",
        "Nao executa os modulos; apenas tenta decompilar copia de codigo cliente.",
        "Os textos exportados podem conter codigo de terceiros; revise antes de compartilhar.",
        "Resultados no lobby podem nao incluir estado de uma rodada ativa."
    },
    services = {},
    localScripts = {},
    extraModules = {},
    runtimeState = {status = "not_scanned", candidates = {}},
    summary = {
        extraFound = 0, extraDecompiled = 0,
        localScriptsFound = 0, clientScriptsDecompiled = 0,
        extractedCharacters = 0
    }
}

local bytesUsed = 0
local airfront = ReplicatedStorage:FindFirstChild("Airfront")

local function safePath(instance)
    local ok, result = pcall(function() return instance:GetFullName() end)
    return ok and result or instance.Name
end

local function nkeys(t, max)
    if type(t) ~= "table" then return 0 end
    local count = 0
    for _ in pairs(t) do
        count = count + 1
        if count >= (max or 100000) then break end
    end
    return count
end

local SEARCH_TERMS = {
    "GameState", "SimState", "local_owner", "local_info", "snapshot",
    "ToServer", "ToClient", "GetMap", "player_state", "owner_id",
    "state.loaded", "require(", "FireServer", "InvokeServer", "getgc"
}

local function excerpts(source, maxChars)
    local lines = {}
    for line in (source .. "\n"):gmatch("(.-)\n") do
        lines[#lines + 1] = line
    end
    local idx = {}
    for i, line in ipairs(lines) do
        for _, term in ipairs(SEARCH_TERMS) do
            if string.find(line, term, 1, true) then
                for j = math.max(1, i - 3), math.min(#lines, i + 5) do
                    idx[j] = true
                end
                break
            end
        end
    end
    local snippets, total = {}, 0
    for i, line in ipairs(lines) do
        if idx[i] then
            local short = tostring(i) .. ": " .. line .. "\n"
            if total + #short > maxChars then break end
            snippets[#snippets + 1] = short
            total = total + #short
        end
    end
    return table.concat(snippets), #lines
end

local function inspectSource(scriptInstance, limit)
    local entry = {name = scriptInstance.Name, path = safePath(scriptInstance), class = scriptInstance.ClassName}
    if type(decompile) ~= "function" then
        entry.status = "decompiler_unavailable"
        return entry
    end
    if bytesUsed >= MAX_TOTAL_SOURCE then
        entry.status = "global_output_limit"
        return entry
    end
    local ok, source = pcall(function() return decompile(scriptInstance) end)
    if not ok or type(source) ~= "string" or #source == 0 then
        entry.status = "decompile_failed"
        return entry
    end
    entry.status = "decompiled"
    entry.sourceCharacters = #source
    local allowed = math.min(limit, MAX_TOTAL_SOURCE - bytesUsed)
    if #source <= allowed then
        entry.source = source
        entry.capture = "full"
    else
        entry.source, entry.sourceLines = excerpts(source, allowed)
        entry.capture = "relevant_excerpts"
        entry.note = "Arquivo grande: apenas trechos relacionados a estado e comunicacao."
    end
    entry.exportedCharacters = #entry.source
    bytesUsed = bytesUsed + entry.exportedCharacters
    report.summary.extractedCharacters = bytesUsed
    return entry
end

-- 1. Inventario de elementos do cliente (sem textos, chat ou jogadores).
local playerScripts = localPlayer and localPlayer:FindFirstChildOfClass("PlayerScripts")
local playerGui = localPlayer and localPlayer:FindFirstChildOfClass("PlayerGui")
report.services = {
    airfrontPresent = airfront ~= nil,
    playerScriptsPresent = playerScripts ~= nil,
    playerGuiPresent = playerGui ~= nil,
    replicatedFirstChildren = {},
    screenGuiNames = {},
    playerScriptsTotalDescendants = 0,
    decompilerAvailable = type(decompile) == "function",
    getgcAvailable = type(getgc) == "function"
}

for _, child in ipairs(ReplicatedFirst:GetChildren()) do
    if child:IsA("LuaSourceContainer") or child:IsA("Folder") then
        table.insert(report.services.replicatedFirstChildren, {name = child.Name, class = child.ClassName})
    end
end
if playerGui then
    for _, child in ipairs(playerGui:GetChildren()) do
        if child:IsA("ScreenGui") then
            table.insert(report.services.screenGuiNames, child.Name)
        end
    end
end

-- 2. Descobrir o script que inicializa o cliente.
local scripts = {}
if playerScripts then
    local descendants = playerScripts:GetDescendants()
    report.services.playerScriptsTotalDescendants = #descendants
    for _, instance in ipairs(descendants) do
        if instance:IsA("LocalScript") or instance:IsA("ModuleScript") then
            scripts[#scripts + 1] = instance
        end
    end
end
for _, instance in ipairs(ReplicatedFirst:GetDescendants()) do
    if instance:IsA("LocalScript") or instance:IsA("ModuleScript") then
        scripts[#scripts + 1] = instance
    end
end

table.sort(scripts, function(a, b)
    local ap = safePath(a):lower()
    local bp = safePath(b):lower()
    local function priority(p)
        if p:find("airfront", 1, true) then return 0 end
        if p:find("rofront", 1, true) then return 1 end
        if p:find("client", 1, true) then return 2 end
        if p:find("main", 1, true) then return 3 end
        if p:find("player", 1, true) then return 5 end
        return 4
    end
    if priority(ap) ~= priority(bp) then return priority(ap) < priority(bp) end
    return ap < bp
end)

for index, scriptInstance in ipairs(scripts) do
    if index > MAX_CLIENT_SCRIPTS then break end
    local item = {name = scriptInstance.Name, class = scriptInstance.ClassName, path = safePath(scriptInstance)}
    report.summary.localScriptsFound = report.summary.localScriptsFound + 1
    local p = item.path:lower()
    -- Evita scripts padrao do Roblox e de chat para manter relatorio restrito ao jogo.
    if p:find("airfront", 1, true) or p:find("rofront", 1, true)
       or (scriptInstance:IsA("LocalScript") and not p:find("playermodule", 1, true)
           and not p:find("chat", 1, true)) then
        print("[RoWorld V3] Cliente " .. index .. ": " .. item.name)
        item = inspectSource(scriptInstance, MAX_SOURCE_PER_CLIENT)
        if item.status == "decompiled" then
            report.summary.clientScriptsDecompiled = report.summary.clientScriptsDecompiled + 1
        end
    else
        item.status = "listed_only"
    end
    table.insert(report.localScripts, item)
    task.wait(0.01)
end

-- 3. Modulos complementares aos ja exportados no V2.
for index, info in ipairs(TARGETS) do
    local folder = airfront and airfront:FindFirstChild(info[1])
    local instance = folder and folder:FindFirstChild(info[2])
    if instance and instance:IsA("ModuleScript") then
        report.summary.extraFound = report.summary.extraFound + 1
        print(string.format("[RoWorld V3] Modulo %d/%d: %s", index, #TARGETS, info[2]))
        local entry = inspectSource(instance, MAX_SOURCE_PER_MODULE)
        if entry.status == "decompiled" then
            report.summary.extraDecompiled = report.summary.extraDecompiled + 1
        end
        report.extraModules[#report.extraModules + 1] = entry
    else
        report.extraModules[#report.extraModules + 1] = {
            name = info[2], family = info[1], status = "missing"
        }
    end
    task.wait(0.015)
end

-- 4. Identificacao de GameState em memoria. Nao executa nenhuma funcao do jogo.
-- No lobby e NORMAL nao encontrar uma instancia ativa.
if type(getgc) ~= "function" then
    report.runtimeState.status = "getgc_unavailable"
else
    local ok, all = pcall(function() return getgc(true) end)
    if not ok or type(all) ~= "table" then
        report.runtimeState.status = "getgc_failed"
    else
        local started = os.clock()
        local scanned = 0
        local hits = {}
        for _, value in pairs(all) do
            scanned = scanned + 1
            if scanned > MAX_GC_ITEMS or (os.clock() - started) > MAX_GC_SECONDS then break end
            if type(value) == "table" then
                local owners = rawget(value, "owners")
                local tick = rawget(value, "tick")
                local map = rawget(value, "map")
                local localOwner = rawget(value, "local_owner")
                if type(owners) == "table" and type(tick) == "number"
                   and type(localOwner) == "number" and type(map) == "table" then
                    local item = {
                        tick = tick,
                        phase = rawget(value, "phase"),
                        loaded = rawget(value, "loaded"),
                        localOwnerKnown = localOwner > 0,
                        totalOwners = nkeys(owners, 1200),
                        structureCount = nkeys(rawget(value, "structures"), 20000),
                        unitCount = nkeys(rawget(value, "units"), 20000),
                        currentAttacks = nkeys(rawget(value, "attacks"), 20000),
                        map = {W = rawget(map, "W"), H = rawget(map, "H"), N = rawget(map, "N")}
                    }
                    local ownInfo = owners[localOwner]
                    if type(ownInfo) == "table" and localOwner > 0 then
                        -- Apenas estatisticas da propria nacao; sem nomes nem IDs.
                        item.myNation = {
                            alive = rawget(ownInfo, "alive"),
                            spawned = rawget(ownInfo, "spawned"),
                            troops = rawget(ownInfo, "troops"),
                            maxTroops = rawget(ownInfo, "max_troops"),
                            gold = rawget(ownInfo, "gold"),
                            income = rawget(ownInfo, "income"),
                            tiles = rawget(ownInfo, "tiles")
                        }
                    end
                    hits[#hits + 1] = item
                    if #hits >= 4 then break end
                end
            end
        end
        report.runtimeState.status = #hits > 0 and "possible_state_found" or "no_state_in_lobby"
        report.runtimeState.scannedObjects = scanned
        report.runtimeState.candidates = hits
    end
end

-- 5. Exportar JSON local, sem rede.
local okJson, payload = pcall(function() return HttpService:JSONEncode(report) end)
if not okJson then
    warn("[RoWorld V3] Erro ao montar relatorio: " .. tostring(payload))
    return
end

print(string.format(
    "[RoWorld V3] Pronto! %d modulos; %d scripts do cliente; estado: %s; %d caracteres exportados.",
    report.summary.extraDecompiled,
    report.summary.clientScriptsDecompiled,
    report.runtimeState.status,
    report.summary.extractedCharacters
))

if type(savefiledialog) == "function" then
    local ok, result = pcall(function()
        return savefiledialog(payload, {
            title = "Salvar diagnostico V3 do RoWorld (Lobby)",
            defaultPath = DEFAULT_FOLDER,
            suggestedName = FILE_NAME,
            defaultExtension = "json",
            extensionFilter = {"json"}
        })
    end)
    if ok and result then
        print("[RoWorld V3] Arquivo salvo: " .. FILE_NAME)
        return
    end
    if ok then
        warn("[RoWorld V3] Janela cancelada. Tentando salvar no workspace.")
    else
        warn("[RoWorld V3] Falha da janela. Tentando workspace.")
    end
end

if type(writefile) == "function" then
    local relative = "Rofront/" .. FILE_NAME
    local ok, err = pcall(function()
        if type(makefolder) == "function" then pcall(makefolder, "Rofront") end
        writefile(relative, payload)
    end)
    if ok then
        print("[RoWorld V3] Salvo no workspace do executor: " .. relative)
        return
    end
    warn("[RoWorld V3] Nao foi possivel salvar: " .. tostring(err))
end

warn("[RoWorld V3] Nao houve exportacao. Verifique API de arquivos do Real.")
