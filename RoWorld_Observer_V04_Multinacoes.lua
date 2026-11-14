-- RoWorld Observer v0.4 (teste de telemetria, somente leitura)
-- Inicie no lobby antes de entrar numa partida.
-- Nao ataca, nao constrói, nao usa remotes e nao envia dados para internet.
-- Salva periodicamente um JSON no workspace do Real Executor.
-- O bot de decisoes sera construido em uma etapa posterior.

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local player = Players.LocalPlayer

local EXPECTED_UNIVERSE = 10768172922
local DEFAULT_EXPORT_FOLDER = [[C:\Users\Usuario\Downloads\Rofront]]
local SCAN_INTERVAL = 8             -- Segundos entre procuras na memoria
local SAMPLE_INTERVAL = 1           -- Segundos entre leituras da partida
local AUTOSAVE_INTERVAL = 15        -- Salvar JSON incremental
local MAX_GC_ITEMS = 65000          -- Limite de objetos inspecionados
local MAX_SAMPLES_PER_ROUND = 14400 -- Ate 4 horas por partida a 1 amostra/seg
local MAX_EVENTS_PER_ROUND = 9000
local GLOBAL_INTERVAL = 12        -- snapshot de todas as nacoes
local RELATIONS_INTERVAL = 3       -- alianças/estruturas (eventos)
local MAX_WORLD_SNAPSHOTS = 320    -- ~64min de historia global a cada 12s
local MAX_WORLD_EVENTS = 20000     -- protecao de memoria
local MAX_NATIONS = 1024
local MAX_ATTACKS = 600
local MAX_STRUCTURES = 9000

if game.GameId ~= EXPECTED_UNIVERSE then
    warn("[RoWorld Observer] Outro universo detectado. Execucao cancelada.")
    return
end

local env = (type(getgenv) == "function" and getgenv()) or _G
if env.ROWORLD_OBSERVER_V04 and type(env.ROWORLD_OBSERVER_V04.Stop) == "function" then
    pcall(env.ROWORLD_OBSERVER_V04.Stop)
end

-- Encerra a v0.3 para impedir dois registros simultaneos.
if env.ROWORLD_OBSERVER_V03 and type(env.ROWORLD_OBSERVER_V03.Stop) == "function" then
    pcall(env.ROWORLD_OBSERVER_V03.Stop)
end

-- Encerra a v0.2 anterior, se estiver em execucao.
if env.ROWORLD_OBSERVER_V02 and type(env.ROWORLD_OBSERVER_V02.Stop) == "function" then
    pcall(env.ROWORLD_OBSERVER_V02.Stop)
end

-- Encerra a v0.1 para evitar dois monitores simultaneos.
if env.ROWORLD_OBSERVER_V01 and type(env.ROWORLD_OBSERVER_V01.Stop) == "function" then
    pcall(env.ROWORLD_OBSERVER_V01.Stop)
end

local runId = os.date("!%Y%m%d_%H%M%S")
local fileName = "RoWorld_Observer_V04_" .. runId .. ".json"
local workspacePath = "Rofront/" .. fileName
local fallbackPath = fileName

local report = {
    schema = "roworld-observer-v0.4",
    startedUTC = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    gameId = game.GameId,
    placeId = game.PlaceId,
    source = "client_memory_readonly",
    sampleSeconds = SAMPLE_INTERVAL,
    autosaveSeconds = AUTOSAVE_INTERVAL,
    documentation = "Telemetria somente leitura: propria nacao 1s, ataques globais 1s, alianças/estruturas 3s e nacoes globais 12s. Sem leitura do pensamento do rsHub; eventos podem ocorrer entre amostras.",
    worldSnapshotFormat = [=[Cada nacao = [id,kind,tiles,troops,gold,income,maxTroops,team,alive(1/0),spawned(1/0),traitor(1/0)]; sem nomes ou userIds.]=],
    rounds = {},
    warnings = {},
    observer = {
        status = "starting",
        stateFound = false,
        lastSeenUTC = nil,
        lastSaveUTC = nil,
        lastSaveError = nil,
        scannedObjects = 0,
        saveCount = 0,
        saveFailures = 0
    },
    privacy = "Sem nomes de jogadores, UserIds, chat, cookies ou chamadas externas de rede"
}

