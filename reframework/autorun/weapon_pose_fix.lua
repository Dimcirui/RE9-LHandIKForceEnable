local cfg = {
    check_interval = 0.5,
}

local CONFIG_DIR = "WeaponPoseFix/"
local IN_HAND_THRESHOLD = 0.011   -- LocalPosition 各分量与偏移量之差小于此值视为在手

-- 供其他脚本读取的全局武器状态
-- 用法: WeaponPoseFix.active_weapon["Grace"]  →  "Pistol" / "Melee" / nil
-- 用法: WeaponPoseFix.active_weapon["Leon"]   →  "Shotgun" / nil
WeaponPoseFix = WeaponPoseFix or {}
WeaponPoseFix.active_weapon = {}

local function make_defaults(rules)
    local d = {}
    for i, r in ipairs(rules) do
        d[i] = { x = r.x, y = r.y, z = r.z }
    end
    return d
end

local characters = {
    {
        name = "Grace",
        go_name = "cp_A100",
        enabled = true,
        fix_count = 0,
        status = "Waiting...",
        found_arms = {},
        config_source = "default",
        initialized = false,
        suspended = false,
        arm_states = {},
        rules = {
            { prefix = "arm00", x = 0.0, y = 0.0, z = 0.0, label = "Pistol" },
            { prefix = "arm02", x = 0.0,   y = 0.0, z = 0.0,  label = "Grenade"  },
            { prefix = "arm03", x = 0.0,   y = 0.0, z = 0.0,   label = "Melee"  },
            { prefix = "arm04", x = 0.0, y = 0.0, z = 0.0, label = "Magnum" },
            { prefix = "arm05", x = 0.0, y = 0.0, z = 0.0, label = "SMG" },
        },
        flashlight = {
            node_name = "HandLight",
            x = 0.0, y = 0.0, z = 0.0,
            default_x = 0.0, default_y = 0.0, default_z = 0.0,
            status = "Waiting...",
            root_joint = nil,
        },
    },
    {
        name = "Leon",
        go_name = "cp_A000",
        enabled = true,
        fix_count = 0,
        status = "Waiting...",
        found_arms = {},
        config_source = "default",
        initialized = false,
        suspended = false,
        arm_states = {},
        rules = {

            { prefix = "arm00", x = 0.0, y = 0.0, z = 0.0, label = "Pistol" },
            { prefix = "arm01", x = 0.0, y = 0.0, z = 0.0, label = "Shotgun" },
            { prefix = "arm02", x = 0.0,   y = 0.0, z = 0.0,  label = "Grenade"  },
            { prefix = "arm03", x = 0.0,   y = 0.0, z = 0.0,   label = "Melee"  },
            { prefix = "arm04", x = 0.0, y = 0.0, z = 0.0, label = "Magnum" },
            { prefix = "arm05", x = 0.0, y = 0.0, z = 0.0, label = "SMG" },
            { prefix = "arm06", x = 0.0, y = 0.0, z = 0.0, label = "Sniper" },

        },
        flashlight = {
            node_name = "HandLight",
            x = 0.0, y = 0.0, z = 0.0,
            default_x = 0.0, default_y = 0.0, default_z = 0.0,
            status = "Waiting...",
            root_joint = nil,
        },
    },
}

for _, char in ipairs(characters) do
    char.defaults = make_defaults(char.rules)
end

------------------------------------------------------
-- JSON save / load
------------------------------------------------------
local function get_config_path(char)
    return CONFIG_DIR .. "weapon_pose_" .. char.name .. ".json"
end

local function save_config(char)
    local path = get_config_path(char)
    local data = {
        enabled = char.enabled,
        rules = {},
        flashlight = {
            x = char.flashlight.x,
            y = char.flashlight.y,
            z = char.flashlight.z,
        }
    }
    for _, rule in ipairs(char.rules) do
        table.insert(data.rules, {
            prefix = rule.prefix,
            label  = rule.label,
            x      = rule.x,
            y      = rule.y,
            z      = rule.z,
        })
    end
    json.dump_file(path, data)
    char.config_source = path
    log.info("[WeaponPosFix] Saved config for " .. char.name)
