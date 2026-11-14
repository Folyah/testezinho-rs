-- RoWorld Observer v0.1 (teste de telemetria, somente leitura)
-- Inicie no lobby antes de entrar numa partida.
-- Nao ataca, nao constrói, nao usa remotes e nao envia dados para internet.
-- Salva periodicamente um JSON no workspace do Real Executor.
-- O bot de decisoes sera construido em uma etapa posterior.

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local player = Players.LocalPlayer

local EXPECTED_UNIVERSE = 10768172922
local DEFAULT_EXPORT_FOLDER = [[C:\Users\Usuario\Downloads\Rofront]]
local SCAN_INTERVAL = 6             -- Segundos entre procuras na memoria
local SAMPLE_INTERVAL = 2           -- Segundos entre leituras da partida
local AUTOSAVE_INTERVAL = 12        -- Salvar JSON incremental
local MAX_GC_ITEMS = 60000          -- Limite de objetos inspecionados
local MAX_SAMPLES_PER_ROUND = 2100  -- 70 minutos com amostras a cada 2 s
local MAX_EVENTS_PER_ROUND = 400

if game.GameId ~= EXPECTED_UNIVERSE then
    warn("[RoWorld Observer] Outro universo detectado. Execucao cancelada.")
    return
end

local env = (type(getgenv) == "function" and getgenv()) or _G
if env.ROWORLD_OBSERVER_V01 and type(env.ROWORLD_OBSERVER_V01.Stop) == "function" then
    pcall(env.ROWORLD_OBSERVER_V01.Stop)
end

local runId = os.date("!%Y%m%d_%H%M%S")
local fileName = "RoWorld_Observer_" .. runId .. ".json"
local workspacePath = "Rofront/" .. fileName

local report = {
    schema = "roworld-observer-v0.1",
    startedUTC = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    gameId = game.GameId,
    placeId = game.PlaceId,
    source = "client_memory_readonly",
    sampleSeconds = SAMPLE_INTERVAL,
    rounds = {},
    warnings = {},
    observer = {
        status = "starting",
        stateFound = false,
        lastSeenUTC = nil,
        lastSaveUTC = nil,
        lastSaveError = nil,
        scannedObjects = 0
    },
    privacy = "Sem nomes de jogadores, chat, cookies, identidade ou chamadas de rede"
}

local running = true
local foundState = nil
local currentRound = nil
local currentPhase = nil
local lastFoundTime = 0
local lastScanTime = -999
local lastSaveTime = 0
local lastSampleTime = 0
local seenAnyState = false
local ui = {}