local running = true
local foundState = nil
local currentRound = nil
local currentPhase = nil
local lastFoundTime = 0
local lastScanTime = -999
local lastSaveTime = 0
local lastOwner = 0
local previousSample = nil
local savePathUsed = nil
local lastSampleTime = 0
local seenAnyState = false
local lastGlobalTime = -999
local lastRelationsTime = -999
local previousAttacks = nil
local previousAlliances = nil
local previousStructures = nil
local lastStateTick = nil
local lastOwnNationId = 0
local saveReport
local ui = {}

local function nowUTC()
    return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function limitedAdd(array, value, limit)
    if #array < limit then
        array[#array + 1] = value
        return true
    end
    return false
end

local function event(kind, details)
    if not currentRound then return end
    if not limitedAdd(currentRound.events, {
        at = nowUTC(),
        tick = foundState and rawget(foundState, "tick") or nil,
        kind = kind,
        details = details
    }, MAX_EVENTS_PER_ROUND) then
        currentRound.droppedEvents = (currentRound.droppedEvents or 0) + 1
    end
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

-- Prioriza instancias que representem o jogador local, em vez de escolher
-- a primeira tabela semelhante ao GameState encontrada na memoria.
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
    local best, bestScore = nil, -math.huge
    local tested = {}
    local candidates = 0
    for i = 1, limit do
        local obj = objects[i]
        if type(obj) == "table" then
            local success, state = pcall(extractState, obj)
            if success and state and not tested[state] and rawget(state, "loaded") == true then
                tested[state] = true
                candidates = candidates + 1
                local ownerId = n(state, "local_owner") or 0
                local owners = rawget(state, "owners")
                local hasLocal = ownerId > 0 and type(owners) == "table" and type(owners[ownerId]) == "table"
                local score = (hasLocal and 1000000 or 0) + math.max(0, n(state,"tick") or 0)
                if n(state,"phase") == 1 then score = score + 1000 end
                if score > bestScore then
                    best = state
                    bestScore = score
                end
            end
        end
        if i % 6000 == 0 then task.wait() end
    end
    report.observer.stateCandidates = candidates
    return best
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

local function countOwnedUnits(state, ownerId)
    local counts = {}
    local units = rawget(state, "units")
    if type(units) ~= "table" then return counts end
    for _, unit in pairs(units) do
        if type(unit) == "table" and rawget(unit, "owner") == ownerId then
            local kind = rawget(unit, "kind")
            if type(kind) == "number" then
                local key = tostring(kind)
                counts[key] = (counts[key] or 0) + 1
            end
        end
    end
    return counts
end

local function countOwnedAttacks(state, ownerId)
    local total = 0
    local attacks = rawget(state, "attacks")
    if type(attacks) ~= "table" then return total end
    for _, attack in pairs(attacks) do
        if type(attack) == "table" and rawget(attack, "attacker") == ownerId then
            total = total + 1
        end
    end
    return total
end

local function countAllies(state, ownerId)
    local count = 0
    local alliances = rawget(state, "alliances")
    if type(alliances) ~= "table" then return count end
    for key, enabled in pairs(alliances) do
        if enabled == true and type(key) == "number" then
            if key // 1024 == ownerId or key % 1024 == ownerId then
                count = count + 1
            end
        end
    end
    return count
end

-- O observador registra identificadores internos da partida, nunca nomes ou UserIds.
-- Preserva informacao sobre TODOS os adversarios em snapshots compactos.
local function worldEvent(kind, details)
    if not currentRound or not currentRound.world then return end
    local w = currentRound.world
    if not limitedAdd(w.events, {at=nowUTC(), tick=foundState and n(foundState,"tick") or nil,
        kind=kind, details=details}, MAX_WORLD_EVENTS) then
        w.droppedEvents = (w.droppedEvents or 0) + 1
    end
end

local function captureWorld(state)
    local w = currentRound and currentRound.world
    if not w or #w.snapshots >= MAX_WORLD_SNAPSHOTS then return end
    local owners = rawget(state, "owners")
    if type(owners) ~= "table" then return end
    local ids = {}
    for id, info in pairs(owners) do
        if type(id)=="number" and type(info)=="table" and id > 0 and id <= MAX_NATIONS then
            ids[#ids+1] = id
        end
    end
    table.sort(ids)
    local rows = {}
    local ranking = {}
    local tick = n(state, "tick") or 0
    for _,id in ipairs(ids) do
        local info = owners[id]
        local tiles = n(info,"tiles") or 0
        local alive = b(info,"alive") == true
        local spawned = b(info,"spawned") == true
        if spawned or tiles > 0 then
            rows[#rows+1] = {id, n(info,"kind") or 0, tiles,
                n(info,"troops") or 0, n(info,"gold") or 0, n(info,"income") or 0,
                n(info,"max_troops") or 0, n(info,"team") or 0,
                alive and 1 or 0, spawned and 1 or 0,
                tick < (n(info,"traitor_until") or 0) and 1 or 0}
            if alive and tiles > 0 then ranking[#ranking+1]={id,tiles} end
        end
    end
    table.sort(ranking, function(a,z) return a[2] > z[2] end)
    local ownId = currentRound.localOwner or lastOwnNationId
    local rank = nil
    for i,v in ipairs(ranking) do if v[1]==ownId then rank=i break end end
    limitedAdd(w.snapshots, {
        at=nowUTC(), tick=tick, nations=rows, activeCount=#ranking,
        ownRank=rank, activeAttacks=type(rawget(state,"attacks"))=="table" and (function()
            local k=0; for _ in pairs(rawget(state,"attacks")) do k=k+1 end return k
        end)() or 0
    }, MAX_WORLD_SNAPSHOTS)
    report.observer.worldSnapshots = #w.snapshots
    report.observer.nationsLastSeen = #rows
end

local function captureAttacks(state)
    if not currentRound or not currentRound.world then return end
    local attacks = rawget(state,"attacks")
    if type(attacks) ~= "table" then return end
    local newer, total = {}, 0
    local ownId = currentRound.localOwner or lastOwnNationId
    for k,v in pairs(attacks) do
        if total >= MAX_ATTACKS then break end
        if type(v)=="table" then
            local aid = n(v,"aid") or (type(k)=="number" and k or nil)
            if aid ~= nil then
                total=total+1
                local d = {aid=aid, attacker=n(v,"attacker"), target=n(v,"target"),
                    troops=n(v,"troops"), anchor=n(v,"anchor_tile"), retreat=b(v,"retreating")}
                newer[tostring(aid)] = d
                local prev = previousAttacks and previousAttacks[tostring(aid)] or nil
                if previousAttacks and not prev then
                    worldEvent("attack_started", d)
                elseif prev and (d.retreat ~= prev.retreat or (d.troops and prev.troops and math.abs(d.troops-prev.troops) >= math.max(25000,prev.troops*0.3)))
                  and (d.attacker==ownId or d.target==ownId) then
                    worldEvent("attack_updated_involving_local",d)
                end
            end
        end
    end
    if previousAttacks then
        for id, prev in pairs(previousAttacks) do
            if not newer[id] then worldEvent("attack_ended",prev) end
        end
    end
    previousAttacks=newer
    report.observer.activeGlobalAttacks=total
end

local function captureRelations(state)
    if not currentRound or not currentRound.world then return end
    local alliances=rawget(state,"alliances")
    local newerAlliances={}
    if type(alliances)=="table" then
        for key,enabled in pairs(alliances) do
            if type(key)=="number" and enabled==true then
                local first=key // 1024
                local second=key % 1024
                newerAlliances[tostring(key)]={a=first,b=second}
                if previousAlliances and not previousAlliances[tostring(key)] then
                    worldEvent("alliance_formed",{a=first,b=second})
                end
            end
        end
    end
    if previousAlliances then
        for key,pair in pairs(previousAlliances) do
            if not newerAlliances[key] then worldEvent("alliance_ended",pair) end
        end
    end
    previousAlliances=newerAlliances
    report.observer.activeAlliances=(function() local c=0 for _ in pairs(newerAlliances) do c=c+1 end return c end)()

    local allStructures=rawget(state,"structures")
    local newerStructures={}
    local c=0
    if type(allStructures)=="table" then
        for id,s in pairs(allStructures) do
            if c >= MAX_STRUCTURES then break end
            if type(s)=="table" then
                local sid=n(s,"sid") or (type(id)=="number" and id or nil)
                if sid then
                    c=c+1
                    local d={sid=sid,owner=n(s,"owner"),kind=n(s,"kind"),level=n(s,"level"),tile=n(s,"tile")}
                    newerStructures[tostring(sid)]=d
                    local old=previousStructures and previousStructures[tostring(sid)] or nil
                    if previousStructures and not old then worldEvent("structure_added",d)
                    elseif old and old.level~=d.level then
                        worldEvent("structure_level_changed",{sid=sid,owner=d.owner,kind=d.kind,from=old.level,to=d.level})
                    end
                end
            end
        end
    end
    if previousStructures then
        for id,old in pairs(previousStructures) do
            if not newerStructures[id] then worldEvent("structure_removed",old) end
        end
    end
    previousStructures=newerStructures
    report.observer.activeStructures=c
end

-- Eventos desta secao sao INFERIDOS por comparacao entre leituras, nao
-- comandos emitidos pelo jogador ou pelo rsHub.
local function recordChanges(previous, sample)
    if not previous or not sample or not currentRound then return end
    if sample.localOwnerId ~= previous.localOwnerId and sample.hasOwner then
        event("owner_changed", {from = previous.localOwnerId, to = sample.localOwnerId})
    end
    if sample.hasOwner and previous.hasOwner and sample.localOwnerId == previous.localOwnerId then
        local function compare(field, label, minAbs, minRelative)
            local a, z = previous[field], sample[field]
            if type(a) ~= "number" or type(z) ~= "number" then return end
            local difference = z - a
            local relative = math.abs(difference) / math.max(1, math.abs(a))
            if difference ~= 0 and (math.abs(difference) >= minAbs or relative >= minRelative) then
                event(label, {before = a, after = z, delta = difference, tick = sample.tick})
            end
        end
        compare("tiles", "territorio_variou", 40, 0.06)
        compare("troops", "tropas_variaram", 2000, 0.15)
        compare("gold", "ouro_variou", 50000, 0.20)
        compare("income", "renda_variou", 1500, 0.20)
        compare("maxTroops", "limite_tropas_variou", 1000, 0.05)
        compare("activeAttacks", "ataques_ativos_variaram", 1, 1)
        compare("allies", "aliancas_variaram", 1, 1)
        for _, group in ipairs({"structures", "units"}) do
            local a = previous[group] or {}
            local z = sample[group] or {}
            local changes = {}
            for key, count in pairs(z) do
                if count ~= (a[key] or 0) then
                    changes[key] = count - (a[key] or 0)
                end
            end
            for key, count in pairs(a) do
                if z[key] == nil and count ~= 0 then changes[key] = -count end
            end
            if next(changes) then
                event(group == "structures" and "estruturas_variaram" or "unidades_variaram", {
                    deltaByKind = changes, tick = sample.tick
                })
            end
        end
        if previous.alive ~= false and sample.alive == false then
            event("nacao_eliminada", {tick = sample.tick})
        end
    end
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
        localOwnerId = ownerId,
        ownerCount = type(owners) == "table" and (function()
            local c = 0
            for _ in pairs(owners) do c = c + 1 end
            return c
        end)() or 0,
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
        sample.units = countOwnedUnits(state, ownerId)
        sample.activeAttacks = countOwnedAttacks(state, ownerId)
        sample.allies = countAllies(state, ownerId)
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
        world = {snapshots={},events={},droppedEvents=0},
        summary = {}
    }
    report.rounds[#report.rounds + 1] = currentRound
    currentPhase = nil
    previousSample = nil
    previousAttacks = nil
    previousAlliances = nil
    previousStructures = nil
    lastGlobalTime = -999
    lastRelationsTime = -999
    lastOwner = 0
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
        peakActiveAttacks = 0,
        finalTerritoryShare = nil,
        ownNationIdentified = false,
        firstSample = round.samples[1],
        lastSample = round.samples[#round.samples]
    }
    local previous
    for _, sample in ipairs(round.samples) do
        if sample.hasOwner then result.ownNationIdentified = true end
        if type(sample.activeAttacks) == "number" then
            result.peakActiveAttacks = math.max(result.peakActiveAttacks, sample.activeAttacks)
        end
        if type(sample.territoryShare) == "number" then
            result.finalTerritoryShare = sample.territoryShare
        end
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
    local phase = n(state,"phase")
    local sample=takeSample(state)
    local now=os.clock()
    -- Ignorar estados velhos carregados no lobby (phase=1 sem jogador local).
    local isActive = phase==1 and sample.hasOwner and sample.spawned==true and sample.alive~=false
    if not currentRound then
        if not isActive then return end
        newRound(state)
    elseif currentRound.endUTC then
        local firstTick=currentRound.summary and currentRound.summary.lastSample and currentRound.summary.lastSample.tick or -1
        if isActive and sample.tick and (firstTick<0 or sample.tick + 30 < firstTick) then
            newRound(state)
        else
            return
        end
    elseif previousSample and sample.tick and previousSample.tick
        and previousSample.tick-sample.tick>50 then
        conclude("incomplete","round_tick_reset",state)
        saveReport("tick_reset")
        if isActive then newRound(state) else return end
    end
    if phase~=currentPhase then
        event("fase_alterada",{from=currentPhase,to=phase})
        currentPhase=phase
    end
    if isActive and not currentRound.startUTC then
        currentRound.startUTC=nowUTC()
        event("jogo_iniciado",{tick=sample.tick,owner=sample.localOwnerId})
    end
    if sample.hasOwner and sample.localOwnerId>0 then
        lastOwnNationId=sample.localOwnerId
        if lastOwner~=sample.localOwnerId then
            event("nacao_local_identificada",{ownerId=sample.localOwnerId})
        end
    elseif previousSample and previousSample.hasOwner then
        event("nacao_local_nao_visivel",{previousOwner=previousSample.localOwnerId,
            note="Pode ser saida, rendicao ou troca de estado; requer verificacao."})
    end
    lastOwner=sample.localOwnerId or 0
    recordChanges(previousSample,sample)
    previousSample=sample
    if not limitedAdd(currentRound.samples,sample,MAX_SAMPLES_PER_ROUND) then
        currentRound.droppedSamples=(currentRound.droppedSamples or 0)+1
    end
    captureAttacks(state)
    if now-lastRelationsTime>=RELATIONS_INTERVAL then
        lastRelationsTime=now
        captureRelations(state)
    end
    if now-lastGlobalTime>=GLOBAL_INTERVAL then
        lastGlobalTime=now
        captureWorld(state)
    end
    if phase==2 then
        conclude(outcomeFromGameState(state,sample),"phase_over",state)
    elseif phase==0 and currentRound.startUTC then
        conclude("unknown","returned_to_spawn_or_lobby",state)
    elseif sample.hasOwner and sample.alive==false then
        conclude("defeat","owner_eliminated",state)
    end
end

local function encodedReport()
    return HttpService:JSONEncode(report)
end

saveReport = function(reason)
    report.observer.lastSaveUTC = nowUTC()
    report.observer.lastSaveReason = reason
    local encodedOk, encoded = pcall(encodedReport)
    if not encodedOk then
        report.observer.lastSaveError = "JSONEncode: " .. tostring(encoded)
        report.observer.saveFailures = report.observer.saveFailures + 1
        return false
    end
    if type(writefile) ~= "function" then
        report.observer.lastSaveError = "writefile indisponivel; use Exportar JSON"
        report.observer.saveFailures = report.observer.saveFailures + 1
        return false
    end

    local errors = {}
    local paths = {workspacePath, fallbackPath}
    for _, path in ipairs(paths) do
        local success, err = pcall(function()
            if path == workspacePath and type(makefolder) == "function" then
                if type(isfolder) ~= "function" or not isfolder("Rofront") then
                    makefolder("Rofront")
                end
            end
            writefile(path, encoded)
            if type(isfile) == "function" and not isfile(path) then
                error("writefile terminou, mas isfile retornou false")
            end
        end)
        if success then
            report.observer.lastSaveError = nil
            report.observer.lastSavedPath = path
            report.observer.saveCount = report.observer.saveCount + 1
            savePathUsed = path
            return true
        end
        errors[#errors + 1] = path .. ": " .. (err == nil and "erro sem descricao" or tostring(err))
    end
    report.observer.lastSaveError = table.concat(errors, " | ")
    report.observer.saveFailures = report.observer.saveFailures + 1
    warn("[RoWorld Observer V0.4] " .. report.observer.lastSaveError)
    return false
end

local function exportWindows()
    saveReport("pre_export")
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
    button.Position = UDim2.fromOffset(x, 125)
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
    local old = guiParent:FindFirstChild("RoWorldObserverV04")
    if old then old:Destroy() end
    local gui = Instance.new("ScreenGui")
    gui.Name = "RoWorldObserverV04"
    gui.ResetOnSpawn = false
    gui.DisplayOrder = 200
    gui.Parent = guiParent

    local frame = Instance.new("Frame")
    frame.Size = UDim2.fromOffset(468, 165)
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
        t.Size = UDim2.fromOffset(448, 21)
        t.BackgroundTransparency = 1
        t.Text = text
        t.TextColor3 = Color3.fromRGB(228, 236, 247)
        t.TextXAlignment = Enum.TextXAlignment.Left
        t.Font = Enum.Font.Code
        t.TextSize = size or 13
        t.Parent = frame
        return t
    end
    label("ROWORLD OBSERVER v0.4 | MULTINACOES", 7, 13)
    ui.status = label("Estado: procurando partida...", 34)
    ui.metrics = label("Sem dados de tropas/economia ainda", 58, 11)
    ui.world = label("Aguardando dados das nacoes...", 80, 11)
    ui.file = label("Aguardando primeiro salvamento...", 100, 11)
    makeButton(frame, "Exportar JSON", 12, exportWindows)
    makeButton(frame, "Salvar agora", 123, function() saveReport("manual") end)
    makeButton(frame, "Rendicao", 234, function()
        if currentRound and not currentRound.endUTC then
            conclude("defeat", "manual_surrender_confirmed_by_user", foundState)
            saveReport("manual_surrender")
        elseif currentRound and (currentRound.outcome=="unknown" or currentRound.outcome=="incomplete") then
            currentRound.outcome="defeat"
            currentRound.reason="manual_surrender_confirmed_by_user"
            event("resultado_confirmado_pelo_jogador",{resultado="defeat",motivo="surrender"})
            currentRound.summary=summarizeRound(currentRound)
            saveReport("manual_surrender")
        else
            warn("[RoWorld Observer] Nao ha partida para marcar como rendicao")
        end
    end)
    makeButton(frame, "Parar", 345, function()
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
        if ui.world then ui.world.Text="Sem partida detectada; aguarda dados globais" end
        ui.status.Text = "Estado: lobby / estado da partida nao encontrado"
        ui.metrics.Text = "Aguardando a rodada iniciar..."
        if report.observer.lastSaveError then
            ui.file.Text = "ERRO: " .. tostring(report.observer.lastSaveError):sub(1, 48)
        elseif savePathUsed then
            ui.file.Text = "Salvo: " .. tostring(savePathUsed):sub(1, 30)
                .. " | " .. tostring(report.observer.saveCount) .. "x"
        end
        return
    end
    local phase = n(state, "phase")
    local names = {[0]="SPAWN", [1]="JOGANDO", [2]="ENCERRADO"}
    ui.status.Text = "Estado: " .. (currentRound and (names[phase] or "DESCONHECIDO") or "LOBBY / AGUARDANDO") .. " | rodada " .. tostring(currentRound and currentRound.index or "-")
    if currentRound and currentRound.endUTC then
        ui.status.Text = ui.status.Text .. " | " .. currentRound.outcome
    end
    local sample = currentRound and currentRound.samples[#currentRound.samples]
    if sample and sample.hasOwner then
        ui.metrics.Text = string.format("Tropas %s | Ouro %s | Terras %s | Renda %s",
            tostring(sample.troops or "?"), tostring(sample.gold or "?"),
            tostring(sample.tiles or "?"), tostring(sample.income or "?"))
    else
        local ownerId = sample and sample.localOwnerId or (n(state, "local_owner") or 0)
        local ownersCount = sample and sample.ownerCount or 0
        ui.metrics.Text = "Nacao local ID " .. tostring(ownerId) .. " | nacoes " .. tostring(ownersCount)
        if ownerId == 0 then
            ui.metrics.Text = ui.metrics.Text .. " | aguardando spawn"
        end
    end
    if ui.world then
        ui.world.Text = "Entidades " .. tostring(report.observer.nationsLastSeen or 0)
            .. " | ataques " .. tostring(report.observer.activeGlobalAttacks or 0)
            .. " | snapshots " .. tostring(report.observer.worldSnapshots or 0)
            .. " | eventos " .. tostring(currentRound and currentRound.world and #currentRound.world.events or 0)
    end
    if report.observer.lastSaveError then
        ui.file.Text = "ERRO: " .. tostring(report.observer.lastSaveError):sub(1, 48)
    elseif savePathUsed then
        ui.file.Text = "Salvo: " .. tostring(savePathUsed):sub(1, 30)
            .. " | " .. tostring(report.observer.saveCount) .. "x"
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

env.ROWORLD_OBSERVER_V04 = {
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
            -- Se o estado ainda nao tem nacao local, procura um candidato melhor.
            -- Tambem renova a referencia entre rodadas.
            local noLocalOwner = (n(foundState, "local_owner") or 0) <= 0
            local needScan = (currentRound and currentRound.endUTC) or noLocalOwner
            local interval = noLocalOwner and 10 or SCAN_INTERVAL
            if needScan and now - lastScanTime >= interval then
                lastScanTime = now
                local newState = discoverState()
                if newState and newState ~= foundState then
                    local currentHasOwner = (n(foundState,"local_owner") or 0) > 0
                    local newHasOwner = (n(newState,"local_owner") or 0) > 0
                    if not currentHasOwner or newHasOwner then foundState = newState end
                end
            end
        end

        if foundState and looksLikeGameState(foundState) and rawget(foundState, "loaded") == true then
            seenAnyState = true
            lastFoundTime = now
            report.observer.stateFound = true
            report.observer.lastSeenUTC = nowUTC()
            report.observer.status = "state_found"
            if now - lastSampleTime >= SAMPLE_INTERVAL then
                lastSampleTime = now
                local wasFinished = currentRound and currentRound.endUTC ~= nil
                recordState(foundState)
                if currentRound and currentRound.endUTC and not wasFinished then
                    saveReport("round_finished")
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

print("[RoWorld Observer] v0.4 multinacoes executando. Inicie uma partida e observe o painel.")
print("[RoWorld Observer] Autosave workspace: " .. workspacePath)
