-- ExportModule.lua — 書き出し操作
-- Export presets へのアクセスは LrApplication SDK に API がないため、
-- ~/Library/Application Support/Adobe/Lightroom/Export Presets/ を直接読む。

local LrApplication     = import 'LrApplication'
local LrExportSession   = import 'LrExportSession'
local LrTasks           = import 'LrTasks'
local LrFunctionContext = import 'LrFunctionContext'
local LrPathUtils       = import 'LrPathUtils'
local LrFileUtils       = import 'LrFileUtils'
local LrDate            = import 'LrDate'

local ExportModule = {}

local function getLogger()
    if _G.LightroomPythonBridge and _G.LightroomPythonBridge.logger then
        return _G.LightroomPythonBridge.logger
    end
    local LrLogger = import 'LrLogger'
    local logger = LrLogger('ExportModule')
    logger:enable("logfile")
    return logger
end

-- ~/Library/Application Support/Adobe/Lightroom/Export Presets を返す
local function getExportPresetsDir()
    local home = LrPathUtils.getStandardFilePath("home")
    local base = LrPathUtils.child(home, "Library")
    base = LrPathUtils.child(base, "Application Support")
    base = LrPathUtils.child(base, "Adobe")
    base = LrPathUtils.child(base, "Lightroom")
    return LrPathUtils.child(base, "Export Presets")
end

-- .lrtemplate ファイルから export settings テーブルを読み込む
-- .lrtemplate は "s = { value = {...}, ... }" と書いて return しない形式のため、
-- グローバル s を一時的に捕捉して読む。
local function loadPresetSettings(presetPath)
    local chunk, err = loadfile(presetPath)
    if not chunk then
        local f = io.open(presetPath, "r")
        if not f then return nil, "Cannot open: " .. presetPath end
        local src = f:read("*all")
        f:close()
        chunk = loadstring(src) or load(src)
        if not chunk then return nil, "Parse error: " .. tostring(err) end
    end
    -- グローバル s を保存して上書き実行し、読み取る
    local prev_s = rawget(_G, "s")
    rawset(_G, "s", nil)
    local ok, pcall_err = pcall(chunk)
    local preset_data = rawget(_G, "s")
    rawset(_G, "s", prev_s)
    if not ok then
        return nil, "Execution error: " .. tostring(pcall_err)
    end
    if type(preset_data) == "table" and preset_data.value then
        return preset_data.value, nil
    end
    return nil, "Invalid preset format: s.value not found (got " .. type(preset_data) .. ")"
end

-- presetsDir 以下を走査してプリセット一覧を構築
local function scanPresets(presetsDir, query)
    local results = {}
    if LrFileUtils.exists(presetsDir) ~= "directory" then return results end

    for folderPath in LrFileUtils.directoryEntries(presetsDir) do
        if LrFileUtils.exists(folderPath) == "directory" then
            local folderName = LrPathUtils.leafName(folderPath)
            for presetPath in LrFileUtils.directoryEntries(folderPath) do
                local ext = LrPathUtils.extension(presetPath)
                if ext == "lrtemplate" then
                    local leaf = LrPathUtils.leafName(presetPath)
                    local name = LrPathUtils.removeExtension(leaf)
                    local include = true
                    if query then
                        local lq = string.lower(query)
                        include = string.find(string.lower(name), lq, 1, true) ~= nil
                            or string.find(string.lower(folderName), lq, 1, true) ~= nil
                    end
                    if include then
                        table.insert(results, {
                            name   = name,
                            folder = folderName,
                            path   = presetPath,
                        })
                    end
                end
            end
        end
        LrTasks.yield()
    end
    return results
end