end

local function load_config(char)
    local path = get_config_path(char)
    local data = json.load_file(path)
    if data then
        if data.enabled ~= nil then char.enabled = data.enabled end
        if data.rules then
            for _, saved_rule in ipairs(data.rules) do
                for _, rule in ipairs(char.rules) do
                    if rule.prefix == saved_rule.prefix then
                        rule.x = saved_rule.x
                        rule.y = saved_rule.y
                        rule.z = saved_rule.z
                        break
                    end
                end
            end
        end
        if data.flashlight then
            char.flashlight.x = data.flashlight.x or char.flashlight.x
            char.flashlight.y = data.flashlight.y or char.flashlight.y
            char.flashlight.z = data.flashlight.z or char.flashlight.z
        end
        char.config_source = path
        log.info("[WeaponPosFix] Loaded config for " .. char.name)
    else
        save_config(char)
        char.config_source = path .. " (auto-generated)"
        log.info("[WeaponPosFix] Auto-generated config for " .. char.name)
    end
end

for _, char in ipairs(characters) do
    load_config(char)
end

------------------------------------------------------
-- Core
------------------------------------------------------
local function get_rule(char, name)
    for _, rule in ipairs(char.rules) do
        if name:sub(1, #rule.prefix) == rule.prefix then
            return rule
        end
    end
    return nil
end


local last_check = -999

local _scene_cache = nil
local _scene_frame = -1

local function get_scene()
    local frame = os.clock()  -- 用时间戳做帧缓存 key
    if _scene_cache and (frame - _scene_frame) < 0.016 then
        return _scene_cache
    end
    local sm = sdk.get_native_singleton("via.SceneManager")
    if not sm then return nil end
    local scene = nil
    pcall(function()
        scene = sdk.call_native_func(sm,
            sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
    end)
    if not scene then
        pcall(function() scene = sm:call("get_CurrentScene") end)
    end
    _scene_cache = scene
    _scene_frame = frame
    return scene
end

local function collect_arm_transforms(parent_transform)
    local results = {}
    if not parent_transform then return results end
    local ok, child = pcall(function() return parent_transform:call("get_Child") end)
    if not ok or not child then return results end
    while child do
        local ok_g, go = pcall(function() return child:call("get_GameObject") end)
        if ok_g and go then
            local ok_n, n = pcall(function() return go:call("get_Name") end)
            if ok_n and n and n:sub(1, 3) == "arm" then
                table.insert(results, { name = n, transform = child })
            end
        end
        local ok_next, next_t = pcall(function() return child:call("get_Next") end)
        if not ok_next or not next_t then break end
        child = next_t
    end
    return results
end

-- 从角色根节点往下找，避免两个角色的 HandLight 混淆
local function find_flashlight_root_joint(char)
    local fl = char.flashlight
    local scene = get_scene()
    if not scene then return end

    local char_go = nil
    pcall(function() char_go = scene:call("findGameObject(System.String)", char.go_name) end)
    if not char_go then return end

    local char_t = nil
    pcall(function() char_t = char_go:call("get_Transform") end)
    if not char_t then return end

    -- 遍历子级找 PlayerFlashLightController
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
                        if inner_name == fl.node_name then
                            -- 找到 HandLight，取 WeaponReleaseFromHand._RootJoint
                            local comps = inner_go:call("get_Components")
                            local count = comps:call("get_Count")
                            for i = 0, count - 1 do
                                pcall(function()
                                    local comp = comps:call("get_Item", i)
                                    if not comp then return end
                                    if comp:get_type_definition():get_full_name() == "app.WeaponReleaseFromHand" then
                                        for _, field in ipairs(comp:get_type_definition():get_fields()) do
                                            local ok, fn = pcall(function() return field:get_name() end)
                                            if ok and fn == "_RootJoint" then
                                                local ok2, fv = pcall(function() return field:get_data(comp) end)
                                                if ok2 and fv then
                                                    fl.root_joint = fv
                                                    fl.status = "Joint found"
                                                    log.info("[WeaponPosFix] HandLight _RootJoint found for " .. char.name)
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
end

local function apply_flashlight_fix(char)
    local fl = char.flashlight

    -- 角色被挂到其他物体下时（如电梯），apply_fix 已设置 suspended，这里同步跳过
    if char.suspended then
        fl.status = "Suspended (attached to object)"
        return
    end

    if not fl.root_joint then
        find_flashlight_root_joint(char)
        if not fl.root_joint then
            fl.status = "Joint not found"
            return
        end
    end

    local ok = pcall(function()
        fl.root_joint:call("set_LocalPosition", Vector3f.new(fl.x, fl.y, fl.z))
    end)
    if not ok then
        fl.root_joint = nil
        fl.status = "Joint lost, retrying..."
        return
    end

    local result = nil
    pcall(function() result = fl.root_joint:call("get_LocalPosition") end)
    if result then
        fl.status = string.format("(%.3f, %.3f, %.3f)", result.x, result.y, result.z)
    end
end

local function recheck_states(char)
    local scene = get_scene()
    if not scene then return end
    local go = nil
    pcall(function() go = scene:call("findGameObject(System.String)", char.go_name) end)
    if not go then return end
    local cp_transform = nil
    pcall(function() cp_transform = go:call("get_Transform") end)
    if not cp_transform then return end
    local arms = collect_arm_transforms(cp_transform)

    -- 只对已经是 in_hand 的 arm 重新写入新偏移，不重新判断状态
    for _, arm in ipairs(arms) do
        if char.arm_states[arm.name] == "in_hand" then
            local rule = get_rule(char, arm.name)
            if rule then
                pcall(function() arm.transform:call("set_LocalPosition", Vector3f.new(rule.x, rule.y, rule.z)) end)
            end
        end
    end
    last_check = -999
end

local function apply_fix(char)
    local scene = get_scene()
    if not scene then char.status = "No scene"; return end

    local ok_go, go = pcall(function()
        return scene:call("findGameObject(System.String)", char.go_name)
    end)
    if not ok_go or not go then
        char.status = "Not in scene"
        char.initialized = false
        char.arm_states = {}
            return
    end

    -- 检测角色是否被挂到其他物体下（如电梯）
    -- suspended 已在 on_frame 每帧更新，这里直接读取
    if char.suspended then
        char.status = "Suspended (attached to object)"
        char.initialized = false
        char.arm_states = {}
        return
    end

    local ok_t, cp_transform = pcall(function() return go:call("get_Transform") end)
    if not ok_t or not cp_transform then char.status = "No Transform"; return end

    local arms = collect_arm_transforms(cp_transform)
    if #arms == 0 then char.status = "No arm* children found"; return end

    if not char.initialized then
        char.initialized = true
        char.arm_states = {}
        char.status = "Initializing..."
        return
    end

    char.found_arms = {}
    local active_count = 0
    local stored_count = 0
    local skipped_count = 0

    -- 偏移模块：lp=(0,0,0) 且 DrawSelf=true → in_hand，写偏移
    for _, arm in ipairs(arms) do
        local rule = get_rule(char, arm.name)
        if rule then
            local pos = nil
                pcall(function() pos = arm.transform:call("get_LocalPosition") end)
                if not pos then
                    skipped_count = skipped_count + 1
                else
                    local draw_self = false
                    local cgo = nil
                    pcall(function() cgo = arm.transform:call("get_GameObject") end)
                    if cgo then
                        pcall(function() draw_self = cgo:call("get_DrawSelf") end)
                    end

                    local near_zero = math.abs(pos.x) < IN_HAND_THRESHOLD and
                        math.abs(pos.y) < IN_HAND_THRESHOLD and
                        math.abs(pos.z) < IN_HAND_THRESHOLD
                    local near_rule = math.abs(pos.x - rule.x) < IN_HAND_THRESHOLD and
                        math.abs(pos.y - rule.y) < IN_HAND_THRESHOLD and
                        math.abs(pos.z - rule.z) < IN_HAND_THRESHOLD
                    local in_hand = draw_self and (near_zero or near_rule)

                    if in_hand then
                        char.arm_states[arm.name] = "in_hand"
                        pcall(function() arm.transform:call("set_LocalPosition", Vector3f.new(rule.x, rule.y, rule.z)) end)
                        table.insert(char.found_arms, string.format("[%s][IN HAND] %s", rule.label, arm.name))
                        active_count = active_count + 1
                    else
                        char.arm_states[arm.name] = "stored"
                        table.insert(char.found_arms, string.format("[%s][stored] %s (pos=%.3f,%.3f,%.3f draw=%s)",
                            rule.label, arm.name, pos.x, pos.y, pos.z, tostring(draw_self)))
                        stored_count = stored_count + 1
                    end
                end
        else
            table.insert(char.found_arms, string.format("[--] %s (no rule)", arm.name))
            skipped_count = skipped_count + 1
        end
    end

    char.fix_count = char.fix_count + 1
    char.status = string.format("In hand: %d, stored: %d, skipped: %d (fixes: %d)",
        active_count, stored_count, skipped_count, char.fix_count)

    -- 武器输出模块：直接从 arm_states 读，DrawSelf 已保证只有一个 in_hand
    local active_weapon = nil
    for _, arm in ipairs(arms) do
        if char.arm_states[arm.name] == "in_hand" then
            local rule = get_rule(char, arm.name)
            if rule then
                active_weapon = rule.label
                break
            end
        end
    end
    WeaponPoseFix.active_weapon[char.name] = active_weapon
end

local function restore_char(char)
    local scene = get_scene()
    if not scene then return end
    local go = nil
    pcall(function() go = scene:call("findGameObject(System.String)", char.go_name) end)
    if not go then return end
    local cp_transform = nil
    pcall(function() cp_transform = go:call("get_Transform") end)
    if not cp_transform then return end
    local arms = collect_arm_transforms(cp_transform)
    local zero = Vector3f.new(0, 0, 0)
    for _, arm in ipairs(arms) do
        if char.arm_states[arm.name] == "in_hand" then
            pcall(function() arm.transform:call("set_LocalPosition", zero) end)
        end
    end
    if char.flashlight.root_joint then
        pcall(function() char.flashlight.root_joint:call("set_LocalPosition", zero) end)
    end
    char.initialized = false
    char.arm_states = {}
    char.found_arms = {}
    char.flashlight.root_joint = nil
    char.flashlight.status = "Disabled"
    char.status = "Disabled"
end

------------------------------------------------------
-- Main loop
------------------------------------------------------
local function get_char_go(scene, char)
    if not scene then return nil end
    local go = nil
    pcall(function() go = scene:call("findGameObject(System.String)", char.go_name) end)
    return go
end

re.on_frame(function()
    local scene = get_scene()

    -- 每帧更新 suspended + 手电筒，合并 GO 查找
    for _, char in ipairs(characters) do
        if char.enabled then
            local go = get_char_go(scene, char)
            -- suspended 检测
            if go then
                local t = nil
                pcall(function() t = go:call("get_Transform") end)
                if t then
                    local parent = nil
                    pcall(function() parent = t:call("get_Parent") end)
                    char.suspended = parent ~= nil
                end
            end
            -- 手电筒写入
            pcall(apply_flashlight_fix, char)
        end
    end

    -- 武器位置 0.5s 间隔
    local now = os.clock()
    if now - last_check < cfg.check_interval then return end
    last_check = now

    for _, char in ipairs(characters) do
        if not char.enabled then
            if char.initialized then
                pcall(restore_char, char)
            else
                char.status = "Disabled"
            end
        else
            pcall(apply_fix, char)
        end
    end
end)

------------------------------------------------------
-- UI
------------------------------------------------------
re.on_draw_ui(function()
    if imgui.collapsing_header("Weapon Position Fix") then
        for _, char in ipairs(characters) do
            imgui.push_id("wpf_" .. char.name)
            if imgui.tree_node(char.name .. "##wpf_" .. char.name) then

                local changed_en, new_en = imgui.checkbox("Enabled", char.enabled)
                if changed_en then
                    char.enabled = new_en
                    if not new_en then pcall(restore_char, char) end
                end

                imgui.same_line()
                if imgui.button("Apply Now") then
                    char.initialized = false
                    char.arm_states = {}
                    char.flashlight.root_joint = nil
                    last_check = -999
                end

                imgui.separator()
                imgui.text("Status: " .. char.status)
                imgui.text("Config: " .. char.config_source)

                if #char.found_arms > 0 then
                    for _, info in ipairs(char.found_arms) do
                        imgui.text("  " .. info)
                    end
                end

                imgui.separator()
                imgui.text("Weapon Offset Adjust:")
                imgui.spacing()

                imgui.begin_disabled(char.suspended)

                for i, rule in ipairs(char.rules) do
                    imgui.push_id(char.name .. i)
                    imgui.text("[" .. rule.label .. "] " .. rule.prefix .. "xx")

                    local cx, vx = imgui.drag_float("X##" .. char.name .. i, rule.x, 0.001, -1.0, 1.0, "%.4f")
                    if cx then char.rules[i].x = vx; pcall(recheck_states, char) end

                    local cy, vy = imgui.drag_float("Y##" .. char.name .. i, rule.y, 0.001, -1.0, 1.0, "%.4f")
                    if cy then char.rules[i].y = vy; pcall(recheck_states, char) end

                    local cz, vz = imgui.drag_float("Z##" .. char.name .. i, rule.z, 0.001, -1.0, 1.0, "%.4f")
                    if cz then char.rules[i].z = vz; pcall(recheck_states, char) end

                    if imgui.button("Reset##" .. char.name .. i) then
                        rule.x = char.defaults[i].x
                        rule.y = char.defaults[i].y
                        rule.z = char.defaults[i].z
                        pcall(recheck_states, char)
                    end

                    imgui.spacing()
                    imgui.pop_id()
                end

                imgui.separator()
                imgui.text("Flashlight (HandLight) Offset:")
                imgui.text("  Status: " .. char.flashlight.status)
                imgui.spacing()

                local fl = char.flashlight

                local fx, fvx = imgui.drag_float("X##fl" .. char.name, fl.x, 0.001, -2.0, 2.0, "%.4f")
                if fx then char.flashlight.x = fvx end

                local fy, fvy = imgui.drag_float("Y##fl" .. char.name, fl.y, 0.001, -2.0, 2.0, "%.4f")
                if fy then char.flashlight.y = fvy end

                local fz, fvz = imgui.drag_float("Z##fl" .. char.name, fl.z, 0.001, -2.0, 2.0, "%.4f")
                if fz then char.flashlight.z = fvz end

                if imgui.button("Reset Flashlight##" .. char.name) then
                    fl.x = fl.default_x
                    fl.y = fl.default_y
                    fl.z = fl.default_z
                end

                imgui.end_disabled()

                imgui.separator()

                if imgui.button("Save Config##" .. char.name) then
                    save_config(char)
                end
                imgui.same_line()
                if imgui.button("Reload Config##" .. char.name) then
                    load_config(char)
                    char.initialized = false
                    char.arm_states = {}
                    char.flashlight.root_joint = nil
                    last_check = -999
                end

                imgui.tree_pop()
            end
            imgui.pop_id()
        end
    end
end)

log.info("[Weapon Position Fix] Loaded.")