-- joint_wep_fix.lua  v1.0
-- 通过骨骼 Joint 叠加位置偏移（R_Wep / L_Wep）
-- 写入时机: PrepareRendering（动画帧算完之后、渲染之前）
-- 偏移方式: 每帧读取动画值，写入 AnimPos + Offset（保留完整动画，不锁死）
-- 无需手动开关，加载即生效

local CONFIG_DIR        = "WepJointFix/"
local IN_HAND_THRESHOLD = 0.011
local WEAPON_INTERVAL   = 0.5

-- 全局武器状态（兼容 WeaponPoseFix 接口，LHandIKForceEnable 可直接读取）
WeaponPoseFix               = WeaponPoseFix or {}
WeaponPoseFix.active_weapon = WeaponPoseFix.active_weapon or {}

------------------------------------------------------
-- 角色定义
------------------------------------------------------
local characters = {
    {
        name    = "Grace",
        go_name = "cp_A100",
        enabled = true,
        joints  = {
            { name = "R_Wep",
              off_x = 0.0, off_y = 0.0, off_z = 0.0,
              base_x = nil, base_y = nil, base_z = nil,
              threshold = 0.05,
              _joint = nil, _cur_pos = nil },
            { name = "L_Wep",
              off_x = 0.0, off_y = 0.0, off_z = 0.0,
              base_x = nil, base_y = nil, base_z = nil,
              threshold = 0.05,
              _joint = nil, _cur_pos = nil },
        },
        flashlight = {
            _joint       = nil,
            status       = "Waiting...",
        },
        arm_weapon_map = {
            { prefix = "arm00", label = "Pistol"  },
            { prefix = "arm02", label = "Grenade" },
            { prefix = "arm03", label = "Melee"   },
            { prefix = "arm04", label = "Magnum"  },
            { prefix = "arm05", label = "SMG"     },
        },
        _transform          = nil,
        _go_ref             = nil,
        _arm_cache          = nil,
        _weapon_check_time  = -999,
        _detected_weapon    = nil,
        status              = "Waiting...",
        write_count         = 0,
        config_source       = "default",
    },
    {
        name    = "Leon",
        go_name = "cp_A000",
        enabled = true,
        joints  = {
            { name = "R_Wep",
              off_x = 0.0, off_y = 0.0, off_z = 0.0,
              base_x = nil, base_y = nil, base_z = nil,
              threshold = 0.05,
              _joint = nil, _cur_pos = nil },
            { name = "L_Wep",
              off_x = 0.0, off_y = 0.0, off_z = 0.0,
              base_x = nil, base_y = nil, base_z = nil,
              threshold = 0.05,
              _joint = nil, _cur_pos = nil },
        },
        flashlight = {
            _joint       = nil,
            status       = "Waiting...",
        },
        arm_weapon_map = {
            { prefix = "arm00", label = "Pistol"  },
            { prefix = "arm01", label = "Shotgun" },
            { prefix = "arm02", label = "Grenade" },
            { prefix = "arm03", label = "Melee"   },
            { prefix = "arm04", label = "Magnum"  },
            { prefix = "arm05", label = "SMG"     },
            { prefix = "arm06", label = "Sniper"  },
        },
        _transform          = nil,
        _go_ref             = nil,
        _arm_cache          = nil,
        _weapon_check_time  = -999,
        _detected_weapon    = nil,
        status              = "Waiting...",
        write_count         = 0,
        config_source       = "default",
    },
}

------------------------------------------------------
-- Config
------------------------------------------------------
local function cfg_path(char)
    return CONFIG_DIR .. "joint_wep_fix_" .. char.name .. ".json"
end

local function save_config(char)
    local jdata = {}
    for _, j in ipairs(char.joints) do
        jdata[j.name] = {
            x = j.off_x, y = j.off_y, z = j.off_z,
            base_x = j.base_x, base_y = j.base_y, base_z = j.base_z,
            threshold = j.threshold,
        }
    end
    local fl = char.flashlight
    json.dump_file(cfg_path(char), {
        enabled    = char.enabled,
        joints     = jdata,
        flashlight = { x = fl.x, y = fl.y, z = fl.z },
    })
    char.config_source = cfg_path(char)
end