-- catalog.listExportPresets
-- 返り値: { presets: [{name, folder}], count: N }
function ExportModule.listExportPresets(params, callback)
    local logger = getLogger()
    local query = params and params.query or nil
    local presetsDir = getExportPresetsDir()
    local results = scanPresets(presetsDir, query)
    -- path フィールドはクライアントに返さない
    local out = {}
    for _, r in ipairs(results) do
        table.insert(out, { name = r.name, folder = r.folder })
    end
    logger:debug("listExportPresets: found " .. #out .. " presets")
    callback({ result = { presets = out, count = #out } })
end

-- catalog.exportWithPreset
-- params:
--   photoIds:   string[]  (localIdentifier の文字列配列)
--   presetName: string    (書き出しプリセット名)
--   outputDir:  string?   (省略時はプリセットの宛先をそのまま使う)
--   dryRun:     boolean?
-- 返り値: { exported: string[], count: N, skipped: N, presetName: string }
function ExportModule.exportWithPreset(params, callback)
    local logger = getLogger()

    local photoIds   = params and params.photoIds   or {}
    local presetName = params and params.presetName
    local outputDir  = params and params.outputDir
    local dryRun     = params and params.dryRun or false

    if not presetName or presetName == "" then
        callback({ error = { code = "MISSING_PARAM", message = "presetName is required" } })
        return
    end
    if #photoIds == 0 then
        callback({ error = { code = "NO_PHOTOS", message = "photoIds must not be empty" } })
        return
    end

    -- プリセットをファイルシステムから検索
    local presetsDir = getExportPresetsDir()
    local all = scanPresets(presetsDir, nil)
    local presetPath = nil
    for _, r in ipairs(all) do
        if r.name == presetName then
            presetPath = r.path
            break
        end
    end

    if not presetPath then
        -- デバッグ: 実際に見つかった名前を列挙
        local foundNames = {}
        for _, r in ipairs(all) do
            table.insert(foundNames, r.name)
        end
        callback({ error = {
            code    = "PRESET_NOT_FOUND",
            message = "Export preset not found: [" .. presetName .. "] len=" .. #presetName
                .. ". Found presets: " .. table.concat(foundNames, " | "),
        }})
        return
    end

    -- 写真を localIdentifier で取得
    local catalog = LrApplication.activeCatalog()
    local photos = {}
    for _, pid in ipairs(photoIds) do
        local photo = catalog:getPhotoByLocalId(tonumber(pid))
        if photo then
            table.insert(photos, photo)
        else
            logger:warn("exportWithPreset: photo not found for id: " .. tostring(pid))
        end
    end

    if #photos == 0 then
        callback({ error = {
            code    = "NO_PHOTOS_FOUND",
            message = "None of the specified photoIds were found in catalog",
        }})
        return
    end

    -- dry-run
    if dryRun then
        callback({ result = {
            exported    = {},
            count       = 0,
            skipped     = 0,
            dryRun      = true,
            wouldExport = #photos,
            presetName  = presetName,
        }})
        return
    end

    -- .lrtemplate から設定を読み込み
    local exportSettings, loadErr = loadPresetSettings(presetPath)
    if not exportSettings then
        callback({ error = { code = "PRESET_LOAD_ERROR", message = tostring(loadErr) } })
        return
    end

    -- outputDir が指定された場合は宛先を上書き
    -- LrExportSession は非 ASCII パスを受け付けないため、
    -- ASCII 以外の文字を含む場合は Pictures 下に ASCII 一時ディレクトリを作り
    -- 書き出し後に最終パスへ移動する。
    local finalOutputDir = nil
    local tempOutputDir  = nil

    local function hasNonAscii(s)
        for i = 1, #s do
            if s:byte(i) > 127 then return true end
        end
        return false
    end

    local function createDirectoryOrError(path, code)
        local createdOk, createErr = LrFileUtils.createAllDirectories(path)
        if createdOk then return true end
        if LrFileUtils.exists(path) == "directory" then return true end
        callback({ error = {
            code    = code,
            message = "Failed to create directory: " .. tostring(path) .. ": " .. tostring(createErr),
        }})
        return false
    end

    local function makeAsciiStagingDir()
        local pictures = LrPathUtils.getStandardFilePath("pictures")
        if not pictures or pictures == "" then
            local home = LrPathUtils.getStandardFilePath("home")
            pictures = LrPathUtils.child(home, "Pictures")
        end

        local stamp = tostring(math.floor(LrDate.currentTime() * 1000))
        local candidate = LrPathUtils.child(pictures, "lrwf_stg_" .. stamp)
        return LrFileUtils.chooseUniqueFileName(candidate)
    end

    if outputDir then
        if not hasNonAscii(outputDir) then
            if not createDirectoryOrError(outputDir, "OUTPUT_DIR_ERROR") then return end
            exportSettings.LR_export_destinationType        = "specificFolder"
            exportSettings.LR_export_destinationPathPrefix  = outputDir
            exportSettings.LR_export_destinationPathSuffix  = ""
            exportSettings.LR_export_useSubfolder           = false
        else
            -- 非 ASCII パス: Pictures 下に ASCII 一時ディレクトリを作成
            tempOutputDir = makeAsciiStagingDir()
            if not createDirectoryOrError(tempOutputDir, "STAGING_DIR_ERROR") then return end
            finalOutputDir = outputDir
            exportSettings.LR_export_destinationType        = "specificFolder"
            exportSettings.LR_export_destinationPathPrefix  = tempOutputDir
            exportSettings.LR_export_destinationPathSuffix  = ""
            exportSettings.LR_export_useSubfolder           = false
        end
    end

    -- LrExportSession で書き出し
    local exportedPaths = {}
    local skippedCount  = 0

    local ok, err = LrTasks.pcall(function()
        LrFunctionContext.callWithContext("exportWithPreset", function(_context)
            local session = LrExportSession {
                photosToExport = photos,
                exportSettings = exportSettings,
            }
            for _, rendition in session:renditions() do
                local success, pathOrMessage = rendition:waitForRender()
                if success then
                    table.insert(exportedPaths, pathOrMessage)
                else
                    skippedCount = skippedCount + 1
                    logger:warn("rendition failed: " .. tostring(pathOrMessage))
                end
                LrTasks.yield()
            end
        end)
    end)

    if not ok then
        callback({ error = { code = "EXPORT_ERROR", message = tostring(err) } })
        return
    end

    -- 非 ASCII パスの場合は移動を Python 側に委譲
    -- staging dir パスと最終パスを返し、Python が shutil.move で処理する
    logger:info("exportWithPreset: exported " .. #exportedPaths .. ", skipped " .. skippedCount)
    callback({ result = {
        exported      = exportedPaths,
        count         = #exportedPaths,
        skipped       = skippedCount,
        presetName    = presetName,
        stagingDir    = tempOutputDir,
        finalOutputDir = finalOutputDir,
    }})
end

return ExportModule