local function nowUTC()
    return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function limitedAdd(array, value, limit)
    if #array < limit then
        array[#array + 1] = value
    end
end

local function event(kind, details)
    if not currentRound then return end
    limitedAdd(currentRound.events, {
        at = nowUTC(),
        kind = kind,
        details = details
    }, MAX_EVENTS_PER_ROUND)
end

local function n(t, key)
    if type(t) ~= "table" then return nil end
    local value = rawget(t, key)
    if type(value) == "number" and value == value and math.abs(value) < math.huge then
        return value
    end
    return nil
end

local function b(t, key)
    if type(t) ~= "table" then return nil end
    local value = rawget(t, key)
    if type(value) == "boolean" then return value end
    return nil
end

-- Confere varias propriedades concretas encontradas no GameState do diagnostico V2.
-- Evita confundir uma tabela aleatoria com uma instancia de partida.
local function looksLikeGameState(t)
    if type(t) ~= "table" then return false end
    if type(rawget(t, "owners")) ~= "table" then return false end
    if type(rawget(t, "map")) ~= "table" then return false end
    if type(rawget(t, "phase")) ~= "number" then return false end
    if type(rawget(t, "tick")) ~= "number" then return false end
    if type(rawget(t, "local_owner")) ~= "number" then return false end
    if type(rawget(t, "owner")) ~= "buffer" and typeof(rawget(t, "owner")) ~= "buffer" then return false end
    return true
end

local function extractState(obj)
    if looksLikeGameState(obj) then return obj end
    if type(obj) ~= "table" then return nil end
    local state = rawget(obj, "state")
    if looksLikeGameState(state) then return state end
    local session = rawget(obj, "session")
    if type(session) == "table" then
        local nested = rawget(session, "state")
        if looksLikeGameState(nested) then return nested end
    end
    local ctx = rawget(obj, "ctx")
    if type(ctx) == "table" then
        local nested = rawget(ctx, "state")
        if looksLikeGameState(nested) then return nested end
    end
    return nil
end

local function discoverState()
    if type(getgc) ~= "function" then
        report.observer.status = "getgc_unavailable"
        return nil
    end
    local ok, objects = pcall(getgc, true)
    if not ok or type(objects) ~= "table" then
        report.observer.status = "gc_unavailable"
        return nil
    end

    local limit = math.min(#objects, MAX_GC_ITEMS)
    report.observer.scannedObjects = limit
    for i = 1, limit do
        local obj = objects[i]
        if type(obj) == "table" then
            local success, result = pcall(extractState, obj)
            if success and result and rawget(result, "loaded") == true then
                return result
            end
        end
        if i % 6000 == 0 then task.wait() end
    end
    return nil
end

local function countOwnedStructures(state, ownerId)
    local counts = {}
    local structures = rawget(state, "structures")
    if type(structures) ~= "table" then return counts end
    for _, structure in pairs(structures) do
        if type(structure) == "table" and rawget(structure, "owner") == ownerId then
            local kind = rawget(structure, "kind")
            if type(kind) == "number" then
                local key = tostring(kind)
                counts[key] = (counts[key] or 0) + 1
            end
        end
    end
    return counts
end

local function takeSample(state)
    local ownerId = n(state, "local_owner") or 0
    if ownerId == 0 and currentRound and currentRound.localOwner then
        ownerId = currentRound.localOwner
    end
    local owners = rawget(state, "owners")
    local info = type(owners) == "table" and owners[ownerId] or nil
    local sample = {
        at = nowUTC(),
        tick = n(state, "tick"),
        phase = n(state, "phase"),
        loaded = b(state, "loaded"),
        hasOwner = ownerId > 0 and type(info) == "table",
    }
    if sample.hasOwner then
        if currentRound and ownerId > 0 then currentRound.localOwner = ownerId end
        sample.troops = n(info, "troops")
        sample.gold = n(info, "gold")
        sample.income = n(info, "income")
        sample.maxTroops = n(info, "max_troops")
        sample.tiles = n(info, "tiles")
        sample.alive = b(info, "alive")
        sample.spawned = b(info, "spawned")
        sample.team = n(info, "team")
        sample.territoryShare = nil
        local map = rawget(state, "map")
        local contestable = type(map) == "table" and n(map, "contestable_count") or nil
        if contestable and contestable > 0 and sample.tiles then
            sample.territoryShare = sample.tiles / contestable
        end
        sample.structures = countOwnedStructures(state, ownerId)
    end
    return sample
end

local function newRound(state)
    currentRound = {
        index = #report.rounds + 1,
        discoveredUTC = nowUTC(),
        startUTC = nil,
        endUTC = nil,
        outcome = "in_progress",
        mapId = type(rawget(state, "map_id")) == "string" and rawget(state, "map_id") or nil,
        samples = {},
        events = {},
        summary = {}
    }
    report.rounds[#report.rounds + 1] = currentRound
    currentPhase = nil
    event("estado_encontrado", {phase = n(state, "phase")})
end

local function summarizeRound(round)
    local result = {
        sampleCount = #round.samples,
        peakTiles = nil,
        peakTroops = nil,
        peakGold = nil,
        peakIncome = nil,
        gainedTilesObserved = 0,
        lostTilesObserved = 0,
        largestTroopDropObserved = 0,
        lowestArmyFraction = nil,
        firstSample = round.samples[1],
        lastSample = round.samples[#round.samples]
    }
    local previous
    for _, sample in ipairs(round.samples) do
        for key, target in pairs({tiles="peakTiles", troops="peakTroops", gold="peakGold", income="peakIncome"}) do
            if type(sample[key]) == "number" then
                result[target] = math.max(result[target] or -math.huge, sample[key])
            end
        end
        if type(sample.troops) == "number" and type(sample.maxTroops) == "number" and sample.maxTroops > 0 then
            local fraction = sample.troops / sample.maxTroops
            result.lowestArmyFraction = math.min(result.lowestArmyFraction or math.huge, fraction)
        end
        if previous then
            if sample.tiles and previous.tiles then
                local change = sample.tiles - previous.tiles
                result.gainedTilesObserved = result.gainedTilesObserved + math.max(0, change)
                result.lostTilesObserved = result.lostTilesObserved + math.max(0, -change)
            end
            if sample.troops and previous.troops then
                result.largestTroopDropObserved = math.max(result.largestTroopDropObserved, previous.troops - sample.troops)
            end
        end
        previous = sample
    end
    return result
end

local function conclude(outcome, reason, state)
    if not currentRound or currentRound.endUTC then return end
    currentRound.endUTC = nowUTC()
    currentRound.outcome = outcome
    currentRound.reason = reason
    if state and looksLikeGameState(state) then
        currentRound.winnerOwner = n(state, "winner")
        currentRound.overReason = n(state, "over_reason")
        currentRound.winnerTeam = n(state, "winner_team")
        currentRound.ownOwner = currentRound.localOwner or n(state, "local_owner")
    end
    event("rodada_encerrada", {resultado = outcome, motivo = reason})
    currentRound.summary = summarizeRound(currentRound)
    report.observer.status = "finished_" .. outcome
end

local function outcomeFromGameState(state, sample)
    local localOwner = (currentRound and currentRound.localOwner) or n(state, "local_owner") or 0
    local winner = n(state, "winner") or 0
    local winnerTeam = n(state, "winner_team") or 0
    if localOwner > 0 and winner == localOwner then return "victory" end
    if winnerTeam > 0 and sample.team and winnerTeam == sample.team then return "victory" end
    if localOwner > 0 and (winner > 0 or winnerTeam > 0) then return "defeat" end
    return "unknown"
end

local function recordState(state)
    if not currentRound or currentRound.endUTC then
        newRound(state)
    end
    local phase = n(state, "phase")
    if phase ~= currentPhase then
        event("fase_alterada", {from = currentPhase, to = phase})
        currentPhase = phase
    end
    if phase == 1 and not currentRound.startUTC then
        currentRound.startUTC = nowUTC()
        event("jogo_iniciado", {tick = n(state, "tick")})
    end
    local sample = takeSample(state)
    limitedAdd(currentRound.samples, sample, MAX_SAMPLES_PER_ROUND)
    if phase == 2 then
        conclude(outcomeFromGameState(state, sample), "phase_over", state)
    elseif currentRound.startUTC and sample.hasOwner and sample.alive == false then
        conclude("defeat", "owner_eliminated", state)
    end
end

local function encodedReport()
    return HttpService:JSONEncode(report)
end

local function saveReport(reason)
    report.observer.lastSaveUTC = nowUTC()
    report.observer.lastSaveReason = reason
    local encodedOk, encoded = pcall(encodedReport)
    if not encodedOk then
        report.observer.lastSaveError = tostring(encoded)
        return false
    end
    if type(writefile) ~= "function" then
        report.observer.lastSaveError = "writefile indisponivel no executor"
        return false
    end
    local success, err = pcall(writefile, workspacePath, encoded)
    report.observer.lastSaveError = success and nil or tostring(err)
    if success then
        print("[RoWorld Observer] JSON atualizado no workspace: " .. workspacePath)
    end
    return success
end

local function exportWindows()
    if type(savefiledialog) ~= "function" then
        warn("[RoWorld Observer] savefiledialog nao esta disponivel. Use o JSON do workspace do Real.")
        return
    end
    local ok, result = pcall(function()
        return savefiledialog(encodedReport(), {
            title = "Salvar diagnostico do RoWorld",
            defaultPath = DEFAULT_EXPORT_FOLDER,
            suggestedName = fileName,
            defaultExtension = "json",
            extensionFilter = {"json"}
        })
    end)
    if ok and result then
        print("[RoWorld Observer] Relatorio exportado pelo Windows.")
    elseif not ok then
        warn("[RoWorld Observer] Falha na exportacao: " .. tostring(result))
    else
        print("[RoWorld Observer] Exportacao cancelada.")
    end
end

local function makeButton(parent, label, x, onClick)
    local button = Instance.new("TextButton")
    button.Size = UDim2.fromOffset(105, 29)
    button.Position = UDim2.fromOffset(x, 103)
    button.BackgroundColor3 = Color3.fromRGB(48, 62, 82)
    button.BorderSizePixel = 0
    button.TextColor3 = Color3.fromRGB(236, 239, 245)
    button.Font = Enum.Font.GothamMedium
    button.TextSize = 12
    button.Text = label
    button.Parent = parent
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 6)
    corner.Parent = button
    button.MouseButton1Click:Connect(onClick)
    return button
end

local function createGui()
    local guiParent = player and player:FindFirstChildOfClass("PlayerGui")
    if not guiParent then return end
    local old = guiParent:FindFirstChild("RoWorldObserverV01")
    if old then old:Destroy() end
    local gui = Instance.new("ScreenGui")
    gui.Name = "RoWorldObserverV01"
    gui.ResetOnSpawn = false
    gui.DisplayOrder = 200
    gui.Parent = guiParent

    local frame = Instance.new("Frame")
    frame.Size = UDim2.fromOffset(344, 142)
    frame.Position = UDim2.fromOffset(16, 110)
    frame.BackgroundColor3 = Color3.fromRGB(15, 23, 35)
    frame.BackgroundTransparency = 0.09
    frame.BorderSizePixel = 0
    frame.Parent = gui
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 9)
    corner.Parent = frame

    local function label(text, y, size)
        local t = Instance.new("TextLabel")
        t.Position = UDim2.fromOffset(12, y)
        t.Size = UDim2.fromOffset(319, 21)
        t.BackgroundTransparency = 1
        t.Text = text
        t.TextColor3 = Color3.fromRGB(228, 236, 247)
        t.TextXAlignment = Enum.TextXAlignment.Left
        t.Font = Enum.Font.Code
        t.TextSize = size or 13
        t.Parent = frame
        return t
    end
    label("ROWORLD OBSERVER v0.1 | SOMENTE LEITURA", 7, 13)
    ui.status = label("Estado: procurando partida...", 34)
    ui.metrics = label("Sem dados de tropas/economia ainda", 58, 11)
    ui.file = label("Salvando: Rofront/ (workspace Real)", 79, 11)
    makeButton(frame, "Exportar JSON", 12, exportWindows)
    makeButton(frame, "Salvar agora", 123, function() saveReport("manual") end)
    makeButton(frame, "Parar", 234, function()
        running = false
        if currentRound and not currentRound.endUTC then
            conclude("incomplete", "manual_stop", foundState)
        end
        saveReport("stopped")
        ui.status.Text = "Estado: monitor encerrado"
    end)
    ui.gui = gui
end

local function updateGui(state)
    if not ui.status or not ui.status.Parent then return end
    if not state then
        ui.status.Text = "Estado: lobby / estado da partida nao encontrado"
        ui.metrics.Text = "Aguardando a rodada iniciar..."
        return
    end
    local phase = n(state, "phase")
    local names = {[0]="SPAWN", [1]="JOGANDO", [2]="ENCERRADO"}
    ui.status.Text = "Estado: " .. (names[phase] or "DESCONHECIDO") .. " | rodada " .. tostring(currentRound and currentRound.index or "?")
    if currentRound and currentRound.endUTC then
        ui.status.Text = ui.status.Text .. " | " .. currentRound.outcome
    end
    local sample = currentRound and currentRound.samples[#currentRound.samples]
    if sample and sample.hasOwner then
        ui.metrics.Text = string.format("Tropas %s | Ouro %s | Terras %s | Renda %s", tostring(sample.troops or "?"), tostring(sample.gold or "?"), tostring(sample.tiles or "?"), tostring(sample.income or "?"))
    else
        ui.metrics.Text = "Sem nacao selecionada ou dados disponiveis"
    end
    if report.observer.lastSaveError then
        ui.file.Text = "Falha ao salvar: " .. tostring(report.observer.lastSaveError):sub(1, 42)
    end
end

local function stop()
    running = false
    if currentRound and not currentRound.endUTC then
        conclude("incomplete", "script_stopped", foundState)
    end
    saveReport("stopped")
    if ui.gui then pcall(function() ui.gui:Destroy() end) end
end

env.ROWORLD_OBSERVER_V01 = {
    Stop = stop,
    Export = exportWindows,
    Save = function() return saveReport("manual") end,
    GetStatus = function() return report.observer.status end
}

createGui()
saveReport("boot")

-- O jogo pode usar uma mesma tela para lobby e partida: a deteccao usa GameState,
-- nao textos da interface, como comprovado nos arquivos V2/V3.
task.spawn(function()
    while running do
        local now = os.clock()
        if not foundState or not looksLikeGameState(foundState) or rawget(foundState, "loaded") ~= true then
            if now - lastScanTime >= SCAN_INTERVAL then
                lastScanTime = now
                foundState = discoverState()
            end
        else
            -- Periodicamente procura um estado novo quando a rodada termina.
            if currentRound and currentRound.endUTC and now - lastScanTime >= SCAN_INTERVAL then
                lastScanTime = now
                local newState = discoverState()
                if newState and newState ~= foundState then foundState = newState end
            end
        end

        if foundState and looksLikeGameState(foundState) and rawget(foundState, "loaded") == true then
            seenAnyState = true
            lastFoundTime = now
            report.observer.stateFound = true
            report.observer.lastSeenUTC = nowUTC()
            report.observer.status = "state_found"
            if not currentRound or not currentRound.endUTC or (n(foundState, "phase") == 0 and currentPhase ~= 0) then
                if now - lastSampleTime >= SAMPLE_INTERVAL then
                    lastSampleTime = now
                    local wasFinished = currentRound and currentRound.endUTC ~= nil
                    recordState(foundState)
                    if currentRound and currentRound.endUTC and not wasFinished then
                        saveReport("round_finished")
                    end
                end
            end
        else
            if not seenAnyState then report.observer.status = "waiting_in_lobby" end
            if seenAnyState and currentRound and not currentRound.endUTC and now - lastFoundTime >= 18 then
                conclude("incomplete", "state_unavailable_18s", nil)
                saveReport("state_lost")
            end
        end
        updateGui(foundState)
        if now - lastSaveTime >= AUTOSAVE_INTERVAL then
            lastSaveTime = now
            saveReport("periodic")
        end
        task.wait(0.5)
    end
end)

print("[RoWorld Observer] v0.1 executando. Inicie uma partida e observe o painel.")
print("[RoWorld Observer] Autosave workspace: " .. workspacePath)