local function load_config(char)
    local data = json.load_file(cfg_path(char))
    if data then
        if data.enabled ~= nil then char.enabled = data.enabled end
        if data.joints then
            for _, j in ipairs(char.joints) do
                local d = data.joints[j.name]
                if d then
                    j.off_x     = type(d.x)         == "number" and d.x         or j.off_x
                    j.off_y     = type(d.y)         == "number" and d.y         or j.off_y
                    j.off_z     = type(d.z)         == "number" and d.z         or j.off_z
                    j.base_x    = type(d.base_x)    == "number" and d.base_x    or j.base_x
                    j.base_y    = type(d.base_y)    == "number" and d.base_y    or j.base_y
                    j.base_z    = type(d.base_z)    == "number" and d.base_z    or j.base_z
                    j.threshold = type(d.threshold) == "number" and d.threshold or j.threshold
                end
            end
        end
        if data.flashlight then
            local fl = char.flashlight
            fl.x = type(data.flashlight.x) == "number" and data.flashlight.x or fl.x
            fl.y = type(data.flashlight.y) == "number" and data.flashlight.y or fl.y
            fl.z = type(data.flashlight.z) == "number" and data.flashlight.z or fl.z
        end
        char.config_source = cfg_path(char)
    else
        char.config_source = "default (no file)"
    end
end

for _, char in ipairs(characters) do
    load_config(char)
end

------------------------------------------------------
-- Scene / Transform helpers
------------------------------------------------------
local function get_scene()
    local sm = sdk.get_native_singleton("via.SceneManager")
    if not sm then return nil end
    local scene = nil
    pcall(function()
        scene = sdk.call_native_func(
            sm,
            sdk.find_type_definition("via.SceneManager"),
            "get_CurrentScene")
    end)
    return scene
end

local function ensure_transform(char)
    -- 检查缓存是否仍然有效
    if char._go_ref then
        local ok = pcall(function() char._go_ref:call("get_Name") end)
        if not ok then
            char._go_ref       = nil
            char._transform    = nil
            char._arm_cache    = nil
            for _, j in ipairs(char.joints) do
                j._joint = nil
            end
        end
    end

    if char._transform then return char._transform end

    local scene = get_scene()
    if not scene then return nil end

    local go = nil
    pcall(function()
        go = scene:call("findGameObject(System.String)", char.go_name)
    end)
    if not go then return nil end

    char._go_ref = go
    local t = nil
    pcall(function() t = go:call("get_Transform") end)
    char._transform = t
    return t
end

------------------------------------------------------
-- Joint helpers
------------------------------------------------------
local function joint_ok(j_obj)
    if not j_obj then return false end
    return pcall(function() j_obj:call("get_Position") end)
end

local function ensure_joints(char)
    local t = char._transform
    if not t then return end
    for _, j in ipairs(char.joints) do
        if not joint_ok(j._joint) then
            j._joint = nil
            local found = nil
            pcall(function() found = t:call("getJointByName", j.name) end)
            if found then
                j._joint = found
                log.info(string.format("[WepJointFix] found joint: %s %s", char.name, j.name))
            end
        end
    end
end

------------------------------------------------------
-- Flashlight: PlayerFlashLightController→HandLight→WeaponReleaseFromHand._RootJoint
-- 路径与 weapon_pose_fix.lua 完全相同
------------------------------------------------------
local function find_flashlight_joint(char)
    local fl = char.flashlight
    fl._joint = nil
    fl.status  = "Searching..."

    local scene = get_scene()
    if not scene then return end

    local char_go = nil
    pcall(function()
        char_go = scene:call("findGameObject(System.String)", char.go_name)
    end)
    if not char_go then return end

    local char_t = nil
    pcall(function() char_t = char_go:call("get_Transform") end)
    if not char_t then return end

    local child = nil
    pcall(function() child = char_t:call("get_Child") end)
    while child do
        local go = nil
        pcall(function() go = child:call("get_GameObject") end)
        if go then
            local name = ""
            pcall(function() name = go:call("get_Name") end)
            if name == "PlayerFlashLightController" then
                -- 往下找 HandLight
                local inner = nil
                pcall(function() inner = child:call("get_Child") end)
                while inner do
                    local inner_go = nil
                    pcall(function() inner_go = inner:call("get_GameObject") end)
                    if inner_go then
                        local inner_name = ""
                        pcall(function() inner_name = inner_go:call("get_Name") end)
                        if inner_name == "HandLight" then
                            -- 从 app.WeaponReleaseFromHand 读 _RootJoint
                            local comps = inner_go:call("get_Components")
                            local count = comps:call("get_Count")
                            for i = 0, count - 1 do
                                pcall(function()
                                    local comp = comps:call("get_Item", i)
                                    if not comp then return end
                                    local td = comp:get_type_definition()
                                    if td:get_full_name() == "app.WeaponReleaseFromHand" then
                                        for _, field in ipairs(td:get_fields()) do
                                            local ok_n, fn = pcall(function() return field:get_name() end)
                                            if ok_n and fn == "_RootJoint" then
                                                local ok_v, fv = pcall(function() return field:get_data(comp) end)
                                                if ok_v and fv then
                                                    fl._joint = fv
                                                    fl.status = "Joint found"
                                                    log.info("[WepJointFix] flashlight joint found: " .. char.name)
                                                end
                                            end
                                        end
                                    end
                                end)
                            end
                            break
                        end
                    end
                    local ok_n, nxt = pcall(function() return inner:call("get_Next") end)
                    if not ok_n or not nxt then break end
                    inner = nxt
                end
                break
            end
        end
        local ok_n, nxt = pcall(function() return child:call("get_Next") end)
        if not ok_n or not nxt then break end
        child = nxt
    end

    if not fl._joint then
        fl.status = "Joint not found"
    end
end

local function update_weapon(char)
    if os.clock() - char._weapon_check_time < WEAPON_INTERVAL then return end
    char._weapon_check_time = os.clock()

    local t = char._transform
    if not t then return end

    -- 构建 arm 缓存
    if not char._arm_cache then
        local arms = {}
        local ok, child = pcall(function() return t:call("get_Child") end)
        if ok and child then
            while child do
                local ok2, cgo = pcall(function() return child:call("get_GameObject") end)
                if ok2 and cgo then
                    local ok3, n = pcall(function() return cgo:call("get_Name") end)
                    if ok3 and n and n:sub(1, 3) == "arm" then
                        table.insert(arms, { name = n, go = cgo, transform = child })
                    end
                end
                local ok4, nx = pcall(function() return child:call("get_Next") end)
                if not ok4 or not nx then break end
                child = nx
            end
        end
        char._arm_cache = arms
    end

    -- 检测当前持握武器
    local detected = nil
    for _, arm in ipairs(char._arm_cache) do
        for _, rule in ipairs(char.arm_weapon_map) do
            if arm.name:sub(1, #rule.prefix) == rule.prefix then
                local draw_self = false
                local ok1 = pcall(function() draw_self = arm.go:call("get_DrawSelf") end)
                if not ok1 then
                    char._arm_cache = nil
                    return
                end
                if draw_self then
                    local pos   = nil
                    local ok2   = pcall(function() pos = arm.transform:call("get_LocalPosition") end)
                    if not ok2 then
                        char._arm_cache = nil
                        return
                    end
                    if pos
                        and math.abs(pos.x) < IN_HAND_THRESHOLD
                        and math.abs(pos.y) < IN_HAND_THRESHOLD
                        and math.abs(pos.z) < IN_HAND_THRESHOLD
                    then
                        detected = rule.label
                    end
                end
                break
            end
        end
        if detected then break end
    end

    char._detected_weapon               = detected
    WeaponPoseFix.active_weapon[char.name] = detected
end

------------------------------------------------------
-- Weapon detection（移植自 weapon_pose_fix.lua）
------------------------------------------------------
re.on_frame(function()
    for _, char in ipairs(characters) do
        if char.enabled then
            ensure_transform(char)
            if char._transform then
                ensure_joints(char)
                pcall(update_weapon, char)
                for _, j in ipairs(char.joints) do
                    if joint_ok(j._joint) then
                        local cur = nil
                        pcall(function() cur = j._joint:call("get_LocalPosition") end)
                        if cur then
                            j._cur_pos = cur
                            -- 首次找到日自动捕获 base（临时，未存入 JSON）
                            if j.base_x == nil then
                                j.base_x = cur.x
                                j.base_y = cur.y
                                j.base_z = cur.z
                                log.info(string.format("[WepJointFix] auto-captured base %s %s: (%.4f,%.4f,%.4f)",
                                    char.name, j.name, cur.x, cur.y, cur.z))
                            end
                        end
                    else
                        j._joint = nil
                    end
                end
                local fl = char.flashlight
                if not joint_ok(fl._joint) then
                    fl._joint = nil
                    pcall(find_flashlight_joint, char)
                end
            else
                char.status = "Not in scene"
            end
        else
            char.status = "Disabled"
        end
    end
end)


------------------------------------------------------
-- PrepareRendering
-- 模仿 arm00 逻辑：
--   cur 靠近 base    (pos ~= base)   → 正常站姿，写入 base+offset
--   cur 靠近 target  (pos ~= base+off) → 已写入过，继续写入
--   cur 远离两者  (换弹、特殊动画)  → 跳过，动画自由播放
-- 写入绝对值不积累，无需任何暂停检测
------------------------------------------------------
re.on_pre_application_entry("PrepareRendering", function()
    for _, char in ipairs(characters) do
        if not char.enabled or not char._transform then
            -- skip
        else
            local written = false

            for _, j in ipairs(char.joints) do
                if joint_ok(j._joint) and j.base_x ~= nil then
                    local tx = j.base_x + j.off_x
                    local ty = j.base_y + j.off_y
                    local tz = j.base_z + j.off_z
                    local thr = j.threshold

                    local cur = nil
                    pcall(function() cur = j._joint:call("get_LocalPosition") end)
                    if cur then
                        -- 靠近自然位置（相对静止）或曾经写入过的 target 位置
                        local near_base = math.abs(cur.x - j.base_x) < thr
                                      and math.abs(cur.y - j.base_y) < thr
                                      and math.abs(cur.z - j.base_z) < thr
                        local near_target = math.abs(cur.x - tx) < thr
                                        and math.abs(cur.y - ty) < thr
                                        and math.abs(cur.z - tz) < thr

                        if near_base or near_target then
                            pcall(function()
                                j._joint:call("set_LocalPosition", Vector3f.new(tx, ty, tz))
                            end)
                            written = true
                        end
                        -- else: 动画公远的位置（如换弹），跳过，不干扰
                    end
                else
                    if not joint_ok(j._joint) then j._joint = nil end
                end
            end

            -- 手电筒：直接吸附到 L_Wep，无需再计算偏移！
            -- 因为 L_Wep 自身支持上面配置的偏移滑条
            local fl = char.flashlight
            if joint_ok(fl._joint) then
                local l_wep = nil
                for _, j in ipairs(char.joints) do
                    if j.name == "L_Wep" then
                        l_wep = j._joint
                        break
                    end
                end
                
                if joint_ok(l_wep) then
                    local wpos = nil
                    local wrot = nil
                    pcall(function()
                        wpos = l_wep:call("get_Position")
                        wrot = l_wep:call("get_Rotation")
                    end)
                    if wpos and wrot then
                        local ok = pcall(function()
                            fl._joint:call("set_Position", wpos)
                            fl._joint:call("set_Rotation", wrot)
                        end)
                        if not ok then
                            fl._joint = nil
                            fl.status = "Failed to parent to L_Wep"
                        else
                            fl.status = "Anchored to L_Wep"
                            written = true
                        end
                    end
                else
                    fl.status = "Waiting for L_Wep..."
                end
            else
                fl._joint = nil
            end

            if written then char.write_count = char.write_count + 1 end
            char.status = string.format(
                "Active | weapon: %s | writes: %d",
                char._detected_weapon or "None",
                char.write_count)
        end
    end
end)



------------------------------------------------------

-- UI
------------------------------------------------------
re.on_draw_ui(function()
    if not imgui.collapsing_header("Wep Joint Fix") then return end

    for _, char in ipairs(characters) do
        imgui.push_id("wjf_" .. char.name)

        if imgui.tree_node(char.name .. " (" .. char.go_name .. ")") then

            local ch, ne = imgui.checkbox("Enabled", char.enabled)
            if ch then char.enabled = ne end

            imgui.text("Status : " .. char.status)
            imgui.text("Config : " .. char.config_source)
            imgui.separator()

            for _, j in ipairs(char.joints) do
                imgui.push_id("j_" .. j.name)

                local joint_status = joint_ok(j._joint) and "  [OK]" or "  [NOT FOUND]"
                imgui.text(j.name .. joint_status)
                if j.base_x then
                    imgui.text(string.format("  Base  : (%.4f, %.4f, %.4f)", j.base_x, j.base_y, j.base_z))
                    imgui.text(string.format("  Target: (%.4f, %.4f, %.4f)",
                        j.base_x+j.off_x, j.base_y+j.off_y, j.base_z+j.off_z))
                else
                    imgui.text("  Base: not captured yet (will auto-capture)")
                end
                if j._cur_pos then
                    imgui.text(string.format("  Cur   : (%.4f, %.4f, %.4f)",
                        j._cur_pos.x, j._cur_pos.y, j._cur_pos.z))
                end

                local cx, vx = imgui.drag_float("X##" .. j.name, j.off_x, 0.0001, -0.5, 0.5, "%.4f")
                if cx then j.off_x = vx end
                local cy, vy = imgui.drag_float("Y##" .. j.name, j.off_y, 0.0001, -0.5, 0.5, "%.4f")
                if cy then j.off_y = vy end
                local cz, vz = imgui.drag_float("Z##" .. j.name, j.off_z, 0.0001, -0.5, 0.5, "%.4f")
                if cz then j.off_z = vz end

                if imgui.button("Reset##" .. j.name) then
                    j.off_x, j.off_y, j.off_z = 0.0, 0.0, 0.0
                end

                imgui.spacing()
                imgui.pop_id()
            end

            imgui.separator()

            -- 手电筒
            imgui.text("Flashlight (HandLight._RootJoint):")
            imgui.text("  Status: " .. char.flashlight.status)
            imgui.spacing()

            imgui.separator()

            if imgui.button("Save##" .. char.name) then
                save_config(char)
            end
            imgui.same_line()
            if imgui.button("Reload##" .. char.name) then
                load_config(char)
            end

            imgui.tree_pop()
        end

        imgui.pop_id()
    end
end)

log.info("[WepJointFix] Loaded.")